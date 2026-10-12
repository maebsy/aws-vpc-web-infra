#!/usr/bin/env bash
# =============================================================================
#  troubleshoot.sh — 장애를 "의도적으로" 재현하고 증상→가설→검증→조치→결과를 기록
#
#    bash scripts/troubleshoot.sh route     # 사례 1: 0.0.0.0/0 경로 삭제 → 외부 접속 timeout
#    bash scripts/troubleshoot.sh ssh-ip    # 사례 2: SSH 허용 IP 불일치 → SSH timeout
#    bash scripts/troubleshoot.sh nginx     # 사례 3: 웹 서버 중지 → connection refused
#    bash scripts/troubleshoot.sh iam       # 사례 4: 최소 권한 밖 작업 → UnauthorizedOperation
#
#  결과: docs/evidence/troubleshoot-<사례>-<시각>.txt  (docs/troubleshooting.md 에 옮겨 적는다)
#  모든 사례는 마지막에 원래 상태로 되돌린다. 중간에 멈추면 같은 명령을 다시 실행하면 복구 단계부터 이어진다.
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/lib.sh"
preflight
load_state
CASE="${1:-}"
[[ -n "${PUBLIC_IP:-}" ]] || die ".state/resources.env 가 없습니다 (provision.sh 먼저)"
mkdir -p "$REPO_DIR/docs/evidence"
OUT="$REPO_DIR/docs/evidence/troubleshoot-$CASE-$(date +%Y%m%d-%H%M%S).txt"
KEY_FILE="$STATE_DIR/$KEY_NAME.pem"

stage() { printf '\n## %s  (%s)\n' "$1" "$(date '+%H:%M:%S')"; }
cmd()   { echo "\$ $*"; "$@" 2>&1; echo "(exit $?)"; }
probe() {   # HTTP 응답 코드·소요 시간·curl 오류를 함께 남긴다 (timeout 과 refused 를 구분하는 핵심 증거)
    curl -s -o /dev/null --max-time 8 -w 'http_code=%{http_code} time_total=%{time_total}s\n' "http://$PUBLIC_IP/health"
    echo "(curl exit $?: 0=정상, 7=connection refused, 28=timeout)"
}
tcp22() { if timeout 6 bash -c "exec 3<>/dev/tcp/$PUBLIC_IP/22" 2>/dev/null; then echo "22/tcp: 연결됨"; else echo "22/tcp: 6초 내 응답 없음 (timeout)"; fi; }
confirm() { [[ "${YES:-0}" == 1 ]] && return 0; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }

case "$CASE" in
route)
    confirm "Route Table $RTB_ID 의 0.0.0.0/0 경로를 삭제합니다(잠시 외부 접속 불가). 진행할까요?" || exit 0
    {
    echo "# 사례 1: 기본 경로 누락 — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    stage "정상 상태";            probe
    stage "장애 주입: 0.0.0.0/0 → IGW 경로 삭제"; cmd aws ec2 delete-route --route-table-id "$RTB_ID" --destination-cidr-block 0.0.0.0/0
    sleep 5
    stage "증상: 외부에서 /health";  probe; tcp22
    stage "가설 검증 1: 인스턴스·Nginx 는 정상인가"; cmd aws ec2 describe-instance-status --instance-ids "$INSTANCE_ID" --query 'InstanceStatuses[0].[InstanceState.Name,InstanceStatus.Status,SystemStatus.Status]' --output text
    stage "가설 검증 2: 보안 그룹은 그대로인가"; cmd aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG_ID" --query 'SecurityGroupRules[?IsEgress==`false`].[FromPort,CidrIpv4]' --output text
    stage "가설 검증 3: 라우팅"; cmd aws ec2 describe-route-tables --route-table-ids "$RTB_ID" --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId]' --output text
    stage "조치: 경로 복구";        cmd aws ec2 create-route --route-table-id "$RTB_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
    sleep 5
    stage "결과";                   probe
    } 2>&1 | tee "$OUT" ;;
