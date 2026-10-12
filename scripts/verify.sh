#!/usr/bin/env bash
# =============================================================================
#  verify.sh — 요구사항 검증 + 증빙 저장 (docs/evidence/verify-<시각>.txt)
#
#    bash scripts/verify.sh            # .state/resources.env 의 리소스를 검증
#
#  검증 항목 (체크리스트 항목 1)
#    1. Route Table 에 0.0.0.0/0 → IGW 경로, Subnet 연결
#    2. Security Group: 80 ← 0.0.0.0/0, 22 ← /32 (0.0.0.0/0 아님), 전체 포트 허용 규칙 없음
#    3. 외부 접속 (방식 B): GET http://<퍼블릭IP>/health → 200 + "OK"
#    4. (참고) 방식 A: GET http://<퍼블릭IP>/ → 200
#    5. SSH 22 포트 응답 (내 IP 에서)
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/lib.sh"
preflight
load_state
[[ -n "${INSTANCE_ID:-}" ]] || die ".state/resources.env 가 없습니다. 먼저 provision.sh (또는 콘솔 작업 후 ID 를 직접 기록)"
mkdir -p "$REPO_DIR/docs/evidence"
OUT="$REPO_DIR/docs/evidence/verify-$(date +%Y%m%d-%H%M%S).txt"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "[PASS] $*"; }
fail() { FAIL=$((FAIL + 1)); echo "[FAIL] $*"; }

{
echo "# verify.sh $(date '+%Y-%m-%d %H:%M:%S %Z') region=$AWS_REGION"
echo

echo "## 1. Route Table"
routes="$(aws ec2 describe-route-tables --route-table-ids "$RTB_ID" \
    --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,State]' --output text)"
echo "$routes"
grep -qE "^0\.0\.0\.0/0[[:space:]]+${IGW_ID}[[:space:]]+active" <<< "$routes" && pass "0.0.0.0/0 → $IGW_ID (active)" || fail "기본 경로가 IGW 로 가지 않습니다"
assoc="$(aws ec2 describe-route-tables --route-table-ids "$RTB_ID" --query 'RouteTables[0].Associations[].SubnetId' --output text)"
grep -qw "$SUBNET_ID" <<< "$assoc" && pass "Subnet $SUBNET_ID 연결됨" || fail "Subnet 이 Route Table 에 연결되지 않았습니다"
echo

echo "## 2. Security Group 인바운드"
rules="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG_ID" \
    --query 'SecurityGroupRules[?IsEgress==`false`].[IpProtocol,FromPort,ToPort,CidrIpv4,CidrIpv6,Description]' --output text)"
echo "$rules"
grep -qE '^tcp[[:space:]]+80[[:space:]]+80[[:space:]]+0\.0\.0\.0/0' <<< "$rules" && pass "80/tcp ← 0.0.0.0/0" || fail "HTTP 80 공개 규칙 없음"
ssh_src="$(awk '$1=="tcp" && $2==22 {print $4}' <<< "$rules")"
if [[ "$ssh_src" =~ /32$ ]]; then pass "22/tcp ← $ssh_src (단일 IP)"; else fail "22/tcp 소스가 /32 가 아닙니다: ${ssh_src:-없음}"; fi
if awk '($1=="-1") || ($2==0 && $3==65535) {found=1} END {exit !found}' <<< "$rules"; then
    fail "전체 포트/프로토콜 허용 규칙이 있습니다"
else
    pass "전체 포트(0-65535) 허용 규칙 없음"
fi
others="$(awk '$1=="tcp" && $2!=22 && $2!=80' <<< "$rules")"
[[ -z "$others" ]] && pass "그 외 인바운드 없음" || fail "추가 인바운드: $others"
echo

echo "## 3. 외부 접속 — 방식 B: GET http://$PUBLIC_IP/health"
resp="$(curl -s -i --max-time 5 "http://$PUBLIC_IP/health")"
echo "$resp" | sed 's/\r$//'
head -n 1 <<< "$resp" | grep -q ' 200' && tail -n 1 <<< "$resp" | grep -qx 'OK' && pass "/health → 200 OK" || fail "/health 응답 이상"
echo

echo "## 4. (참고) 방식 A: GET http://$PUBLIC_IP/"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$PUBLIC_IP/")"
echo "HTTP $code"
[[ "$code" == 200 ]] && pass "/ → 200" || fail "/ → $code"
echo

echo "## 5. SSH 포트 (내 IP → 22)"
if timeout 5 bash -c "exec 3<>/dev/tcp/$PUBLIC_IP/22" 2>/dev/null; then pass "22/tcp 연결 가능 (이 PC 는 허용 IP)"; else fail "22/tcp 연결 불가 (내 IP 가 바뀌었는지 확인)"; fi
echo
echo "결과: PASS $PASS / FAIL $FAIL"
} 2>&1 | tee "$OUT"
info "증빙 저장: ${OUT#"$REPO_DIR"/}"
