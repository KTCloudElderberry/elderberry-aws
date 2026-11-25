#!/usr/bin/env bash
# daily/ destroy 전에 실행: Terraform이 모르는 리소스(Tailscale 기기, EBS)를 먼저 정리
# 평소 밤에는 night-stop.sh만 사용 (이 스크립트는 destroy할 때만)
set -euo pipefail

CLUSTER_NAME="elderberry-eks"
REGION="ap-northeast-2"

echo "[1/3] kubeconfig 갱신"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "[2/3] Karpenter 노드 → ALB → Tailscale 입구 → DB 클러스터 → 디스크 요청(PVC) 순서로 삭제"
# Karpenter가 만든 EC2·인스턴스 프로필은 Terraform이 모름 → 컨트롤러가 살아 있을 때 먼저 정리
#   (인스턴스 프로필이 남으면 노드 IAM 역할을 지우지 못해 destroy 실패)
kubectl delete nodepool --all --ignore-not-found --wait=true --timeout=10m
kubectl delete ec2nodeclass --all --ignore-not-found --wait=true --timeout=5m
# Argo CD(selfHeal)가 Ingress를 다시 만들지 못하게 coupon 쓰기 권한부터 회수 (읽기는 남음)
kubectl delete rolebinding argocd-manager -n coupon --ignore-not-found
# LBC가 ALB·보안 그룹을 지울 때까지 기다림 (남기면 VPC destroy 실패 + 요금 계속)
kubectl delete ingress coupon -n coupon --ignore-not-found --wait=true
# 오퍼레이터가 Tailnet의 aws-coupon-db 기기를 지울 때까지 기다림 (Service의 finalizer)
kubectl delete svc coupon-db-tailscale -n database --ignore-not-found --wait=true
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