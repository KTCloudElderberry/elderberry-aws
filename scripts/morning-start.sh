#!/usr/bin/env bash
# 매일 아침 실행 (WBS 3.11): 노드를 2대로 올리고 DB 동면을 해제
set -euo pipefail

CLUSTER_NAME="elderberry-eks"
REGION="ap-northeast-2"

echo "[1/4] 노드 그룹 2대로"
NODEGROUP=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --query "nodegroups[0]" --output text)
aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$REGION" \
  --scaling-config minSize=0,maxSize=2,desiredSize=2 >/dev/null
aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$REGION"

echo "[2/4] kubeconfig 갱신 후 노드 2대 Ready 대기 (최대 10분)"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
for i in $(seq 1 40); do
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
  if [ "$READY" -ge 2 ]; then break; fi
  echo "  Ready 노드 ${READY}/2, 15초 뒤 다시 확인 ($i/40)"
  sleep 15
done
kubectl get nodes -L topology.kubernetes.io/zone

echo "[3/4] DB 동면 해제"
kubectl annotate cluster coupon-db -n database cnpg.io/hibernation=off --overwrite
kubectl wait --for=condition=Ready cluster/coupon-db -n database --timeout=10m

echo "[4/4] 상태 확인"
kubectl get cluster -n database coupon-db
kubectl get pods -n tailscale

echo "완료"