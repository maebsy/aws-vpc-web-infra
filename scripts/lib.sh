#!/usr/bin/env bash
# scripts/*.sh 공용 설정과 함수. source 해서 사용한다.
# shellcheck disable=SC2034  # 아래 값은 source 한 스크립트에서 사용

export AWS_REGION="${AWS_REGION:-ap-northeast-2}"     # 과제 제약: 서울 리전 고정
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""                                    # CLI 결과를 less 로 열지 않음
PROJECT="${PROJECT:-aws-vpc-web-infra}"                # 모든 리소스에 Project 태그 → 추적·정리 기준
PREFIX="${PREFIX:-awsweb}"                             # Name 태그 접두어
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.0.1.0/24}"
AZ="${AZ:-ap-northeast-2a}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"             # 프리 티어: t2.micro 또는 t3.micro
VOLUME_GIB="${VOLUME_GIB:-8}"
KEY_NAME="${KEY_NAME:-${PREFIX}-key}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$REPO_DIR/.state"
STATE_FILE="$STATE_DIR/resources.env"
DRY_RUN="${DRY_RUN:-0}"

info() { printf '\033[36m[INFO]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m[ OK ]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# aws 를 실행한다. DRY_RUN=1 이면 명령만 보여주고 자리표시 값을 돌려준다.
awsx() {
    printf '  $ aws %s\n' "$*" >&2
    if [[ "$DRY_RUN" == 1 ]]; then
        echo "${DRY_VALUE:-dryrun-id}"
        return 0
    fi
    aws "$@"
}

tags() {   # tags <리소스종류> <Name>  → --tag-specifications 값
    printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=Project,Value=%s}]' "$1" "$2" "$PROJECT"
}

save_state() {   # save_state KEY VALUE  (DRY_RUN 에서는 기록하지 않음 → 이후 실제 실행에 영향 없음)
    [[ "$DRY_RUN" == 1 ]] && return 0
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
    echo "$1=$2" >> "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

load_state() {
    [[ "$DRY_RUN" == 1 ]] && return 0
    # shellcheck disable=SC1090
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
    return 0
}

preflight() {
    [[ "$DRY_RUN" == 1 ]] && { info "DRY_RUN=1: AWS 를 호출하지 않고 명령만 출력합니다"; return 0; }
    command -v aws >/dev/null 2>&1 || die "AWS CLI v2 가 필요합니다: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    local arn
    arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)" || die "자격 증명이 없습니다: aws configure (IAM 사용자 Access Key)"
    [[ "$arn" == *":root" ]] && die "루트 계정 자격 증명입니다. 과제 제약에 따라 IAM 사용자로 실행하세요: $arn"
    info "호출자: $arn / 리전: $AWS_REGION"
}
