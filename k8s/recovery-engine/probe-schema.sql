-- 복구 엔진 쓰기 검증용 테이블 (coupon DB에서 postgres로 실행, 다시 실행해도 안전)
-- 실행: kubectl exec -i -n database <primary> -c postgres -- psql -U postgres -d coupon -v ON_ERROR_STOP=1 < k8s/recovery-engine/probe-schema.sql
-- 계정(recovery_monitor / recovery_writer)은 k8s/database/20-cluster.yaml의 managed.roles로 만듦
CREATE SCHEMA IF NOT EXISTS recovery_check;

CREATE TABLE IF NOT EXISTS recovery_check.write_probe (
    operation_id UUID PRIMARY KEY,
    probe_token TEXT NOT NULL UNIQUE
        CHECK (probe_token ~ '^[0-9a-f]{64}$'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 이 스키마는 writer만 사용 (SELECT·INSERT만, 수정·삭제 불가)
REVOKE ALL ON SCHEMA recovery_check FROM PUBLIC;
GRANT USAGE ON SCHEMA recovery_check TO recovery_writer;
GRANT SELECT, INSERT ON recovery_check.write_probe TO recovery_writer;
