#!/bin/bash
################################################################################
#
#   落地机一键部署脚本 v3.0
#   仓库: github.com/vpn3288/proxy
#
#   两种使用方式：
#
#   方式A（推荐）：使用中转机生成的专属脚本，零交互
#     bash luodiji_<名称>.sh
#
#   方式B：手动运行此脚本，交互式填写中转机给的参数
#     bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/luodi.sh)
#
################################################################################

set -uo pipefail

# ── 颜色 ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'

title()   { clear; echo -e "${CYAN}"
            echo "╔══════════════════════════════════════════════════════════╗"
            echo "║          落地机一键部署工具 v3.0                         ║"
            echo "║          WireGuard 隧道 + iptables 防火墙                ║"
            echo "╚══════════════════════════════════════════════════════════╝"
            echo -e "${NC}"; }
section() { echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n${1}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
ok()      { echo -e "${GREEN}[✓]${NC} $1"; }
err()     { echo -e "${RED}[✗]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }

# ── 验证函数 ──────────────────────────────────────────────────────────────────
chk_ip()   { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
             local IFS='.'; read -ra p <<< "$1"
             for x in "${p[@]}"; do (( x<=255 )) || return 1; done; }
chk_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1>=1 && $1<=65535 )); }
chk_wgkey(){ [[ ${#1} -eq 44 && $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]; }
chk_wgip() { local ip="${1%/*}"; [[ $ip =~ ^10\.0\.0\.[2-9]$|^10\.0\.0\.[1-9][0-9]$|^10\.0\.0\.(1[0-9]{2}|2[0-4][0-9]|25[0-4])$ ]]; }

# ── 带重试的输入 ──────────────────────────────────────────────────────────────
ask_input() {
    # ask_input <变量名引用> <提示> <验证函数> <错误提示> [默认值]
    local -n _ref=$1
    local prompt="$2" vfunc="$3" errmsg="$4" default="${5:-}"
    while true; do
        if [[ -n "$default" ]]; then
            echo -ne "${CYAN}${prompt}${NC} [默认: ${default}]: "
        else
            echo -ne "${CYAN}${prompt}${NC}: "
        fi
        read -r _ref
        [[ -z "$_ref" && -n "$default" ]] && _ref="$default"
        if [[ -z "$_ref" ]]; then
            err "不能为空，请重新输入"; continue
        fi
        $vfunc "$_ref" && break || err "$errmsg"
    done
}

# ── 主程序 ────────────────────────────────────────────────────────────────────
title

[[ "$EUID" -ne 0 ]] && { err "需要 root 权限"; exit 1; }
[[ -f /etc/os-release ]] && source /etc/os-release
info "系统: ${PRETTY_NAME:-未知}"

WORK_DIR="/opt/relay-wg"
mkdir -p "$WORK_DIR/config"

# ============================================================================
section "步骤 1/6 · 填写中转机给的参数"
# ============================================================================

echo ""
info "以下参数均来自中转机部署完成后的输出（或 relay-info / summary.txt）"
echo ""

# 中转机公网 IP
ask_input RELAY_IP "中转机公网 IP" chk_ip "IP 格式错误，示例: 185.201.226.132"
ok "中转机 IP: $RELAY_IP"

# WireGuard 端口
ask_input WG_PORT "WireGuard 端口" chk_port "端口须为 1-65535 的数字" "51820"
ok "WireGuard 端口: $WG_PORT"

# 中转机 WireGuard 公钥
echo ""
info "中转机公钥：在中转机运行 relay-info 查看「WireGuard 公钥」"
ask_input RELAY_PUBKEY "中转机 WireGuard 公钥" chk_wgkey "公钥应为 44 字符的 Base64（以 = 结尾）"
ok "中转机公钥已输入"

# 本落地机 WireGuard 私钥
echo ""
info "落地机私钥：在中转机运行 relay-info 查看对应落地机的「WireGuard 私钥」"
warn "私钥 ≠ 公钥！私钥是 [Interface] PrivateKey，公钥是 [Peer] PublicKey"
while true; do
    ask_input WG_PRIVKEY "本落地机 WireGuard 私钥" chk_wgkey "私钥应为 44 字符的 Base64（以 = 结尾）"
    if [[ "$WG_PRIVKEY" == "$RELAY_PUBKEY" ]]; then
        err "私钥与中转机公钥相同！你可能填反了，请重新输入"
    else
        ok "私钥已输入"
        break
    fi
done

# 本落地机虚拟 IP
echo ""
info "虚拟 IP：在中转机 relay-info 里找到本落地机对应的「WireGuard IP」（如 10.0.0.2）"
while true; do
    echo -ne "${CYAN}本落地机虚拟 IP${NC} (10.0.0.2 ~ 10.0.0.254): "
    read -r raw_ip
    # 自动补全 /32
    [[ "$raw_ip" =~ ^10\.0\.0\.[0-9]+$ ]] && raw_ip="${raw_ip}/32"
    local_ip="${raw_ip%/*}"
    if chk_wgip "$local_ip"; then
        WG_ADDRESS="$local_ip"
        break
    else
        err "格式错误，应为 10.0.0.2 ~ 10.0.0.254"
    fi
done
ok "本落地机虚拟 IP: ${WG_ADDRESS}/32"

# 落地机名称（可选，用于显示）
echo ""
echo -ne "${CYAN}落地机名称${NC} (可选，如 us-lax-1，回车跳过): "
read -r PEER_NAME
PEER_NAME="${PEER_NAME:-luodiji}"
ok "落地机名称: $PEER_NAME"

RELAY_WG_IP="10.0.0.1"

echo ""
info "参数确认："
info "  中转机 IP       : $RELAY_IP"
info "  WireGuard 端口  : $WG_PORT/UDP"
info "  中转机公钥      : $RELAY_PUBKEY"
info "  本机虚拟 IP     : ${WG_ADDRESS}/32"
info "  落地机名称      : $PEER_NAME"
echo ""
echo -ne "${YELLOW}确认以上信息并开始部署？[y/N]: ${NC}"
read -r confirm
[[ "${confirm,,}" == "y" ]] || { info "已取消"; exit 0; }

# ============================================================================
section "步骤 2/6 · 系统优化"
# ============================================================================

info "配置内核转发参数..."
for kv in "net.ipv4.ip_forward=1" "net.ipv4.conf.all.rp_filter=0" "net.ipv4.conf.default.rp_filter=0"; do
    k="${kv%%=*}"; v="${kv##*=}"
    if grep -q "^${k}" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s|^${k}.*|${k} = ${v}|" /etc/sysctl.conf
    else
        echo "${k} = ${v}" >> /etc/sysctl.conf
    fi
done
sysctl -p >/dev/null 2>&1
ok "内核参数已配置"

# ============================================================================
section "步骤 3/6 · 安装依赖"
# ============================================================================

apt-get update -qq
PKGS="wireguard wireguard-tools curl wget net-tools iptables"
ORES=$(apt-cache policy openresolv 2>/dev/null | awk '/Candidate:/{print $2}')
[[ -n "$ORES" && "$ORES" != "(none)" ]] && PKGS="$PKGS openresolv"
info "安装: $PKGS"
# shellcheck disable=SC2086
apt-get install -y $PKGS
modprobe wireguard 2>/dev/null || apt-get install -y wireguard-go
ok "依赖安装完成"

# ============================================================================
section "步骤 4/6 · 配置 WireGuard"
# ============================================================================

mkdir -p /etc/wireguard; chmod 700 /etc/wireguard

# 检测出口网卡
WAN_IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
WAN_IFACE=${WAN_IFACE:-eth0}
info "出口网卡: $WAN_IFACE"

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = ${WG_ADDRESS}/32
PrivateKey = ${WG_PRIVKEY}

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_IFACE} -j MASQUERADE

[Peer]
PublicKey = ${RELAY_PUBKEY}
Endpoint = ${RELAY_IP}:${WG_PORT}
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

# DNS（如果 systemd-resolved 在运行）
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    sed -i '/^\[Interface\]/a DNS = 8.8.8.8, 1.1.1.1' /etc/wireguard/wg0.conf
fi

chmod 600 /etc/wireguard/wg0.conf
ok "wg0.conf 已生成"

info "启动 WireGuard..."
systemctl enable wg-quick@wg0 >/dev/null 2>&1
systemctl is-active --quiet wg-quick@wg0 && systemctl restart wg-quick@wg0 || systemctl start wg-quick@wg0
sleep 3

if wg show wg0 >/dev/null 2>&1; then
    ok "WireGuard 已启动"
    wg show wg0
else
    err "WireGuard 启动失败！"
    err "查看日志: journalctl -xe -u wg-quick@wg0"
    exit 1
fi

# 验证隧道
info "验证与中转机的隧道连通性..."
if ping -c 3 -W 3 "$RELAY_WG_IP" >/dev/null 2>&1; then
    ok "隧道连通 ✓  ping $RELAY_WG_IP 成功"
else
    warn "隧道暂未连通，可稍后手动测试: ping $RELAY_WG_IP"
fi

# ============================================================================
section "步骤 5/6 · 配置防火墙"
# ============================================================================

FW_SCRIPT="$WORK_DIR/port.sh"
info "下载防火墙脚本..."
if curl -sSL --max-time 15 \
    "https://raw.githubusercontent.com/vpn3288/iptables/refs/heads/main/port.sh" \
    -o "$FW_SCRIPT" 2>/dev/null; then
    ok "防火墙脚本已下载"
else
    warn "下载失败，使用内嵌备用版..."
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
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 10/sec -j ACCEPT
iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT
iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -o "$WAN" -j MASQUERADE
iptables -A INPUT -j DROP
mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4
echo "✓ 防火墙配置完成"
FWEOF
fi
chmod +x "$FW_SCRIPT"
bash "$FW_SCRIPT" --landing <<< "y"
ok "防火墙配置完成"

# ============================================================================
section "步骤 6/6 · 完成"
# ============================================================================

MY_PUBLIC_IP=$(curl -s --max-time 8 https://api.ip.sb/ip 2>/dev/null \
             || curl -s --max-time 8 https://ifconfig.me 2>/dev/null || echo "未知")

# 保存摘要
SUMMARY_FILE="$WORK_DIR/config/summary.txt"
cat > "$SUMMARY_FILE" << EOF
========================================
  落地机部署信息摘要: ${PEER_NAME}
  生成时间: $(date '+%Y-%m-%d %H:%M:%S')
========================================

【本落地机】
  名称          : ${PEER_NAME}
  公网 IP       : ${MY_PUBLIC_IP}
  WireGuard IP  : ${WG_ADDRESS}/32

【中转机信息】
  公网 IP       : ${RELAY_IP}
  WireGuard端口 : ${WG_PORT}/UDP
  中转机WG IP   : ${RELAY_WG_IP}

【常用命令】
  查看信息      : relay-info
  查看WG状态    : wg show
  重启WireGuard : systemctl restart wg-quick@wg0
  查看日志      : journalctl -u wg-quick@wg0 -f
  防火墙状态    : bash $WORK_DIR/port.sh --status
EOF
chmod 600 "$SUMMARY_FILE"
ok "摘要已保存: $SUMMARY_FILE"

# 安装 relay-info
cat > /usr/local/bin/relay-info << 'CMEOF'
#!/bin/bash
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
SUMMARY=/opt/relay-wg/config/summary.txt
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              落地机信息速查                              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
[[ -f "$SUMMARY" ]] && cat "$SUMMARY" || echo "摘要文件不存在"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━ 实时状态 ━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}▸ WireGuard:${NC}"; wg show 2>/dev/null || echo "  (未运行)"
echo ""
echo -e "${GREEN}▸ 本机公网 IP:${NC}"
curl -s --max-time 5 https://api.ip.sb/ip 2>/dev/null || echo "  (获取失败)"
echo ""
echo -e "${GREEN}▸ 隧道连通性 (ping 10.0.0.1):${NC}"
ping -c 3 -W 2 10.0.0.1 2>/dev/null || echo "  (不通)"
CMEOF
chmod +x /usr/local/bin/relay-info
ok "relay-info 命令已安装"

# ── 最终输出 ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         ★ 落地机 ${PEER_NAME} 部署完成！★               ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}【本落地机】${NC}"
echo -e "  公网 IP       → ${GREEN}${MY_PUBLIC_IP}${NC}"
echo -e "  WireGuard IP  → ${GREEN}${WG_ADDRESS}/32${NC}"
echo ""
echo -e "${YELLOW}【中转机】${NC}"
echo -e "  IP            → ${GREEN}${RELAY_IP}${NC}"
echo -e "  WG 端口       → ${GREEN}${WG_PORT}/UDP${NC}"
echo ""
echo -e "${YELLOW}【下一步：安装代理节点（v2ray-agent）】${NC}"
echo -e "  在本机（落地机）和中转机上分别运行："
echo -e "  ${CYAN}wget -P /root -N --no-check-certificate https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh && chmod 755 /root/install.sh && bash /root/install.sh${NC}"
echo ""
echo -e "  随时运行 ${CYAN}relay-info${NC} 查看状态"
echo ""
