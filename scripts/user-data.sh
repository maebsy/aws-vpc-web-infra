#!/bin/bash
# =============================================================================
#  user-data.sh — EC2 첫 부팅 시 1회 실행 (cloud-init, root 권한)
#
#  Nginx 를 설치하고 두 가지 응답을 만든다.
#    GET /        → 정적 페이지 (방식 A: 브라우저 확인용)
#    GET /health  → 200 + "OK" (방식 B: 이 저장소가 선택한 외부 접속 검증 방식)
#
#  지원 OS: Ubuntu 22.04/24.04 (apt), Amazon Linux 2023 (dnf)
#  실행 기록: /var/log/user-data.log  (문제가 생기면 SSH 접속 후 가장 먼저 볼 파일)
# =============================================================================
set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y nginx curl
    CONF_DIR=/etc/nginx/sites-available
    LINK_DIR=/etc/nginx/sites-enabled
    WEB_ROOT=/var/www/html
else
    dnf install -y nginx
    CONF_DIR=/etc/nginx/conf.d
    LINK_DIR=""
    WEB_ROOT=/usr/share/nginx/html
fi

# IMDSv2 로 인스턴스 메타데이터를 읽어 페이지에 표시 (어느 인스턴스가 응답했는지 확인용)
TOKEN="$(curl -sS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' || true)"
meta() { curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || echo unknown; }
INSTANCE_ID="$(meta instance-id)"
AZ="$(meta placement/availability-zone)"
PRIVATE_IP="$(meta local-ipv4)"

cat > "$WEB_ROOT/index.html" <<HTML
<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><title>Hello Cloud</title>
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:60px auto;padding:0 16px;color:#1f2933}
code{background:#f1f3f5;padding:2px 6px;border-radius:4px}</style></head>
<body>
<h1>Hello Cloud</h1>
<p>VPC 안의 Public Subnet 에 배포한 Nginx 웹 서버입니다.</p>
<ul>
  <li>Instance: <code>${INSTANCE_ID}</code></li>
  <li>AZ: <code>${AZ}</code></li>
  <li>Private IP: <code>${PRIVATE_IP}</code></li>
  <li>Health check: <a href="/health"><code>/health</code></a></li>
</ul>
</body></html>
HTML

cat > "$CONF_DIR/aws-vpc-web.conf" <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root __WEB_ROOT__;
    index index.html;

    # 방식 B: 고정 응답. 로드밸런서·모니터링이 쓰는 형태와 같다
    location = /health {
        access_log off;
        default_type text/plain;
        add_header Cache-Control "no-store";
        return 200 "OK\n";
    }

    location / {
        try_files $uri $uri/ =404;
    }

    # 서버 버전 노출 최소화
    server_tokens off;
}
NGINX
sed -i "s#__WEB_ROOT__#${WEB_ROOT}#" "$CONF_DIR/aws-vpc-web.conf"

if [[ -n "$LINK_DIR" ]]; then
    rm -f "$LINK_DIR/default"                       # 기본 사이트와 default_server 충돌 방지
    ln -sf "$CONF_DIR/aws-vpc-web.conf" "$LINK_DIR/aws-vpc-web.conf"
else
    # Amazon Linux: nginx.conf 의 기본 server 블록이 default_server 를 가지고 있으면 비활성화
    sed -i 's/listen       80 default_server;/listen       80;/; s/listen       \[::\]:80 default_server;/listen       [::]:80;/' /etc/nginx/nginx.conf || true
fi

nginx -t
systemctl enable --now nginx
systemctl restart nginx

# 자체 점검: 인스턴스 안에서 200 이 나와야 한다 (요구사항: curl http://localhost → 200)
for _ in $(seq 1 10); do
    code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost/health || true)"
    [[ "$code" == 200 ]] && break
    sleep 2
done
echo "[user-data] localhost / → $(curl -s -o /dev/null -w '%{http_code}' http://localhost/)  /health → $(curl -s http://localhost/health)"
# 아웃바운드 인터넷 확인 (요구사항: Public Subnet 에서 curl https://example.com 성공)
echo "[user-data] outbound https://example.com → $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://example.com || echo FAIL)"
echo "[user-data] done"
