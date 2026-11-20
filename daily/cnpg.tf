# ── CNPG(PostgreSQL) 이름 규칙 ──
# 매니페스트(B-6-3)도 이 이름을 그대로 써요
locals {
  cnpg_namespace     = "database"
  cnpg_cluster_name  = "coupon-db"
  cnpg_backup_bucket = "${local.name}-cnpg-backup-${data.aws_caller_identity.current.account_id}"
}

# ── CNPG 백업(S3)용 IAM 권한 (Pod Identity) ──
# CNPG는 DB Pod를 클러스터 이름과 같은 서비스 계정으로 실행해요
# → 그 계정에 global/ 층에서 만든 백업 버킷 읽기·쓰기 권한만 줘요
module "cnpg_backup_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.11.0"

  name = "${local.name}-cnpg-backup"

  attach_custom_policy = true
  policy_statements = [
    {
      sid       = "ListBackupBucket"
      actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
      resources = ["arn:aws:s3:::${local.cnpg_backup_bucket}"]
    },
    {
      sid       = "ReadWriteBackupObjects"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["arn:aws:s3:::${local.cnpg_backup_bucket}/*"]
    }
  ]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = local.cnpg_namespace
      service_account = local.cnpg_cluster_name
    }
  }
}