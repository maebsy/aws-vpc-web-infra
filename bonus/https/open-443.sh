#!/usr/bin/env bash
# [보너스 1] 보안 그룹에 443/tcp(HTTPS) 인바운드 추가 + Elastic IP 할당·연결. 로컬 PC 에서 실행.
#   bash bonus/https/open-443.sh            # 추가
#   bash bonus/https/open-443.sh --revert   # 443 규칙 제거 + EIP 해제 (실습 종료 시)
set -euo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
preflight
load_state
if [[ "${1:-}" == "--revert" ]]; then
    awsx ec2 revoke-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null || true
    if [[ -n "${EIP_ALLOC_ID:-}" ]]; then
        assoc="$(aws ec2 describe-addresses --allocation-ids "$EIP_ALLOC_ID" --query 'Addresses[0].AssociationId' --output text)"
        [[ "$assoc" != None ]] && awsx ec2 disassociate-address --association-id "$assoc"
        awsx ec2 release-address --allocation-id "$EIP_ALLOC_ID" && ok "EIP 해제 $EIP_ALLOC_ID"
    fi
    exit 0
fi
awsx ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTPS-public}]" >/dev/null && ok "443/tcp ← 0.0.0.0/0"
if [[ -z "${EIP_ALLOC_ID:-}" ]]; then
    EIP_ALLOC_ID="$(DRY_VALUE=eipalloc-DRYRUN awsx ec2 allocate-address --domain vpc \
        --tag-specifications "$(tags elastic-ip "$PREFIX-eip")" --query AllocationId --output text)"
    save_state EIP_ALLOC_ID "$EIP_ALLOC_ID"
fi
awsx ec2 associate-address --allocation-id "$EIP_ALLOC_ID" --instance-id "$INSTANCE_ID" >/dev/null
PUBLIC_IP="$(DRY_VALUE=198.51.100.30 awsx ec2 describe-addresses --allocation-ids "$EIP_ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)"
save_state PUBLIC_IP "$PUBLIC_IP"
ok "Elastic IP $PUBLIC_IP → $INSTANCE_ID  (도메인 A 레코드를 이 IP 로 설정)"
warn "Elastic IP 는 인스턴스를 멈추거나 연결을 끊으면 시간당 과금됩니다. 실습 후 --revert 또는 cleanup.sh"
