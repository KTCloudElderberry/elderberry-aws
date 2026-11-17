provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project   = "elderberry"
      ManagedBy = "terraform"
      Layer     = "global"
    }
  }
}

locals {
  github_org  = "KTCloudElderberry"
  github_repo = "elderberry-aws"

  tfstate_bucket = "elderberry-tfstate-${data.aws_caller_identity.current.account_id}"
}

data "aws_caller_identity" "current" {}

# ── 1) GitHub OIDC 공급자
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# ── 2) 신뢰 정책
data "aws_iam_policy_document" "gha_plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # 토큰의 대상(aud)이 AWS STS여야 함
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # 토큰을 받은 곳(sub)이 우리 저장소의 main 브랜치 또는 PR이어야 함
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.github_org}/${local.github_repo}:ref:refs/heads/main",
        "repo:${local.github_org}/${local.github_repo}:pull_request",
      ]
    }
  }
}

# ── 3) plan 전용 IAM 역할 ──
resource "aws_iam_role" "gha_plan" {
  name               = "elderberry-gha-terraform-plan"
  description        = "Read-only role for GitHub Actions to run terraform plan"
  assume_role_policy = data.aws_iam_policy_document.gha_plan_trust.json
}

# ── 4) 읽기 권한: AWS 관리형 ReadOnlyAccess 붙이기 ──
resource "aws_iam_role_policy_attachment" "gha_plan_readonly" {
  role       = aws_iam_role.gha_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ── 5) 잠금 파일 권한: plan 중 .tflock 만들고 지우기 ──
data "aws_iam_policy_document" "gha_plan_lock" {
  statement {
    sid       = "TerraformStateLock"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.tfstate_bucket}/*.tflock"]
  }
}

resource "aws_iam_role_policy" "gha_plan_lock" {
  name   = "terraform-state-lock"
  role   = aws_iam_role.gha_plan.id
  policy = data.aws_iam_policy_document.gha_plan_lock.json
}