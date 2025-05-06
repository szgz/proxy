#!/bin/bash
set -e

# === 基础配置 ===
DOMAIN="mieru.frankwong.dpdns.org"
TUNNEL_NAME="mieru-tunnel"
CONFIG_DIR="/etc/cloudflared"
TUNNEL_DIR="${CONFIG_DIR}/tunnels"
API_TOKEN="1fJN-EYwwSEdb18EbvYiAlkY3f8fNnD79KfdpHVZ"
DOMAIN_ROOT="frankwong.dpdns.org"

echo "📦 安装依赖..."
apt update -y
apt install -y curl wget unzip git jq qrencode

# ========== 停止可能存在的服务 ==========
echo "🛑 停止 cloudflared..."
systemctl stop cloudflared || true

echo "🛑 停止 mita.service..."
systemctl stop mita || true

# ========== 安装 cloudflared ==========
echo "📥 安装 cloudflared..."
wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

# ========== 安装 Mita (Mieru Server) ==========
echo "📥 安装 Mita..."
ARCH=$(uname -m)
if [ "$ARCH" == "x86_64" ]; then
  MITA_PKG="mita_3.14.1_amd64.deb"
elif [ "$ARCH" == "aarch64" ]; then
  MITA_PKG="mita_3.14.1_arm64.deb"
else
  echo "❌ 不支持的架构: $ARCH"
  exit 1
fi

wget https://github.com/enfein/mieru/releases/download/v3.14.1/$MITA_PKG
dpkg -i $MITA_PKG

# ========== Cloudflare 登录授权 ==========
echo "🌐 请在弹出的浏览器中登录 Cloudflare 账户以授权此主机..."
cloudflared tunnel login

# ========== 创建 Cloudflare 隧道 ==========
if cloudflared tunnel list | grep -Fq "$TUNNEL_NAME"; then
    echo "⚠️ Tunnel '$TUNNEL_NAME' 已存在，正在删除..."
    cloudflared tunnel delete "$TUNNEL_NAME"
fi

echo "🚧 创建 Tunnel: $TUNNEL_NAME ..."
cloudflared tunnel create "$TUNNEL_NAME"
TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')

mkdir -p "$TUNNEL_DIR"
cp /root/.cloudflared/${TUNNEL_ID}.json $TUNNEL_DIR

# ========== 写入 cloudflared 配置 ==========
mkdir -p $CONFIG_DIR
cat <<EOF > $CONFIG_DIR/config.yml
tunnel: $TUNNEL_ID
credentials-file: $TUNNEL_DIR/${TUNNEL_ID}.json

ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:3080
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

# ========== 配置 Mita ==========
echo "🛠️ 配置 Mita..."
cat <<EOF > /etc/mita_config.json
{
    "portBindings": [
        {
            "port": 3080,
            "protocol": "TCP"
        }
    ],
    "users": [
        {
            "name": "user1",
            "password": "pass1"
        }
    ],
    "loggingLevel": "INFO"
}
EOF

mita apply config /etc/mita_config.json
mita start

# ========== 配置 systemd ==========
echo "🛠️ 写入 systemd 服务..."

cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared --config $CONFIG_DIR/config.yml tunnel run
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

# ========== 启动服务 ==========
echo "🔄 启动服务..."
systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared

sleep 5

# ========== 更新 CNAME ==========
echo "🔄 更新 Cloudflare CNAME 记录..."
ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN_ROOT" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

DNS_RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=CNAME&name=$DOMAIN" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$DNS_RECORD_ID" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "type": "CNAME",
    "name": "'"$DOMAIN"'",
    "content": "'"$TUNNEL_ID"'.cfargotunnel.com",
    "ttl": 120,
    "proxied": true
}')

echo "✅ 安装完成，公网地址： http://$DOMAIN"

# ========== 输出二维码 ==========
echo "📱 生成访问二维码..."
qrencode -t ANSIUTF8 "http://$DOMAIN"
