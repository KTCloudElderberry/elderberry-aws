#!/usr/bin/env bash
# 클러스터를 새로 만든 뒤(destroy → apply) 실행: 클러스터 안의 구성 요소를 다시 설치
# 평소 밤/아침에는 night-stop.sh / morning-start.sh만 사용 (이 스크립트는 필요 없음)
# 이미 있는 것은 건너뜀 → 실수로 다시 실행해도 S3 백업과 DB가 안전
#
# 필요한 환경변수 (해당 항목을 처음 만들 때만. Git·채팅에 붙이지 말 것, 입력: read -rs 변수 && export 변수)
#   TS_OAUTH_CLIENT_ID, TS_OAUTH_CLIENT_SECRET  Tailscale 오퍼레이터
#   GH_USER, GHCR_TOKEN                         쿠폰 앱 이미지(GHCR, read:packages) 내려받기
#   CLOUDFLARE_API_TOKEN                        aws. DNS 레코드를 새 ALB 주소로 갱신 (없으면 확인만 건너뜀)
# 쿠폰 앱 매니페스트는 팀 GitOps 저장소에서 읽음: GITOPS_DIR (기본 ~/projects/elderberry-gitops)
set -euo pipefail

CLUSTER_NAME="elderberry-eks"
REGION="ap-northeast-2"
DOMAIN="elderberry-coupon.com"
GITOPS_DIR="${GITOPS_DIR:-$HOME/projects/elderberry-gitops}"

# 버전 고정 (helm list -A의 CHART 번호)
CERT_MANAGER_VERSION="v1.21.3"                # 2026-11-20 확인
CNPG_CHART_VERSION="0.29.2"                   # CNPG 1.30.2
BARMAN_PLUGIN_CHART_VERSION="0.9.0"           # 플러그인 v0.16.0
TAILSCALE_OPERATOR_CHART_VERSION="1.104.7"    # 2026-11-23 확인
LBC_CHART_VERSION="3.6.3"                     # 2026-11-24 확인
NODE_EXPORTER_CHART_VERSION="6.0.0"           # 2026-11-23 확인
KSM_CHART_VERSION="9.1.0"                     # 2026-11-23 확인
KARPENTER_CHART_VERSION="1.15.1"              # 2026-11-26 확인 (EKS 1.36은 1.13 이상 필요)
DESCHEDULER_CHART_VERSION="0.36.0"            # 2026-11-26 확인 (EKS 1.36용)

# 이 스크립트가 어디서 실행돼도 저장소 기준 경로를 찾게 함
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[1/10] kubeconfig 갱신"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "[2/10] Helm 저장소 등록"
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update
helm repo add tailscale https://pkgs.tailscale.com/helmcharts --force-update
helm repo add eks https://aws.github.io/eks-charts --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update

echo "[3/10] cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "$CERT_MANAGER_VERSION" \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait

echo "[4/10] CNPG 오퍼레이터 + Barman Cloud 플러그인"
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --version "$CNPG_CHART_VERSION" \
  --namespace cnpg-system --create-namespace -f "$REPO_DIR/k8s/cnpg/operator-values.yaml" --wait
helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud \
  --version "$BARMAN_PLUGIN_CHART_VERSION" \
  --namespace cnpg-system -f "$REPO_DIR/k8s/cnpg/barman-plugin-values.yaml" --wait
kubectl -n cnpg-system rollout status deploy/plugin-barman-cloud

echo "[5/10] AWS Load Balancer Controller (권한은 daily/eks.tf의 Pod Identity)"
# 리전·VPC를 직접 지정 → 노드 메타데이터(IMDS) 조회에 의존하지 않음
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query "cluster.resourcesVpcConfig.vpcId" --output text)
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version "$LBC_CHART_VERSION" \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" --wait

echo "[5-1/10] Karpenter (권한·큐는 daily/karpenter.tf) + NodePool"
# 큐 이름은 Terraform 모듈 기본 규칙: Karpenter-<클러스터 이름>
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "$KARPENTER_CHART_VERSION" \
  --namespace kube-system \
  --set settings.clusterName="$CLUSTER_NAME" \
  --set settings.interruptionQueue="Karpenter-$CLUSTER_NAME" \
  --set serviceAccount.name=karpenter --wait
