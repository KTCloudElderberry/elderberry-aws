terraform {
  backend "s3" {
    # bucket 은 backend.s3.tfbackend 파일에서 넣습니다 (Git에 안 올림)
    key          = "global/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}