#!/usr/bin/env bash
# =============================================================================
#  iam-check.sh — IAM 최소 권한이 의도대로인지 "비용 없이" 검증 (EC2 DryRun)
#
#    bash scripts/iam-check.sh       # 결과: docs/evidence/iam-check-<시각>.txt
#
#  EC2 API 는 --dry-run 을 주면 실제로 만들지 않고 권한만 검사한다.
#    허용이면  → DryRunOperation (요청이 성공했을 것)
#    거부면    → UnauthorizedOperation
#  S3/IAM 처럼 dry-run 이 없는 서비스는 읽기 호출로 AccessDenied 를 확인한다(아무것도 만들지 않음).
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/lib.sh"
preflight
load_state
mkdir -p "$REPO_DIR/docs/evidence"
OUT="$REPO_DIR/docs/evidence/iam-check-$(date +%Y%m%d-%H%M%S).txt"
PASS=0; FAIL=0

expect() {   # expect <allow|deny> <설명> <명령...>
    local want="$1" desc="$2"; shift 2
    local out got rc
    out="$("$@" 2>&1)"; rc=$?
    if grep -q 'DryRunOperation' <<< "$out"; then got=allow
    elif grep -qE 'UnauthorizedOperation|AccessDenied|not authorized' <<< "$out"; then got=deny
    elif [[ $rc -eq 0 ]]; then got=allow
    else got="error"; fi
    if [[ "$got" == "$want" ]]; then PASS=$((PASS + 1)); printf '[PASS] %-5s %s\n' "$got" "$desc"
    else FAIL=$((FAIL + 1)); printf '[FAIL] %-5s (기대 %s) %s\n       %s\n' "$got" "$want" "$desc" "$(head -c 300 <<< "$out")"; fi
}

AMI="$(aws ec2 describe-images --owners 099720108477 \
    --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>/dev/null)"
SUBNET="${SUBNET_ID:-}"
net=(); [[ -n "$SUBNET" ]] && net=(--subnet-id "$SUBNET")
TAGS="ResourceType=instance,Tags=[{Key=Project,Value=$PROJECT}]"

{
echo "# iam-check.sh $(date '+%Y-%m-%d %H:%M:%S %Z') caller=$(aws sts get-caller-identity --query Arn --output text)"
echo
echo "## 허용되어야 하는 작업"
expect allow "EC2 조회 (서울)"                  aws ec2 describe-vpcs --max-items 1 --output text
expect allow "t3.micro 실행 (dry-run)"          aws ec2 run-instances --dry-run --image-id "$AMI" --instance-type t3.micro "${net[@]}" --tag-specifications "$TAGS"
expect allow "VPC 생성 (dry-run)"               aws ec2 create-vpc --dry-run --cidr-block 10.99.0.0/16
expect allow "SG 규칙 변경 권한 (dry-run)"       aws ec2 create-security-group --dry-run --group-name iam-check --description x --vpc-id "${VPC_ID:-vpc-00000000}"
echo
echo "## 거부되어야 하는 작업 (최소 권한)"
expect deny  "t3.small 실행 — 프리 티어 밖"     aws ec2 run-instances --dry-run --image-id "$AMI" --instance-type t3.small "${net[@]}"
expect deny  "루트 볼륨 30GiB — 10GiB 초과"     aws ec2 run-instances --dry-run --image-id "$AMI" --instance-type t3.micro "${net[@]}" \
                                                   --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=30}'
expect deny  "다른 리전(us-east-1) VPC 생성"    aws ec2 create-vpc --dry-run --cidr-block 10.98.0.0/16 --region us-east-1
expect deny  "S3 버킷 목록 — 실습과 무관"        aws s3api list-buckets
expect deny  "IAM 사용자 목록 — 관리자 권한"      aws iam list-users
expect deny  "RDS 조회 — 실습과 무관"            aws rds describe-db-instances
echo
echo "결과: PASS $PASS / FAIL $FAIL"
} 2>&1 | tee "$OUT"
info "증빙 저장: ${OUT#"$REPO_DIR"/}"
