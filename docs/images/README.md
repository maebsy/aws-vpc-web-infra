# 스크린샷

[`../console-guide.md`](../console-guide.md) 의 📸 번호대로 저장합니다.

| 파일 | 내용 |
| --- | --- |
| `01-iam-user-policy.png` | IAM 사용자에 최소 권한 정책만 연결된 화면 |
| `02-route-table.png` | Route Table 라우팅 탭 (local + 0.0.0.0/0 → igw) |
| `03-security-group.png` | SG 인바운드 (80 ← 0.0.0.0/0, 22 ← 내 IP/32) |
| `04-ec2-instance.png` | 인스턴스 세부 정보 (퍼블릭 IP, 서브넷, SG) |
| `05-ssh-localhost.png` | SSH 접속 후 `curl localhost` 200, `curl https://example.com` |
| `06-health-200.png` | **외부 접속 증빙**: `curl -i http://<IP>/health` → 200 OK |
| `07-cleanup-*.png` | 정리 후 EC2 terminated, VPC 목록, (선택) Billing |
| `bonus-docker-ps.png`, `bonus-docker-health.png` | 보너스 2 |
| `bonus-https-browser.png`, `bonus-https-curl.png` | 보너스 1 |
