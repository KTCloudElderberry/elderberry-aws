variable "tailscale_remote_cidrs" {
  description = "AWS에서 Tailscale 라우터를 거쳐 보낼 원격 대역. 100.64.0.0/10 = tailnet 기기 주소 (KT Monitoring 등)"
  type        = list(string)
  default     = ["100.64.0.0/10"]
}

locals {
  tailscale_name          = "${local.name}-tailscale-router"
  tailscale_authkey_param = "/elderberry/tailscale/authkey"

  # 라우터를 AZ마다 1대씩. 키는 AZ 이름의 끝 글자 (a, c)
  tailscale_routers = {
    for i, az in local.azs : substr(az, -1, 1) => {
      az_index  = i
      subnet_id = module.vpc.public_subnets[i]
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# ── 보안 그룹: 인터넷 인바운드 없음, VPC 안에서 오는 것만 ──
resource "aws_security_group" "tailscale_router" {
  name        = local.tailscale_name
  description = "Tailscale subnet router"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = local.tailscale_name
  }
}

resource "aws_vpc_security_group_ingress_rule" "tailscale_from_vpc" {
  security_group_id = aws_security_group.tailscale_router.id
  description       = "From VPC to forward to remote sites"
  cidr_ipv4         = module.vpc.vpc_cidr_block
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "tailscale_all" {
  security_group_id = aws_security_group.tailscale_router.id
  description       = "Outbound for Tailscale, package install, SSM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ── IAM 역할: Session Manager 접속 + 인증 키 읽기만 ──
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "tailscale_router" {
  name               = local.tailscale_name
  description        = "Tailscale subnet router on EC2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "tailscale_ssm_core" {
  role       = aws_iam_role.tailscale_router.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "tailscale_authkey_read" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter${local.tailscale_authkey_param}"]
  }
}

resource "aws_iam_role_policy" "tailscale_authkey_read" {
  name   = "read-tailscale-authkey"
  role   = aws_iam_role.tailscale_router.id
  policy = data.aws_iam_policy_document.tailscale_authkey_read.json
}

resource "aws_iam_instance_profile" "tailscale_router" {
  name = local.tailscale_name
  role = aws_iam_role.tailscale_router.name
}

# ── EC2: Tailscale 서브넷 라우터 (AZ마다 1대) ──
resource "aws_instance" "tailscale_router" {
  for_each = local.tailscale_routers

  ami                         = data.aws_ssm_parameter.al2023_arm64.insecure_value
  instance_type               = "t4g.micro"
  subnet_id                   = each.value.subnet_id
  vpc_security_group_ids      = [aws_security_group.tailscale_router.id]
  iam_instance_profile        = aws_iam_instance_profile.tailscale_router.name
  associate_public_ip_address = true
  source_dest_check           = false # 다른 사이트로 가는 패킷을 대신 넘겨주려면 꺼야 함

  metadata_options {
    http_tokens = "required" # IMDSv2만 허용
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = replace(templatefile("${path.module}/templates/tailscale-router.sh.tftpl", {
    region        = "ap-northeast-2"
    authkey_param = local.tailscale_authkey_param
    hostname      = "aws-router-${each.key}"
    vpc_cidr      = module.vpc.vpc_cidr_block
  }), "\r", "")
  user_data_replace_on_change = true

  tags = {
    Name = "${local.tailscale_name}-${each.key}"
  }
}

# ── VPC 경로: 원격 대역은 같은 AZ의 라우터로 보내기 ──
# 프라이빗 라우팅 테이블이 AZ마다 하나씩 있으므로 (라우터 수 × 대역 수)만큼 경로 생성
resource "aws_route" "to_remote_sites" {
  for_each = {
    for pair in setproduct(keys(local.tailscale_routers), var.tailscale_remote_cidrs) :
    "${pair[0]}_${pair[1]}" => {
      router = pair[0]
      cidr   = pair[1]
    }
  }

  route_table_id         = module.vpc.private_route_table_ids[local.tailscale_routers[each.value.router].az_index]
  destination_cidr_block = each.value.cidr
  network_interface_id   = aws_instance.tailscale_router[each.value.router].primary_network_interface_id
}