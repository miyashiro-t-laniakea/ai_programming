#!/bin/bash
# このスクリプトは、Django（バックエンド）、React（フロントエンド）、Nginx（リバースプロキシ）を
# 使用したウェブアプリケーション開発環境をDockerで構築します。
# 必要なファイルとディレクトリを作成し、Dockerコンテナをビルドして起動します。

# 必要なアプリケーションがインストールされているか確認
command -v docker >/dev/null 2>&1 || { echo "Dockerがインストールされていません。インストールしてください。" >&2; exit 1; }
command -v docker compose >/dev/null 2>&1 || { echo "docker composeがインストールされていません。インストールしてください。" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "Node.jsがインストールされていません。インストールしてください。" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Python3がインストールされていません。インストールしてください。" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "Gitがインストールされていません。インストールしてください。" >&2; exit 1; }

# プロジェクト名やディレクトリ名などの変数を定義
PROJECT_NAME="RepairManager"
DJANGO_APP_NAME="sampleapi"
REACT_APP_NAME="frontend"

# プロジェクトディレクトリの作成
mkdir -p $PROJECT_NAME/backend
mkdir -p $PROJECT_NAME/frontend
mkdir -p $PROJECT_NAME/nginx

# Gitリポジトリの初期化
cd $PROJECT_NAME
git init

# .gitignoreの生成
cat <<EOF > .gitignore
# Python関連
*.pyc
__pycache__/
env/
venv/
ENV/
.venv/
*.pyo
*.pyd
.Python
build/
develop-eggs/
dist/
downloads/
eggs/
.eggs/
lib/
lib64/
parts/
sdist/
var/
*.egg-info/
.installed.cfg
*.egg

# Node関連
node_modules/
npm-debug.log
yarn-error.log

# Docker関連
*.log
*.lock
*.pid
*.swp
docker-compose.override.yml
docker-compose.local.yml

# その他
.DS_Store
.vscode/
.idea/
EOF

# Djangoプロジェクトのセットアップ
cd backend
docker run --rm -v $(pwd):/app -w /app python:3.10 bash -c "
    pip install django &&
    django-admin startproject $DJANGO_APP_NAME .
"

# Reactプロジェクトのセットアップ
cd ../frontend
docker run --rm -v $(pwd):/app -w /app node:16 bash -c "
    npx create-react-app . &&
    npm install
"

# Django用のDockerfileの作成
cat <<EOF > ../backend/Dockerfile
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

cat <<EOF > ../backend/requirements.txt
django>=3.2,<4.0
gunicorn
EOF

# React用のDockerfileの作成
cat <<EOF > ../frontend/Dockerfile
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

# Nginx用のDockerfileの作成
cat <<EOF > ../nginx/Dockerfile
FROM nginx:alpine
COPY nginx.conf /etc/nginx/nginx.conf
EOF

# Nginxの設定ファイルの作成
cat <<EOF > ../nginx/nginx.conf
# このnginx.confファイルはNginxウェブサーバーの主要な設定ファイルです。
# サーバーの動作、リクエストの処理方法、プロキシの設定などを定義します。
# この設定により、Nginxは異なるアプリケーション（フロントエンド、バックエンド）へのトラフィックを適切に振り分けます。

events {
    worker_connections 1024;  # 1ワーカーあたりの最大同時接続数
}

http {
    server {
        listen 80;  # ポート80でHTTPリクエストを受け付け

        location / {
            proxy_pass http://frontend:3000;  # フロントエンド(React)へリクエストを転送、'frontend'はDocker Composeで定義されたサービス名、3000はReactの開発サーバーのデフォルトポート
        }

        location /api/ {
            proxy_pass http://web:8000;  # バックエンド(Django)へAPIリクエストを転送、'web'はDockerComposeで定義されたサービス名、8000はDjangoのデフォルトポート
            proxy_set_header Host \$host;  # オリジナルのHostヘッダーを保持
            proxy_set_header X-Real-IP \$remote_addr;  # クライアントの実際のIPを設定
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;  # プロキシ経由の場合のIP情報を追加
            proxy_set_header X-Forwarded-Proto \$scheme;  # 使用されているプロトコル(http/https)を伝達
        }
    }
}
EOF

# docker-compose.ymlの作成
cat <<EOF > ../docker-compose.yml
# このdocker-compose.ymlファイルは、プロジェクトの複数のDockerコンテナを定義し管理します。
# バックエンド(Django)、フロントエンド(React)、Nginxの3つのサービスを設定しています。
# このファイルにより、開発環境全体を簡単に起動、停止、管理することができます。

version: '3.8'  # Docker Composeのバージョンを指定

services:
  # バックエンド(Django)サービス:
  # Djangoアプリケーションを実行し、APIエンドポイントを提供します。
  web:
    build: ./backend  # Dockerfileのパスを指定
    ports:
      - "8000:8000"  # ホストのポート8000をコンテナのポート8000にマッピング
    volumes:
      - ./backend:/app  # ホストのbackendディレクトリをコンテナの/appにマウント（ライブリロード用）
    environment:
      - DEBUG=1  # Djangoのデバッグモードを有効化

  # フロントエンド(React)サービス:
  # Reactアプリケーションを実行し、ユーザーインターフェースを提供します。
  frontend:
    build: ./frontend  # Dockerfileのパスを指定
    ports:
      - "3000:3000"  # ホストのポート3000をコンテナのポート3000にマッピング
    volumes:
      - ./frontend:/app  # ホストのfrontendディレクトリをコンテナの/appにマウント（ライブリロード用）
    environment:
      - CHOKIDAR_USEPOLLING=true  # ファイル変更の検出方法を設定（特定の環境で必要）

  # Nginxサービス:
  # リバースプロキシとして機能し、クライアントリクエストを適切なサービスに振り分けます。
  nginx:
    build: ./nginx  # Dockerfileのパスを指定
    ports:
      - "80:80"  # ホストのポート80をコンテナのポート80にマッピング
    depends_on:  # 依存関係を定義（Nginxは他のサービスの後に起動）
      - web
      - frontend
EOF

# Dockerコンテナのビルドと起動
cd ..
docker compose up --build

echo "Nginxを使って、Djangoのサンプル画面は http://localhost/api/ に、Reactのサンプル画面は http://localhost/ にアクセスして確認してください。"
