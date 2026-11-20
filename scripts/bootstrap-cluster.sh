#!/usr/bin/env bash
# 매일 아침 daily/ apply 뒤에 실행: 클러스터 안의 구성 요소(DB 등)를 다시 설치
set -euo pipefail

CLUSTER_NAME="elderberry-eks"
REGION="ap-northeast-2"

# 버전 고정 (helm list -A의 CHART 번호, 2026-11-20 확인)
CERT_MANAGER_VERSION="v1.21.3"
CNPG_CHART_VERSION="0.29.2"          # CNPG 1.30.2
BARMAN_PLUGIN_CHART_VERSION="0.9.0"  # 플러그인 v0.16.0

# 이 스크립트가 어디서 실행돼도 저장소 기준 경로를 찾게 함
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[1/6] kubeconfig 갱신"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "[2/6] Helm 저장소 등록"
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update

echo "[3/6] cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "$CERT_MANAGER_VERSION" \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait

echo "[4/6] CNPG 오퍼레이터 + Barman Cloud 플러그인"
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --version "$CNPG_CHART_VERSION" \
  --namespace cnpg-system --create-namespace --wait
helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud \
  --version "$BARMAN_PLUGIN_CHART_VERSION" \
  --namespace cnpg-system --wait
kubectl -n cnpg-system rollout status deploy/plugin-barman-cloud

echo "[5/6] 어제 WAL 비우기 (새 DB는 빈 백업 위치가 필요)"
BUCKET="elderberry-cnpg-backup-$(aws sts get-caller-identity --query Account --output text)"
aws s3 rm "s3://$BUCKET/aws/coupon-db/" --recursive --quiet

echo "[6/6] DB 클러스터"
kubectl apply -f "$REPO_DIR/k8s/database/00-namespace-storage.yaml"
sed "s|BACKUP_BUCKET|$BUCKET|" "$REPO_DIR/k8s/database/10-objectstore.yaml" | kubectl apply -f -
kubectl apply -f "$REPO_DIR/k8s/database/20-cluster.yaml"
kubectl wait --for=condition=Ready cluster/coupon-db -n database --timeout=10m
kubectl get cluster -n database coupon-db

echo "완료"