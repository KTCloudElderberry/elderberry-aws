# ── EKS API 공개 엔드포인트에 접근할 수 있는 IP (내 PC 공인 IP 등) ──
# 값은 terraform.tfvars(내 PC)와 GitHub Secret에서 넣어요. Git에 올리지 않습니다.
variable "eks_public_access_cidrs" {
  description = "EKS API 공개 엔드포인트 허용 대역"
  type        = list(string)
}

# ── EKS 클러스터 + 노드 그룹 ──
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.30.2"

  name               = "${local.name}-eks"
  kubernetes_version = "1.36"

  # API 서버 접근
  # - 비공개: 노드(kubelet)는 VPC 안 경로로 접속 → NAT와 무관
  # - 공개: 허용한 IP에서만 (kubectl, 나중에 kt cloud Argo CD)
  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.eks_public_access_cidrs

  # terraform을 실행한 IAM 사용자를 클러스터 관리자로 등록 (액세스 엔트리)
  enable_cluster_creator_admin_permissions = true

  # EKS 관리형 애드온
  addons = {
    vpc-cni = {
      before_compute = true # 노드보다 먼저 설치 (Pod에 VPC IP 할당)
    }
    eks-pod-identity-agent = {
      before_compute = true # Pod 단위 IAM 권한
    }
    kube-proxy = {}
    coredns    = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets # 노드는 프라이빗 서브넷 a·c

  eks_managed_node_groups = {
    default = {
      instance_types = ["c7i-flex.large"]
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = 2
      max_size     = 2
      desired_size = 2
    }
  }
}

# ── AWS Load Balancer Controller가 쓸 IAM 권한 (Pod Identity) ──
module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.11.0"

  name                            = "${local.name}-aws-lbc"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}