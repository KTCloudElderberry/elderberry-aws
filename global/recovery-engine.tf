# ── 복구 엔진(KT Control VM) 전용 IAM 사용자 ──
# 할 수 있는 권한 : 1.EKS·EC2·ALB 상태 조회 2. 노드 그룹 크기 변경(fencing)
# 조건: KT 공인 IP에서만 사용 가능
# 액세스 키는 Terraform으로 만들지 않음 (비밀 키가 상태 파일에 남지 않게 CLI로 발급)

variable "recovery_engine_source_cidrs" {
  description = "Source IPs allowed to use the recovery engine key (KT egress IP)"
  type        = list(string)
}

data "aws_caller_identity" "recovery" {}

resource "aws_iam_user" "recovery_engine" {
  name = "elderberry-recovery-engine"
}

resource "aws_iam_user_policy" "recovery_engine" {
  name = "recovery-engine-least-privilege"
  user = aws_iam_user.recovery_engine.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadStatus"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListNodegroups",
          "eks:DescribeNodegroup",
          "ec2:DescribeInstances",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
        ]
        Resource = "*"
        Condition = {
          IpAddress = { "aws:SourceIp" = var.recovery_engine_source_cidrs }
        }
      },
      {
        Sid      = "FenceNodegroup"
        Effect   = "Allow"
        Action   = ["eks:UpdateNodegroupConfig"]
        Resource = "arn:aws:eks:ap-northeast-2:${data.aws_caller_identity.recovery.account_id}:nodegroup/elderberry-eks/default*/*"
        Condition = {
          IpAddress = { "aws:SourceIp" = var.recovery_engine_source_cidrs }
        }
      },
    ]
  })
}