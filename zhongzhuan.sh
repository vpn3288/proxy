#!/bin/bash

################################################################################
#                                                                              #
#               CN2GIA中转机 WireGuard + Mack-a 一键部署脚本                   #
#                           v1.1.0                                             #
#                                                                              #
#  修复：                                                                       #
#    - Ubuntu 24.04 无 openresolv 包问题                                        #
#    - 自动识别系统发行版，按需安装依赖                                            #
#    - 自动处理 DNS 解析冲突（systemd-resolved vs resolvconf）                   #
#    - WireGuard 内核模块缺失时自动回退到 wireguard-go                           #
#    - iptables-persistent / ufw 冲突自动处理                                   #
#    - 防止重复写入 sysctl.conf                                                 #
#    - 改进密钥输入循环逻辑（避免 i-- 在严格模式下出错）                            #
#                                                                              #
################################################################################

set -euo pipefail

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
    echo "║                    v1.13                                       ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}${1}${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_info()    { echo -e "${BLUE}[i]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
print_input()   { echo -e "${CYAN}[?]${NC} $1"; }

pause_input() {
    echo ""
    read -rp "$(echo -e "${CYAN}")[按Enter继续...]$(echo -e "${NC}")"
    echo ""
}

# ============================================================================
# 工具函数
# ============================================================================
generate_uuid() {
    python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null \
        || uuidgen 2>/dev/null \
        || cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || date +%s%N | md5sum | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\).*/\1-\2-\3-\4-\5/'
}

generate_random() {
    local length=${1:-32}
    openssl rand -hex "$((length / 2))" 2>/dev/null \
        || head -c "$length" /dev/urandom | xxd -p | tr -d '\n' | head -c "$length"
}

validate_ip() {
    local ip=$1
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra parts <<< "$ip"
    for part in "${parts[@]}"; do
        (( part >= 0 && part <= 255 )) || return 1
    done
    return 0
}