kubectl apply -f "$REPO_DIR/k8s/karpenter/nodepool.yaml"

echo "[5-2/10] Descheduler (HPA 축소 뒤 AZ에 치우친 쿠폰 Pod를 2분마다 재배치)"
helm repo add descheduler https://kubernetes-sigs.github.io/descheduler/ --force-update
helm upgrade --install descheduler descheduler/descheduler \
  --version "$DESCHEDULER_CHART_VERSION" \
  --namespace kube-system \
  -f "$REPO_DIR/k8s/descheduler/values.yaml"

echo "[6/10] Tailscale 오퍼레이터 (이미 있으면 건너뜀)"
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

echo "[7/10] DB 클러스터 (이미 있으면 건너뜀)"
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

echo "[8/10] 온프렘이 DB에 닿는 Tailscale 입구"
kubectl apply -f "$REPO_DIR/k8s/database/30-tailscale-expose.yaml"
kubectl get svc -n database coupon-db-tailscale

echo "[9/10] 모니터링 (node-exporter, kube-state-metrics, 노드별 Agent → kt)"
helm upgrade --install node-exporter prometheus-community/prometheus-node-exporter \
  --version "$NODE_EXPORTER_CHART_VERSION" --namespace monitoring --create-namespace --wait
helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --version "$KSM_CHART_VERSION" --namespace monitoring --wait
kubectl apply -f "$REPO_DIR/k8s/monitoring/prometheus-agent.yaml"
kubectl rollout status ds/prometheus-agent -n monitoring

echo "[10/10] 쿠폰 앱 준비 (Secret 2개 → Argo CD 출입증 → Argo CD 배포 대기 → aws. DNS)"
# 쿠폰 앱 자체는 KT Argo CD가 배포 (elderberry-gitops/argocd/coupon-aws.yaml). 여기서는 Git에 없는 것만 준비
kubectl create namespace coupon --dry-run=client -o yaml | kubectl apply -f -
# DB 접속 정보: database → coupon 네임스페이스로 매번 새로 복사 (DB를 다시 만들어 비밀번호가 바뀌어도 맞춰짐)
kubectl create secret generic coupon-db-app -n coupon \
  --from-literal=uri="$(kubectl get secret coupon-db-app -n database -o jsonpath='{.data.uri}' | base64 -d)" \
  --dry-run=client -o yaml | kubectl apply -f -
# GHCR 비공개 이미지 출입증 (이미 있으면 건너뜀)
if kubectl get secret ghcr-pull -n coupon >/dev/null 2>&1; then
  echo "  ghcr-pull 이미 있음 → 건너뜀"
else
  : "${GH_USER:?GH_USER(깃허브 아이디)를 먼저 export 하세요}"
  : "${GHCR_TOKEN:?GHCR_TOKEN(read:packages)을 먼저 export 하세요}"
  kubectl create secret docker-registry ghcr-pull -n coupon \
    --docker-server=ghcr.io --docker-username="$GH_USER" --docker-password="$GHCR_TOKEN"
fi
# KT Argo CD 출입증 (읽기 전체, 쓰기 coupon만)
kubectl apply -f "$REPO_DIR/k8s/argocd/eks-access.yaml"

# 쿠폰 앱이 없으면 = 새 클러스터 → EKS 주소·CA·토큰이 바뀌어 Argo CD 등록을 다시 해야 함
if kubectl get deploy coupon -n coupon >/dev/null 2>&1; then
  echo "  쿠폰 앱 있음 → Argo CD 연결 정상, 등록 파일 생성 건너뜀"
else
  ARGO_TOKEN=""
  for i in $(seq 1 12); do
    ARGO_TOKEN=$(kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    if [ -n "$ARGO_TOKEN" ]; then break; fi
    sleep 5
  done
  EKS_SERVER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query "cluster.endpoint" --output text)
  EKS_CA=$(kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.ca\.crt}')
  ARGO_FILE="$HOME/argocd-cluster-aws.yaml"
  cat > "$ARGO_FILE" <<ARGOEOF
