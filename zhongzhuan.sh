#!/bin/bash

################################################################################
#                                                                              #
#               CN2GIA中转机 WireGuard + Mack-a 一键部署脚本                   #
#                                                                              #
#  GitHub: https://github.com/your-username/vps-relay-setup                  #
#  使用方法: bash <(curl -s https://raw.githubusercontent.com/xxx/relay-setup/main/relay-setup.sh)
#                                                                              #
################################################################################

set -e

# ============================================================================
# 颜色定义
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# 打印函数
# ============================================================================
print_title() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║        CN2GIA中转机 WireGuard + Mack-a 一键部署工具             ║"
    echo "║                    v1.0.0                                      ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}${1}${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_input() {
    echo -e "${CYAN}[?]${NC} $1"
}

pause_input() {
    echo ""
    read -p "$(echo -e ${CYAN})[按Enter继续...]$(echo -e ${NC})" 
    echo ""
}

# ============================================================================
# 生成函数
# ============================================================================
generate_uuid() {
    python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || uuidgen 2>/dev/null || date +%s%N | md5sum | head -c 32
}

generate_random() {
    local length=$1
    openssl rand -hex $((length/2)) 2>/dev/null || head -c $length /dev/urandom | xxd -p
}

validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_port() {
    local port=$1
    if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 1 ] && [ $port -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# 主程序
# ============================================================================

print_title

if [ "$EUID" -ne 0 ]; then 
    print_error "必须使用 root 权限运行此脚本！"
    exit 1
fi

print_section "步骤 1/8: 收集基本信息"

WORK_DIR="/opt/relay-wg"
CONFIG_DIR="$WORK_DIR/config"
mkdir -p "$CONFIG_DIR"
chmod 755 "$WORK_DIR"

print_info "工作目录: $WORK_DIR"
echo ""

print_input "请输入中转机的公网IP地址"
print_info "  (如果不确定，按Enter自动获取)"
read -p "$(echo -e ${CYAN})IP${NC}: " RELAY_IP

if [ -z "$RELAY_IP" ]; then
    print_info "正在自动获取IP..."
    RELAY_IP=$(curl -s https://api.ip.sb/ip 2>/dev/null || echo "")
    
    if [ -z "$RELAY_IP" ]; then
        print_error "无法自动获取IP，请手动输入"
        read -p "$(echo -e ${CYAN})IP${NC}: " RELAY_IP
    else
        print_success "自动获取IP: $RELAY_IP"
    fi
fi

if ! validate_ip "$RELAY_IP"; then
    print_error "IP地址格式不正确！"
    exit 1
fi

echo ""
print_input "请输入WireGuard监听端口"
print_info "  (默认: 51820)"
read -p "$(echo -e ${CYAN})端口${NC}: " WG_PORT
WG_PORT=${WG_PORT:-51820}

if ! validate_port "$WG_PORT"; then
    print_error "端口号无效！"
    exit 1
fi

print_success "WireGuard端口: $WG_PORT"
echo ""

print_input "请输入Mack-a服务端口"
print_info "  (默认: 8080)"
read -p "$(echo -e ${CYAN})端口${NC}: " MACKA_PORT
MACKA_PORT=${MACKA_PORT:-8080}

if ! validate_port "$MACKA_PORT"; then
    print_error "端口号无效！"
    exit 1
fi

print_success "Mack-a端口: $MACKA_PORT"
echo ""

print_input "请输入需要配置的落地机数量"
print_info "  (支持1-10台)"
read -p "$(echo -e ${CYAN})数量${NC}: " PEER_COUNT

if ! [[ $PEER_COUNT =~ ^[1-9]$|^10$ ]]; then
    print_error "请输入1-10之间的数字"
    exit 1
fi

print_success "落地机数量: $PEER_COUNT"
echo ""

MACKA_TOKEN=$(generate_random 32)
print_success "已自动生成Mack-a认证令牌"

RELAY_UUID=$(generate_uuid)
print_success "已自动生成中转机UUID: $RELAY_UUID"

pause_input

print_section "步骤 2/8: 系统优化"

print_info "正在配置系统参数..."
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf 2>/dev/null || true
echo "net.ipv4.conf.all.rp_filter = 0" >> /etc/sysctl.conf 2>/dev/null || true
echo "net.ipv4.conf.default.rp_filter = 0" >> /etc/sysctl.conf 2>/dev/null || true
sysctl -p > /dev/null 2>&1

print_success "系统参数已配置"
pause_input

print_section "步骤 3/8: 安装依赖"

print_info "正在安装依赖包..."
apt-get update -qq > /dev/null 2>&1
apt-get install -y wireguard wireguard-tools openresolv curl wget net-tools ufw > /dev/null 2>&1

print_success "依赖已安装"
pause_input

print_section "步骤 4/8: 生成密钥"

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
cd /etc/wireguard

print_info "为中转机生成WireGuard密钥..."
wg genkey | tee relay_privatekey | wg pubkey > relay_publickey
RELAY_PRIV=$(cat relay_privatekey)
RELAY_PUB=$(cat relay_publickey)
print_success "中转机密钥已生成"
echo ""

declare -a PEER_NAMES
declare -a PEER_PRIVKEYS
declare -a PEER_PUBKEYS
declare -a PEER_IPS
declare -a PEER_UUIDS

print_info "为 $PEER_COUNT 台落地机生成密钥..."
echo ""

for ((i=1; i<=PEER_COUNT; i++)); do
    print_input "请输入第 $i 台落地机的名称"
    print_info "  (例如: phoenix, oregon, ashburn, lax)"
    read -p "$(echo -e ${CYAN})名称${NC}: " PEER_NAME
    
    if [ -z "$PEER_NAME" ]; then
        print_error "名称不能为空"
        ((i--))
        continue
    fi
    
    PEER_NAMES[$i]="$PEER_NAME"
    
    wg genkey | tee peer${i}_privatekey | wg pubkey > peer${i}_publickey
    PEER_PRIVKEYS[$i]=$(cat peer${i}_privatekey)
    PEER_PUBKEYS[$i]=$(cat peer${i}_publickey)
    PEER_IPS[$i]=$((i+1))
    PEER_UUIDS[$i]=$(generate_uuid)
    
    print_success "$PEER_NAME 密钥已生成"
    echo ""
done

pause_input

print_section "步骤 5/8: 生成配置文件"

print_info "正在生成中转机WireGuard配置..."

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = $WG_PORT
PrivateKey = $RELAY_PRIV

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT;
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT;

EOF

for ((i=1; i<=PEER_COUNT; i++)); do
    cat >> /etc/wireguard/wg0.conf <<EOF
[Peer]
# ${PEER_NAMES[$i]}
PublicKey = ${PEER_PUBKEYS[$i]}
AllowedIPs = 10.0.0.${PEER_IPS[$i]}/32
PersistentKeepalive = 25

EOF
done

chmod 600 /etc/wireguard/wg0.conf
print_success "中转机WireGuard配置已生成"

echo ""
mkdir -p /etc/mack-a

cat > /etc/mack-a/server.conf <<EOF
listen = "0.0.0.0:$MACKA_PORT"
protocol = "http"
cipher = "chacha20-ietf-poly1305"
obfs = "http"
auth_token = "$MACKA_TOKEN"
uuid = "$RELAY_UUID"
EOF

chmod 644 /etc/mack-a/server.conf
print_success "Mack-a配置已生成"

echo ""
mkdir -p "$CONFIG_DIR/peer-configs"

for ((i=1; i<=PEER_COUNT; i++)); do
    cat > "$CONFIG_DIR/peer-configs/${PEER_NAMES[$i]}-wg.conf" <<EOF
[Interface]
Address = 10.0.0.${PEER_IPS[$i]}/32
PrivateKey = ${PEER_PRIVKEYS[$i]}
DNS = 8.8.8.8, 1.1.1.1

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT;
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT;

[Peer]
PublicKey = $RELAY_PUB
Endpoint = $RELAY_IP:$WG_PORT
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF
    
    cat > "$CONFIG_DIR/peer-configs/${PEER_NAMES[$i]}-macka.conf" <<EOF
server = "$RELAY_IP"
port = $MACKA_PORT
protocol = "http"
cipher = "chacha20-ietf-poly1305"
obfs = "http"
auth_token = "$MACKA_TOKEN"
uuid = "${PEER_UUIDS[$i]}"
EOF
    
    print_success "已生成 ${PEER_NAMES[$i]} 的配置"
done

pause_input

print_section "步骤 6/8: 启动服务"

print_info "正在启动WireGuard..."
systemctl enable wg-quick@wg0 > /dev/null 2>&1
systemctl start wg-quick@wg0
sleep 2

if wg show wg0 > /dev/null 2>&1; then
    print_success "WireGuard已启动"
else
    print_error "WireGuard启动失败"
    exit 1
fi

pause_input

print_section "步骤 7/8: 配置防火墙"

print_info "正在配置防火墙..."
ufw allow 22/tcp > /dev/null 2>&1 || true
ufw allow $WG_PORT/udp > /dev/null 2>&1 || true
ufw allow $MACKA_PORT/tcp > /dev/null 2>&1 || true
echo "y" | ufw enable > /dev/null 2>&1 || true

print_success "防火墙配置完成"
pause_input

print_section "步骤 8/8: 完成总结"

print_success "部署完成！"
echo ""

echo -e "${YELLOW}【中转机信息】${NC}"
echo -e "  中转机IP:      ${GREEN}$RELAY_IP${NC}"
echo -e "  WireGuard端口: ${GREEN}$WG_PORT${NC}"
echo -e "  Mack-a端口:    ${GREEN}$MACKA_PORT${NC}"
echo ""

echo -e "${YELLOW}【认证信息】${NC}"
echo -e "  UUID:       ${GREEN}$RELAY_UUID${NC}"
echo -e "  Token:      ${GREEN}$MACKA_TOKEN${NC}"
echo ""

echo -e "${YELLOW}【落地机配置文件位置】${NC}"
echo -e "  ${GREEN}$CONFIG_DIR/peer-configs/${NC}"
echo ""

echo -e "${YELLOW}【配置文件列表】${NC}"
for ((i=1; i<=PEER_COUNT; i++)); do
    echo -e "  ${PEER_NAMES[$i]}:"
    echo -e "    ├─ ${PEER_NAMES[$i]}-wg.conf"
    echo -e "    └─ ${PEER_NAMES[$i]}-macka.conf"
done
echo ""

echo -e "${YELLOW}【验证命令】${NC}"
echo -e "  ${CYAN}wg show${NC}"
echo ""
