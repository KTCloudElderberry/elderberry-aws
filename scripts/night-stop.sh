#!/usr/bin/env bash
# 매일 저녁 실행 (WBS 3.11): destroy 대신 DB를 동면시키고 노드를 0대로 내림
# - DB 디스크(EBS), 인증서, Tailscale 프록시 신분은 그대로 남아서 아침에 같은 상태로 돌아옴
set -euo pipefail

CLUSTER_NAME="elderberry-eks"
REGION="ap-northeast-2"

echo "[1/4] kubeconfig 갱신"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "[2/4] DB 동면 (Pod를 정상 종료, 디스크는 유지)"
kubectl annotate cluster coupon-db -n database cnpg.io/hibernation=on --overwrite
kubectl wait --for=condition=cnpg.io/hibernation cluster/coupon-db -n database --timeout=5m
kubectl wait --for=delete pod -l cnpg.io/cluster=coupon-db -n database --timeout=5m

echo "[3/4] 노드 그룹 0대로"
NODEGROUP=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --query "nodegroups[0]" --output text)
aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$REGION" \
  --scaling-config minSize=0,maxSize=2,desiredSize=0 >/dev/null

echo "[4/4] 변경 완료 대기 (노드가 실제로 사라지기까지 몇 분 걸릴 수 있음)"
aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$REGION"
aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$REGION" \
  --query "nodegroup.scalingConfig" --output table

echo "완료: 노드 0대. 아침에 scripts/morning-start.sh 실행"