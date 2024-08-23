#!/bin/bash
# このスクリプトは、Django（バックエンド）、React（フロントエンド）、Nginx（リバースプロキシ）を
# 使用したウェブアプリケーション開発環境をDockerで構築します。
# 必要なファイルとディレクトリを作成し、Dockerコンテナをビルドして起動します。

# プロジェクト名やディレクトリ名などの変数を定義
PROJECT_NAME="RepairManager"
DJANGO_APP_NAME="sampleapi"
REACT_APP_NAME="frontend"

echo "プロジェクト名: $PROJECT_NAME"
echo "Djangoアプリ名: $DJANGO_APP_NAME"
echo "Reactアプリ名: $REACT_APP_NAME"

# 必要なアプリケーションがインストールされているか確認
echo "必要なアプリケーションの確認中..."
command -v docker >/dev/null 2>&1 || { echo "Dockerがインストールされていません。インストールしてください。" >&2; exit 1; }
command -v docker compose >/dev/null 2>&1 || { echo "docker composeがインストールされていません。インストールしてください。" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "Node.jsがインストールされていません。インストールしてください。" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Python3がインストールされていません。インストールしてください。" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "Gitがインストールされていません。インストールしてください。" >&2; exit 1; }
echo "必要なアプリケーションの確認が完了しました。"

# プロジェクトディレクトリが既に存在する場合はエラーを表示して終了
if [ -d "$PROJECT_NAME" ]; then
    echo "エラー: ディレクトリ $PROJECT_NAME は既に存在します。別のディレクトリ名を使用するか、既存のディレクトリを削除してください。" >&2
    exit 1
fi

# プロジェクトディレクトリの作成
echo "プロジェクトディレクトリを作成中..."
mkdir -p $PROJECT_NAME/backend
mkdir -p $PROJECT_NAME/frontend
mkdir -p $PROJECT_NAME/nginx
echo "プロジェクトディレクトリの作成が完了しました。"

# Djangoプロジェクトのセットアップ
echo "Djangoプロジェクトをセットアップ中..."
cd $PROJECT_NAME/backend
docker run --rm -v $(pwd):/app -w /app python:3.10 bash -c "
    pip install django djangorestframework &&
    django-admin startproject $DJANGO_APP_NAME .
"
echo "Djangoプロジェクトのセットアップが完了しました。"

# Reactプロジェクトのセットアップ
echo "Reactプロジェクトをセットアップ中..."
cd ../frontend
docker run --rm -v $(pwd):/app -w /app node:16 bash -c "
    npx create-react-app . &&
    npm install
"
echo "Reactプロジェクトのセットアップが完了しました。"

# Django用のDockerfileの作成
echo "Django用のDockerfileを作成中..."
cd ../
cat <<EOF > backend/Dockerfile
# ベースイメージ
FROM python:3.10

# 作業ディレクトリの設定
WORKDIR /app

# 依存関係のインストール
COPY requirements.txt .
RUN pip install -r requirements.txt

# ソースコードをコンテナにコピー
COPY . .

# GunicornでDjangoアプリケーションを起動
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "$DJANGO_APP_NAME.wsgi:application"]
EOF
echo "Django用のDockerfileの作成が完了しました。"

echo "Django用のrequirements.txtを作成中..."
cat <<EOF > backend/requirements.txt
django>=3.2,<4.0
djangorestframework
gunicorn
EOF
echo "Django用のrequirements.txtの作成が完了しました。"

# React用のDockerfileの作成
echo "React用のDockerfileを作成中..."
cat <<EOF > frontend/Dockerfile
# ベースイメージ
FROM node:16

# 作業ディレクトリの設定
WORKDIR /app

# 依存関係のインストール
COPY package*.json ./
RUN npm install

# ソースコードをコンテナにコピー
COPY . .

# Reactアプリケーションの起動
CMD ["npm", "start"]
EOF
echo "React用のDockerfileの作成が完了しました。"

# Nginx用のDockerfileの作成
echo "Nginx用のDockerfileを作成中..."
cat <<EOF > nginx/Dockerfile
FROM nginx:alpine
COPY nginx.conf /etc/nginx/nginx.conf
EOF
echo "Nginx用のDockerfileの作成が完了しました。"

# Nginxの設定ファイルの作成
echo "Nginxの設定ファイルを作成中..."
cat <<EOF > nginx/nginx.conf
events {
    worker_connections 1024;
}

http {
    server {
        listen 80;

        location / {
            proxy_pass http://frontend:3000;
        }

        location /api/ {
            proxy_pass http://web:8000;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
EOF
echo "Nginxの設定ファイルの作成が完了しました。"

# docker-compose.ymlの作成
echo "docker-compose.ymlを作成中..."
cat <<EOF > docker-compose.yml
version: '3.8'

services:
  web:
    build: ./backend
    ports:
      - "8000:8000"
    volumes:
      - ./backend:/app
    environment:
      - DEBUG=1

  frontend:
    build: ./frontend
    ports:
      - "3000:3000"
    volumes:
      - ./frontend:/app
    environment:
      - CHOKIDAR_USEPOLLING=true

  nginx:
    build: ./nginx
    ports:
      - "80:80"
    depends_on:
      - web
      - frontend
EOF
echo "docker-compose.ymlの作成が完了しました。"

# Gitの初期化と.gitignoreの作成
echo "Gitの初期化と.gitignoreの作成中..."
cd $PROJECT_NAME
git init
cat <<EOF > .gitignore
# Python
*.pyc
__pycache__/

# Node
node_modules/

# Docker
*.log
Dockerfile
docker-compose.yml

# Django
db.sqlite3
/media/
staticfiles/
EOF
echo "Gitの初期化と.gitignoreの作成が完了しました。"

# Dockerコンテナのビルドと起動
echo "Dockerコンテナのビルドと起動を開始します..."
docker compose up --build

echo "セットアップが完了しました。"
echo "Nginxを使って、Djangoのサンプル画面は http://localhost/api/ に、Reactのサンプル画面は http://localhost/ にアクセスして確認してください。"