#!/usr/bin/env bash
# =============================================================================
#  audit.sh — 과금 위험 리소스 점검 (정리 후 0 이어야 함) + 증빙 저장
#
#    bash scripts/audit.sh     # 결과: docs/evidence/audit-<시각>.txt
#
#  "Project 태그가 붙은 것" 뿐 아니라 리전 전체의 과금 위험 리소스를 본다.
#  태그를 깜빡하고 만든 리소스도 놓치지 않기 위해서다.
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/lib.sh"
preflight
mkdir -p "$REPO_DIR/docs/evidence"
OUT="$REPO_DIR/docs/evidence/audit-$(date +%Y%m%d-%H%M%S).txt"
left=0
row() {   # 이름 명령...
    local name="$1"; shift
    local out
    if ! out="$("$@" 2>&1)"; then
        printf '%-32s %s\n' "$name" "확인 불가 ($(grep -o 'AccessDenied\|UnauthorizedOperation' <<< "$out" | head -1 || echo 오류)) → 콘솔에서 확인"
        return
    fi
    out="$(grep -v '^None$' <<< "$out" | grep . || true)"
    if [[ -z "$out" ]]; then printf '%-32s %s\n' "$name" "0 ✅"
    else printf '%-32s %s\n' "$name" "$(wc -l <<< "$out")개 ⚠️"; sed 's/^/    /' <<< "$out"; left=$((left + 1)); fi
}
{
echo "# audit.sh $(date '+%Y-%m-%d %H:%M:%S %Z') region=$AWS_REGION project=$PROJECT"
row "EC2 (terminated 제외)"   aws ec2 describe-instances --query 'Reservations[].Instances[?State.Name!=`terminated`].[InstanceId,State.Name,InstanceType]' --output text
row "EBS 볼륨 (전체)"          aws ec2 describe-volumes --query 'Volumes[].[VolumeId,State,Size]' --output text
row "Elastic IP"               aws ec2 describe-addresses --query 'Addresses[].[PublicIp,AllocationId,AssociationId]' --output text
row "NAT Gateway (삭제 제외)"  aws ec2 describe-nat-gateways --query 'NatGateways[?State!=`deleted`].[NatGatewayId,State]' --output text
row "EBS 스냅샷 (내 소유)"      aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[].[SnapshotId,VolumeSize]' --output text
row "VPC (Project 태그)"       aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJECT" --query 'Vpcs[].VpcId' --output text
row "Internet Gateway (태그)"  aws ec2 describe-internet-gateways --filters "Name=tag:Project,Values=$PROJECT" --query 'InternetGateways[].InternetGatewayId' --output text
row "Security Group (태그)"    aws ec2 describe-security-groups --filters "Name=tag:Project,Values=$PROJECT" --query 'SecurityGroups[].GroupId' --output text
row "Key Pair"                 aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text
# 최소 권한 정책에는 ELB/RDS 권한이 없다(생성하지 않았으므로). 확인 불가로 나오면 콘솔에서 0 인지 본다.
row "ELB/ALB"                  aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text
row "RDS"                      aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text
echo
if [[ $left -eq 0 ]]; then echo "결론: 과금 위험 리소스 없음 (Key Pair 는 과금 없음)"; else echo "결론: 남은 항목 $left 종 — cleanup.sh 재실행 또는 콘솔에서 삭제"; fi
echo "※ Billing Dashboard 의 당월 비용은 반영까지 최대 24시간 걸릴 수 있습니다."
} 2>&1 | tee "$OUT"
info "증빙 저장: ${OUT#"$REPO_DIR"/}"
