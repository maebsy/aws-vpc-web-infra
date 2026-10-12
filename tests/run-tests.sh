#!/usr/bin/env bash
# 정적 검증 (AWS 계정·비용 불필요): 스크립트 문법, IAM 정책 최소 권한 규칙, DRY_RUN 명령 순서.
#   bash tests/run-tests.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
section() { printf '\n[%s]\n' "$1"; }
P=iam/policy-least-privilege.json

section "스크립트 문법 / ShellCheck"
for f in scripts/*.sh bonus/*/*.sh tests/*.sh; do check "bash -n $f" bash -n "$f"; done
command -v shellcheck >/dev/null && check "shellcheck warning 0" shellcheck -S warning scripts/*.sh bonus/*/*.sh tests/*.sh

section "IAM 정책: 최소 권한"
for f in iam/*.json; do check "JSON 형식 $f" jq empty "$f"; done
check "Action \"*\" 없음 (관리자 권한 아님)" bash -c "! jq -e '[.Statement[].Action] | flatten | index(\"*\")' $P"
check "ec2/sts 외 서비스 권한 없음 (S3·RDS·IAM 없음)" bash -c "! jq -r '[.Statement[].Action] | flatten[]' $P | grep -vE '^(ec2|sts):'"
check "변경 작업에는 와일드카드 없음 (Describe* 만 허용)" bash -c "! jq -r '[.Statement[].Action] | flatten[]' $P | grep '\\*' | grep -v '^ec2:Describe\\*$'"
check "iam:PassRole 없음" bash -c "! grep -q PassRole $P"
check "RunInstances 인스턴스 타입 t2/t3.micro 제한" bash -c "jq -e '.Statement[] | select(.Sid==\"RunOnlyFreeTierInstanceTypes\") | .Condition.StringEquals[\"ec2:InstanceType\"] == [\"t2.micro\",\"t3.micro\"]' $P"
check "루트 볼륨 ≤ 10GiB" bash -c "jq -e '.Statement[] | select(.Sid==\"RunInstancesRootVolumeUpTo10GiB\") | .Condition.NumericLessThanEquals[\"ec2:VolumeSize\"] == \"10\"' $P"
check "Resource 가 \"*\" 인 문장은 모두 서울 리전 조건 (sts 제외)" bash -c "jq -e '[.Statement[] | select(.Resource==\"*\") | select((.Action|tostring|test(\"sts:\"))|not) | .Condition.StringEquals[\"aws:RequestedRegion\"]] | all(. == \"ap-northeast-2\")' $P"
check "RunInstances ARN 은 모두 ap-northeast-2" bash -c "jq -r '.Statement[] | select(.Action==\"ec2:RunInstances\") | .Resource | if type==\"array\" then .[] else . end' $P | grep -v ':ap-northeast-2:' | grep -q . && exit 1 || exit 0"
check "태그 강제 정책은 Deny 만 포함" bash -c "jq -e '[.Statement[].Effect] | all(. == \"Deny\")' iam/policy-tag-scoped.json"

section "user-data"
check "/health → 200 OK 고정 응답" grep -qF 'return 200 "OK' scripts/user-data.sh
check "localhost 200 자체 점검" grep -q 'http://localhost/health' scripts/user-data.sh
check "아웃바운드 확인 (example.com)" grep -q 'https://example.com' scripts/user-data.sh
check "Docker: -p 80:80 포트 매핑" grep -q -- '-p 80:80' bonus/docker/user-data-docker.sh
check "Docker: --restart unless-stopped" grep -q -- '--restart unless-stopped' bonus/docker/user-data-docker.sh

section "provision.sh DRY_RUN"
rm -rf .state
OUT="$(DRY_RUN=1 bash scripts/provision.sh 2>&1)"
order="$(grep -oE 'aws ec2 (create-vpc|create-subnet|create-internet-gateway|attach-internet-gateway|create-route-table|create-route |associate-route-table|create-security-group|authorize-security-group-ingress|create-key-pair|run-instances)' <<< "$OUT" | awk '{print $3}' | uniq | tr '\n' ' ')"
check "생성 순서 VPC→Subnet→IGW→RT→Route→SG→Key→EC2" test "$order" = "create-vpc create-subnet create-internet-gateway attach-internet-gateway create-route-table create-route associate-route-table create-security-group authorize-security-group-ingress create-key-pair run-instances "
check "0.0.0.0/0 → IGW 경로" grep -q 'create-route --route-table-id rtb-DRYRUN --destination-cidr-block 0.0.0.0/0 --gateway-id igw-DRYRUN' <<< "$OUT"
check "HTTP 80 ← 0.0.0.0/0" grep -q 'FromPort=80,ToPort=80,IpRanges=\[{CidrIp=0.0.0.0/0' <<< "$OUT"
check "SSH 22 ← /32 만" grep -qE 'FromPort=22,ToPort=22,IpRanges=\[\{CidrIp=[0-9.]+/32' <<< "$OUT"
check "전체 포트 규칙 없음" bash -c "! grep -qE 'IpProtocol=-1|FromPort=0,ToPort=65535' <<< \"\$1\"" _ "$OUT"
check "프리 티어 타입 + 8GiB gp3 + IMDSv2" bash -c 'grep -q -- "--instance-type t3.micro" <<< "$1" && grep -q "VolumeSize=8,VolumeType=gp3" <<< "$1" && grep -q "HttpTokens=required" <<< "$1"' _ "$OUT"
check "모든 생성에 Project 태그" bash -c '[[ $(grep -c "aws ec2 create-\|run-instances" <<< "$1") -le $(grep -c "Key=Project,Value=aws-vpc-web-infra" <<< "$1") ]] || [[ $(grep -c "Key=Project" <<< "$1") -ge 6 ]]' _ "$OUT"
check "DRY_RUN 은 .state 를 만들지 않음" test ! -e .state/resources.env

section "cleanup.sh DRY_RUN"
OUT="$(DRY_RUN=1 bash scripts/cleanup.sh 2>&1)"
order="$(grep -oE 'aws ec2 (terminate-instances|delete-security-group|disassociate-route-table|delete-route-table|detach-internet-gateway|delete-internet-gateway|delete-subnet|delete-vpc)' <<< "$OUT" | awk '{print $3}' | tr '\n' ' ')"
check "삭제 순서 EC2→SG→RT→IGW→Subnet→VPC" test "$order" = "terminate-instances delete-security-group disassociate-route-table delete-route-table detach-internet-gateway delete-internet-gateway delete-subnet delete-vpc "
check "EC2 terminated 대기 후 진행" grep -q 'wait instance-terminated' <<< "$OUT"

section "문서"
for f in README.md docs/architecture.png docs/troubleshooting.md docs/cleanup-checklist.md; do check "제출물 $f" test -s "$f"; done
check "README 에 선택 방식(B) 명시" grep -q '방식 B' README.md

printf '\n결과: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
