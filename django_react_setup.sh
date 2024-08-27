#!/bin/bash
# このスクリプトは、Django（バックエンド）、React（フロントエンド）、選択されたデータベース、
# Nginx（リバースプロキシ）を使用したウェブアプリケーション開発環境をDockerで構築します。

set -e  # エラーが発生した場合にスクリプトを終了

# プロジェクト名やディレクトリ名などの変数を定義
PROJECT_NAME="RepairManager"
DJANGO_APP_NAME="sampleapi"
REACT_APP_NAME="frontend"

echo "プロジェクト名: $PROJECT_NAME"
echo "Djangoアプリ名: $DJANGO_APP_NAME"
echo "Reactアプリ名: $REACT_APP_NAME"

# 必要なアプリケーションがインストールされているか確認
echo "1. 必要なアプリケーションの確認中..."
command -v docker >/dev/null 2>&1 || { echo "エラー: Dockerがインストールされていません。" >&2; exit 1; }
command -v docker compose >/dev/null 2>&1 || { echo "エラー: docker composeがインストールされていません。" >&2; exit 1; }
echo "必要なアプリケーションの確認が完了しました。"

echo "Dockerデーモンの状態を確認中..."
if ! docker info >/dev/null 2>&1; then
    echo "Dockerデーモンが動作していません。起動を試みます..."
    
    # OSによって起動コマンドが異なる
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        open -a Docker
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux (要sudo権限)
        sudo systemctl start docker
    else
        echo "お使いのOSでのDockerの自動起動に対応していません。手動でDockerを起動してください。"
        exit 1
    fi
    
    # Dockerの起動を待つ
    echo "Dockerの起動を待っています..."
    while ! docker info >/dev/null 2>&1; do
        sleep 1
    done
    echo "Dockerが正常に起動しました。"
else
    echo "Dockerデーモンは既に動作しています。"
fi

# プロジェクトディレクトリが既に存在する場合はエラーを表示して終了
if [ -d "$PROJECT_NAME" ]; then
    echo "エラー: ディレクトリ $PROJECT_NAME は既に存在します。別のディレクトリ名を使用するか、既存のディレクトリを削除してください。" >&2
    exit 1
fi

# プロジェクトディレクトリの作成
echo "2. プロジェクトディレクトリを作成中..."
mkdir -p $PROJECT_NAME/{backend,frontend,nginx}
cd $PROJECT_NAME
echo "プロジェクトディレクトリの作成が完了しました。"

# データベースの選択
echo "使用するデータベースを選択してください:"
echo "1) SQLite"
echo "2) PostgreSQL"
echo "3) MySQL"
read -p "選択 (1, 2, or 3): " db_choice

case $db_choice in
  1)
    DB_TYPE="sqlite"
    DB_IMAGE=""
    DB_PORT=""
    DB_PACKAGE=""
    ;;
  2)
    DB_TYPE="postgresql"
    DB_IMAGE="postgres:13"
    DB_PORT="5432"
    DB_PACKAGE="psycopg2-binary"
    ;;
  3)
    DB_TYPE="mysql"
    DB_IMAGE="mysql:8.0"
    DB_PORT="3306"
    DB_PACKAGE="mysqlclient"
    ;;
  *)
    echo "無効な選択です。SQLiteをデフォルトとして使用します。"
    DB_TYPE="sqlite"
    DB_IMAGE=""
    DB_PORT=""
    DB_PACKAGE=""
    ;;
esac

# Djangoプロジェクトのセットアップ
echo "3. Djangoプロジェクトをセットアップ中..."
docker run --rm -v $(pwd)/backend:/app -w /app python:3.10 bash -c "
    pip install django djangorestframework &&
    django-admin startproject $DJANGO_APP_NAME . &&
    python manage.py startapp api
"
echo "Djangoプロジェクトのセットアップが完了しました。"

# Django settings.pyの修正
echo "Django settings.pyを修正中..."
if [ "$DB_TYPE" = "sqlite" ]; then
  cat <<EOF >> backend/$DJANGO_APP_NAME/settings.py

import os

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': os.path.join(BASE_DIR, 'db.sqlite3'),
    }
}
EOF
elif [ "$DB_TYPE" = "postgresql" ]; then
  cat <<EOF >> backend/$DJANGO_APP_NAME/settings.py

