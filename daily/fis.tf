# ── AWS FIS: 장애를 같은 조건으로 반복해서 일으키는 실험 템플릿 ──
# 방식: 대상 서브넷에 "모든 통신 거부" 네트워크 ACL을 잠시 붙였다가 시간이 지나면 원래대로 되돌림
# 실행: aws fis start-experiment --experiment-template-id <ID>   (중지: aws fis stop-experiment --id <실험 ID>)

# FIS가 실험할 때 쓰는 역할 (네트워크 ACL을 잠시 바꾸는 권한만)
resource "aws_iam_role" "fis" {
  name = "${local.name}-fis"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "fis.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fis_network" {
  role       = aws_iam_role.fis.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorNetworkAccess"
}

# 실험 1: AZ a 장애 (5분) → AWS 안에서 버티는지 (DB 승격, 사이트 전환 없음)
resource "aws_fis_experiment_template" "az_a_outage" {
  description = "Isolate private subnet in AZ a for 5 minutes"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "disrupt-az-a"
    action_id = "aws:network:disrupt-connectivity"

    parameter {
      key   = "duration"
      value = "PT5M"
    }
    parameter {
      key   = "scope"
      value = "all"
    }

    target {
      key   = "Subnets"
      value = "private-az-a"
    }
  }

  target {
    name           = "private-az-a"
    resource_type  = "aws:ec2:subnet"
    selection_mode = "ALL"
    resource_arns  = [module.vpc.private_subnet_arns[0]]
  }

  tags = {
    Name = "${local.name}-az-a-outage"
  }
}

# 실험 2: AWS 사이트 장애 (10분) → 진단·fencing·온프렘 승격·Cloudflare 전환 (S4)
resource "aws_fis_experiment_template" "site_outage" {
  description = "Isolate all private subnets (AZ a and c) for 10 minutes"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "disrupt-all-private"
    action_id = "aws:network:disrupt-connectivity"

    parameter {
      key   = "duration"
      value = "PT10M"
    }
    parameter {
      key   = "scope"
      value = "all"
    }

    target {
      key   = "Subnets"
      value = "private-all"
    }
  }

  target {
    name           = "private-all"
    resource_type  = "aws:ec2:subnet"
    selection_mode = "ALL"
    resource_arns  = module.vpc.private_subnet_arns
  }

  tags = {
    Name = "${local.name}-site-outage"
  }
}

# FIS가 대상(서브넷)을 찾을 때 쓰는 태그 조회 권한
# 관리형 NetworkAccess 정책에 없어서 실험이 "Error resolving targets"로 실패함 (11/27)
resource "aws_iam_role_policy" "fis_resolve_targets" {
  name = "resolve-targets"
  role = aws_iam_role.fis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["tag:GetResources"]
      Resource = "*"
    }]
  })
}