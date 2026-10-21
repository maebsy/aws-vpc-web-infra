# 트러블슈팅 보고서

외부 접속이 안 될 때 "어디가 막혔는지" 를 **로그·명령 결과를 근거로** 좁혀 가는 과정을 기록합니다.
장애는 실제 환경에서 [`scripts/troubleshoot.sh`](../scripts/troubleshoot.sh) 로 **의도적으로 재현**하고(재현 → 원복 자동), 실행 기록은 `docs/evidence/troubleshoot-<사례>-<시각>.txt` 에 남습니다.

- [진단 원칙: timeout 과 refused 는 다른 층의 문제다](#진단-원칙)
- [사례 1. 외부에서 웹 접속 timeout — 기본 경로 누락](#사례-1-외부에서-웹-접속-timeout--기본-경로-누락)
- [사례 2. SSH 접속 timeout — 허용 IP 불일치](#사례-2-ssh-접속-timeout--허용-ip-불일치)
- [사례 3. connection refused — 웹 서버 프로세스 중지](#사례-3-connection-refused--웹-서버-프로세스-중지)
- [사례 4. UnauthorizedOperation — 최소 권한 밖 작업](#사례-4-unauthorizedoperation--최소-권한-밖-작업)
- [재발 방지 체크리스트](#재발-방지-체크리스트)

> **작성 상태**: 2026-10-21 서울 리전 실제 리소스에서 4개 사례를 재현했고, **"실제 관측" 칸은 `troubleshoot.sh` 실행 결과(evidence 파일)를 옮긴 것입니다.** 계정 ID·내 IP 뒷자리는 가렸습니다.
> 실행: `bash scripts/troubleshoot.sh route` (나머지 사례도 동일). 각 칸에 해당 evidence 파일의 줄을 그대로 옮깁니다.

## 진단 원칙

외부 요청이 웹 서버에 닿기까지 거치는 층과, 각 층이 막혔을 때 클라이언트가 보는 증상이 다릅니다.

```
브라우저 ─▶ DNS/퍼블릭 IP ─▶ IGW ─▶ Route Table ─▶ Security Group ─▶ 인스턴스 OS ─▶ Nginx(:80)
           (주소가 맞나)    (인터넷 관문)  (경로가 있나)    (허용됐나)        (켜져 있나)    (듣고 있나)
```

| 증상 (curl) | 의미 | 의심할 층 |
| --- | --- | --- |
| `curl: (28) … timed out` (수 초 대기) | 패킷이 **응답 없이 버려짐** | Route Table · Security Group · NACL · 퍼블릭 IP 없음 |
| `curl: (7) … Connection refused` (즉시) | 서버 OS 까지 **도달했지만** 그 포트를 아무도 듣지 않음 → OS 가 RST 응답 | 웹 서버 프로세스 · 포트 바인딩 |
| `HTTP 403/404/502` | 웹 서버까지 정상, **애플리케이션 응답** 문제 | Nginx 설정 · 파일 · 백엔드 |
| `Could not resolve host` | 이름 해석 실패 | DNS |

그래서 점검 순서는 **바깥에서 안으로**: 라우팅 → 보안 그룹 → 퍼블릭 IP/DNS → 서버 프로세스/로그 입니다. 한 번에 하나의 가설만 바꾸고, 바꾼 뒤 같은 명령으로 다시 확인합니다.

---

## 사례 1. 외부에서 웹 접속 timeout — 기본 경로 누락

| 항목 | 내용 |
| --- | --- |
| **증상** | 브라우저와 `curl http://<IP>/health` 가 응답 없이 대기하다 timeout. 인스턴스 콘솔 상태 검사는 2/2 정상 |
| **원인 가설** | ① 보안 그룹 80 규칙 누락 ② Nginx 중지 ③ **Route Table 에 `0.0.0.0/0 → IGW` 경로 없음** |
| **가설을 좁힌 근거** | refused 가 아니라 **timeout** → 서버 OS 까지 패킷이 오지 않음 → ② 제외(프로세스 문제면 즉시 refused). 보안 그룹 규칙 조회 결과 80 허용이 그대로 있음 → ① 제외 |
| **검증 방법** | `aws ec2 describe-route-tables --route-table-ids <rtb>` 로 경로 확인 / 서브넷 연결 확인 |
| **조치 내용** | `aws ec2 create-route --route-table-id <rtb> --destination-cidr-block 0.0.0.0/0 --gateway-id <igw>` |
| **결과** | `/health` → `200 OK` |
| **재발 방지** | 배포 체크리스트에 "Public Subnet 의 라우팅 테이블 = `0.0.0.0/0 → igw-…` + 서브넷 명시적 연결" 추가. `verify.sh` 1번 항목으로 자동 검사 |

**왜 경로 하나로 전체가 끊기나** — IGW 가 VPC 에 붙어 있어도, 서브넷의 라우팅 테이블에 "VPC 밖으로 가는 트래픽은 IGW 로" 라는 줄이 없으면 인스턴스의 **응답 패킷**이 인터넷으로 나갈 길이 없습니다. 들어오는 요청은 IGW 까지 와도 응답이 돌아가지 못해 클라이언트는 timeout 을 봅니다. SSH 도 같이 끊기므로 서버 안에서 확인할 수 없어, 콘솔/CLI 의 설정 조회로 검증합니다.

**실제 관측** (`docs/evidence/troubleshoot-route-20261021-235351.txt`, 2026-10-21)

```text
## 정상 상태  (23:53:51)
http_code=200 time_total=0.016891s
## 장애 주입: 0.0.0.0/0 → IGW 경로 삭제
$ aws ec2 delete-route --route-table-id rtb-019d5a395d230f163 --destination-cidr-block 0.0.0.0/0
## 증상: 외부에서 /health  (23:53:58)
http_code=000 time_total=8.002598s
(curl exit 28: 0=정상, 7=connection refused, 28=timeout)
22/tcp: 6초 내 응답 없음 (timeout)
## 가설 검증 1: 인스턴스 상태 → running  ok  ok   (서버는 멀쩡함)
## 가설 검증 2: 보안 그룹 → 80 0.0.0.0/0 / 443 0.0.0.0/0 / 22 116.121.x.x/32  (그대로)
## 가설 검증 3: 라우팅
10.0.0.0/16	local                     ← 0.0.0.0/0 → igw 가 사라짐
## 조치: create-route 0.0.0.0/0 → igw-04af417632b803fb9
## 결과  (23:54:23)
http_code=200 time_total=0.030423s
```

---

## 사례 2. SSH 접속 timeout — 허용 IP 불일치

| 항목 | 내용 |
| --- | --- |
| **증상** | 어제까지 되던 `ssh -i key.pem ubuntu@<IP>` 가 `Connection timed out`. 같은 시각 HTTP 는 정상 |
| **원인 가설** | ① 인스턴스 다운 ② sshd 중지 ③ **보안 그룹 22 규칙의 소스 IP 와 현재 내 공인 IP 가 다름** (집/카페/통신사 변경) |
| **가설을 좁힌 근거** | HTTP 는 정상 → 인스턴스·라우팅 정상 → ① 제외. timeout(refused 아님) → sshd 까지 오지 않음 → ② 제외 |
| **검증 방법** | `curl https://checkip.amazonaws.com` (현재 내 IP) vs `describe-security-group-rules` 의 22 규칙 `CidrIpv4` 비교 |
| **조치 내용** | 22 규칙 소스를 **현재 IP/32 로 수정** (0.0.0.0/0 으로 넓히지 않음) |
| **결과** | `22/tcp: 연결됨`, SSH 접속 성공 |
| **재발 방지** | SSH 가 안 되면 "0.0.0.0/0 으로 열기" 대신 `checkip` 확인 → /32 수정. 장기적으로는 SSH 포트를 닫고 SSM Session Manager 사용 검토 |

**실제 관측** (`docs/evidence/troubleshoot-ssh-ip-20261021-235424.txt`, 2026-10-21)

```text
## 정상 상태          22/tcp: 연결됨
## 장애 주입          22/tcp 소스 → 198.51.100.1/32 (문서용 예약 대역 = "IP 가 바뀐 상황")
## 증상               22/tcp: 6초 내 응답 없음 (timeout)
                      (HTTP 는 정상) http_code=200 time_total=0.013176s
## 가설 검증          my ip : 116.121.x.x   vs   SG: 198.51.100.1/32
## 조치               modify-security-group-rules → 현재 IP/32
## 결과               22/tcp: 연결됨
```

---

## 사례 3. connection refused — 웹 서버 프로세스 중지

| 항목 | 내용 |
| --- | --- |
| **증상** | `curl http://<IP>/health` 가 **즉시** `Failed to connect … Connection refused` |
| **원인 가설** | ① 보안 그룹 ② 라우팅 ③ **Nginx 중지/포트 미바인딩** |
| **가설을 좁힌 근거** | 즉시 refused = 패킷이 서버 OS 까지 도달해 RST 를 받음 → 네트워크 경로(①②)는 정상. 문제는 서버 안 |
| **검증 방법** | SSH → `ss -tlnp | grep :80` (LISTEN 없음), `systemctl is-active nginx` (inactive), `journalctl -u nginx` |
| **조치 내용** | `sudo systemctl start nginx` (원인이 설정 오류였다면 `nginx -t` 로 문법 확인 후 수정) |
| **결과** | `/health` → `200 OK`, `curl http://localhost` → 200 |
| **재발 방지** | `systemctl enable nginx` (재부팅 후 자동 시작) 확인, 보너스 2 에서는 컨테이너 `--restart unless-stopped` + healthcheck 로 자동 복구 |

**실제 관측** (`docs/evidence/troubleshoot-nginx-20261021-235444.txt`, 2026-10-21)

```text
## 정상 상태          http_code=200 time_total=0.013899s
## 장애 주입          sudo systemctl stop nginx
## 증상               http_code=000 time_total=0.005953s
                      (curl exit 7 = connection refused)   ← 사례 1 의 timeout(8초)과 대비: 0.006초 만에 즉시 거부
## 가설 검증 (서버 안)
80 포트 LISTEN 없음
inactive
localhost http_code=000
systemd[1]: Stopped nginx.service - A high performance web server and a reverse proxy server.
## 조치               sudo systemctl start nginx
## 결과               http_code=200 time_total=0.014398s / localhost http_code=200
```

---

## 사례 4. UnauthorizedOperation — 최소 권한 밖 작업

| 항목 | 내용 |
| --- | --- |
| **증상** | 성능을 올리려 `t3.small` 로 인스턴스를 만들려 하자 `An error occurred (UnauthorizedOperation) … You are not authorized to perform this operation. Encoded authorization failure message: …` |
| **원인 가설** | ① 권한 정책이 연결되지 않음 ② 리전 조건 불일치 ③ **인스턴스 타입 조건(t2/t3.micro)에 걸림** |
| **가설을 좁힌 근거** | 같은 사용자로 `t3.micro` 는 dry-run 성공 → ①② 제외 |
| **검증 방법** | `aws sts decode-authorization-message --encoded-message <메시지>` → `action: ec2:RunInstances`, `resource: …instance/*`, `ec2:InstanceType = t3.small` 확인 |
| **조치 내용** | **권한을 넓히지 않고** 요구사항(프리 티어) 범위인 `t3.micro` 로 요청 수정. 정말 필요한 변경이면 "어떤 Action·Resource·조건이 추가로 필요한지" 를 해독 결과로 특정해 그 한 줄만 추가 요청 |
| **결과** | `DryRunOperation` (요청이 성공했을 것) |
| **재발 방지** | 권한 오류는 해독 메시지로 정확한 Action 을 찾는다. `iam-check.sh` 로 허용/거부 경계를 비용 없이 주기적으로 확인 |

**실제 관측** (`docs/evidence/troubleshoot-iam-20261021-235447.txt`, `iam-check-*.txt`, 2026-10-21)

```text
## 증상: t3.small 실행 (dry-run)
An error occurred (UnauthorizedOperation) when calling the RunInstances operation:
You are not authorized to perform this operation. User: arn:aws:iam::<ACCOUNT_ID>:user/awsweb-student ...
## 검증: sts decode-authorization-message
{
  "allowed": false,
  "explicitDeny": false,
  "action": "RunInstances",
  "resource": "arn:aws:ec2:ap-northeast-2:<ACCOUNT_ID>:instance/*",
  "instanceType": "t3.small"
}
## 조치: 권한을 넓히지 않고 t3.micro 로 요청 수정
An error occurred (DryRunOperation) ... Request would have succeeded, but DryRun flag is set.

iam-check.sh: PASS 10 / FAIL 0  (허용 4건 allow, 범위 밖 6건 deny)
```

---

## 재발 방지 체크리스트

배포 직후 `bash scripts/verify.sh` 가 아래를 자동 검사합니다.

- [ ] Public Subnet 라우팅 테이블: `0.0.0.0/0 → igw-…` 가 `active`, 서브넷 명시적 연결
- [ ] Subnet 퍼블릭 IP 자동 할당 ON (또는 Elastic IP 연결)
- [ ] SG 인바운드: 80 ← 0.0.0.0/0, 22 ← 내 IP/32, 그 외 없음, 전체 포트 규칙 없음
- [ ] 서버: `systemctl is-enabled nginx`, `curl http://localhost` 200
- [ ] 외부: `GET /health` 200 + `OK`
- [ ] 권한 오류는 `decode-authorization-message` 로 원인 Action 을 특정 (권한을 통째로 올리지 않음)