import os

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.environ.get('DB_NAME', 'myapp'),
        'USER': os.environ.get('DB_USER', 'user'),
        'PASSWORD': os.environ.get('DB_PASSWORD', 'password'),
        'HOST': os.environ.get('DB_HOST', 'db'),
        'PORT': os.environ.get('DB_PORT', '5432'),
    }
}
EOF
else
  cat <<EOF >> backend/$DJANGO_APP_NAME/settings.py

import os

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': os.environ.get('DB_NAME', 'myapp'),
        'USER': os.environ.get('DB_USER', 'user'),
        'PASSWORD': os.environ.get('DB_PASSWORD', 'password'),
        'HOST': os.environ.get('DB_HOST', 'db'),
        'PORT': os.environ.get('DB_PORT', '3306'),
        'OPTIONS': {
            'init_command': "SET sql_mode='STRICT_TRANS_TABLES'"
        }
    }
}
EOF
fi

echo "INSTALLED_APPS += ['rest_framework', 'api']" >> backend/$DJANGO_APP_NAME/settings.py
echo "Django settings.pyの修正が完了しました。"

# Django models.pyの作成
echo "Django models.pyを作成中..."
cat <<EOF > backend/api/models.py
from django.db import models

class Item(models.Model):
    name = models.CharField(max_length=100)
    description = models.TextField()

    def __str__(self):
        return self.name
EOF
echo "Django models.pyの作成が完了しました。"

# Django views.pyの修正
echo "Django views.pyを修正中..."
cat <<EOF > backend/api/views.py
from rest_framework import generics
from .models import Item
from .serializers import ItemSerializer

class ItemList(generics.ListCreateAPIView):
    queryset = Item.objects.all()
    serializer_class = ItemSerializer

class ItemDetail(generics.RetrieveUpdateDestroyAPIView):
    queryset = Item.objects.all()
    serializer_class = ItemSerializer
EOF
echo "Django views.pyの修正が完了しました。"

# Django serializers.pyの作成
echo "Django serializers.pyを作成中..."
cat <<EOF > backend/api/serializers.py
from rest_framework import serializers
from .models import Item

class ItemSerializer(serializers.ModelSerializer):
    class Meta:
        model = Item
        fields = ['id', 'name', 'description']
EOF
echo "Django serializers.pyの作成が完了しました。"

# Django urls.pyの修正
echo "Django urls.pyを修正中..."
cat <<EOF > backend/$DJANGO_APP_NAME/urls.py
from django.contrib import admin
from django.urls import path
from api.views import ItemList, ItemDetail

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/items/', ItemList.as_view(), name='item-list'),
    path('api/items/<int:pk>/', ItemDetail.as_view(), name='item-detail'),
]
EOF
echo "Django urls.pyの修正が完了しました。"

# Reactプロジェクトのセットアップ
echo "4. Reactプロジェクトをセットアップ中..."
docker run --rm -v $(pwd)/frontend:/app -w /app node:16 bash -c "
    npx create-react-app . &&
    npm install axios &&
    npm install
"
echo "Reactプロジェクトのセットアップが完了しました。"

# React App.jsの修正
echo "React App.jsを修正中..."
cat <<EOF > frontend/src/App.js
import React, { useState, useEffect } from 'react';
import axios from 'axios';
import './App.css';

function App() {
  const [items, setItems] = useState([]);

  useEffect(() => {
    axios.get('/api/items/')
      .then(response => {
        setItems(response.data);
      })
      .catch(error => {
        console.error('Error fetching data: ', error);
      });
  }, []);

  return (
    <div className="App">
      <header className="App-header">
        <h1>Item List</h1>
        <ul>
          {items.map(item => (
            <li key={item.id}>{item.name}: {item.description}</li>
          ))}
        </ul>
      </header>
    </div>
  );
}

export default App;
EOF
echo "React App.jsの修正が完了しました。"

# バックエンド用のDockerfileの作成
echo "5. バックエンド用のDockerfileを作成中..."
cat <<EOF > backend/Dockerfile
FROM python:3.10
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "$DJANGO_APP_NAME.wsgi:application"]
EOF
echo "バックエンド用のDockerfileの作成が完了しました。"

# バックエンド用のrequirements.txtの作成
echo "バックエンド用のrequirements.txtを作成中..."
cat <<EOF > backend/requirements.txt
django>=3.2,<4.0
djangorestframework
gunicorn
EOF

if [ "$DB_PACKAGE" != "" ]; then
  echo "$DB_PACKAGE" >> backend/requirements.txt
fi

echo "バックエンド用のrequirements.txtの作成が完了しました。"

