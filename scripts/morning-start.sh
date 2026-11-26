#!/usr/bin/env bash
# 매일 아침 실행 (WBS 3.11): 노드를 2대로 올리고 DB 동면을 해제
# 순서가 중요: 노드 → CNPG 오퍼레이터·플러그인 준비 → 동면 해제 → DB → 쿠폰 앱
#   (오퍼레이터 웹훅이 준비되기 전에 동면 해제를 시도하면 거부됨, 11/24 원인)
set -euo pipefail

CLUSTER_NAME="elderberry-eks"
REGION="ap-northeast-2"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ONPREM_STATUS_URL="https://onprem.elderberry-coupon.com/api/coupons/status"

echo "[0/5] 사이트 전환 상태 확인 (온프렘이 Primary면 AWS를 켜지 않음 → split-brain 방지)"
if [ "${FORCE_START:-0}" = "1" ]; then
  echo "  FORCE_START=1 → 검사 건너뜀 (복귀 절차 중에만 사용)"
else
  ONPREM=$(curl -s --max-time 10 "$ONPREM_STATUS_URL" || true)
  if echo "$ONPREM" | grep -q '"db_role":"primary"'; then
    echo "중지: 온프렘 DB가 Primary입니다 (사이트 전환 상태)." >&2
    echo "  지금 AWS를 켜면 Primary가 2개가 됩니다. 복귀(failback) 절차를 따르세요." >&2
    echo "  복귀 절차 중이라면: FORCE_START=1 bash scripts/morning-start.sh" >&2
    exit 1
  elif [ -z "$ONPREM" ]; then
    echo "  경고: 온프렘 상태 응답 없음 → 전환 여부를 확인할 수 없어 계속 진행"
  else
    echo "  온프렘은 Replica → 평소 상태, 계속 진행"
  fi
fi

echo "[1/5] 노드 그룹 2대로"
NODEGROUP=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --query "nodegroups[0]" --output text)
aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$REGION" \
  --scaling-config minSize=0,maxSize=2,desiredSize=2 >/dev/null
aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$REGION"

echo "[2/5] kubeconfig 갱신 후 노드 2대 Ready 대기 (최대 10분)"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
READY=0
for i in $(seq 1 40); do
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
  if [ "$READY" -ge 2 ]; then break; fi
  echo "  Ready 노드 ${READY}/2, 15초 뒤 다시 확인 ($i/40)"
  sleep 15
done
if [ "$READY" -lt 2 ]; then
  echo "오류: 10분이 지나도 노드 2대가 Ready가 아닙니다. kubectl get nodes 확인" >&2
  exit 1
fi
kubectl get nodes -L topology.kubernetes.io/zone

echo "[3/5] CNPG 오퍼레이터·Barman 플러그인 준비 대기 (동면 해제 요청을 받을 웹훅)"
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg --timeout=5m
kubectl -n cnpg-system rollout status deploy/plugin-barman-cloud --timeout=5m

echo "[3-1/5] Karpenter 준비 + NodePool 다시 적용 (night-stop에서 지웠음)"
kubectl -n kube-system rollout status deploy/karpenter --timeout=5m
kubectl apply -f "$REPO_DIR/k8s/karpenter/nodepool.yaml"

echo "[4/5] DB 동면 해제"
# 웹훅이 막 준비된 직후에는 한두 번 거부될 수 있어서 다시 시도 (최대 1분)
for i in $(seq 1 12); do
  if kubectl annotate cluster coupon-db -n database cnpg.io/hibernation=off --overwrite 2>/dev/null; then break; fi
  if [ "$i" -eq 12 ]; then
    echo "오류: 동면 해제 요청이 1분 동안 거부됐습니다. kubectl get pods -n cnpg-system 확인" >&2
    exit 1
  fi
  echo "  웹훅 대기 중, 5초 뒤 다시 시도 ($i/12)"
  sleep 5
done
kubectl wait --for=condition=Ready cluster/coupon-db -n database --timeout=10m

echo "[5/5] 상태 확인"
kubectl get cluster -n database coupon-db
# 쿠폰 앱은 DB가 깨어나야 준비 상태가 됨
kubectl -n coupon rollout status deploy/coupon --timeout=5m
kubectl get pods -n tailscale

echo "완료"