# KT Argo CD에 EKS 클러스터 등록 (적용: kubectl apply -f argocd-cluster-aws.yaml -n argocd)
# 토큰이 들어 있음: DM으로만 전달하고, 적용 후 파일 삭제
apiVersion: v1
kind: Secret
metadata:
  name: cluster-aws
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: aws
  server: ${EKS_SERVER}
  config: |
    {
      "bearerToken": "${ARGO_TOKEN}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${EKS_CA}"
      }
    }
ARGOEOF
  chmod 600 "$ARGO_FILE"
  unset ARGO_TOKEN EKS_CA
  echo "  ★ 새 클러스터: $ARGO_FILE 을 경현님께 DM으로 전달하세요 (KT에서 kubectl apply -f ... -n argocd, 적용 후 삭제)"
  echo "  ★ Argo CD가 쿠폰 앱을 배포할 때까지 아래에서 최대 20분 기다립니다"
fi

# Argo CD 배포 → LBC가 ALB 생성할 때까지 대기 (최대 20분)
ALB_DNS=""
for i in $(seq 1 120); do
  ALB_DNS=$(kubectl get ingress coupon -n coupon -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$ALB_DNS" ]; then break; fi
  if [ $((i % 6)) -eq 0 ]; then echo "  ALB 주소 대기 중 ($((i / 6))/20분)"; fi
  sleep 10
done
if [ -z "$ALB_DNS" ]; then
  echo "오류: 20분 안에 ALB가 생기지 않았습니다. Argo CD에서 coupon-aws 상태와 kubectl describe ingress coupon -n coupon 확인" >&2
  exit 1
fi
echo "  ALB: $ALB_DNS"

# aws. 레코드가 새 ALB를 가리키게 함 (메인 주소는 aws.를 가리키므로 따로 바꿀 필요 없음)
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "  CLOUDFLARE_API_TOKEN 없음 → DNS 확인 건너뜀. aws.$DOMAIN 이 위 ALB를 가리키는지 직접 확인하세요"
else
  CF_API="https://api.cloudflare.com/client/v4"
  CF_AUTH="Authorization: Bearer $CLOUDFLARE_API_TOKEN"
  ZONE_ID=$(curl -s "$CF_API/zones?name=$DOMAIN" -H "$CF_AUTH" | grep -o '"id":"[a-f0-9]\{32\}"' | head -1 | cut -d'"' -f4)
  RECORD=$(curl -s "$CF_API/zones/$ZONE_ID/dns_records?type=CNAME&name=aws.$DOMAIN" -H "$CF_AUTH")
  RECORD_ID=$(echo "$RECORD" | grep -o '"id":"[a-f0-9]\{32\}"' | head -1 | cut -d'"' -f4 || true)
  CURRENT=$(echo "$RECORD" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  if [ "$CURRENT" = "$ALB_DNS" ]; then
    echo "  aws.$DOMAIN 이미 최신 → 건너뜀"
  elif [ -n "$RECORD_ID" ]; then
    curl -s -X PATCH "$CF_API/zones/$ZONE_ID/dns_records/$RECORD_ID" -H "$CF_AUTH" -H "Content-Type: application/json" \
      --data "{\"content\":\"$ALB_DNS\"}" | grep -o '"success":[a-z]*'
    echo "  aws.$DOMAIN → 새 ALB로 갱신"
  else
    curl -s -X POST "$CF_API/zones/$ZONE_ID/dns_records" -H "$CF_AUTH" -H "Content-Type: application/json" \
      --data "{\"type\":\"CNAME\",\"name\":\"aws\",\"content\":\"$ALB_DNS\",\"proxied\":true,\"ttl\":1,\"comment\":\"B-7 AWS ALB (coupon)\"}" | grep -o '"success":[a-z]*'
    echo "  aws.$DOMAIN 새로 생성"
  fi
fi

echo "완료"
