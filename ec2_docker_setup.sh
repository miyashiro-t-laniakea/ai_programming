#!/bin/bash

# このスクリプトは、AWS EC2インスタンスを自動的に作成し、Dockerをインストールします。
# カスタムVPC、サブネット、セキュリティグループの自動設定を含みます。
# 変数の設定
AMI_ID="ami-0ac6fa9865c21266e"  # Ubuntu 22.04 LTS AMI ID (東京リージョン)
INSTANCE_TYPE="t2.micro"
KEY_NAME="RepairManager-key"  # デフォルトのキーペア名
VOLUME_SIZE="${3:-16}"  # デフォルトのボリュームサイズを16GBに設定

set -euo pipefail  # より厳格なエラーハンドリング
LOG_FILE="deployment_$(date +%Y%m%d%H%M%S).log"

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# エラーハンドリング関数
handle_error() {
    log "エラー: $1"
    exit 1
}

# AWS CLIがインストールされているか確認
log "AWS CLIのインストールを確認中..."
command -v aws &> /dev/null || handle_error "AWS CLIがインストールされていません。インストールしてから再実行してください。"
log "AWS CLIがインストールされています。"

# カスタムVPCとサブネットの指定、指定がなければデフォルトを使用
VPC_ID="${1:-$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)}"
SUBNET_ID="${2:-$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" --query "Subnets[0].SubnetId" --output text)}"

# キーペアの確認と作成
log "キーペアを確認中..."
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" &> /dev/null; then
    log "キーペア $KEY_NAME が見つかりません。新しく作成します。"
    aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "${KEY_NAME}.pem" || handle_error "キーペアの作成に失敗しました。"
    chmod 400 "${KEY_NAME}.pem"
    log "新しいキーペア ${KEY_NAME} を作成し、${KEY_NAME}.pem として保存しました。"
else
    log "既存のキーペア ${KEY_NAME} を使用します。"
    if [ ! -f "${KEY_NAME}.pem" ]; then
        handle_error "${KEY_NAME}.pem ファイルが見つかりません。既存の秘密鍵ファイルを ${KEY_NAME}.pem として保存してください。"
    fi
fi

log "キーペアの確認が完了しました。"
log "使用するVPC ID: $VPC_ID"
log "使用するサブネットID: $SUBNET_ID"
log "EBSボリュームサイズ: ${VOLUME_SIZE}GB"

# セキュリティグループを作成
log "セキュリティグループを作成中..."
SG_NAME="MyEC2DockerSG-$(date +%Y%m%d%H%M%S)"
SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "Security group for EC2 with Docker" --vpc-id "$VPC_ID" --query 'GroupId' --output text) || handle_error "セキュリティグループの作成に失敗しました。"

# セキュリティグループのルールを設定
for port in 22 80 443; do
    log "${port}番ポートへのアクセスを許可中..."
    aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --protocol tcp --port "$port" --cidr 0.0.0.0/0 || handle_error "${port}番ポートへのアクセス許可に失敗しました。"
done

log "作成したセキュリティグループID: $SECURITY_GROUP_ID"

# EC2インスタンスの作成
log "EC2インスタンスを作成中..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --count 1 \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --subnet-id "$SUBNET_ID" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp2\"}}]" \
    --query 'Instances[0].InstanceId' \
    --output text) || handle_error "インスタンスの作成に失敗しました。"

log "インスタンスID: $INSTANCE_ID"

log "インスタンスの起動を待機中..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" || handle_error "インスタンスの起動に失敗しました。"

# インスタンスの状態を確認
INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text)

# パブリックIPアドレスの取得
log "パブリックIPアドレスを取得中..."
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text) || handle_error "パブリックIPアドレスの取得に失敗しました。"

log "パブリックIPアドレス: $PUBLIC_IP"

log "SSHの準備ができるまで待機中..."
sleep 30

# SSHでの接続を確認
log "SSHでの接続を確認中..."
ssh -i "$KEY_NAME.pem" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@"$PUBLIC_IP" exit || handle_error "SSHでインスタンスに接続できません。"

# Dockerのインストールスクリプトを作成
log "Dockerのインストールスクリプトを作成中..."
cat << EOF > install_docker.sh
#!/bin/bash
set -euo pipefail
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable"
sudo apt-get update
sudo apt-get install -y docker-ce
sudo usermod -aG docker ubuntu
EOF

# インストールスクリプトをEC2インスタンスにコピー
log "インストールスクリプトをEC2インスタンスにコピー中..."
scp -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no install_docker.sh ubuntu@"$PUBLIC_IP":~ || handle_error "インストールスクリプトのコピーに失敗しました。"

# Dockerのインストール
log "Dockerをインストール中..."
ssh -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no ubuntu@"$PUBLIC_IP" 'bash install_docker.sh' || handle_error "Dockerのインストールに失敗しました。"

# Dockerが正しくインストールされているか確認
log "Dockerのインストールを確認中..."
DOCKER_VERSION=$(ssh -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no ubuntu@"$PUBLIC_IP" 'docker --version') || handle_error "Dockerが正しくインストールされていません。"

# 結果の表示
log "セットアップが完了しました。"
cat << EOF | tee -a "$LOG_FILE"
==== デプロイ結果 ====
インスタンスID: $INSTANCE_ID
パブリックIP: $PUBLIC_IP
インスタンス状態: $INSTANCE_STATE
Docker版数: $DOCKER_VERSION
VPC ID: $VPC_ID
サブネットID: $SUBNET_ID
セキュリティグループID: $SECURITY_GROUP_ID
EBSボリュームサイズ: ${VOLUME_SIZE}GB
======================
SSHでログインするには: ssh -i $KEY_NAME.pem ubuntu@$PUBLIC_IP
EOF