# フロントエンド用のDockerfileの作成
echo "6. フロントエンド用のDockerfileを作成中..."
cat <<EOF > frontend/Dockerfile
FROM node:16
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
CMD ["npm", "start"]
EOF
echo "フロントエンド用のDockerfileの作成が完了しました。"

# Nginx用のDockerfileの作成
echo "7. Nginx用のDockerfileを作成中..."
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
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }

        location /api/ {
            proxy_pass http://backend:8000;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }

        location /admin/ {
            proxy_pass http://backend:8000;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
    }
}
EOF
echo "Nginxの設定ファイルの作成が完了しました。"

# docker-compose.ymlの作成
echo "8. docker-compose.ymlを作成中..."
cat <<EOF > docker-compose.yml
services:
  backend:
    build: ./backend
    volumes:
      - ./backend:/app
EOF

if [ "$DB_TYPE" != "sqlite" ]; then
  cat <<EOF >> docker-compose.yml
    environment:
      - DEBUG=1
      - DB_NAME=myapp
      - DB_USER=user
      - DB_PASSWORD=password
      - DB_HOST=db
      - DB_PORT=$DB_PORT
    depends_on:
      - db
EOF
fi

cat <<EOF >> docker-compose.yml

  frontend:
    build: ./frontend
    volumes:
      - ./frontend:/app
      - /app/node_modules
    environment:
      - CHOKIDAR_USEPOLLING=true

  nginx:
    build: ./nginx
    ports:
      - "80:80"
    depends_on:
      - backend
      - frontend
EOF

if [ "$DB_TYPE" != "sqlite" ]; then
DB_TYPE_UPPER=$(echo "$DB_TYPE" | tr '[:lower:]' '[:upper:]')

cat <<EOF >> docker-compose.yml

  db:
    image: $DB_IMAGE
    volumes:
      - db_data:/var/lib/$DB_TYPE
    environment:
      - ${DB_TYPE_UPPER}_DATABASE=myapp
      - ${DB_TYPE_UPPER}_USER=user
      - ${DB_TYPE_UPPER}_PASSWORD=password
      - ${DB_TYPE_UPPER}_ROOT_PASSWORD=rootpassword

volumes:
  db_data:
EOF

  if [ "$DB_TYPE" = "mysql" ]; then
    # MySQLの場合、認証プラグインを設定
    sed -i '' 's/image: $DB_IMAGE/image: $DB_IMAGE\n    command: --default-authentication-plugin=mysql_native_password/' docker-compose.yml
  fi
fi

echo "docker-compose.ymlの作成が完了しました。"

# エントリーポイントスクリプトの作成
echo "9. バックエンド用エントリーポイントスクリプトを作成中..."
cat <<EOF > backend/entrypoint.sh
#!/bin/sh

if [ "$DB_TYPE" != "sqlite" ]; then
  echo "Waiting for database..."
  while ! nc -z \$DB_HOST \$DB_PORT; do
    sleep 0.1
  done
  echo "Database started"
fi

python manage.py migrate
python manage.py collectstatic --no-input --clear

exec "\$@"
EOF
chmod +x backend/entrypoint.sh
echo "エントリーポイントスクリプトの作成が完了しました。"

# Gitの初期化と.gitignoreの作成
echo "10. Gitの初期化と.gitignoreの作成中..."
git init
cat <<EOF > .gitignore
# Python
*.pyc
__pycache__/

# Node
node_modules/

# Docker
*.log

# Django
staticfiles/

# Database
*.sqlite3

# その他
.env
EOF
echo "Gitの初期化と.gitignoreの作成が完了しました。"

echo "セットアップが完了しました。以下のコマンドでアプリケーションを起動できます："
echo "docker compose up --build"

echo "アプリケーションが起動したら、以下のURLにアクセスしてください："
echo "- フロントエンド: http://localhost"
echo "- バックエンドAPI: http://localhost/api/items/"
echo "- Django管理画面: http://localhost/admin/"

echo "注意: 初回起動時にDjango管理者ユーザーを作成するには、以下のコマンドを実行してください："
echo "docker compose exec backend python manage.pycle

# アプリケーションを起動し、健全性をチェックする
echo "アプリケーションを起動しています..."
docker compose up --build -d

# 各サービスの健全性をチェック
check_health backend || exit 1
check_health frontend || exit 1
check_health nginx || exit 1
if [ "$DB_TYPE" != "sqlite" ]; then
    check_health db || exit 1
fi

echo "すべてのサービスが正常に動作しています。"

# ブラウザでアプリケーションを開く
open_browser

echo "セットアップが完了し、アプリケーションが正常に起動しました。"