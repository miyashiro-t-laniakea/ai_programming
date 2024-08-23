#!/bin/bash

# リポジトリ名とGitHubユーザー名の設定
REPO_NAME="RepairManager"
GITHUB_USERNAME="miyashiro-t-laniakea"

# 必要な環境変数の設定（事前に設定する）
DOCKER_USERNAME="takamiya584"
DOCKER_PASSWORD="rubicone49"
EC2_SSH_PRIVATE_KEY_PATH="/Users/miyashirotakao/Desktop/Cursor_test/django-app-key.pem"
EC2_PUBLIC_IP="54.199.34.207"

# 環境変数が設定されているか確認
if [ -z "$DOCKER_USERNAME" ] || [ -z "$DOCKER_PASSWORD" ] || [ -z "$EC2_SSH_PRIVATE_KEY_PATH" ] || [ -z "$EC2_PUBLIC_IP" ]; then
  echo "必要な環境変数が設定されていません。以下の環境変数を設定してください:"
  echo "  DOCKER_USERNAME: Docker Hubのユーザー名"
  echo "  DOCKER_PASSWORD: Docker Hubのパスワード"
  echo "  EC2_SSH_PRIVATE_KEY_PATH: EC2インスタンスへのSSH秘密鍵のパス"
  echo "  EC2_PUBLIC_IP: EC2のパブリックIPアドレス"
  exit 1
fi

cd RepairManager || { echo "プロジェクトディレクトリに移動できませんでした。"; exit 1; }

# 1. GitHub Actionsワークフローファイルの作成
echo "GitHub Actionsのワークフローファイルを作成しています..."

mkdir -p .github/workflows || { echo "ディレクトリ .github/workflows の作成に失敗しました。"; exit 1; }

cat <<EOF > .github/workflows/deploy.yml
name: CI/CD Pipeline

on:
  push:
    branches:
      - master

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
    - name: コードのチェックアウト
      uses: actions/checkout@v2

    - name: Dockerのセットアップ
      uses: docker/setup-buildx-action@v1

    - name: Docker Hubにログイン
      run: echo "\${{ secrets.DOCKER_PASSWORD }}" | docker login -u "\${{ secrets.DOCKER_USERNAME }}" --password-stdin

    - name: Dockerイメージのビルドとプッシュ
      run: |
        docker build -t \${{ secrets.DOCKER_USERNAME }}/repairmanager-backend:latest ./backend
        docker build -t \${{ secrets.DOCKER_USERNAME }}/repairmanager-frontend:latest ./frontend
        docker push \${{ secrets.DOCKER_USERNAME }}/repairmanager-backend:latest
        docker push \${{ secrets.DOCKER_USERNAME }}/repairmanager-frontend:latest

  deploy:
    needs: build
    runs-on: ubuntu-latest

    steps:
    - name: コードのチェックアウト
      uses: actions/checkout@v2

    - name: デプロイ用SSH設定
      uses: webfactory/ssh-agent@v0.5.3
      with:
        ssh-private-key: \${{ secrets.EC2_SSH_PRIVATE_KEY }}

    - name: EC2へのデプロイ
      run: |
        ssh ubuntu@\${{ secrets.EC2_PUBLIC_IP }} <<EOF
          cd /path/to/your/app
          docker-compose down
          docker-compose pull
          docker-compose up -d
        EOF
EOF

if [ $? -ne 0 ]; then
  echo "GitHub Actionsのワークフローファイルの作成に失敗しました。"
  exit 1
fi

echo "GitHub Actionsのワークフローファイルを作成しました。"

# 2. GitHub Secretsの設定
echo "GitHub Secretsを設定しています..."

# SSHキーをbase64エンコード
EC2_SSH_PRIVATE_KEY=$(cat "$EC2_SSH_PRIVATE_KEY_PATH" | base64) || { echo "SSH秘密鍵のエンコードに失敗しました。"; exit 1; }

# GitHub CLIがインストールされているか確認
command -v gh >/dev/null 2>&1 || { echo "GitHub CLI (gh) がインストールされていません。インストールしてください。" >&2; exit 1; }

# GitHub CLIでシークレットを設定
gh secret set DOCKER_USERNAME -b"$DOCKER_USERNAME" -r "$GITHUB_USERNAME/$REPO_NAME" || { echo "DOCKER_USERNAMEのシークレット設定に失敗しました。"; exit 1; }
gh secret set DOCKER_PASSWORD -b"$DOCKER_PASSWORD" -r "$GITHUB_USERNAME/$REPO_NAME" || { echo "DOCKER_PASSWORDのシークレット設定に失敗しました。"; exit 1; }
gh secret set EC2_SSH_PRIVATE_KEY -b"$EC2_SSH_PRIVATE_KEY" -r "$GITHUB_USERNAME/$REPO_NAME" || { echo "EC2_SSH_PRIVATE_KEYのシークレット設定に失敗しました。"; exit 1; }
gh secret set EC2_PUBLIC_IP -b"$EC2_PUBLIC_IP" -r "$GITHUB_USERNAME/$REPO_NAME" || { echo "EC2_PUBLIC_IPのシークレット設定に失敗しました。"; exit 1; }

echo "GitHub Secretsを設定しました。"

# 3. GitHub Actionsワークフローの実行
echo "ワークフローファイルをGitHubにプッシュしています..."

# GitHubにファイルをプッシュ
git add .github/workflows/deploy.yml || { echo "GitHub Actionsワークフローファイルのステージングに失敗しました。"; exit 1; }
git commit -m "GitHub Actions CI/CDワークフローの追加" || { echo "GitHub Actionsワークフローファイルのコミットに失敗しました。"; exit 1; }
git push -u origin master || { echo "GitHub Actionsワークフローファイルのプッシュに失敗しました。"; exit 1; }

echo "GitHub Actionsのワークフローがプッシュされ、実行中です。"
