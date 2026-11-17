module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.8.0"

  name = "${local.name}-vpc"
  cidr = "10.10.0.0/16"
  azs  = local.azs

  private_subnets = ["10.10.0.0/20", "10.10.16.0/20"]
  public_subnets  = ["10.10.128.0/24", "10.10.129.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.ap-northeast-2.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name = "${local.name}-s3-endpoint"
  }
}