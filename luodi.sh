#!/bin/bash

################################################################################
#                                                                              #
#                 落地机 WireGuard + Mack-a 一键部署脚本                        #
#                                                                              #
#  GitHub: https://github.com/your-username/vps-relay-setup                  #
#  使用方法: bash <(curl -s https://raw.githubusercontent.com/xxx/relay-setup/main/peer-setup.sh)
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
    echo "║           落地机 WireGuard + Mack-a 一键部署工具              ║"
    echo "║                    v1.0.0                                     ║"
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

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

pause_input() {
    echo ""
    read -p "$(echo -e ${CYAN})[按Enter继续...]$(echo -e ${NC})" 
    echo ""
}

# ============================================================================
# 验证函数
# ============================================================================
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

validate_uuid() {
    local uuid=$1
    if [[ $uuid =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_hex() {
    local hex=$1
    if [[ $hex =~ ^[a-f0-9]+$ ]]; then
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

print_section "步骤 1/7: 收集配置信息"

WORK_DIR="/opt/relay-wg"
CONFIG_DIR="$WORK_DIR/config"
mkdir -p "$CONFIG_DIR"

echo ""
print_info "请从中转机获取以下信息（在中转机上运行脚本后会显示）"
echo ""

print_input "请输入中转机的公网IP地址"
read -p "$(echo -e ${CYAN})IP${NC}: " RELAY_IP

if ! validate_ip "$RELAY_IP"; then
    print_error "IP地址格式不正确！"
    exit 1
fi

print_success "中转机IP: $RELAY_IP"
echo ""

print_input "请输入WireGuard端口"
print_info "  (中转机设置的端口，通常是51820)"
read -p "$(echo -e ${CYAN})端口${NC}: " WG_PORT

if ! validate_port "$WG_PORT"; then
    print_error "端口号无效！"
    exit 1
fi

print_success "WireGuard端口: $WG_PORT"
echo ""

print_input "请输入Mack-a端口"
print_info "  (中转机设置的端口，通常是8080)"
read -p "$(echo -e ${CYAN})端口${NC}: " MACKA_PORT

if ! validate_port "$MACKA_PORT"; then
    print_error "端口号无效！"
    exit 1
fi

print_success "Mack-a端口: $MACKA_PORT"
echo ""

print_input "请输入Mack-a认证令牌"
print_info "  (在中转机部署完成后显示的Token)"
read -p "$(echo -e ${CYAN})Token${NC}: " MACKA_TOKEN

if ! validate_hex "$MACKA_TOKEN"; then
    print_error "Token格式不正确！应该是十六进制字符"
    exit 1
fi

print_success "Mack-a令牌已设置"
echo ""

print_input "请输入中转机UUID"
print_info "  (在中转机部署完成后显示的UUID)"
read -p "$(echo -e ${CYAN})UUID${NC}: " RELAY_UUID

if ! validate_uuid "$RELAY_UUID"; then
    print_error "UUID格式不正确！"
    exit 1
fi

print_success "中转机UUID: $RELAY_UUID"
echo ""

print_input "请输入此落地机的WireGuard私钥"
print_info "  (从中转机生成的配置文件中复制: [Interface]中的PrivateKey)"
read -p "$(echo -e ${CYAN})私钥${NC}: " WG_PRIVKEY

if [ -z "$WG_PRIVKEY" ]; then
    print_error "私钥不能为空"
    exit 1
fi

print_success "WireGuard私钥已设置"
echo ""

print_input "请输入中转机的WireGuard公钥"
print_info "  (从中转机生成的配置文件中复制: [Peer]中的PublicKey)"
read -p "$(echo -e ${CYAN})公钥${NC}: " RELAY_PUBKEY

if [ -z "$RELAY_PUBKEY" ]; then
    print_error "公钥不能为空"
    exit 1
fi

print_success "中转机公钥已设置"
echo ""

print_input "请输入此落地机的虚拟IP地址"
print_info "  (从中转机生成的配置文件中复制: Address, 例如10.0.0.2)"
read -p "$(echo -e ${CYAN})IP${NC}: " WG_ADDRESS

if ! [[ $WG_ADDRESS =~ ^10\.0\.0\.[0-9]+/32$ ]]; then
    print_error "IP地址格式不正确！应该是 10.0.0.x/32"
    exit 1
fi

print_success "虚拟IP: $WG_ADDRESS"
echo ""

print_input "请输入此落地机的UUID"
print_info "  (从中转机生成的配置文件中复制: Mack-a配置的uuid字段)"
read -p "$(echo -e ${CYAN})UUID${NC}: " PEER_UUID

if ! validate_uuid "$PEER_UUID"; then
    print_error "UUID格式不正确！"
    exit 1
fi

print_success "落地机UUID: $PEER_UUID"
echo ""

pause_input

print_section "步骤 2/7: 系统优化"

print_info "正在配置系统参数..."
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf 2>/dev/null || true
echo "net.ipv4.conf.all.rp_filter = 0" >> /etc/sysctl.conf 2>/dev/null || true
echo "net.ipv4.conf.default.rp_filter = 0" >> /etc/sysctl.conf 2>/dev/null || true
sysctl -p > /dev/null 2>&1

print_success "系统参数已配置"
pause_input

print_section "步骤 3/7: 安装依赖"

print_info "正在安装依赖包..."
apt-get update -qq > /dev/null 2>&1
apt-get install -y wireguard wireguard-tools openresolv curl wget net-tools > /dev/null 2>&1

print_success "依赖已安装"
pause_input

print_section "步骤 4/7: 配置WireGuard"

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

print_info "正在生成WireGuard配置文件..."

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = $WG_ADDRESS
PrivateKey = $WG_PRIVKEY
DNS = 8.8.8.8, 1.1.1.1

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT;
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT;

[Peer]
PublicKey = $RELAY_PUBKEY
Endpoint = $RELAY_IP:$WG_PORT
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg0.conf
print_success "WireGuard配置已生成"
pause_input

print_section "步骤 5/7: 配置Mack-a"

mkdir -p /etc/mack-a

print_info "正在生成Mack-a配置文件..."

cat > /etc/mack-a/client.conf <<EOF
server = "$RELAY_IP"
port = $MACKA_PORT
protocol = "http"
cipher = "chacha20-ietf-poly1305"
obfs = "http"
auth_token = "$MACKA_TOKEN"
uuid = "$PEER_UUID"
log_level = "info"
EOF

chmod 644 /etc/mack-a/client.conf
print_success "Mack-a配置已生成"
pause_input

print_section "步骤 6/7: 启动服务"

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

echo ""
print_warn "Mack-a客户端需要手动启动（暂不自动安装）"
print_info "Mack-a配置文件位置: /etc/mack-a/client.conf"

pause_input

print_section "步骤 7/7: 完成总结和验证"

print_success "配置完成！"
echo ""

echo -e "${YELLOW}【已配置的信息】${NC}"
echo -e "  中转机IP:      ${GREEN}$RELAY_IP${NC}"
echo -e "  WireGuard端口: ${GREEN}$WG_PORT${NC}"
echo -e "  Mack-a端口:    ${GREEN}$MACKA_PORT${NC}"
echo -e "  虚拟IP:        ${GREEN}$WG_ADDRESS${NC}"
echo ""

echo -e "${YELLOW}【配置文件位置】${NC}"
echo -e "  WireGuard: ${GREEN}/etc/wireguard/wg0.conf${NC}"
echo -e "  Mack-a:    ${GREEN}/etc/mack-a/client.conf${NC}"
echo ""

echo -e "${YELLOW}【验证步骤】${NC}"
echo -e "  ${CYAN}# 1. 检查WireGuard连接${NC}"
echo -e "  wg show"
echo ""
echo -e "  ${CYAN}# 2. 检查虚拟IP${NC}"
echo -e "  ip addr show wg0"
echo ""
echo -e "  ${CYAN}# 3. 最重要！验证出站IP（应该是本地IP，不是中转机IP）${NC}"
echo -e "  curl https://api.ip.sb/ip"
echo ""
echo -e "  ${CYAN}# 4. 检查延迟到中转机${NC}"
echo -e "  ping 10.0.0.1"
echo ""

echo -e "${YELLOW}【可能需要手动部署】${NC}"
echo -e "  1. Mack-a客户端程序"
echo -e "  2. 启动Mack-a服务: systemctl start mack-a"
echo ""

echo -e "${YELLOW}【故障排查】${NC}"
echo -e "  如果出站IP显示为中转机IP而非本地IP:"
echo -e "    ├─ 检查IP转发: sysctl net.ipv4.ip_forward"
echo -e "    └─ 重启WireGuard: systemctl restart wg-quick@wg0"
echo ""
echo -e "  如果无法连接中转机:"
echo -e "    ├─ 检查WireGuard状态: wg show"
echo -e "    └─ 查看日志: journalctl -xe"
echo ""

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "配置已完成！接下来启动Mack-a客户端连接到中转机"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
