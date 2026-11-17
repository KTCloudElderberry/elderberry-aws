output "gha_plan_role_arn" {
  description = "GitHub Actions가 plan 할 때 빌리는 IAM 역할 ARN"
  value       = aws_iam_role.gha_plan.arn
}