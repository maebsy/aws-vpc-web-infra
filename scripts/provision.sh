#!/usr/bin/env bash
# =============================================================================
#  provision.sh — VPC 부터 EC2 웹 서버까지 AWS CLI 로 구축 (콘솔 작업과 같은 순서)
#
#    bash scripts/provision.sh                 # 실제 생성 (IAM 사용자 자격 증명 필요)
#    DRY_RUN=1 bash scripts/provision.sh       # 실행할 명령만 미리 보기 (AWS 호출 없음)
#    MY_IP=203.0.113.10 bash scripts/provision.sh   # SSH 허용 IP 직접 지정
#    USER_DATA=bonus/docker/user-data-docker.sh bash scripts/provision.sh   # [보너스 2] 컨테이너로 배포
#
#  만드는 것 (모두 Project=aws-vpc-web-infra 태그)
#    1. VPC 10.0.0.0/16 (DNS hostname 활성화)
#    2. Public Subnet 10.0.1.0/24 (ap-northeast-2a, 퍼블릭 IP 자동 할당)
#    3. Internet Gateway → VPC 연결
#    4. Route Table: 0.0.0.0/0 → IGW, Subnet 연결
#    5. Security Group: 80/tcp ← 0.0.0.0/0, 22/tcp ← 내 IP/32 (그 외 인바운드 없음)
#    6. Key Pair (.state/<키이름>.pem, 권한 400)
#    7. EC2 t3.micro, Ubuntu 24.04, 루트 볼륨 8GiB gp3, IMDSv2 강제, user-data 로 Nginx + /health
#  생성한 ID 는 .state/resources.env 에 기록 → cleanup.sh 가 역순으로 삭제
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib.sh"
preflight
load_state

