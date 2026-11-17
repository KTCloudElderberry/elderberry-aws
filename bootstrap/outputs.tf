output "tfstate_bucket_name" {
  description = "Terraform 상태 파일을 저장하는 S3 버킷 이름"
  value       = aws_s3_bucket.tfstate.bucket
}