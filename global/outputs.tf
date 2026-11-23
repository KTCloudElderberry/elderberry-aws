output "gha_plan_role_arn" {
  description = "GitHub Actions가 plan 할 때 빌리는 IAM 역할 ARN"
  value       = aws_iam_role.gha_plan.arn
}

output "acm_certificate_arn" {
  description = "ALB에 붙일 인증서 (B-7)"
  value       = aws_acm_certificate_validation.main.certificate_arn
}