# ---------------------------------------------------------------- SSH 허용 IP
if [[ -z "${MY_IP:-}" ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then MY_IP=203.0.113.10
    else MY_IP="$(curl -s --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]')"; fi
fi
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "내 공인 IP 를 알 수 없습니다. MY_IP=x.x.x.x 로 지정하세요"
info "SSH 허용 소스: $MY_IP/32"

# ---------------------------------------------------------------- 1. VPC
if [[ -z "${VPC_ID:-}" ]]; then
    VPC_ID="$(DRY_VALUE=vpc-DRYRUN awsx ec2 create-vpc --cidr-block "$VPC_CIDR" \
        --tag-specifications "$(tags vpc "$PREFIX-vpc")" --query Vpc.VpcId --output text)"
    awsx ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' >/dev/null
    save_state VPC_ID "$VPC_ID"
fi
ok "VPC $VPC_ID ($VPC_CIDR)"

# ---------------------------------------------------------------- 2. Public Subnet
if [[ -z "${SUBNET_ID:-}" ]]; then
    SUBNET_ID="$(DRY_VALUE=subnet-DRYRUN awsx ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_CIDR" \
        --availability-zone "$AZ" --tag-specifications "$(tags subnet "$PREFIX-public-a")" \
        --query Subnet.SubnetId --output text)"
    # 이 서브넷에 뜨는 인스턴스는 퍼블릭 IP 를 자동으로 받는다 (외부에서 접근 가능해지는 조건 중 하나)
    awsx ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch >/dev/null
    save_state SUBNET_ID "$SUBNET_ID"
fi
ok "Subnet $SUBNET_ID ($SUBNET_CIDR, $AZ)"

# ---------------------------------------------------------------- 3. Internet Gateway
if [[ -z "${IGW_ID:-}" ]]; then
    IGW_ID="$(DRY_VALUE=igw-DRYRUN awsx ec2 create-internet-gateway \
        --tag-specifications "$(tags internet-gateway "$PREFIX-igw")" \
        --query InternetGateway.InternetGatewayId --output text)"
    awsx ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" >/dev/null
    save_state IGW_ID "$IGW_ID"
fi
ok "Internet Gateway $IGW_ID → $VPC_ID"

# ---------------------------------------------------------------- 4. Route Table
if [[ -z "${RTB_ID:-}" ]]; then
    RTB_ID="$(DRY_VALUE=rtb-DRYRUN awsx ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "$(tags route-table "$PREFIX-public-rt")" \
        --query RouteTable.RouteTableId --output text)"
    # VPC 밖(인터넷)으로 가는 모든 트래픽은 IGW 로. 이 경로가 있어야 "Public" Subnet 이다
    awsx ec2 create-route --route-table-id "$RTB_ID" --destination-cidr-block 0.0.0.0/0 \
        --gateway-id "$IGW_ID" >/dev/null
    RTB_ASSOC_ID="$(DRY_VALUE=rtbassoc-DRYRUN awsx ec2 associate-route-table --route-table-id "$RTB_ID" \
        --subnet-id "$SUBNET_ID" --query AssociationId --output text)"
    save_state RTB_ID "$RTB_ID"
    save_state RTB_ASSOC_ID "$RTB_ASSOC_ID"
fi
ok "Route Table $RTB_ID (0.0.0.0/0 → $IGW_ID, $SUBNET_ID 연결)"

# ---------------------------------------------------------------- 5. Security Group
if [[ -z "${SG_ID:-}" ]]; then
    SG_ID="$(DRY_VALUE=sg-DRYRUN awsx ec2 create-security-group --group-name "$PREFIX-web-sg" \
        --description "HTTP from anywhere, SSH from my IP only" --vpc-id "$VPC_ID" \
        --tag-specifications "$(tags security-group "$PREFIX-web-sg")" --query GroupId --output text)"
    awsx ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
        "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTP-public}]" >/dev/null
    awsx ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
        "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MY_IP/32,Description=SSH-my-ip-only}]" >/dev/null
    save_state SG_ID "$SG_ID"
    save_state SSH_SOURCE "$MY_IP/32"
fi
ok "Security Group $SG_ID (80 ← 0.0.0.0/0, 22 ← ${SSH_SOURCE:-$MY_IP/32})"

# ---------------------------------------------------------------- 6. Key Pair
KEY_FILE="$STATE_DIR/$KEY_NAME.pem"
if [[ "$DRY_RUN" == 1 ]]; then
    awsx ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 --query KeyMaterial --output text >/dev/null
elif ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    mkdir -p "$STATE_DIR"
    awsx ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 \
        --tag-specifications "$(tags key-pair "$KEY_NAME")" --query KeyMaterial --output text > "$KEY_FILE"
    chmod 400 "$KEY_FILE"
    save_state KEY_NAME "$KEY_NAME"
    warn "개인 키를 $KEY_FILE 에 저장했습니다. 다시 받을 수 없으니 안전한 곳에 보관하세요 (git 에 올리지 않음)."
fi
ok "Key Pair $KEY_NAME"

# ---------------------------------------------------------------- 7. EC2
if [[ -z "${INSTANCE_ID:-}" ]]; then
    AMI_ID="$(DRY_VALUE=ami-DRYRUN awsx ec2 describe-images --owners 099720108477 \
        --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' 'Name=state,Values=available' \
        --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"
    info "AMI: $AMI_ID (Ubuntu 24.04 LTS 최신)"
    INSTANCE_ID="$(DRY_VALUE=i-DRYRUN awsx ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
        --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" --key-name "$KEY_NAME" \
        --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_GIB,VolumeType=gp3,DeleteOnTermination=true}" \
        --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
        --user-data "file://$REPO_DIR/${USER_DATA:-scripts/user-data.sh}" \
        --tag-specifications "$(tags instance "$PREFIX-web")" "$(tags volume "$PREFIX-web-root")" \
        --query 'Instances[0].InstanceId' --output text)"
    save_state INSTANCE_ID "$INSTANCE_ID"
    info "인스턴스 실행 대기..."
    awsx ec2 wait instance-running --instance-ids "$INSTANCE_ID" >/dev/null
fi
PUBLIC_IP="$(DRY_VALUE=198.51.100.20 awsx ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
save_state PUBLIC_IP "$PUBLIC_IP"
ok "EC2 $INSTANCE_ID ($INSTANCE_TYPE) Public IP $PUBLIC_IP"

# ---------------------------------------------------------------- 확인
if [[ "$DRY_RUN" != 1 ]]; then
    info "user-data(Nginx 설치) 완료 대기: 최대 5분"
    for _ in $(seq 1 60); do
        if [[ "$(curl -s --max-time 3 "http://$PUBLIC_IP/health")" == OK ]]; then ok "GET http://$PUBLIC_IP/health → OK"; break; fi
        sleep 5
    done
fi
cat >&2 <<MSG

다음 단계
  외부 접속 검증 : bash scripts/verify.sh
  SSH 접속       : ssh -i $KEY_FILE ubuntu@$PUBLIC_IP
  정리           : bash scripts/cleanup.sh   (실습이 끝나면 반드시)
MSG
