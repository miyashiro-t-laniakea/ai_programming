#!/bin/bash

# 変数定義
DOMAIN_NAME="repairmanager.com"
HOSTED_ZONE_ID="Z08247233V8S47A7YSZ4O"
INSTANCE_ID="i-0398c07ad8cfd5e18"
TTL=300
MAX_RETRIES=10
WAIT_TIME=30

# ログ関数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# エラーチェック関数
check_error() {
    if [ $? -ne 0 ]; then
        log "エラー: $1"
        exit 1
    fi
}

# 変数の妥当性チェック
for var in DOMAIN_NAME HOSTED_ZONE_ID INSTANCE_ID; do
    if [ -z "${!var}" ]; then
        log "エラー: $var が設定されていません。"
        exit 1
    fi
done

# AWS CLIの設定チェック
log "AWS CLIの設定を確認中..."
aws sts get-caller-identity > /dev/null 2>&1
check_error "AWS CLIの設定が正しくありません。認証情報を確認してください。"

# Route 53の権限チェック
log "Route 53の権限を確認中..."
aws route53 list-hosted-zones > /dev/null 2>&1
check_error "Route 53にアクセスする権限がありません。IAMポリシーを確認してください。"

# ホストゾーンの存在確認
log "ホストゾーンの存在を確認中..."
ZONE_CHECK=$(aws route53 get-hosted-zone --id $HOSTED_ZONE_ID 2>&1)
if echo "$ZONE_CHECK" | grep -q "NoSuchHostedZone"; then
    log "エラー: 指定されたホストゾーンID ($HOSTED_ZONE_ID) が見つかりません。"
    exit 1
fi

# ネームサーバーの確認
log "ドメインのネームサーバーを確認中..."
NAMESERVERS=$(aws route53 get-hosted-zone --id $HOSTED_ZONE_ID --query "DelegationSet.NameServers" --output text)
WHOIS_NS=$(whois $DOMAIN_NAME | grep "Name Server" | awk '{print $NF}' | sort)
ROUTE53_NS=$(echo "$NAMESERVERS" | sort)

if [ "$WHOIS_NS" != "$ROUTE53_NS" ]; then
    log "警告: ドメインのネームサーバーがRoute 53のネームサーバーと一致しません。"
    log "WHOISのネームサーバー: $WHOIS_NS"
    log "Route 53のネームサーバー: $ROUTE53_NS"
fi

# EC2インスタンスのパブリックIPアドレスを取得
log "EC2インスタンスのパブリックIPアドレスを取得中..."
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

if [ -z "$PUBLIC_IP" ]; then
    log "エラー: EC2インスタンスのパブリックIPを取得できませんでした。"
    exit 1
fi

log "取得したパブリックIPアドレス: $PUBLIC_IP"

# JSONファイルを作成してAレコードをRoute 53に設定
cat > change-resource-record-sets.json << EOL
{
  "Comment": "Add A record for $DOMAIN_NAME",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$DOMAIN_NAME",
        "Type": "A",
        "TTL": $TTL,
        "ResourceRecords": [
          {
            "Value": "$PUBLIC_IP"
          }
        ]
      }
    }
  ]
}
EOL

# Aレコードの追加
log "Route 53のAレコードを更新中..."
UPDATE_RESULT=$(aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch file://change-resource-record-sets.json 2>&1)
if echo "$UPDATE_RESULT" | grep -q "ERROR"; then
    log "エラー: Route 53のレコード更新に失敗しました。エラーメッセージ: $UPDATE_RESULT"
    rm change-resource-record-sets.json
    exit 1
fi

rm change-resource-record-sets.json

log "ドメイン $DOMAIN_NAME のAレコードにIP $PUBLIC_IP を設定しました。"

# DNS解決を確認するためのチェック
for i in $(seq 1 $MAX_RETRIES); do
    log "DNS更新の確認を試行中... (${i}/${MAX_RETRIES})"
    RESOLVED_IP=$(dig +short $DOMAIN_NAME)

    if [ "$RESOLVED_IP" == "$PUBLIC_IP" ]; then
        log "成功: ドメイン名 $DOMAIN_NAME は正しく $PUBLIC_IP に設定されています。"
        exit 0
    fi

    sleep $WAIT_TIME
done

log "エラー: ドメイン名 $DOMAIN_NAME が $PUBLIC_IP に設定されていません。現在の設定: $RESOLVED_IP"
exit 1