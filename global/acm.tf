# ALB에 붙일 HTTPS 인증서 (매일 destroy하지 않도록 global/에 둠)
# Cloudflare 토큰은 환경변수 CLOUDFLARE_API_TOKEN으로만 전달 (파일·Git에 넣지 않음)

provider "cloudflare" {}

locals {
  domain_name = "elderberry-coupon.com"
}

# 도메인 이름으로 Cloudflare 영역 ID를 찾음 (토큰의 "영역 읽기" 권한 사용)
data "cloudflare_zone" "main" {
  filter = {
    name = local.domain_name
  }
}

# 루트 도메인 + 모든 하위 도메인(*.)을 한 인증서로
resource "aws_acm_certificate" "main" {
  domain_name               = local.domain_name
  subject_alternative_names = ["*.${local.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ACM이 요구하는 검증용 CNAME을 Cloudflare에 등록
# 루트와 *.는 같은 레코드를 쓰므로 *. 쪽은 건너뜀 (중복 생성 오류 방지)
resource "cloudflare_dns_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options :
    dvo.domain_name => dvo if !startswith(dvo.domain_name, "*.")
  }

  zone_id = data.cloudflare_zone.main.id
  name    = trimsuffix(each.value.resource_record_name, ".")
  type    = each.value.resource_record_type
  content = trimsuffix(each.value.resource_record_value, ".")
  ttl     = 1     # 자동
  proxied = false # 검증 레코드는 반드시 DNS only
  comment = "ACM DNS validation (elderberry-aws global/)"
}

# 인증서가 ISSUED가 될 때까지 기다림
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for dvo in aws_acm_certificate.main.domain_validation_options : dvo.resource_record_name]

  depends_on = [cloudflare_dns_record.acm_validation]
}
