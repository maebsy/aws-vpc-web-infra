# 리소스 정리 체크리스트

실습이 끝나면 **생성 역순**으로 삭제하고, 각 항목의 "근거" 를 남깁니다. CLI 로는 `bash scripts/cleanup.sh` 한 번으로 아래 1~8 을 순서대로 실행하고 마지막에 `audit.sh` 로 확인합니다.

| 수행 정보 | 값 |
| --- | --- |
| 정리 일시 | **2026-10-22 00:08 ~ 00:09 KST** (`cleanup.sh` 1회 실행) |
| 리전 | ap-northeast-2 (서울) |
| 추적 기준 | 태그 `Project = aws-vpc-web-infra`, 이름 접두어 `awsweb-` |
| 확인 근거 | [`audit-20261022-000911.txt`](evidence/audit-20261022-000911.txt), [`cleanup-20261022-000801.txt`](evidence/cleanup-20261022-000801.txt) + 📸 `07-cleanup-*.png` |

## 추적 기준 — 무엇을 지울지 어떻게 빠짐없이 아나

| 기준 | 방법 | 이유 |
| --- | --- | --- |
| **태그** | 모든 리소스에 `Project=aws-vpc-web-infra` | 콘솔의 리소스 그룹/태그 편집기, CLI `--filters Name=tag:Project,…` 로 한 번에 조회 |
| **이름 규칙** | `awsweb-vpc`, `awsweb-public-a`, `awsweb-igw`, `awsweb-public-rt`, `awsweb-web-sg`, `awsweb-web`, `awsweb-key` | 콘솔 목록에서 눈으로 구분 |
| **상태 파일** | `.state/resources.env` (provision.sh 가 생성 ID 기록, git 제외) | 정확한 ID 로 삭제 |
| **리전 전체 감사** | `audit.sh` 는 태그와 무관하게 EC2·EBS·EIP·NAT·스냅샷을 리전 전체에서 조회 | 태그를 깜빡한 리소스도 잡기 위해 |

## 필수 정리 항목 (과제 최소 5종: EC2 / EBS / EIP / IGW / VPC)

| 순서 | 리소스 | 작업 | 완료 근거 (콘솔 화면 또는 CLI) | 확인 |
| --- | --- | --- | --- | --- |
| 1 | **EC2** `awsweb-web` | 인스턴스 종료 | 상태 `terminated` · `describe-instances` 에서 terminated 외 0개 | ☑ `i-020360102ec4d4043`(기본), `i-06fd3c7d996a20681`(Docker 보너스) terminated |
| 2 | **Elastic IP** (할당했다면) | 연결 해제 → 릴리스 | `describe-addresses` 결과 0개 | ☑ 할당하지 않음 (HTTPS 보너스는 자동 할당 IP + sslip.io), audit 0 |
| 3 | **EBS 볼륨** | 루트 볼륨은 종료 시 자동 삭제(`DeleteOnTermination=true`). 남은 `available` 볼륨 삭제 | `describe-volumes` 결과 0개 | ☑ 루트 볼륨 자동 삭제, audit 0 |
| 4 | Security Group `awsweb-web-sg` | 삭제 (default SG 는 VPC 와 함께 삭제) | 목록에서 사라짐 | ☑ `sg-02ed843be1eca48fb` 삭제 |
| 5 | Route Table `awsweb-public-rt` | 서브넷 연결 해제 → 삭제 | 목록에서 사라짐 | ☑ `rtb-019d5a395d230f163` 연결 해제 → 삭제 |
| 6 | **Internet Gateway** `awsweb-igw` | VPC 에서 분리 → 삭제 | `describe-internet-gateways --filters tag:Project` 0개 | ☑ `igw-04af417632b803fb9` 분리 → 삭제 |
| 7 | Subnet → **VPC** | 서브넷 삭제 → VPC 삭제 | `describe-vpcs --filters tag:Project` 0개 | ☑ `subnet-0a25c72f99daa5869` → `vpc-0bdc44471e12dcd3f` 삭제 |
| 8 | Key Pair `awsweb-key` | 삭제 (과금 없음, 정리 차원) + 로컬 `.pem` 보관 또는 삭제 | 목록에서 사라짐 | ☑ 삭제, 로컬 `.pem` 도 삭제 |

## 생성하지 않았지만 반드시 0 인지 확인할 항목

