# ── CNPG(PostgreSQL) 백업 저장소: 베이스 백업 + WAL 아카이브 ──
resource "aws_s3_bucket" "cnpg_backup" {
  bucket = "elderberry-cnpg-backup-${data.aws_caller_identity.current.account_id}"

  tags = {
    Purpose = "cnpg-backup"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "cnpg_backup" {
  bucket = aws_s3_bucket.cnpg_backup.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "cnpg_backup" {
  bucket = aws_s3_bucket.cnpg_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cnpg_backup" {
  bucket = aws_s3_bucket.cnpg_backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cnpg_backup" {
  bucket = aws_s3_bucket.cnpg_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 보존 기간은 CNPG가 직접 관리 → 여기서는 "지워진 파일의 안전망"만 짧게 유지
resource "aws_s3_bucket_lifecycle_configuration" "cnpg_backup" {
  bucket = aws_s3_bucket.cnpg_backup.id

  rule {
    id     = "cleanup-noncurrent"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.cnpg_backup]
}

data "aws_iam_policy_document" "cnpg_backup_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.cnpg_backup.arn,
      "${aws_s3_bucket.cnpg_backup.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cnpg_backup" {
  bucket = aws_s3_bucket.cnpg_backup.id
  policy = data.aws_iam_policy_document.cnpg_backup_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.cnpg_backup]
}