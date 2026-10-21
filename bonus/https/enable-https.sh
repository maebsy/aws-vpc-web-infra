#!/usr/bin/env bash
# =============================================================================
#  [보너스 1] enable-https.sh — 무료 서브도메인 + Let's Encrypt 인증서로 HTTPS 적용 (인스턴스 안에서 실행)
#
#    sudo bash enable-https.sh <도메인> <이메일>
#    예) sudo bash enable-https.sh myweb.duckdns.org me@example.com
#
#  사전 조건 (docs/bonus.md 1장)
#    1. Elastic IP 를 인스턴스에 연결 (IP 가 바뀌면 DNS 가 틀어진다) — 실습 후 반드시 Release
#    2. 도메인 A 레코드 → Elastic IP  (DuckDNS 무료 서브도메인 등)
#    3. 보안 그룹 443/tcp ← 0.0.0.0/0 추가  (bonus/https/open-443.sh)
#    4. 80/tcp 는 계속 열어 둔다 (Let's Encrypt HTTP-01 인증이 80 으로 들어온다)
# =============================================================================
set -euo pipefail
DOMAIN="${1:?도메인을 입력하세요 (예: myweb.duckdns.org)}"
EMAIL="${2:?인증서 만료 알림을 받을 이메일을 입력하세요}"
[[ "$(id -u)" -eq 0 ]] || { echo "sudo 로 실행하세요"; exit 1; }

ip_now="$(curl -s https://checkip.amazonaws.com)"
ip_dns="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1)"
echo "[INFO] 이 서버 공인 IP: $ip_now / $DOMAIN → ${ip_dns:-조회 실패}"
[[ "$ip_now" == "$ip_dns" ]] || { echo "[FAIL] DNS 가 아직 이 서버를 가리키지 않습니다. A 레코드를 확인하고 몇 분 뒤 다시 실행하세요."; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y certbot python3-certbot-nginx

# 기본 server 블록에 도메인 이름을 넣어야 certbot --nginx 가 어느 블록에 TLS 를 붙일지 안다
sed -i "s/server_name _;/server_name $DOMAIN;/" /etc/nginx/sites-available/aws-vpc-web.conf
nginx -t && systemctl reload nginx

# --redirect: HTTP 요청을 HTTPS 로 301 리다이렉트 (/health 포함)
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect

# certbot 이 만든 80 블록은 도메인이 아닌 요청(http://<IP>/health)에 404 를 준다.
# 도메인 요청은 그대로 301 → HTTPS, IP 로 오는 기본 과제 요청은 기존처럼 응답하도록 404 를 원래 설정으로 바꾼다.
CONF=/etc/nginx/sites-available/aws-vpc-web.conf
WEB_ROOT="$(awk '$1=="root"{gsub(";","",$2); print $2; exit}' "$CONF")"
perl -0pi -e 's|    return 404; # managed by Certbot|    root '"$WEB_ROOT"';\n    location = /health { access_log off; default_type text/plain; add_header Cache-Control "no-store"; return 200 "OK\\n"; }\n    location / { try_files \$uri \$uri/ =404; }\n    server_tokens off;|' "$CONF"
nginx -t && systemctl reload nginx

systemctl list-timers | grep -i certbot || true    # 자동 갱신 타이머 (90일 인증서를 60일마다 갱신)
certbot renew --dry-run
echo
echo "[CHECK] $(curl -s -o /dev/null -w '%{url_effective} → %{http_code}' "https://$DOMAIN/health")"
echo "[CHECK] 인증서: $(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -enddate | tr '\n' ' ')"