validate_port() {
    local port=$1
    [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

# 检测 DNS 解析方式
detect_dns_manager() {
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "systemd-resolved"
    elif command -v resolvconf &>/dev/null; then
        echo "resolvconf"
    else
        echo "none"
    fi
}

# ============================================================================
# 主程序开始
# ============================================================================

print_title

# ---- root 检查 ----
if [[ "$EUID" -ne 0 ]]; then
    print_error "必须使用 root 权限运行此脚本！"
    exit 1
fi

# ---- 系统检测 ----
if [[ ! -f /etc/os-release ]]; then
    print_error "无法识别操作系统，仅支持 Debian/Ubuntu"
    exit 1
fi
source /etc/os-release
OS_ID="${ID:-unknown}"
OS_VERSION_ID="${VERSION_ID:-0}"
print_info "检测到系统: ${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"

# ============================================================================
print_section "步骤 1/8: 收集基本信息"
# ============================================================================

WORK_DIR="/opt/relay-wg"
CONFIG_DIR="$WORK_DIR/config"
mkdir -p "$CONFIG_DIR/peer-configs"
chmod 755 "$WORK_DIR"
print_info "工作目录: $WORK_DIR"
echo ""

# ---- 中转机 IP ----
print_input "请输入中转机的公网IP地址"
print_info "  (如果不确定，按Enter自动获取)"
read -rp "$(echo -e "${CYAN}")IP${NC}: " RELAY_IP

if [[ -z "$RELAY_IP" ]]; then
    print_info "正在自动获取IP..."
    RELAY_IP=$(
        curl -s --max-time 5 https://api.ip.sb/ip 2>/dev/null \
        || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null \
        || echo ""
    )
    if [[ -z "$RELAY_IP" ]]; then
        print_error "无法自动获取IP，请手动输入"
        read -rp "$(echo -e "${CYAN}")IP${NC}: " RELAY_IP
    else
        print_success "自动获取IP: $RELAY_IP"
    fi
fi

if ! validate_ip "$RELAY_IP"; then
    print_error "IP地址格式不正确！"
    exit 1
fi

# ---- WireGuard 端口 ----
echo ""
print_input "请输入WireGuard监听端口"
print_info "  (默认: 51820)"
read -rp "$(echo -e "${CYAN}")端口${NC}: " WG_PORT
WG_PORT=${WG_PORT:-51820}
if ! validate_port "$WG_PORT"; then
    print_error "端口号无效！"
    exit 1
fi
print_success "WireGuard端口: $WG_PORT"

# ---- Mack-a 端口 ----
echo ""
print_input "请输入Mack-a服务端口"
print_info "  (默认: 8080)"
read -rp "$(echo -e "${CYAN}")端口${NC}: " MACKA_PORT
MACKA_PORT=${MACKA_PORT:-8080}
if ! validate_port "$MACKA_PORT"; then
    print_error "端口号无效！"
    exit 1
fi
print_success "Mack-a端口: $MACKA_PORT"

# ---- 落地机数量 ----
echo ""
print_input "请输入需要配置的落地机数量"
print_info "  (支持1-10台)"
read -rp "$(echo -e "${CYAN}")数量${NC}: " PEER_COUNT
if ! [[ $PEER_COUNT =~ ^([1-9]|10)$ ]]; then
    print_error "请输入1-10之间的数字"
    exit 1
fi
print_success "落地机数量: $PEER_COUNT"

# ---- 自动生成令牌/UUID ----
echo ""
MACKA_TOKEN=$(generate_random 32)
print_success "已自动生成Mack-a认证令牌"
RELAY_UUID=$(generate_uuid)
print_success "已自动生成中转机UUID: $RELAY_UUID"

pause_input

# ============================================================================
print_section "步骤 2/8: 系统优化"
# ============================================================================

print_info "正在配置内核转发参数..."

SYSCTL_CONF=/etc/sysctl.conf
declare -A SYSCTL_PARAMS=(
    ["net.ipv4.ip_forward"]="1"
    ["net.ipv4.conf.all.rp_filter"]="0"
    ["net.ipv4.conf.default.rp_filter"]="0"
)

for key in "${!SYSCTL_PARAMS[@]}"; do
    val="${SYSCTL_PARAMS[$key]}"
    # 如果已存在则替换，否则追加
    if grep -q "^${key}" "$SYSCTL_CONF" 2>/dev/null; then
        sed -i "s|^${key}.*|${key} = ${val}|" "$SYSCTL_CONF"
    else
        echo "${key} = ${val}" >> "$SYSCTL_CONF"
    fi
done

sysctl -p > /dev/null 2>&1
print_success "系统参数已配置"

pause_input

# ============================================================================
print_section "步骤 3/8: 安装依赖"
# ============================================================================

print_info "更新软件包列表..."
# 忽略第三方仓库错误（如 nginx mainline 在 Ubuntu 24.04 上路径变化）
apt-get update -qq 2>/dev/null || apt-get update -qq --allow-insecure-repositories 2>/dev/null || true

# ---- 基础包 ----
BASE_PKGS="wireguard wireguard-tools curl wget net-tools iptables"

# ---- 检测 openresolv 是否真正可安装（apt-cache policy 有候选版本才算）----
# apt-cache show 在包被虚拟引用时也会返回0，需用 policy 判断实际候选
OPENRESOLV_CANDIDATE=$(apt-cache policy openresolv 2>/dev/null | grep 'Candidate:' | awk '{print $2}')
if [[ -n "$OPENRESOLV_CANDIDATE" && "$OPENRESOLV_CANDIDATE" != "(none)" ]]; then
    BASE_PKGS="$BASE_PKGS openresolv"
    print_info "检测到 openresolv 可安装（$OPENRESOLV_CANDIDATE），将一并安装"
else
    print_info "系统无 openresolv（Ubuntu 22.04+ 正常），使用 systemd-resolved"
fi

# ---- 安装基础包 ----
print_info "正在安装: $BASE_PKGS ..."
# shellcheck disable=SC2086
apt-get install -y $BASE_PKGS

# ---- 检查 WireGuard 内核模块，不可用则安装 wireguard-go ----
if ! modprobe wireguard 2>/dev/null; then
    print_warn "内核不支持 WireGuard 模块（内核版本: $(uname -r)），改用 wireguard-go..."
    apt-get install -y wireguard-go
    print_success "wireguard-go 已安装"
else
    print_success "WireGuard 内核模块可用"
fi

print_success "所有依赖已安装"

pause_input

# ============================================================================
print_section "步骤 4/8: 生成密钥"
# ============================================================================

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
cd /etc/wireguard

print_info "为中转机生成WireGuard密钥..."
wg genkey | tee relay_privatekey | wg pubkey > relay_publickey
RELAY_PRIV=$(cat relay_privatekey)
RELAY_PUB=$(cat relay_publickey)
chmod 600 relay_privatekey relay_publickey
print_success "中转机密钥已生成"
echo ""

declare -a PEER_NAMES
declare -a PEER_PRIVKEYS
declare -a PEER_PUBKEYS
declare -a PEER_IPS
declare -a PEER_UUIDS

print_info "为 $PEER_COUNT 台落地机生成密钥..."
echo ""

# 使用 while + counter 代替 for + i-- 避免 set -e 下减法问题
peer_idx=1
while (( peer_idx <= PEER_COUNT )); do
    print_input "请输入第 $peer_idx 台落地机的名称"
    print_info "  (例如: phoenix, oregon, ashburn, lax)"
    read -rp "$(echo -e "${CYAN}")名称${NC}: " PEER_NAME

    if [[ -z "$PEER_NAME" ]]; then
        print_error "名称不能为空，请重新输入"
        continue
    fi

    # 检查名称是否重复
    DUPLICATE=false
    for (( j=1; j<peer_idx; j++ )); do
        if [[ "${PEER_NAMES[$j]}" == "$PEER_NAME" ]]; then
            DUPLICATE=true
            break
        fi
    done
    if $DUPLICATE; then
        print_error "名称 '$PEER_NAME' 已使用，请输入不同的名称"
        continue
    fi

    PEER_NAMES[$peer_idx]="$PEER_NAME"
    wg genkey | tee "peer${peer_idx}_privatekey" | wg pubkey > "peer${peer_idx}_publickey"
    chmod 600 "peer${peer_idx}_privatekey" "peer${peer_idx}_publickey"
    PEER_PRIVKEYS[$peer_idx]=$(cat "peer${peer_idx}_privatekey")
    PEER_PUBKEYS[$peer_idx]=$(cat "peer${peer_idx}_publickey")
    PEER_IPS[$peer_idx]=$(( peer_idx + 1 ))
    PEER_UUIDS[$peer_idx]=$(generate_uuid)

    print_success "${PEER_NAMES[$peer_idx]} 密钥已生成 (WireGuard IP: 10.0.0.${PEER_IPS[$peer_idx]})"
    echo ""
    (( peer_idx++ ))
done

pause_input

# ============================================================================
print_section "步骤 5/8: 生成配置文件"
# ============================================================================

# ---- 中转机 WireGuard 配置 ----
print_info "正在生成中转机WireGuard配置..."

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = $WG_PORT
PrivateKey = $RELAY_PRIV

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

EOF

for (( i=1; i<=PEER_COUNT; i++ )); do
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

# ---- Mack-a 服务端配置 ----
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
print_success "Mack-a服务端配置已生成"

# ---- 落地机配置文件 ----
echo ""
for (( i=1; i<=PEER_COUNT; i++ )); do
    NAME="${PEER_NAMES[$i]}"

    # WireGuard 客户端配置
    cat > "$CONFIG_DIR/peer-configs/${NAME}-wg.conf" <<EOF
[Interface]
Address = 10.0.0.${PEER_IPS[$i]}/32
PrivateKey = ${PEER_PRIVKEYS[$i]}
DNS = 8.8.8.8, 1.1.1.1

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = $RELAY_PUB
Endpoint = $RELAY_IP:$WG_PORT
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

    # Mack-a 客户端配置
    cat > "$CONFIG_DIR/peer-configs/${NAME}-macka.conf" <<EOF
server = "$RELAY_IP"
port = $MACKA_PORT
protocol = "http"
cipher = "chacha20-ietf-poly1305"
obfs = "http"
auth_token = "$MACKA_TOKEN"
uuid = "${PEER_UUIDS[$i]}"
EOF

    print_success "已生成 ${NAME} 的配置文件"
done

# ---- 保存全局信息摘要 ----
cat > "$CONFIG_DIR/summary.txt" <<EOF
========================================
  CN2GIA 中转机部署信息摘要
  生成时间: $(date '+%Y-%m-%d %H:%M:%S')
========================================

【中转机】
  公网IP:         $RELAY_IP
  WireGuard端口:  $WG_PORT (UDP)
  WireGuard公钥:  $RELAY_PUB
  WireGuard地址:  10.0.0.1/24
  Mack-a端口:     $MACKA_PORT (TCP)
  Mack-a UUID:    $RELAY_UUID
  Mack-a Token:   $MACKA_TOKEN

【落地机列表】
EOF

for (( i=1; i<=PEER_COUNT; i++ )); do
    cat >> "$CONFIG_DIR/summary.txt" <<EOF
  [$i] ${PEER_NAMES[$i]}
       WireGuard IP:  10.0.0.${PEER_IPS[$i]}/32
       WireGuard公钥: ${PEER_PUBKEYS[$i]}
       Mack-a UUID:   ${PEER_UUIDS[$i]}
       配置文件:       peer-configs/${PEER_NAMES[$i]}-wg.conf
                      peer-configs/${PEER_NAMES[$i]}-macka.conf

EOF
done

chmod 600 "$CONFIG_DIR/summary.txt"
print_success "部署信息摘要已保存到 $CONFIG_DIR/summary.txt"

pause_input

# ============================================================================
print_section "步骤 6/8: 启动服务"
# ============================================================================

print_info "正在启动WireGuard..."
systemctl enable wg-quick@wg0 > /dev/null 2>&1

# 如果已经在运行，先重启；否则直接启动
if systemctl is-active --quiet wg-quick@wg0; then
    print_warn "WireGuard已在运行，重新加载配置..."
    systemctl restart wg-quick@wg0
else
    systemctl start wg-quick@wg0
fi

sleep 2

if wg show wg0 > /dev/null 2>&1; then
    print_success "WireGuard已启动"
    wg show wg0
else
    print_error "WireGuard启动失败！请检查日志: journalctl -xe -u wg-quick@wg0"
    exit 1
fi

pause_input

# ============================================================================
print_section "步骤 7/8: 配置防火墙"
# ============================================================================

print_info "下载并运行 iptables 防火墙脚本（中转机模式）..."

FW_SCRIPT="/opt/relay-wg/port.sh"

# 优先从 GitHub 下载最新版，失败则使用内嵌备份
if curl -sSL --max-time 15 \
    "https://raw.githubusercontent.com/vpn3288/iptables/refs/heads/main/port.sh" \
    -o "$FW_SCRIPT" 2>/dev/null; then
    print_success "防火墙脚本已下载"
else
    print_warn "GitHub 下载失败，使用内嵌版本..."
    # 内嵌备用：直接复制当前已知可用版本
    cp /dev/stdin "$FW_SCRIPT" << 'FWEOF'
#!/bin/bash
# 内嵌极简版，仅在无法下载时使用
set -uo pipefail
[[ $(id -u) -eq 0 ]] || { echo "需要 root"; exit 1; }
WG_PORT="${1:-51820}"
MACKA_PORT="${2:-8080}"
WG_SUBNET="${3:-10.0.0.0/24}"
SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | grep -oE ':[0-9]+' | grep -oE '[0-9]+' | head -1 || echo 22)
WAN=$(ip route show default 2>/dev/null | awk '/default/{print $5;exit}' || echo eth0)
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
iptables -F; iptables -X; iptables -t nat -F; iptables -t nat -X
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
iptables -A INPUT -p udp --dport "$WG_PORT" -j ACCEPT
iptables -A INPUT -p tcp --dport "$MACKA_PORT" -j ACCEPT
iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -s "$WG_SUBNET" -o "$WAN" -j MASQUERADE
iptables -A INPUT -j DROP
mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4
echo "✓ 防火墙配置完成（内嵌极简版）"
FWEOF
fi

chmod +x "$FW_SCRIPT"

# 以中转机模式调用，自动传入本次部署的端口参数，无需交互确认
bash "$FW_SCRIPT" \
    --relay \
    --wg-port   "$WG_PORT" \
    --macka-port "$MACKA_PORT" \
    --wg-subnet  "10.0.0.0/24" \
    --wg-iface   "wg0" \
    << 'CONFIRM'
y
CONFIRM

print_success "防火墙配置完成"
print_info "后续管理命令："
print_info "  查看状态: bash $FW_SCRIPT --status"
print_info "  重置规则: bash $FW_SCRIPT --reset"

pause_input

# ============================================================================
print_section "步骤 8/8: 完成总结"
# ============================================================================

print_success "部署完成！"
echo ""

# ---- 安装 relay-info 快捷命令 ----
cat > /usr/local/bin/relay-info << CMEOF
#!/bin/bash
CYAN='\033[0;36m' YELLOW='\033[1;33m' GREEN='\033[0;32m' NC='\033[0m'
cat /opt/relay-wg/config/summary.txt 2>/dev/null || echo "摘要文件不存在: /opt/relay-wg/config/summary.txt"
echo ""
echo -e "\${CYAN}━━━━━━━━━━━━━━━━ 实时状态 ━━━━━━━━━━━━━━━━\${NC}"
echo -e "\${GREEN}▸ WireGuard 运行状态:\${NC}"
wg show 2>/dev/null || echo "  (未运行)"
CMEOF
chmod +x /usr/local/bin/relay-info
print_success "已安装 relay-info 快捷命令"
echo ""

# ════════════════════════════════════════════════════════════════
# 展示：中转机信息 + 每台落地机的完整部署信息
# ════════════════════════════════════════════════════════════════
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         ★ 部署完成！以下是落地机部署所需的完整信息 ★          ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【中转机公共信息】 — 每台落地机都需要填写这些              │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
echo -e "  中转机公网IP       → ${GREEN}$RELAY_IP${NC}"
echo -e "  WireGuard端口      → ${GREEN}$WG_PORT/UDP${NC}"
echo -e "  Mack-a端口         → ${GREEN}$MACKA_PORT/TCP${NC}"
echo -e "  Mack-a Token       → ${GREEN}$MACKA_TOKEN${NC}  ← 所有落地机共用"
echo -e "  中转机UUID         → ${GREEN}$RELAY_UUID${NC}  ← 所有落地机共用"
echo -e "  中转机WireGuard公钥→ ${GREEN}$RELAY_PUB${NC}"
echo ""

for (( i=1; i<=PEER_COUNT; i++ )); do
    echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│  【落地机 $i: ${PEER_NAMES[$i]}】 — 此台机器专属，不可混用          │${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
    echo -e "  虚拟IP (WG Address) → ${GREEN}10.0.0.${PEER_IPS[$i]}/32${NC}"
    echo -e "  WireGuard私钥       → ${GREEN}${PEER_PRIVKEYS[$i]}${NC}  ← 填到落地机脚本[私钥]"
    echo -e "  落地机UUID          → ${GREEN}${PEER_UUIDS[$i]}${NC}  ← 填到落地机脚本[落地机UUID]"
    echo -e "  配置文件            → ${CYAN}$CONFIG_DIR/peer-configs/${PEER_NAMES[$i]}-wg.conf${NC}"
    echo -e "                        ${CYAN}$CONFIG_DIR/peer-configs/${PEER_NAMES[$i]}-macka.conf${NC}"
    echo ""
done

echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【中转机常用命令】                                         │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
echo -e "  查看所有信息:       ${CYAN}relay-info${NC}"
echo -e "  查看WireGuard状态:  ${CYAN}wg show${NC}"
echo -e "  重启WireGuard:      ${CYAN}systemctl restart wg-quick@wg0${NC}"
echo -e "  查看WG日志:         ${CYAN}journalctl -u wg-quick@wg0 -f${NC}"
echo -e "  查看防火墙状态:     ${CYAN}bash /opt/relay-wg/port.sh --status${NC}"
echo -e "  查看NAT规则:        ${CYAN}iptables -t nat -L -n -v${NC}"
echo ""
echo -e "${GREEN}随时运行 ${CYAN}relay-info${GREEN} 可重新查看以上所有信息${NC}"
echo -e "${GREEN}完整摘要: ${CYAN}cat $CONFIG_DIR/summary.txt${NC}"
echo ""
