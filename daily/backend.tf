terraform {
  backend "s3" {
    # bucket 은 backend.s3.tfbackend 파일에서 넣습니다 (Git에 안 올림)
    key          = "daily/terraform.tfstate" # global과 다른 경로
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}