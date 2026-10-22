# 체크리스트 답변서

미션 체크리스트의 모든 항목에 대해 **근거 위치**와 **설명 답변**을 정리했습니다.

> 표기: 📂 파일 · ▶️ 확인 명령 · 📸 스크린샷 · 📄 자동 기록(`docs/evidence/`)
> ✅ 표시는 2026-10-21~22 서울 리전 실제 계정에서 수행해 남긴 증빙입니다 (계정 ID·내 IP 뒷자리는 가림).

- [항목 1. 구성 확인](#항목-1-구성-확인)
- [항목 2. 설계 설명](#항목-2-설계-설명)
- [항목 3. 원리 이해](#항목-3-원리-이해)
- [항목 4. 확장 질문](#항목-4-확장-질문)

---

## 항목 1. 구성 확인

### 1-1. VPC, Public Subnet, IGW, Route Table(0.0.0.0/0 → IGW) 구성

- 📂 [`scripts/provision.sh`](../scripts/provision.sh) 1~4단계 / 콘솔: [`console-guide.md`](console-guide.md) 1~4장
- ▶️ `bash scripts/verify.sh` → `## 1. Route Table` 에 `0.0.0.0/0  igw-…  active` 와 서브넷 연결 PASS
- 📸 [`02-route-table.png`](images/02-route-table.png) ✅ · 📄 [`verify-20261021-114519.txt`](evidence/verify-20261021-114519.txt) `0.0.0.0/0 igw-04af417632b803fb9 active` PASS

| 리소스 | 값 |
| --- | --- |
| VPC | `awsweb-vpc` 10.0.0.0/16, DNS 호스트 이름 ON |
| Subnet | `awsweb-public-a` 10.0.1.0/24, ap-northeast-2a, 퍼블릭 IP 자동 할당 ON |
| IGW | `awsweb-igw` → VPC attach |
| Route Table | `awsweb-public-rt`: `10.0.0.0/16 → local`, `0.0.0.0/0 → igw`, 서브넷 명시적 연결 |

### 1-2. EC2 SSH 접속 + 웹 서버 실행

- 📂 [`scripts/user-data.sh`](../scripts/user-data.sh): Nginx 설치·시작·enable, 부팅 로그 `/var/log/user-data.log`
- ▶️ `ssh -i .state/awsweb-key.pem ubuntu@<IP>` → `systemctl is-active nginx` = active, `curl -s -o /dev/null -w '%{http_code}' http://localhost` = **200**, `curl https://example.com` = 200 (아웃바운드)
- 📸 [`05-ssh-localhost.png`](images/05-ssh-localhost.png) ✅ · 📄 [`ssh-inside-20261021-114537.txt`](evidence/ssh-inside-20261021-114537.txt) (nginx active, localhost 200, IMDSv1 401, example.com 200)

### 1-3. 보안 그룹: 필요한 포트만, SSH 는 특정 IP

- ▶️ `verify.sh` → `80/tcp ← 0.0.0.0/0`, `22/tcp ← x.x.x.x/32 (단일 IP)`, `전체 포트 허용 규칙 없음`, `그 외 인바운드 없음` 4개 PASS
- 🧪 `tests/run-tests.sh` 가 provision 명령에 전체 포트 규칙이 없고 22 소스가 /32 인지 정적 검사
- 📸 [`03-security-group.png`](images/03-security-group.png) ✅ (443 규칙은 보너스 1 수행 중 추가한 것) · 📄 `verify-*.txt` SG 4개 PASS

### 1-4. 외부 접속 검증 — 방식 B 선택

- 📂 Nginx `location = /health { return 200 "OK\n"; }`
- ▶️ `curl -i http://<퍼블릭IP>/health` → `HTTP/1.1 200 OK` + 본문 `OK`
- 📸 [`06-health-200.png`](images/06-health-200.png) ✅ · 📄 [`verify-20261021-114519.txt`](evidence/verify-20261021-114519.txt) `/health → 200 OK` PASS

### 1-5. 리소스 정리 5종 (EC2 / EBS / EIP / IGW / VPC)

- 📂 [`cleanup-checklist.md`](cleanup-checklist.md) (필수 8단계 + 생성 안 했지만 확인할 6종)
- ▶️ `bash scripts/cleanup.sh` → 마지막에 `audit.sh` 가 EC2·EBS·EIP·NAT·스냅샷·VPC·IGW·SG 를 리전 전체에서 조회해 0 확인
- 📄 [`audit-20261022-000911.txt`](evidence/audit-20261022-000911.txt) 전 항목 0 ✅ · 📸 [`07-cleanup-ec2-terminated.png`](images/07-cleanup-ec2-terminated.png), [`07-cleanup-vpc-empty.png`](images/07-cleanup-vpc-empty.png) ✅ · Billing 청구 예정 USD 0.00 [`07-cleanup-billing.png`](images/07-cleanup-billing.png) ✅

---

## 항목 2. 설계 설명

### 2-1. 외부 → IGW → Subnet → EC2 네트워크 흐름 (다이어그램 기준)

📂 [`architecture.png`](architecture.png), [`design.md` 2장](design.md#2-외부-요청이-nginx-까지-도달하는-흐름)

**답변**: 사용자가 퍼블릭 IP 로 요청하면 인터넷 라우팅으로 **IGW** 에 도착하고, IGW 가 퍼블릭 IP 를 인스턴스의 사설 IP(10.0.1.x)로 바꿉니다. VPC 라우터가 `10.0.0.0/16 → local` 로 서브넷 안의 인스턴스에 전달하고, **보안 그룹**이 80 포트를 허용하면 Nginx 가 응답합니다. 응답은 서브넷 라우팅 테이블의 `0.0.0.0/0 → IGW` 경로로 나가고 IGW 가 다시 퍼블릭 IP 로 바꿔 인터넷으로 보냅니다. 보안 그룹은 상태 저장이라 응답 패킷은 아웃바운드 규칙과 무관하게 허용됩니다.

### 2-2. 보안 그룹 규칙 최소화 기준

📂 [`design.md` 3장](design.md#3-보안-그룹-규칙을-최소화한-기준)

**답변**: "이 포트를 누가 써야 하는가" 로 판단했습니다. 웹(80)은 모든 사용자가 써야 하므로 `0.0.0.0/0`, SSH(22)는 관리자 한 명만 쓰므로 **내 IP/32**, 그 외 포트는 쓰는 사람이 없으므로 열지 않았습니다. 443 은 HTTPS 보너스를 할 때만 추가합니다. 전체 포트 허용은 나중에 띄운 프로세스(DB, 디버그 서버)까지 자동으로 공개되므로 만들지 않았습니다.

### 2-3. 외부 접속 검증 방식과 구성

**답변**: **B (`GET /health`)** 를 선택했습니다. 사람이 화면을 보는 A 와 달리 **상태 코드 200 + 고정 본문 `OK`** 를 기계적으로 비교할 수 있어 스크립트(`verify.sh`)로 자동 검증되고, 실무의 ALB 헬스 체크·모니터링과 같은 형태이기 때문입니다. 구성은 user-data 가 Nginx 에 `location = /health { return 200 "OK\n"; }` 를 추가하는 것으로, 파일이나 백엔드 없이 Nginx 가 직접 응답하므로 "웹 서버 프로세스가 살아 있다" 만 정확히 확인합니다. 같은 서버가 `/` 에 정적 페이지도 응답하므로 A 방식도 동시에 확인됩니다.

### 2-4. 리소스 추적·정리 기준

📂 [`cleanup-checklist.md` 추적 기준](cleanup-checklist.md#추적-기준--무엇을-지울지-어떻게-빠짐없이-아나)

**답변**: 네 겹으로 추적합니다. ① 모든 리소스에 `Project=aws-vpc-web-infra` **태그** (CLI 필터·태그 편집기로 한 번에 조회) ② `awsweb-` **이름 규칙** (콘솔에서 눈으로 구분) ③ provision.sh 가 기록하는 **상태 파일** `.state/resources.env` (정확한 ID 로 삭제) ④ 태그와 무관하게 **리전 전체를 훑는 audit.sh** (태그를 빠뜨린 리소스도 잡음). 정리는 의존 관계 역순(EC2 → EIP → EBS → SG → RT → IGW → Subnet → VPC)으로 합니다.

---

## 항목 3. 원리 이해

### 3-1. Public Subnet Route Table 의 기본 경로가 필요한 이유

**답변**: 라우팅 테이블은 "이 목적지로 가는 패킷을 어디로 보낼지" 입니다. 기본으로는 `10.0.0.0/16 → local`(VPC 내부)만 있어서, VPC 밖 주소로 가는 패킷은 갈 곳이 없어 버려집니다. `0.0.0.0/0 → IGW` 는 "나머지 모든 목적지는 IGW 로" 라는 뜻이고, 이 경로가 있어야 ① 외부 요청에 대한 **응답**이 돌아가고 ② 인스턴스가 패키지 설치 같은 **아웃바운드** 통신을 할 수 있습니다. IGW 를 VPC 에 붙이기만 하고 이 경로가 없으면 접속은 timeout 이 됩니다(→ [트러블슈팅 사례 1](troubleshooting.md#사례-1-외부에서-웹-접속-timeout--기본-경로-누락)). 이 경로가 있는 서브넷을 Public Subnet 이라고 부릅니다.

### 3-2. Security Group 과 IAM 의 책임 차이, 최소 권한이 필요한 이유

📂 [`design.md` 4·5장](design.md#4-security-group-과-iam-의-차이)

**답변**: 보안 그룹은 **네트워크 패킷**(누가 이 서버의 어느 포트에 접속하나)을, IAM 은 **AWS API 호출**(누가 어떤 리소스를 만들고 지울 수 있나)을 통제합니다. 보안 그룹이 뚫리면 서버 하나가, IAM 이 뚫리면 계정 전체가 위험합니다. 최소 권한이 필요한 이유는 사고의 피해 범위를 줄이기 위해서입니다. 이 실습의 IAM 사용자는 서울 리전에서 EC2/VPC/SG 작업만, 인스턴스는 t2/t3.micro, 볼륨은 10GiB 이하만 가능해서, 키가 유출되거나 실수를 해도 큰 인스턴스로 과금 폭탄을 맞거나 S3·IAM 을 건드릴 수 없습니다. `iam-check.sh` 로 이 경계를 비용 없이 검증합니다.

### 3-3. SSH(22)·DB 포트를 0.0.0.0/0 으로 열면 안 되는 이유와 대안

**답변**: 인터넷 전체가 대상이 되면 자동화된 스캐너가 몇 분 안에 포트를 찾아 무차별 대입·취약점 공격을 시작합니다. 키 인증이라도 데몬 취약점이나 설정 실수 한 번이 곧 침해이고, DB 는 인증 우회·데이터 유출로 바로 이어집니다. 대안은 ① SSH 는 **내 IP/32** 로 제한(이번 구성) ② 22 를 아예 닫고 **SSM Session Manager / EC2 Instance Connect Endpoint** 로 IAM 기반 접속 ③ DB 는 **Private Subnet** 에 두고 보안 그룹 소스를 **웹 서버 SG** 로 지정 ④ 접속 위치가 자주 바뀌면 VPN/배스천 호스트.

### 3-4. 트러블슈팅에서 가설 → 검증 순서를 지킨 이유와 근거 활용

📂 [`troubleshooting.md`](troubleshooting.md)

**답변**: 증상만 보고 설정을 이것저것 바꾸면 우연히 고쳐져도 **무엇이 원인이었는지 모르고**, 원인과 무관한 변경(예: SSH 를 0.0.0.0/0 으로 열기)이 새 위험으로 남습니다. 그래서 한 번에 하나의 가설만 세우고, **그 가설을 확인할 수 있는 명령**으로 검증한 뒤 바꿨습니다. 가장 유용했던 근거는 **curl 의 실패 종류**입니다: 몇 초 기다리다 timeout(exit 28) 이면 네트워크 층(라우팅·SG)이, 즉시 refused(exit 7) 면 서버까지는 도달했고 프로세스 문제입니다. 이 하나로 가설의 절반을 지울 수 있었습니다. 권한 오류는 인코딩된 메시지를 `decode-authorization-message` 로 해독해 정확한 Action·조건을 근거로 삼았습니다.

---

## 항목 4. 확장 질문

### 4-1. 외부 접속이 안 될 때 점검 순서

**답변**: 바깥에서 안쪽으로, 각 단계에서 확인 명령을 하나씩:

| 순서 | 점검 | 확인 | 다음으로 넘어가는 조건 |
| --- | --- | --- | --- |
| 0 | 증상 분류 | `curl -v --max-time 8 http://<IP>/health` | timeout → 1부터 / refused → 4로 / HTTP 오류 → 5로 |
| 1 | **라우팅** | 서브넷의 라우팅 테이블에 `0.0.0.0/0 → igw` active, 서브넷 연결 | 있음 |
| 2 | **보안 그룹** (+NACL) | 인바운드 80 ← 0.0.0.0/0, NACL 기본 허용인지 | 있음 |
| 3 | **퍼블릭 IP/DNS** | 인스턴스에 퍼블릭 IP 가 있나, 내가 쓰는 IP 가 현재 IP 인가(재시작 시 바뀜), 도메인이면 `nslookup` | 일치 |
| 4 | **서버 프로세스** | SSH → `systemctl status nginx`, `ss -tlnp | grep :80`, `curl localhost` | localhost 200 |
| 5 | **로그** | `/var/log/nginx/error.log`, `/var/log/user-data.log`, `journalctl -u nginx`, 콘솔 "시스템 로그 가져오기" | 원인 확인 |

### 4-2. IAM 권한 부족 시 최소 범위를 찾는 방법

📂 [`design.md` 5장](design.md#5-iam-최소-권한-설계), [트러블슈팅 사례 4](troubleshooting.md#사례-4-unauthorizedoperation--최소-권한-밖-작업)

**답변**: 권한을 통째로 올리지 않고 ① 오류 메시지의 인코딩 문자열을 `aws sts decode-authorization-message` 로 해독해 **정확한 Action, Resource, 걸린 Condition** 을 찾고 ② 그 Action 하나를 가능한 좁은 Resource ARN·조건과 함께 추가하고 ③ `--dry-run` 으로 비용 없이 다시 확인하고(`iam-check.sh`) ④ 운영 중에는 CloudTrail·IAM Access Advisor 로 실제 사용한 Action 만 남겨 줄여 나갑니다. "요청을 정책에 맞출 수 있는지"(예: t3.small → t3.micro) 를 먼저 검토하는 것도 포함입니다.

### 4-3. 인스턴스를 2대로 늘린다면

📂 [`design.md` 7장](design.md#7-확장-인스턴스를-2대로-늘린다면)

**답변**: 지금은 **인스턴스 퍼블릭 IP 자체가 진입점**이라, 2대가 되면 주소가 둘로 나뉘고 한 대가 죽으면 그쪽 사용자가 실패합니다(단일 장애점). **ALB** 를 단일 진입점으로 두고 두 인스턴스를 대상 그룹에 등록해 `/health` 로 헬스 체크하면 죽은 인스턴스는 자동으로 빠집니다. ALB 는 최소 2개 AZ 가 필요하므로 Public Subnet 을 2a·2c 에 하나씩 만들고, 인스턴스는 Private Subnet 으로 옮겨 SG 80 의 소스를 **ALB 보안 그룹**으로 바꿉니다(인스턴스는 인터넷에 직접 노출되지 않음). 대수 조절은 Launch Template + Auto Scaling Group 으로 하고 user-data 를 그대로 재사용합니다. 비용상 ALB(시간당)와 Private Subnet 의 아웃바운드용 NAT Gateway(시간당+데이터)가 새로 생긴다는 점을 함께 고려합니다.

### 4-4. Billing 에 예상치 못한 비용이 찍혔다면

📂 [`design.md` 8장](design.md#8-비용-예상치-못한-청구가-생기면)

**답변**: **NAT Gateway → 연결 안 된 Elastic IP → 다른 리전 인스턴스 → 남은 EBS 볼륨/스냅샷 → ALB/RDS** 순으로 의심합니다(비싸고 잊기 쉬운 순). Cost Explorer 에서 서비스별·리전별·사용 유형별로 묶어 원인 서비스와 리전을 특정하고, 그 리전에서 리소스를 찾아 삭제한 뒤 `audit.sh` 로 0 을 확인합니다. 재발 방지로 AWS Budgets 에 낮은 금액의 알림을 걸고, 모든 리소스에 태그를 붙여 "태그 없는 리소스 = 정리 누락" 으로 바로 보이게 합니다.
