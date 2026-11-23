#!/usr/bin/env bash
# 클러스터를 새로 만든 뒤(destroy → apply) 실행: 클러스터 안의 구성 요소(DB 등)를 다시 설치
# 평소 밤/아침에는 night-stop.sh / morning-start.sh만 사용 (이 스크립트는 필요 없음)
# 이미 있는 것은 건너뜀 → 실수로 다시 실행해도 S3 백업과 DB가 안전
# Tailscale 오퍼레이터가 없을 때만 OAuth 값이 필요 (Git·채팅에 붙이지 말 것):
#   export TS_OAUTH_CLIENT_ID=...
#   read -rs TS_OAUTH_CLIENT_SECRET && export TS_OAUTH_CLIENT_SECRET
set -euo pipefail

CLUSTER_NAME="elderberry-eks"
REGION="ap-northeast-2"

# 버전 고정 (helm list -A의 CHART 번호)
CERT_MANAGER_VERSION="v1.21.3"                # 2026-11-20 확인
CNPG_CHART_VERSION="0.29.2"                   # CNPG 1.30.2
BARMAN_PLUGIN_CHART_VERSION="0.9.0"           # 플러그인 v0.16.0
TAILSCALE_OPERATOR_CHART_VERSION="1.104.7"    # 2026-11-23 확인

# 이 스크립트가 어디서 실행돼도 저장소 기준 경로를 찾게 함
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[1/7] kubeconfig 갱신"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "[2/7] Helm 저장소 등록"
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update
helm repo add tailscale https://pkgs.tailscale.com/helmcharts --force-update

echo "[3/7] cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "$CERT_MANAGER_VERSION" \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait

echo "[4/7] CNPG 오퍼레이터 + Barman Cloud 플러그인"
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --version "$CNPG_CHART_VERSION" \
  --namespace cnpg-system --create-namespace --wait
helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud \
  --version "$BARMAN_PLUGIN_CHART_VERSION" \
  --namespace cnpg-system --wait
kubectl -n cnpg-system rollout status deploy/plugin-barman-cloud

echo "[5/7] Tailscale 오퍼레이터 (이미 있으면 건너뜀)"
if helm status tailscale-operator -n tailscale >/dev/null 2>&1; then
  echo "  이미 설치됨 → 건너뜀"
else
  : "${TS_OAUTH_CLIENT_ID:?TS_OAUTH_CLIENT_ID를 먼저 export 하세요}"
  : "${TS_OAUTH_CLIENT_SECRET:?TS_OAUTH_CLIENT_SECRET를 먼저 export 하세요}"
  helm upgrade --install tailscale-operator tailscale/tailscale-operator \
    --version "$TAILSCALE_OPERATOR_CHART_VERSION" \
    --namespace tailscale --create-namespace \
    --set-string oauth.clientId="$TS_OAUTH_CLIENT_ID" \
    --set-string oauth.clientSecret="$TS_OAUTH_CLIENT_SECRET" \
    --wait
fi

echo "[6/7] DB 클러스터 (이미 있으면 건너뜀)"
if kubectl get cluster coupon-db -n database >/dev/null 2>&1; then
  echo "  coupon-db가 이미 있음 → S3 비우기와 DB 생성 건너뜀"
else
  # 새 DB는 빈 백업 위치가 필요 → 이전 WAL 비우기
  # 주의: 새 DB는 시스템 ID가 달라져서 온프렘 replica를 다시 만들어야 함
  BUCKET="elderberry-cnpg-backup-$(aws sts get-caller-identity --query Account --output text)"
  aws s3 rm "s3://$BUCKET/aws/coupon-db/" --recursive --quiet
  kubectl apply -f "$REPO_DIR/k8s/database/00-namespace-storage.yaml"
  sed "s|BACKUP_BUCKET|$BUCKET|" "$REPO_DIR/k8s/database/10-objectstore.yaml" | kubectl apply -f -
  kubectl apply -f "$REPO_DIR/k8s/database/20-cluster.yaml"
  kubectl wait --for=condition=Ready cluster/coupon-db -n database --timeout=10m
fi
kubectl get cluster -n database coupon-db

echo "[7/7] 온프렘이 DB에 닿는 Tailscale 입구"
kubectl apply -f "$REPO_DIR/k8s/database/30-tailscale-expose.yaml"
kubectl get svc -n database coupon-db-tailscale

echo "완료"