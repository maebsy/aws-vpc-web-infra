# 콘솔 작업 가이드 — 그대로 따라 하면 끝나는 순서

AWS 콘솔로 진행할 때의 순서와 입력값입니다. 같은 작업을 CLI 로 한 번에 하려면 [`scripts/provision.sh`](../scripts/provision.sh) 를 쓰세요(결과는 같습니다).
📸 표시는 **스크린샷을 남길 지점**입니다. `docs/images/` 에 번호 그대로 저장하면 README 링크와 맞습니다.

> 모든 리소스에 태그 `Project = aws-vpc-web-infra` 를 붙입니다. 정리할 때 이 태그로 빠짐없이 찾습니다.
> 리전은 오른쪽 위에서 **아시아 태평양(서울) ap-northeast-2** 인지 매번 확인합니다.

## 0. IAM 사용자 준비 (최초 1회)

루트 계정은 **IAM 사용자를 만드는 이 단계에서만** 쓰고, 이후 모든 작업은 실습용 IAM 사용자로 합니다.

1. IAM → 정책 → 정책 생성 → JSON 탭에 [`iam/policy-least-privilege.json`](../iam/policy-least-privilege.json) 붙여넣기 → 이름 `awsweb-least-privilege`
2. (선택) 정리 확인용 [`iam/policy-billing-readonly.json`](../iam/policy-billing-readonly.json) → `awsweb-billing-readonly`
3. IAM → 사용자 → 사용자 생성 `awsweb-student` → 콘솔 액세스 허용 → 위 정책만 직접 연결 (**AdministratorAccess 연결 금지**)
4. CLI 를 쓸 경우: 해당 사용자 → 보안 자격 증명 → 액세스 키 생성 → `aws configure` (리전 `ap-northeast-2`)
5. 루트 계정 로그아웃 → IAM 사용자 로그인 URL 로 로그인

📸 `01-iam-user-policy.png` — 사용자 권한 탭(연결된 정책이 최소 권한 정책뿐인 화면)

## 1. VPC

VPC → VPC 생성 → **VPC만** 선택 (VPC 등 마법사는 NAT 게이트웨이 등 과금 리소스를 함께 만들 수 있어 쓰지 않음)

| 항목 | 값 |
| --- | --- |
| 이름 태그 | `awsweb-vpc` |
| IPv4 CIDR | `10.0.0.0/16` |
| 태그 | `Project = aws-vpc-web-infra` |

생성 후 작업 → VPC 설정 편집 → **DNS 호스트 이름 활성화** 체크

## 2. Public Subnet

VPC → 서브넷 → 서브넷 생성

| 항목 | 값 |
| --- | --- |
| VPC | `awsweb-vpc` |
| 이름 | `awsweb-public-a` |
| 가용 영역 | `ap-northeast-2a` |
| IPv4 CIDR | `10.0.1.0/24` |

생성 후 작업 → 서브넷 설정 편집 → **퍼블릭 IPv4 주소 자동 할당 활성화** 체크

## 3. Internet Gateway

VPC → 인터넷 게이트웨이 → 생성 `awsweb-igw` → 작업 → **VPC에 연결** → `awsweb-vpc`

## 4. Route Table

VPC → 라우팅 테이블 → 생성 `awsweb-public-rt` (VPC: `awsweb-vpc`)

1. 라우팅 탭 → 라우팅 편집 → 라우팅 추가: 대상 `0.0.0.0/0`, 타깃 **인터넷 게이트웨이** `awsweb-igw`
2. 서브넷 연결 탭 → 명시적 서브넷 연결 편집 → `awsweb-public-a` 선택

📸 `02-route-table.png` — 라우팅 탭(`10.0.0.0/16 local`, `0.0.0.0/0 igw-…` 두 줄)

## 5. Security Group

EC2 → 보안 그룹 → 생성 `awsweb-web-sg` (VPC: `awsweb-vpc`)

| 방향 | 유형 | 포트 | 소스 | 설명 |
| --- | --- | --- | --- | --- |
| 인바운드 | HTTP | 80 | `0.0.0.0/0` | HTTP-public |
| 인바운드 | SSH | 22 | **내 IP** (콘솔이 `x.x.x.x/32` 로 채움) | SSH-my-ip-only |
| 아웃바운드 | 모든 트래픽 | 전체 | `0.0.0.0/0` | 기본값 (패키지 설치·curl 용) |

인바운드에 "모든 트래픽" 이나 `0-65535` 규칙을 만들지 않습니다.

📸 `03-security-group.png` — 인바운드 규칙 탭

## 6. EC2

EC2 → 인스턴스 시작

| 항목 | 값 |
| --- | --- |
| 이름 | `awsweb-web` (태그 `Project` 추가: 태그 추가 → 리소스 유형에 인스턴스·볼륨 체크) |
| AMI | Ubuntu Server 24.04 LTS (프리 티어 사용 가능) |
| 인스턴스 유형 | `t3.micro` (또는 `t2.micro`) |
| 키 페어 | 새 키 페어 `awsweb-key` (ED25519, .pem) — **다시 받을 수 없으니 안전하게 보관** |
| 네트워크 설정 → 편집 | VPC `awsweb-vpc` / 서브넷 `awsweb-public-a` / 퍼블릭 IP 자동 할당 **활성화** / 기존 보안 그룹 `awsweb-web-sg` |
| 스토리지 | 8 GiB gp3 |
| 고급 세부 정보 → 메타데이터 버전 | **V2 전용(토큰 필수)** |
| 고급 세부 정보 → 사용자 데이터 | [`scripts/user-data.sh`](../scripts/user-data.sh) 내용 붙여넣기 (보너스 2 는 [`bonus/docker/user-data-docker.sh`](../bonus/docker/user-data-docker.sh)) |

인스턴스가 "실행 중" + 상태 검사 2/2 통과가 될 때까지 2~3분 기다립니다.

📸 `04-ec2-instance.png` — 인스턴스 세부 정보(퍼블릭 IPv4, 서브넷, 보안 그룹이 보이게)

## 7. 서버 안에서 확인 (SSH)

```bash
chmod 400 awsweb-key.pem                          # Windows: 파일 속성에서 본인만 읽기 권한
ssh -i awsweb-key.pem ubuntu@<퍼블릭IP>

systemctl is-active nginx                         # active
curl -s -o /dev/null -w '%{http_code}\n' http://localhost      # 200 (요구사항)
curl -s http://localhost/health                   # OK
curl -s -o /dev/null -w '%{http_code}\n' https://example.com   # 200 (아웃바운드 인터넷)
sudo tail -n 5 /var/log/user-data.log             # user-data 실행 결과
```

📸 `05-ssh-localhost.png` — 위 명령 결과

## 8. 외부 접속 검증 — 방식 B (`/health`)

내 PC 터미널에서:

```bash
curl -i http://<퍼블릭IP>/health
```

```http
HTTP/1.1 200 OK
Server: nginx
Content-Type: text/plain
Cache-Control: no-store

OK
```

📸 `06-health-200.png` — 위 결과 (README 의 "외부 접속 증빙")

CLI 를 쓴다면 `bash scripts/verify.sh` 가 라우팅·보안 그룹·/health·SSH 를 한 번에 검증하고 `docs/evidence/` 에 기록합니다.

## 9. 정리

[`cleanup-checklist.md`](cleanup-checklist.md) 순서대로 삭제합니다. 📸 `07-cleanup-*.png`
