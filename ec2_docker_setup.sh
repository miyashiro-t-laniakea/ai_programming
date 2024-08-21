#!/bin/bash

# このスクリプトは、AWS EC2インスタンスを自動的に作成し、Dockerをインストールします。
# VPC、サブネット、セキュリティグループの自動設定を含みます。

set -e  # エラーが発生した時点でスクリプトを終了

# 変数の設定
AMI_ID="ami-0ac6fa9865c21266e"  # Ubuntu 22.04 LTS AMI ID (東京リージョン)
INSTANCE_TYPE="t2.micro"
KEY_NAME="MyProjectKey"  # 既存のキーペア名を指定してください

echo "VPCとサブネットを確認中..."
# デフォルトVPCのIDを取得
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
if [ -z "$VPC_ID" ]; then
    echo "エラー: デフォルトVPCが見つかりません。"
    exit 1
fi
echo "使用するVPC ID: $VPC_ID"

# デフォルトVPCのサブネットIDを取得
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" --query "Subnets[0].SubnetId" --output text)
if [ -z "$SUBNET_ID" ]; then
    echo "エラー: デフォルトサブネットが見つかりません。"
    exit 1
fi
echo "使用するサブネットID: $SUBNET_ID"

echo "セキュリティグループを作成中..."
# セキュリティグループを作成
SG_NAME="MyEC2DockerSG-$(date +%Y%m%d%H%M%S)"
SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name $SG_NAME --description "Security group for EC2 with Docker" --vpc-id $VPC_ID --query 'GroupId' --output text)
if [ -z "$SECURITY_GROUP_ID" ]; then
    echo "エラー: セキュリティグループの作成に失敗しました。"
    exit 1
fi

# SSHアクセスを許可
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
# HTTPアクセスを許可 (80番ポート)
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
# HTTPSアクセスを許可 (443番ポート)
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 443 --cidr 0.0.0.0/0

echo "作成したセキュリティグループID: $SECURITY_GROUP_ID"

echo "EC2インスタンスを作成中..."
# EC2インスタンスの作成
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_NAME \
    --security-group-ids $SECURITY_GROUP_ID \
    --subnet-id $SUBNET_ID \
    --query 'Instances[0].InstanceId' \
    --output text)

if [ -z "$INSTANCE_ID" ]; then
    echo "エラー: インスタンスの作成に失敗しました。"
    exit 1
fi

echo "インスタンスID: $INSTANCE_ID"

echo "インスタンスの起動を待機中..."
# インスタンスの状態が'running'になるまで待機
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# インスタンスの状態を確認
INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].State.Name' --output text)
if [ "$INSTANCE_STATE" != "running" ]; then
    echo "エラー: インスタンスが正常に起動していません。現在の状態: $INSTANCE_STATE"
    exit 1
fi

echo "パブリックIPアドレスを取得中..."
# パブリックIPアドレスの取得
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

if [ -z "$PUBLIC_IP" ]; then
    echo "エラー: パブリックIPアドレスの取得に失敗しました。"
    exit 1
fi

echo "パブリックIPアドレス: $PUBLIC_IP"

echo "SSHの準備ができるまで待機中..."
# SSHの準備ができるまで待機
sleep 30

echo "SSHでの接続を確認中..."
# SSHでの接続を確認
ssh -i "$KEY_NAME.pem" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$PUBLIC_IP exit
if [ $? -ne 0 ]; then
    echo "エラー: SSHでインスタンスに接続できません。"
    exit 1
fi

echo "Dockerのインストールスクリプトを作成中..."
# Dockerのインストールスクリプトを作成
cat << EOF > install_docker.sh
#!/bin/bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable"
sudo apt-get update
sudo apt-get install -y docker-ce
sudo usermod -aG docker ubuntu
EOF

echo "インストールスクリプトをEC2インスタンスにコピー中..."
# インストールスクリプトをEC2インスタンスにコピー
scp -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no install_docker.sh ubuntu@$PUBLIC_IP:~

echo "Dockerをインストール中..."
# Dockerのインストール
ssh -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no ubuntu@$PUBLIC_IP 'bash install_docker.sh'

echo "Dockerのインストールを確認中..."
# Dockerが正しくインストールされているか確認
DOCKER_VERSION=$(ssh -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no ubuntu@$PUBLIC_IP 'docker --version')
if [ $? -ne 0 ]; then
    echo "エラー: Dockerが正しくインストールされていません。"
    exit 1
fi

echo "セットアップが完了しました。"
echo "==== デプロイ結果 ===="
echo "インスタンスID: $INSTANCE_ID"
echo "パブリックIP: $PUBLIC_IP"
echo "インスタンス状態: $INSTANCE_STATE"
echo "Docker版数: $DOCKER_VERSION"
echo "VPC ID: $VPC_ID"
echo "サブネットID: $SUBNET_ID"
echo "セキュリティグループID: $SECURITY_GROUP_ID"
echo "======================"
echo "SSHでログインするには: ssh -i $KEY_NAME.pem ubuntu@$PUBLIC_IP"