| 리소스 | 과금 특징 | 확인 방법 | 확인 |
| --- | --- | --- | --- |
| NAT Gateway | **시간당 + 데이터 처리량** 과금. "VPC 등" 마법사가 자동 생성할 수 있음 | VPC → NAT 게이트웨이 / `audit.sh` | ☑ audit 0 |
| ELB / ALB | 시간당 과금 | EC2 → 로드 밸런서 (최소 권한 정책에는 조회 권한 없음 → 콘솔에서 확인) | ☑ 콘솔 "No load balancers" (ap-northeast-2) |
| RDS | 인스턴스 시간 + 스토리지 | RDS 콘솔 | ☑ 콘솔 Databases (0) |
| EBS 스냅샷 | GB-월 과금 | EC2 → 스냅샷 (내 소유) / `audit.sh` | ☑ audit 0 |
| 다른 리전 | 실수로 다른 리전에 만든 리소스 | 콘솔 오른쪽 위 리전 전환, EC2 대시보드 "리소스" 카운트 | ☑ EC2 Global View: 다른 리전은 기본 VPC·서브넷·SG 만 (무과금), Volumes 0 |
| **Billing** | 당월 비용 | Billing and Cost Management → 홈 / 프리 티어 사용량 (반영까지 최대 24시간) | ☑ 2026-10-22 23:23 청구 예정액 **USD 0.00** — 사용분 약 $0.24 는 프리 플랜 크레딧 차감 ([기록](evidence/billing-20261022-2323.txt)) |

## 순서가 중요한 이유

리소스끼리 서로 붙잡고 있어서, 앞의 것을 지우지 않으면 뒤의 것이 `DependencyViolation` 으로 실패합니다.

```
EC2 ─(ENI 가 붙잡음)─▶ Subnet, Security Group
EIP ─(연결)─▶ EC2/ENI
Route Table ─(연결)─▶ Subnet
IGW ─(attach)─▶ VPC
Subnet, SG, RT, IGW ─(소속)─▶ VPC
```

- EC2 를 먼저 종료하고 **terminated 가 된 뒤** 진행합니다. `shutting-down` 동안에는 네트워크 인터페이스(ENI)가 남아 SG·Subnet 삭제가 실패합니다.
- Elastic IP 는 **연결되지 않은 상태로 남아 있으면 계속 과금**됩니다. 인스턴스 종료로 함께 사라지지 않으므로 반드시 따로 릴리스합니다.
- EBS 는 인스턴스와 별개 리소스입니다. `DeleteOnTermination=false` 였거나 따로 만든 볼륨은 `available` 상태로 남아 과금됩니다.

## 정리 결과 (audit.sh 출력 붙여넣기)

```text
# audit.sh 2026-10-22 00:09:11 KST region=ap-northeast-2 project=aws-vpc-web-infra
EC2 (terminated 제외)          0 ✅
EBS 볼륨 (전체)              0 ✅
Elastic IP                       0 ✅
NAT Gateway (삭제 제외)      0 ✅
EBS 스냅샷 (내 소유)       0 ✅
VPC (Project 태그)             0 ✅
Internet Gateway (태그)        0 ✅
Security Group (태그)          0 ✅
Key Pair                         0 ✅
ELB/ALB                          확인 불가 (AccessDenied) → 콘솔에서 확인
RDS                              확인 불가 (AccessDenied) → 콘솔에서 확인

결론: 과금 위험 리소스 없음 (Key Pair 는 과금 없음)
※ Billing Dashboard 의 당월 비용은 반영까지 최대 24시간 걸릴 수 있습니다.
```

ELB/RDS 는 최소 권한 정책에 조회 권한이 없어 루트 콘솔에서 따로 확인했습니다 (위 표).

📸 [`07-cleanup-ec2-terminated.png`](images/07-cleanup-ec2-terminated.png) — 인스턴스 2대 Terminated

![EC2 terminated](images/07-cleanup-ec2-terminated.png)

📸 [`07-cleanup-vpc-empty.png`](images/07-cleanup-vpc-empty.png) — 기본 VPC(172.31.0.0/16) 만 남음

![VPC 목록](images/07-cleanup-vpc-empty.png)

📸 [`07-cleanup-billing.png`](images/07-cleanup-billing.png) — 정리 약 23시간 뒤 Bills: 10월 청구 예정액 USD 0.00 (프리 플랜은 크레딧으로 차감)

![Billing](images/07-cleanup-billing.png)

📸 [`07-cleanup-billing-credits.png`](images/07-cleanup-billing-credits.png) — Credits: 실습 사용분 약 $0.24 를 AWS Free Tier 크레딧에서 차감, $119.76 남음
