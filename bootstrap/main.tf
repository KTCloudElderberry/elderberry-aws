provider "aws" {
  region = "ap-northeast-2"

  # 이 코드로 만드는 모든 리소스에 자동으로 붙는 태그
  default_tags {
    tags = {
      Project   = "elderberry"
      ManagedBy = "terraform"
      Layer     = "bootstrap"
    }
  }
}

# ── 지금 로그인한 계정 정보 읽기 ──
data "aws_caller_identity" "current" {}

# ── 1) 상태 파일을 담을 S3 버킷 ──
resource "aws_s3_bucket" "tfstate" {
  bucket = "elderberry-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

# ── 2) 버킷 주인이 모든 파일의 주인이 되도록 (ACL 끄기) ──
resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ── 3) 외부 공개 완전히 차단 ──
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── 4) 버전 관리: 상태 파일이 망가져도 이전 버전으로 되돌리기 ──
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ── 5) 저장할 때 자동 암호화 ──
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── 6) 오래된 버전 자동 정리 ──
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "cleanup-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.tfstate]
}

# ── 7) 암호화되지 않은 연결(HTTP)은 거부하는 정책 내용 ──
data "aws_iam_policy_document" "tfstate_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# ── 8) 위 정책을 버킷에 붙이기 ──
resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}