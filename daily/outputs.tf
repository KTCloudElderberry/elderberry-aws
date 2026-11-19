output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID (EKS 노드용)"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID (NAT·ALB용)"
  value       = module.vpc.public_subnets
}

output "tailscale_router_instance_id" {
  description = "Tailscale 라우터 EC2 ID (Session Manager 접속용)"
  value       = aws_instance.tailscale_router.id
}

output "eks_cluster_name" {
  description = "EKS 클러스터 이름 (kubeconfig 설정용)"
  value       = module.eks.cluster_name
}