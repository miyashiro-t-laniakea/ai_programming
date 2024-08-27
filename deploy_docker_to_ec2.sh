#!/bin/bash

# 変数の設定
INSTANCE_IP="18.177.87.75"
KEY_NAME="RepairManager-key.pem"
PROJECT_NAME="RepairManager"

# 関数: エラーチェックと進捗報告
check_status() {
    if [ $? -eq 0 ]; then
        echo "✅ $1"
    else
        echo "❌ $1"
        exit 1
    fi
}

# キーファイルの存在確認
if [ ! -f "$KEY_NAME" ]; then
    echo "❌ SSHキーファイル $KEY_NAME が見つかりません。"
    exit 1
fi

# キーファイルのパーミッション設定
chmod 400 $KEY_NAME
check_status "SSHキーファイルのパーミッションを設定しました"

# .gitignoreを作成（既存の場合は上書き）
cat << EOF > $PROJECT_NAME/.gitignore
# Python
*.pyc
__pycache__/
venv/

# Node
node_modules/
build/

# Docker
*.log

# Django
db.sqlite3
/media/
/static/

# その他
*.tar
*.tmp
EOF
check_status ".gitignoreファイルを作成しました"

# Dockerイメージのビルドと保存
echo "Dockerイメージをビルドして保存中..."
cd $PROJECT_NAME
docker buildx create --use
docker buildx build --platform linux/amd64 -t repairmanager-backend:latest ./backend --load
docker buildx build --platform linux/amd64 -t repairmanager-frontend:latest ./frontend --load
docker buildx build --platform linux/amd64 -t repairmanager-nginx:latest ./nginx --load
check_status "Dockerイメージをビルドしました"

docker save repairmanager-backend repairmanager-frontend repairmanager-nginx > repairmanager_images.tar
check_status "Dockerイメージを保存しました"

# rsyncを使用して必要なファイルのみを転送
echo "プロジェクトファイルを転送中..."
rsync -avz --exclude-from='.gitignore' -e "ssh -i ../$KEY_NAME" ./ ubuntu@$INSTANCE_IP:/home/ubuntu/$PROJECT_NAME/
check_status "プロジェクトファイルを転送しました"

# イメージファイルを転送
echo "Dockerイメージを転送中..."
scp -i "../$KEY_NAME" repairmanager_images.tar ubuntu@$INSTANCE_IP:/home/ubuntu/$PROJECT_NAME/
check_status "Dockerイメージを転送しました"

# EC2インスタンスに接続してデプロイを実行
echo "EC2インスタンスに接続してデプロイを実行中..."
ssh -i "../$KEY_NAME" ubuntu@$INSTANCE_IP << EOF
    cd $PROJECT_NAME
    
    # 既存のコンテナを停止して削除
    docker-compose down
    
    # 転送したイメージファイルを読み込み
    docker load < repairmanager_images.tar
    
    # docker-compose.ymlからversionを削除
    sed -i '/version:/d' docker-compose.yml
    
    # 新しいコンテナを起動
    docker compose up -d
    
    # コンテナの状態を確認
    docker compose ps
    
    # イメージファイルを削除
    rm repairmanager_images.tar
    
    exit
EOF
check_status "EC2インスタンスでのデプロイを完了しました"

echo "ローカルのイメージファイルを削除中..."
rm repairmanager_images.tar
check_status "ローカルのイメージファイルを削除しました"

echo "✅ デプロイが完了しました。"
echo "アプリケーションには http://$INSTANCE_IP でアクセスできます。"