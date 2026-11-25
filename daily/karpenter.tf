# ── Karpenter: 부하가 몰릴 때만 노드를 추가로 띄우는 컨트롤러 ──
# 이 모듈이 만드는 것
#  - 컨트롤러 IAM 역할 (Pod Identity, kube-system/karpenter)
#  - Karpenter가 띄우는 노드의 IAM 역할 + 클러스터 접근 권한(액세스 엔트리)
#  - SQS 큐 + EventBridge 규칙 (스팟 회수·점검 예정 알림 수신)
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.30.2" # EKS 모듈과 같은 버전

  cluster_name = module.eks.cluster_name

  # 컨트롤러 권한: Pod Identity로 연결
  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"

  # 노드 역할 이름 고정 (NodePool 매니페스트의 EC2NodeClass에서 이 이름을 씀)
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${local.name}-karpenter-node"

  # Karpenter 노드에도 SSM 접속 허용 (관리형 노드와 같은 접속 방식)
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}