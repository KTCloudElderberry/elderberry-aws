# ── EKS API 공개 엔드포인트에 접근할 수 있는 IP (내 PC 공인 IP 등) ──
# 값은 terraform.tfvars(내 PC)와 GitHub Secret에서 넣어요. Git에 올리지 않습니다.
variable "eks_public_access_cidrs" {
  description = "EKS API 공개 엔드포인트 허용 대역"
  type        = list(string)
}
# ── 클러스터 관리자 (내 IAM 사용자) ──
# 계정 ID는 코드에 적지 않고 조회해서 씀 (공개 저장소)
locals {
  cluster_admin_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/elderberry-taehyeon-admin"
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

  # 클러스터 관리자를 "실행한 주체" 대신 내 IAM 사용자로 직접 지정
  # (GitHub Actions에서 plan할 때 관리자가 plan 역할로 바뀌는 차이를 없앰)
  # 키 이름을 cluster_creator / admin으로 두어, 기존 등록과 같은 리소스로 인식되게 함
  enable_cluster_creator_admin_permissions = false
  access_entries = {
    cluster_creator = {
      principal_arn = local.cluster_admin_arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  # EKS 비밀 암호화 키(KMS)의 관리자도 같은 사용자로 고정
  kms_key_administrators = [local.cluster_admin_arn]

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

    # EBS 디스크를 PVC로 만들어 주는 드라이버 (CNPG DB 저장소)
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets # 노드는 프라이빗 서브넷 a·c

  eks_managed_node_groups = {
    default = {
      instance_types = ["m7i-flex.large"]
      ami_type       = "AL2023_x86_64_STANDARD"

      # 밤에는 scripts/night-stop.sh가 desired를 0으로 내림 (WBS 3.11)
      # desired_size는 모듈이 apply 때 무시하므로 스크립트로 바꿔도 되돌아가지 않음
      min_size     = 0
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

# ── EBS CSI 드라이버가 쓸 IAM 권한 (Pod Identity) ──
# 연결(association)은 위 addons의 aws-ebs-csi-driver에서 만들어요
module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.11.0"

  name                      = "${local.name}-ebs-csi"
  attach_aws_ebs_csi_policy = true
}