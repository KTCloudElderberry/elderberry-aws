provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project   = "elderberry"
      ManagedBy = "terraform"
      Layer     = "daily"
    }
  }
}

locals {
  name = "elderberry"
  azs  = ["ap-northeast-2a", "ap-northeast-2c"]
}