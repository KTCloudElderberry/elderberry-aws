#!/usr/bin/env bash
# 매일 저녁 daily/ destroy 전에 실행: Terraform이 모르는 AWS 리소스(EBS)를 먼저 정리
set -euo pipefail

CLUSTER_NAME="elderberry-eks"
REGION="ap-northeast-2"

echo "[1/3] kubeconfig 갱신"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "[2/3] DB 클러스터와 디스크 요청(PVC) 삭제 → EBS CSI가 EBS를 지움"
kubectl delete cluster coupon-db -n database --ignore-not-found --wait=true
kubectl delete pvc -n database --all --wait=true

echo "[3/3] EBS가 실제로 지워질 때까지 대기 (최대 3분)"
for i in $(seq 1 18); do
  LEFT=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
    --query "length(Volumes)" --output text)
  if [ "$LEFT" = "0" ]; then
    echo "남은 EBS 없음. 이제 terraform destroy를 실행하세요."
    exit 0
  fi
  echo "남은 EBS ${LEFT}개, 10초 뒤 다시 확인 ($i/18)"
  sleep 10
done

echo "경고: EBS가 아직 남아 있습니다. destroy 전에 콘솔에서 확인하세요." >&2
exit 1