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