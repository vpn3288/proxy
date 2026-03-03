#!/bin/bash

################################################################################
#                                                                              #
#                 落地机 WireGuard + Mack-a 一键部署脚本                        #
#                           v1.04                                              #
#                                                                              #
#  修复/改进：                                                                   #
#    - 所有输入错误时提示并要求重新输入，不再直接退出                               #
#    - 修复 IP 地址输入不带 /32 时自动补全                                        #
#    - 修复 openresolv 在 Ubuntu 22.04+ 不可用问题                               #
#    - 修复 sysctl.conf 重复写入问题                                              #
#    - 集成 iptables 防火墙（落地机模式）                                          #
#    - 结尾一次性展示所有落地机需填写的信息，并标注含义                              #
#    - 提供 relay-info 快捷查看命令                                               #
#                                                                              #
################################################################################

set -uo pipefail

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
    echo "║           落地机 WireGuard + Mack-a 一键部署工具               ║"
    echo "║                       v1.04                                   ║"
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
# 验证函数（只返回0/1，不退出）
# ============================================================================
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

validate_uuid() {
    local uuid=$1
    [[ $uuid =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]]
}

validate_wg_key() {
    # WireGuard 密钥是 44 字符的 base64（含 = 结尾）
    local key=$1
    [[ ${#key} -eq 44 && $key =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

validate_hex() {
    local hex=$1
    [[ $hex =~ ^[a-fA-F0-9]+$ ]]
}

validate_wg_address() {
    # 接受 10.0.0.x 或 10.0.0.x/32
    local addr=$1
    local ip="${addr%/*}"
    validate_ip "$ip" || return 1
    [[ $ip =~ ^10\.0\.0\.[0-9]+$ ]] || return 1
    local last="${ip##*.}"
    (( last >= 2 && last <= 254 )) || return 1
    return 0
}

# ============================================================================
# 带重试的输入函数
# read_input <变量名> <提示> <校验函数> <错误提示> [默认值]
# ============================================================================
read_input() {
    local -n _var=$1
    local prompt="$2"
    local validator="$3"
    local errmsg="$4"
    local default="${5:-}"

    while true; do
        if [[ -n "$default" ]]; then
            read -rp "$(echo -e "${CYAN}")${prompt}${NC} [默认: ${default}]: " _var
            [[ -z "$_var" ]] && _var="$default"
        else
            read -rp "$(echo -e "${CYAN}")${prompt}${NC}: " _var
        fi

        if [[ -z "$_var" && -z "$default" ]]; then
            print_error "不能为空，请重新输入"
            continue
        fi

        if $validator "$_var"; then
            break
        else
            print_error "$errmsg"
            print_warn "请重新输入 ↑"
        fi
    done
}

# ============================================================================
# 主程序
# ============================================================================

print_title

if [[ "$EUID" -ne 0 ]]; then
    print_error "必须使用 root 权限运行此脚本！"
    exit 1
fi

# 检测系统
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    print_info "检测到系统: ${PRETTY_NAME:-未知}"
fi

WORK_DIR="/opt/relay-wg"
CONFIG_DIR="$WORK_DIR/config"
mkdir -p "$CONFIG_DIR"

# ============================================================================
print_section "步骤 1/7: 收集配置信息"
# ============================================================================

echo ""
print_info "请从中转机的部署摘要中获取以下信息"
print_info "中转机查看命令: ${CYAN}relay-info${NC}  或  ${CYAN}cat /opt/relay-wg/config/summary.txt${NC}"
echo ""

# ---- 中转机公网 IP ----
print_input "中转机的公网IP地址"
read_input RELAY_IP "中转机IP" validate_ip "IP格式不正确，示例: 185.201.226.132"
print_success "中转机IP: $RELAY_IP"
echo ""

# ---- WireGuard 端口 ----
print_input "WireGuard监听端口（中转机上设置的）"
read_input WG_PORT "WireGuard端口" validate_port "端口须为1-65535之间的数字" "51820"
print_success "WireGuard端口: $WG_PORT"
echo ""

# ---- Mack-a 端口 ----
print_input "Mack-a服务端口（中转机上设置的）"
read_input MACKA_PORT "Mack-a端口" validate_port "端口须为1-65535之间的数字" "8080"
print_success "Mack-a端口: $MACKA_PORT"
echo ""

# ---- Mack-a Token ----
print_input "Mack-a认证令牌 Token（中转机部署完成后显示）"
read_input MACKA_TOKEN "Token" validate_hex "Token应为十六进制字符串"
print_success "Mack-a令牌已设置"
echo ""

# ---- 中转机 UUID ----
print_input "中转机UUID（中转机部署完成后显示，注意：是中转机UUID，不是落地机UUID）"
read_input RELAY_UUID "中转机UUID" validate_uuid "UUID格式: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
print_success "中转机UUID: $RELAY_UUID"
echo ""

# ---- 落地机 WG 私钥 ----
echo -e "${YELLOW}[!]${NC} 私钥 ≠ 公钥！私钥在 xxx-wg.conf 的 ${CYAN}[Interface]${NC} 段 ${CYAN}PrivateKey${NC} 字段"
echo -e "    公钥在 ${CYAN}[Peer]${NC} 段，千万不要填反。在中转机运行以下命令查看："
echo -e "    ${CYAN}cat /opt/relay-wg/config/peer-configs/此落地机名称-wg.conf${NC}"
read_input WG_PRIVKEY "WireGuard私钥" validate_wg_key "私钥应为44字符的Base64字符串（以=结尾）"
print_success "WireGuard私钥已设置"
echo ""

# ---- 中转机 WG 公钥 ----
echo -e "${YELLOW}[!]${NC} 中转机公钥在 xxx-wg.conf 的 ${CYAN}[Peer]${NC} 段 ${CYAN}PublicKey${NC} 字段"
echo -e "    或在中转机运行 ${CYAN}relay-info${NC} 查看「中转机WireGuard公钥」"
while true; do
    read_input RELAY_PUBKEY "中转机WireGuard公钥" validate_wg_key "公钥应为44字符的Base64字符串（以=结尾）"
    if [[ "$WG_PRIVKEY" == "$RELAY_PUBKEY" ]]; then
        print_error "填写的公钥与私钥相同！你可能把公钥填到了私钥字段"
        print_warn "请回头检查：[Interface] PrivateKey 是私钥，[Peer] PublicKey 是中转机公钥"
        echo -e "    在中转机运行: ${CYAN}cat /opt/relay-wg/config/peer-configs/落地机名称-wg.conf${NC}"
        print_warn "请重新输入中转机公钥 ↑"
    else
        break
    fi
done
print_success "中转机公钥已设置"
echo ""

# ---- 落地机虚拟 IP ----
print_input "此落地机的虚拟IP（来自 xxx-wg.conf 的 [Interface] Address，例如 10.0.0.2）"
print_info "  可以只输入 10.0.0.x，脚本会自动补全 /32"
while true; do
    read -rp "$(echo -e "${CYAN}")虚拟IP${NC}: " _raw_addr
    # 自动补全 /32
    if [[ "$_raw_addr" =~ ^10\.0\.0\.[0-9]+$ ]]; then
        _raw_addr="${_raw_addr}/32"
    fi
    if validate_wg_address "${_raw_addr%/*}"; then
        WG_ADDRESS="$_raw_addr"
        break
    else
        print_error "格式不正确，应为 10.0.0.2 ~ 10.0.0.254（或带/32）"
        print_warn "请重新输入 ↑"
    fi
done
print_success "虚拟IP: $WG_ADDRESS"
echo ""

# ---- 落地机 UUID ----
echo -e "${YELLOW}[!]${NC} 落地机UUID 来自中转机屏幕输出的 【落地机 N: 名称】 区块中的「落地机UUID」一行"
echo -e "    也可以在中转机运行: ${CYAN}relay-info${NC}  或  ${CYAN}cat /opt/relay-wg/config/summary.txt${NC}"
print_input "此落地机的UUID（每台落地机不同，不要填中转机UUID）"
read_input PEER_UUID "落地机UUID" validate_uuid "UUID格式: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
print_success "落地机UUID: $PEER_UUID"
echo ""

pause_input

# ============================================================================
print_section "步骤 2/7: 系统优化"
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
print_section "步骤 3/7: 安装依赖"
# ============================================================================

print_info "更新软件包列表..."
apt-get update -qq

BASE_PKGS="wireguard wireguard-tools curl wget net-tools iptables"

OPENRESOLV_CANDIDATE=$(apt-cache policy openresolv 2>/dev/null | grep 'Candidate:' | awk '{print $2}')
if [[ -n "$OPENRESOLV_CANDIDATE" && "$OPENRESOLV_CANDIDATE" != "(none)" ]]; then
    BASE_PKGS="$BASE_PKGS openresolv"
    print_info "检测到 openresolv 可安装，将一并安装"
else
    print_info "系统无 openresolv（Ubuntu 22.04+ 正常），使用 systemd-resolved"
fi

print_info "正在安装: $BASE_PKGS ..."
# shellcheck disable=SC2086
apt-get install -y $BASE_PKGS

# 检查 WireGuard 内核模块
if ! modprobe wireguard 2>/dev/null; then
    print_warn "内核不支持 WireGuard 模块（内核: $(uname -r)），改用 wireguard-go..."
    apt-get install -y wireguard-go
    print_success "wireguard-go 已安装"
else
    print_success "WireGuard 内核模块可用"
fi

print_success "所有依赖已安装"
pause_input

# ============================================================================
print_section "步骤 4/7: 配置WireGuard"
# ============================================================================

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

print_info "正在生成WireGuard配置文件..."

# 检测 DNS 解析支持情况，避免 resolvconf 不存在导致 wg-quick 启动失败
WG_DNS_LINE=""
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    WG_DNS_LINE="DNS = 8.8.8.8, 1.1.1.1"
    print_info "检测到 systemd-resolved，启用 DNS 配置"
elif command -v resolvconf &>/dev/null; then
    WG_DNS_LINE="DNS = 8.8.8.8, 1.1.1.1"
    print_info "检测到 resolvconf，启用 DNS 配置"
else
    print_warn "未检测到 DNS 解析器（resolvconf/systemd-resolved），跳过 DNS 配置以防启动失败"
fi

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = $WG_ADDRESS
PrivateKey = $WG_PRIVKEY
${WG_DNS_LINE:+DNS = 8.8.8.8, 1.1.1.1}

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = $RELAY_PUBKEY
Endpoint = $RELAY_IP:$WG_PORT
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg0.conf
print_success "WireGuard配置已生成"
pause_input

# ============================================================================
print_section "步骤 5/7: 配置Mack-a"
# ============================================================================

mkdir -p /etc/mack-a
print_info "正在生成Mack-a客户端配置文件..."

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
print_success "Mack-a客户端配置已生成"
pause_input

# ============================================================================
print_section "步骤 6/7: 启动服务 + 配置防火墙"
# ============================================================================

# ---- 启动 WireGuard ----
print_info "正在启动WireGuard..."
systemctl enable wg-quick@wg0 > /dev/null 2>&1

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

echo ""

# ---- 配置防火墙（落地机模式）----
print_info "下载并运行 iptables 防火墙脚本（落地机模式）..."

FW_SCRIPT="/opt/relay-wg/port.sh"

if curl -sSL --max-time 15 \
    "https://raw.githubusercontent.com/vpn3288/iptables/refs/heads/main/port.sh" \
    -o "$FW_SCRIPT" 2>/dev/null; then
    print_success "防火墙脚本已下载"
else
    print_warn "GitHub 下载失败，使用内嵌极简版..."
    cat > "$FW_SCRIPT" << 'FWEOF'
#!/bin/bash
set -uo pipefail
[[ $(id -u) -eq 0 ]] || { echo "需要 root"; exit 1; }
SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | grep -oE ':[0-9]+' | grep -oE '[0-9]+' | head -1 || echo 22)
WAN=$(ip route show default 2>/dev/null | awk '/default/{print $5;exit}' || echo eth0)
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
iptables -F; iptables -X; iptables -t nat -F; iptables -t nat -X
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT
iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -o "$WAN" -j MASQUERADE
iptables -A INPUT -j DROP
mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4
echo "✓ 防火墙配置完成（内嵌极简版）"
FWEOF
fi

chmod +x "$FW_SCRIPT"

bash "$FW_SCRIPT" --landing << 'CONFIRM'
y
CONFIRM

print_success "防火墙配置完成"

pause_input

# ============================================================================
print_section "步骤 7/7: 完成总结"
# ============================================================================

# ---- 保存本机配置摘要 ----
SUMMARY_FILE="$CONFIG_DIR/peer-summary.txt"
cat > "$SUMMARY_FILE" <<EOF
========================================
  落地机部署信息摘要
  生成时间: $(date '+%Y-%m-%d %H:%M:%S')
========================================

【此落地机信息】
  虚拟IP（WireGuard地址）:  $WG_ADDRESS
  落地机UUID（Mack-a）:     $PEER_UUID

【中转机信息（从中转机复制过来的）】
  中转机公网IP:             $RELAY_IP
  WireGuard端口:            $WG_PORT/UDP
  Mack-a端口:               $MACKA_PORT/TCP
  Mack-a Token:             $MACKA_TOKEN
  中转机UUID:               $RELAY_UUID
  中转机WireGuard公钥:      $RELAY_PUBKEY

【配置文件位置】
  WireGuard: /etc/wireguard/wg0.conf
  Mack-a:    /etc/mack-a/client.conf
  防火墙:    /opt/relay-wg/port.sh

【常用命令】
  查看连接信息:  relay-info
  查看WG状态:    wg show
  重启WG:        systemctl restart wg-quick@wg0
  查看防火墙:    bash /opt/relay-wg/port.sh --status
  重置防火墙:    bash /opt/relay-wg/port.sh --reset
  查看WG日志:    journalctl -u wg-quick@wg0 -f
EOF
chmod 600 "$SUMMARY_FILE"
print_success "摘要已保存: $SUMMARY_FILE"

# ---- 安装 relay-info 快捷命令 ----
cat > /usr/local/bin/relay-info << 'CMEOF'
#!/bin/bash
CYAN='\033[0;36m' YELLOW='\033[1;33m' GREEN='\033[0;32m' NC='\033[0m'
SUMMARY=/opt/relay-wg/config/peer-summary.txt

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                  落地机连接信息速查                             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if [[ -f "$SUMMARY" ]]; then
    cat "$SUMMARY"
else
    echo -e "${YELLOW}[!] 摘要文件不存在: $SUMMARY${NC}"
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━ 实时状态 ━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}▸ WireGuard 状态:${NC}"
wg show 2>/dev/null || echo "  (未运行)"

echo ""
echo -e "${GREEN}▸ 本机出口IP:${NC}"
curl -s --max-time 5 https://api.ip.sb/ip 2>/dev/null \
    || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo "  (获取失败)"

echo ""
echo -e "${GREEN}▸ 中转机隧道连通性 (ping 10.0.0.1):${NC}"
ping -c 3 -W 2 10.0.0.1 2>/dev/null || echo "  (不通，检查WireGuard连接)"
CMEOF
chmod +x /usr/local/bin/relay-info
print_success "已安装 relay-info 命令"

# ============================================================================
# 最终展示：落地机填写所需的所有中转机信息
# ============================================================================
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         ★ 部署完成！以下是本次配置的完整信息 ★               ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【中转机信息】 — 从中转机复制到落地机的内容               │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
echo -e "  中转机公网IP       → ${GREEN}$RELAY_IP${NC}"
echo -e "  WireGuard端口      → ${GREEN}$WG_PORT/UDP${NC}  （落地机连接中转机用）"
echo -e "  Mack-a端口         → ${GREEN}$MACKA_PORT/TCP${NC}  （流量混淆通道）"
echo -e "  Mack-a Token       → ${GREEN}$MACKA_TOKEN${NC}  （认证令牌）"
echo -e "  中转机UUID         → ${GREEN}$RELAY_UUID${NC}  （中转机标识）"
echo -e "  中转机WireGuard公钥→ ${GREEN}$RELAY_PUBKEY${NC}"
echo ""

echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【本落地机信息】 — 此机器的专属配置                       │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
echo -e "  虚拟IP (WG地址)    → ${GREEN}$WG_ADDRESS${NC}  （WireGuard隧道内IP）"
echo -e "  落地机UUID         → ${GREEN}$PEER_UUID${NC}  （Mack-a落地机标识）"
echo ""

echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【配置文件位置】                                           │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
echo -e "  WireGuard配置  → ${CYAN}/etc/wireguard/wg0.conf${NC}"
echo -e "  Mack-a配置     → ${CYAN}/etc/mack-a/client.conf${NC}"
echo -e "  完整摘要       → ${CYAN}$SUMMARY_FILE${NC}"
echo ""

echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【常用命令】                                               │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
echo -e "  查看连接信息   → ${CYAN}relay-info${NC}"
echo -e "  查看WG隧道状态 → ${CYAN}wg show${NC}"
echo -e "  重启WireGuard  → ${CYAN}systemctl restart wg-quick@wg0${NC}"
echo -e "  查看防火墙状态 → ${CYAN}bash /opt/relay-wg/port.sh --status${NC}"
echo -e "  添加端口跳跃   → ${CYAN}bash /opt/relay-wg/port.sh --add-hop${NC}"
echo -e "  查看WG日志     → ${CYAN}journalctl -u wg-quick@wg0 -f${NC}"
echo ""

echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【验证隧道连通性】                                         │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
echo -e "  ${CYAN}ping 10.0.0.1${NC}      # 能通 = WireGuard隧道正常"
echo -e "  ${CYAN}curl https://api.ip.sb/ip${NC}   # 应显示本机出口IP（非中转机IP）"
echo ""

print_warn "Mack-a 客户端程序需另行安装，配置文件已就绪: /etc/mack-a/client.conf"
echo ""
echo -e "${GREEN}随时可以运行 ${CYAN}relay-info${GREEN} 查看以上所有信息${NC}"
echo ""