ssh-ip)
    WRONG="${WRONG_IP:-198.51.100.1}"   # 문서용 예약 대역(TEST-NET-2): "내 IP 가 바뀐 상황" 을 흉내낸다
    current="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG_ID" \
        --query 'SecurityGroupRules[?IsEgress==`false` && FromPort==`22`].[SecurityGroupRuleId,CidrIpv4]' --output text)"
    read -r RULE_ID CUR_CIDR <<< "$current"
    confirm "SSH 허용 IP 를 $CUR_CIDR → $WRONG/32 로 바꿨다가 되돌립니다. 진행할까요?" || exit 0
    {
    echo "# 사례 2: SSH 허용 IP 불일치 — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    stage "정상 상태"; tcp22
    stage "장애 주입: 22/tcp 소스를 다른 IP 로"; cmd aws ec2 modify-security-group-rules --group-id "$SG_ID" \
        --security-group-rules "SecurityGroupRuleId=$RULE_ID,SecurityGroupRule={IpProtocol=tcp,FromPort=22,ToPort=22,CidrIpv4=$WRONG/32,Description=SSH-my-ip-only}"
    sleep 3
    stage "증상"; tcp22; echo "(HTTP 는 정상인지 비교)"; probe
    stage "가설 검증: 지금 내 공인 IP vs SG 허용 IP"; echo "my ip : $(curl -s https://checkip.amazonaws.com)"
    cmd aws ec2 describe-security-group-rules --security-group-rule-ids "$RULE_ID" --query 'SecurityGroupRules[0].CidrIpv4' --output text
    stage "조치: 현재 IP/32 로 수정"; cmd aws ec2 modify-security-group-rules --group-id "$SG_ID" \
        --security-group-rules "SecurityGroupRuleId=$RULE_ID,SecurityGroupRule={IpProtocol=tcp,FromPort=22,ToPort=22,CidrIpv4=$(curl -s https://checkip.amazonaws.com)/32,Description=SSH-my-ip-only}"
    sleep 3
    stage "결과"; tcp22
    } 2>&1 | tee "$OUT" ;;
nginx)
    [[ -r "$KEY_FILE" ]] || die "SSH 키가 없습니다: $KEY_FILE"
    SSH=(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "ubuntu@$PUBLIC_IP")
    confirm "인스턴스의 Nginx 를 잠시 중지합니다. 진행할까요?" || exit 0
    {
    echo "# 사례 3: 웹 서버 프로세스 중지 — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    stage "정상 상태"; probe
    stage "장애 주입: systemctl stop nginx"; cmd "${SSH[@]}" sudo systemctl stop nginx
    stage "증상: 외부에서 /health (timeout 이 아니라 즉시 거부되는지 본다)"; probe
    stage "가설 검증: 서버 안에서 포트·프로세스·로그"
    cmd "${SSH[@]}" "sudo ss -tlnp | grep ':80 ' || echo '80 포트 LISTEN 없음'; systemctl is-active nginx; curl -s -o /dev/null -w 'localhost http_code=%{http_code}\n' http://localhost/health; sudo journalctl -u nginx -n 5 --no-pager"
    stage "조치: systemctl start nginx"; cmd "${SSH[@]}" sudo systemctl start nginx
    stage "결과"; probe; cmd "${SSH[@]}" "curl -s -o /dev/null -w 'localhost http_code=%{http_code}\n' http://localhost/"
    } 2>&1 | tee "$OUT" ;;
iam)
    {
    echo "# 사례 4: 최소 권한 밖 작업 — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    AMI="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].ImageId' --output text)"
    stage "증상: 더 큰 인스턴스(t3.small) 실행 시도 (dry-run, 비용 없음)"
    out="$(aws ec2 run-instances --dry-run --image-id "$AMI" --instance-type t3.small --subnet-id "$SUBNET_ID" 2>&1)"; echo "$out"
    stage "검증: 인코딩된 거부 사유 해독 (어떤 Action·Resource·조건 때문인지)"
    enc="$(grep -o 'Encoded authorization failure message: [^ ]*' <<< "$out" | awk '{print $NF}')"
    if [[ -n "$enc" ]]; then
        aws sts decode-authorization-message --encoded-message "$enc" --query DecodedMessage --output text \
            | jq '{allowed, explicitDeny, action: .context.action, resource: .context.resource, instanceType: (.context.conditions.items[]? | select(.key=="ec2:InstanceType") | .values.items[0].value)}' 2>/dev/null \
            || echo "(해독 실패: sts:DecodeAuthorizationMessage 권한 확인)"
    fi
    stage "조치: 권한을 넓히지 않고 요구사항 범위(t3.micro)로 요청 수정"
    aws ec2 run-instances --dry-run --image-id "$AMI" --instance-type t3.micro --subnet-id "$SUBNET_ID" 2>&1 | head -c 300; echo
    } 2>&1 | tee "$OUT" ;;
*)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
info "기록 저장: ${OUT#"$REPO_DIR"/}"
