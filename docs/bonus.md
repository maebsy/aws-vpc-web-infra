# 보너스 과제

| 보너스 | 구현 | 사용자가 직접 할 일 |
| --- | --- | --- |
| **1. HTTPS 적용** | [`bonus/https/open-443.sh`](../bonus/https/open-443.sh) (SG 443 + Elastic IP), [`bonus/https/enable-https.sh`](../bonus/https/enable-https.sh) (certbot, 자동 갱신, 리다이렉트) | 무료 서브도메인 발급·A 레코드 설정, 스크립트 실행, 결과 캡처 |
| **2. Docker 배포** | [`bonus/docker/user-data-docker.sh`](../bonus/docker/user-data-docker.sh) (Docker 설치 + `nginx:1.27-alpine` 실행, /health, 헬스체크, 자동 재시작) | `USER_DATA=… provision.sh` 실행, `docker ps`·외부 접속 캡처 |

---

## 보너스 2 — Docker 컨테이너로 웹 서비스 배포

| 항목 | 값 |
| --- | --- |
| 이미지 | **`nginx:1.27-alpine`** (Docker Hub 공식 이미지) |
| 실행 방식 | user-data 가 첫 부팅에 `docker run -d --name web --restart unless-stopped -p 80:80 -v /opt/web/conf.d:/etc/nginx/conf.d:ro -v /opt/web/html:/usr/share/nginx/html:ro --health-cmd … nginx:1.27-alpine` |
| **포트 매핑** | **호스트 `80` → 컨테이너 `80`** (`-p 80:80`). 보안 그룹은 기본 과제와 같은 80 ← 0.0.0.0/0 그대로 |
| 설정 | `/health` → `200 OK` 고정 응답 (기본 과제와 동일), 정적 페이지 "running in Docker" |
| 운영 장치 | `--restart unless-stopped` (재부팅·크래시 후 자동 시작), `--health-cmd` (컨테이너 상태 `healthy` 표시), 설정은 읽기 전용(`:ro`) 마운트 |

```bash
USER_DATA=bonus/docker/user-data-docker.sh bash scripts/provision.sh   # 새로 만들 때
# 콘솔이라면: 인스턴스 시작 → 고급 세부 정보 → 사용자 데이터에 user-data-docker.sh 내용 붙여넣기
```

**검증 (README 에 스크린샷 2장 이상)**

```bash
# ① 인스턴스 안 (SSH)
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
# NAMES  IMAGE              STATUS                  PORTS
# web    nginx:1.27-alpine  Up 2 minutes (healthy)  0.0.0.0:80->80/tcp, :::80->80/tcp
curl -s -o /dev/null -w '%{http_code}\n' http://localhost      # 200 (필수)

# ② 외부 (내 PC)
curl -i http://<퍼블릭IP>/health                                # 200 OK / OK (필수)
```

📸 `docs/images/bonus-docker-ps.png`, `docs/images/bonus-docker-health.png`

**호스트 설치와 비교해 달라진 점**: Nginx 버전이 이미지 태그로 고정돼 어느 서버에서나 같은 결과가 나오고, 서버에는 Docker 만 있으면 됩니다. 반대로 컨테이너 로그는 `docker logs web` 으로 봐야 하고(호스트 `/var/log/nginx` 가 아님), 포트 매핑을 빠뜨리면 컨테이너는 떠 있는데 외부 접속은 안 되는(SG 가 아니라 호스트 포트 문제) 새로운 장애 유형이 생깁니다.

---

## 보너스 1 — HTTPS 적용 (무료 서브도메인 + Let's Encrypt)

**구성**

```
https://myweb.duckdns.org ──▶ DNS A 레코드 ──▶ Elastic IP ──▶ IGW ──▶ SG 443 ──▶ Nginx(:443, Let's Encrypt 인증서)
http://…  ──▶ Nginx(:80) ──301──▶ https://…          (인증 갱신용 /.well-known 은 80 으로 처리)
```

**절차**

1. **Elastic IP + 443 열기** (내 PC): `bash bonus/https/open-443.sh`
   퍼블릭 IP 는 인스턴스를 멈추면 바뀌므로, DNS 가 가리킬 고정 주소로 Elastic IP 를 씁니다.
2. **무료 서브도메인**: [DuckDNS](https://www.duckdns.org) 등에서 서브도메인 발급 → IP 를 1번의 Elastic IP 로 설정 → `nslookup <도메인>` 으로 반영 확인
3. **인증서 발급** (인스턴스 안):
   ```bash
   scp -i .state/awsweb-key.pem bonus/https/enable-https.sh ubuntu@<EIP>:~
   ssh -i .state/awsweb-key.pem ubuntu@<EIP> sudo bash enable-https.sh <도메인> <이메일>
   ```
   스크립트가 DNS 가 이 서버를 가리키는지 먼저 확인하고, `certbot --nginx --redirect` 로 인증서 설치·HTTP→HTTPS 리다이렉트, `certbot renew --dry-run` 으로 자동 갱신까지 확인합니다.
4. **검증**: 브라우저 `https://<도메인>` 자물쇠 / `curl -I https://<도메인>/health` → `HTTP/1.1 200 OK`
5. **정리**: `bash bonus/https/open-443.sh --revert` (443 규칙 제거 + **Elastic IP 릴리스**), DuckDNS 레코드 삭제

📸 `docs/images/bonus-https-browser.png`, `docs/images/bonus-https-curl.png`

**주의**
- 80 포트를 닫으면 HTTP-01 인증과 갱신이 실패합니다. 80 은 리다이렉트용으로 유지합니다.
- Elastic IP 는 연결이 끊긴 상태로 남으면 과금됩니다. 정리 체크리스트 2번에 포함했습니다.
- Let's Encrypt 는 같은 도메인에 대한 발급 횟수 제한이 있으니 실패하면 원인(DNS·SG)을 먼저 고치고 다시 실행합니다.
