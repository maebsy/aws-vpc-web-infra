#!/usr/bin/env bash
# =============================================================================
#  cleanup.sh — 생성 역순으로 삭제 (과금 방지)
#
#    bash scripts/cleanup.sh           # .state 의 ID + Project 태그로 찾은 리소스 삭제
#    DRY_RUN=1 bash scripts/cleanup.sh # 삭제 명령만 미리 보기
#
#  순서 이유 (의존 관계 역순 — 앞의 것이 남아 있으면 뒤의 것이 DependencyViolation 으로 실패)
#    1. EC2 종료 → terminated 확인    : ENI(네트워크 인터페이스)가 Subnet·SG 를 붙잡고 있다
#    2. Elastic IP 해제                 : 연결 안 된 EIP 는 시간당 과금
#    3. 남은 EBS 볼륨 삭제 (available)  : DeleteOnTermination=false 였거나 수동 생성한 볼륨
#    4. Security Group 삭제
#    5. Route Table 연결 해제 → 삭제
#    6. IGW 분리 → 삭제
#    7. Subnet 삭제 → VPC 삭제
#    8. Key Pair 삭제 (과금은 없지만 정리)
#  마지막에 audit.sh 로 남은 리소스가 0 인지 확인한다.
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/lib.sh"
preflight
load_state
if [[ "$DRY_RUN" == 1 ]]; then   # 미리 보기: 자리표시 ID 로 전체 순서를 보여준다
    INSTANCE_ID=i-DRYRUN SG_ID=sg-DRYRUN RTB_ID=rtb-DRYRUN IGW_ID=igw-DRYRUN SUBNET_ID=subnet-DRYRUN VPC_ID=vpc-DRYRUN
fi

by_tag() {   # by_tag <describe 명령> <query>  → Project 태그가 붙은 리소스 ID
    [[ "$DRY_RUN" == 1 ]] && return 0
    aws ec2 "$1" --filters "Name=tag:Project,Values=$PROJECT" --query "$2" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' | sort -u
}
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*" >&2; }

step "1. EC2 종료"
instances="$( { echo "${INSTANCE_ID:-}"; by_tag describe-instances 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId'; } | grep . | sort -u)"
if [[ -n "$instances" ]]; then
    # shellcheck disable=SC2086
    awsx ec2 terminate-instances --instance-ids $instances >/dev/null
    # shellcheck disable=SC2086
    awsx ec2 wait instance-terminated --instance-ids $instances >/dev/null && ok "terminated: $instances"
else info "대상 없음"; fi

step "2. Elastic IP 해제"
for alloc in $( { echo "${EIP_ALLOC_ID:-}"; by_tag describe-addresses 'Addresses[].AllocationId'; } | grep . | sort -u); do
    assoc="$( [[ "$DRY_RUN" == 1 ]] || aws ec2 describe-addresses --allocation-ids "$alloc" --query 'Addresses[0].AssociationId' --output text)"
    [[ -n "$assoc" && "$assoc" != None ]] && awsx ec2 disassociate-address --association-id "$assoc"
    awsx ec2 release-address --allocation-id "$alloc" && ok "released $alloc"
done

step "3. 남은 EBS 볼륨 (available)"
for vol in $(by_tag describe-volumes 'Volumes[?State==`available`].VolumeId'); do
    awsx ec2 delete-volume --volume-id "$vol" && ok "deleted $vol"
done

step "4. Security Group"
for sg in $( { echo "${SG_ID:-}"; by_tag describe-security-groups 'SecurityGroups[?GroupName!=`default`].GroupId'; } | grep . | sort -u); do
    awsx ec2 delete-security-group --group-id "$sg" && ok "deleted $sg"
done

step "5. Route Table"
for rtb in $( { echo "${RTB_ID:-}"; by_tag describe-route-tables 'RouteTables[].RouteTableId'; } | grep . | sort -u); do
    for a in $( [[ "$DRY_RUN" == 1 ]] && echo "${RTB_ASSOC_ID:-rtbassoc-DRYRUN}" || aws ec2 describe-route-tables --route-table-ids "$rtb" \
                --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text); do
        awsx ec2 disassociate-route-table --association-id "$a"
    done
    awsx ec2 delete-route-table --route-table-id "$rtb" && ok "deleted $rtb"
done

step "6. Internet Gateway"
for igw in $( { echo "${IGW_ID:-}"; by_tag describe-internet-gateways 'InternetGateways[].InternetGatewayId'; } | grep . | sort -u); do
    for v in $( [[ "$DRY_RUN" == 1 ]] && echo "${VPC_ID:-vpc-DRYRUN}" || aws ec2 describe-internet-gateways --internet-gateway-ids "$igw" \
                --query 'InternetGateways[0].Attachments[].VpcId' --output text); do
        awsx ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$v"
    done
    awsx ec2 delete-internet-gateway --internet-gateway-id "$igw" && ok "deleted $igw"
done

step "7. Subnet → VPC"
for sn in $( { echo "${SUBNET_ID:-}"; by_tag describe-subnets 'Subnets[].SubnetId'; } | grep . | sort -u); do
    awsx ec2 delete-subnet --subnet-id "$sn" && ok "deleted $sn"
done
for vpc in $( { echo "${VPC_ID:-}"; by_tag describe-vpcs 'Vpcs[].VpcId'; } | grep . | sort -u); do
    awsx ec2 delete-vpc --vpc-id "$vpc" && ok "deleted $vpc"
done

step "8. Key Pair"
awsx ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null && ok "deleted key pair $KEY_NAME"

if [[ "$DRY_RUN" != 1 ]]; then
    mv "$STATE_FILE" "$STATE_FILE.deleted-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    step "확인"
    bash "$(dirname "$0")/audit.sh"
fi
