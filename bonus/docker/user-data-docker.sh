#!/bin/bash
# =============================================================================
#  [보너스 2] user-data-docker.sh — Nginx 를 "호스트에 설치" 하지 않고 Docker 컨테이너로 실행
#
#    USER_DATA=bonus/docker/user-data-docker.sh bash scripts/provision.sh
#
#  이미지   : nginx:1.27-alpine (공식 이미지) + 이 스크립트가 만든 설정·페이지를 읽기 전용 마운트
#  포트 매핑: 호스트 80 → 컨테이너 80  (-p 80:80)  → 보안 그룹 80 규칙을 그대로 사용
#  재시작   : --restart unless-stopped  (인스턴스 재부팅 후 자동 실행)
#  검증     : 인스턴스 안 curl http://localhost → 200 / 외부 GET /health → 200 OK
#  기록     : /var/log/user-data.log
# =============================================================================
set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

IMAGE="nginx:1.27-alpine"
WEB=/opt/web

if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y docker.io curl
else
    dnf install -y docker
fi
systemctl enable --now docker
usermod -aG docker ubuntu 2>/dev/null || usermod -aG docker ec2-user 2>/dev/null || true

mkdir -p "$WEB/conf.d" "$WEB/html"
cat > "$WEB/conf.d/default.conf" <<'NGINX'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;
    location = /health {
        access_log off;
        default_type text/plain;
        return 200 "OK\n";
    }
    location / { try_files $uri $uri/ =404; }
    server_tokens off;
}
NGINX
cat > "$WEB/html/index.html" <<'HTML'
<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><title>Hello Cloud (Docker)</title></head>
<body style="font-family:system-ui,sans-serif;max-width:640px;margin:60px auto;padding:0 16px">
<h1>Hello Cloud — running in Docker</h1>
<p>EC2 안의 <code>nginx:1.27-alpine</code> 컨테이너가 응답했습니다. 헬스 체크: <a href="/health">/health</a></p>
</body></html>
HTML

docker pull "$IMAGE"
docker rm -f web 2>/dev/null || true
docker run -d --name web --restart unless-stopped -p 80:80 \
    -v "$WEB/conf.d:/etc/nginx/conf.d:ro" -v "$WEB/html:/usr/share/nginx/html:ro" \
    --health-cmd 'wget -qO- http://127.0.0.1/health || exit 1' --health-interval 30s \
    "$IMAGE"

for _ in $(seq 1 15); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost/health || true)" == 200 ]] && break
    sleep 2
done
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
echo "[user-data-docker] localhost / → $(curl -s -o /dev/null -w '%{http_code}' http://localhost/)  /health → $(curl -s http://localhost/health)"
