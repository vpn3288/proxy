#!/bin/bash
################################################################################
#
#   CN2GIA 中转机管理脚本 v4.0
#   仓库: github.com/vpn3288/proxy
#
#   设计逻辑：
#     首次运行 → 初始化中转机（WireGuard服务端 + 防火墙）
#     再次运行 → 新增一台落地机，生成其专属一键部署脚本
#     历史参数永久保存，随时通过 relay-info 查询
#     落地机重装代理：relay-info --peer <名称> 查参数，粘贴重跑即可
#
#   用法：
#     bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/zhongzhuan.sh)
#
################################################################################

set -uo pipefail

# ── 颜色 ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${BLUE}[i]${NC} $1"; }
ok()      { echo -e "${GREEN}[✓]${NC} $1"; }
err()     { echo -e "${RED}[✗]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
section() { echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n${1}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
pause()   { echo ""; read -rp "$(echo -e "${CYAN}")[按 Enter 继续...]$(echo -e "${NC}")" _; echo ""; }

# ── 验证 ─────────────────────────────────────────────────────────────────────
chk_ip() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'; read -ra p <<< "$1"
    for x in "${p[@]}"; do (( x <= 255 )) || return 1; done
}
chk_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
chk_name() { [[ $1 =~ ^[a-zA-Z0-9_-]+$ ]] && (( ${#1} >= 1 && ${#1} <= 32 )); }

gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null \
    || uuidgen 2>/dev/null \
    || date +%s%N | md5sum | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\).*/\1-\2-\3-\4-\5/'
}

# ── 路径 ─────────────────────────────────────────────────────────────────────
WORK_DIR="/opt/relay-wg"
CONFIG_DIR="$WORK_DIR/config"
DEPLOY_DIR="$WORK_DIR/deploy"
PEERS_DIR="$CONFIG_DIR/peers"
STATE_FILE="$CONFIG_DIR/relay.state"
FW_SCRIPT="$WORK_DIR/port.sh"

mkdir -p "$CONFIG_DIR" "$DEPLOY_DIR" "$PEERS_DIR"

# ============================================================================
# 函数：读取全局状态
# ============================================================================
load_state() {
    INITIALIZED=false
    RELAY_IP=""; WG_PORT="51820"; RELAY_PUB=""; RELAY_PRIV=""
    WAN_IFACE=""; PEER_COUNT=0
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        INITIALIZED=true
    fi
}

# ============================================================================
# 函数：保存全局状态
# ============================================================================
save_state() {
    cat > "$STATE_FILE" << EOF
RELAY_IP="${RELAY_IP}"
WG_PORT="${WG_PORT}"
RELAY_PUB="${RELAY_PUB}"
RELAY_PRIV="${RELAY_PRIV}"
WAN_IFACE="${WAN_IFACE}"
PEER_COUNT=${PEER_COUNT}
EOF
    chmod 600 "$STATE_FILE"
}

# ============================================================================
# 函数：分配下一个可用虚拟 IP
# ============================================================================
next_wg_ip() {
    local last used f stored_ip
    for last in $(seq 2 254); do
        used=0
        for f in "$PEERS_DIR"/*.state; do
            [[ -f "$f" ]] || continue
            stored_ip=$(grep "^WG_IP=" "$f" | cut -d= -f2 | tr -d '"')
            [[ "$stored_ip" == "10.0.0.${last}" ]] && used=1 && break
        done
        [[ $used -eq 0 ]] && echo "10.0.0.${last}" && return
    done
    echo ""
}

# ============================================================================
# 函数：安装防火墙脚本
# ============================================================================
install_fw_script() {
    if curl -sSL --max-time 15 \
        "https://raw.githubusercontent.com/vpn3288/iptables/refs/heads/main/port.sh" \
        -o "$FW_SCRIPT" 2>/dev/null; then
        ok "防火墙脚本已下载"
    else
        warn "下载失败，使用内嵌备用版"
        cat > "$FW_SCRIPT" << 'FWEOF'
#!/bin/bash
set -uo pipefail
[[ $(id -u) -eq 0 ]] || { echo "需要 root"; exit 1; }
SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | grep -oE ':[0-9]+' | grep -oE '[0-9]+' | head -1 || echo 22)
WG_PORT_VAL="${WG_PORT_VAR:-51820}"
WAN=$(ip route show default 2>/dev/null | awk '/default/{print $5;exit}' || echo eth0)
[[ "${1:-}" == "--status" ]] && { iptables -L -n; exit 0; }
[[ "${1:-}" == "--reset"  ]] && { iptables -P INPUT ACCEPT; iptables -F; iptables -t nat -F; echo "已重置"; exit 0; }
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
iptables -F; iptables -X; iptables -t nat -F; iptables -t nat -X
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 10/sec -j ACCEPT
iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
iptables -A INPUT -p udp --dport "$WG_PORT_VAL" -j ACCEPT
iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o "$WAN" -j MASQUERADE
iptables -A INPUT -j DROP
mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4
echo "✓ 防火墙配置完成"
FWEOF
    fi
    chmod +x "$FW_SCRIPT"
}

# ============================================================================
# 函数：安装/更新中转机 relay-info 命令
# ============================================================================
install_relay_info() {
    local sf="$STATE_FILE" pd="$PEERS_DIR" dd="$DEPLOY_DIR" fw="$FW_SCRIPT"
    cat > /usr/local/bin/relay-info << CMEOF
#!/bin/bash
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; NC='\033[0m'
STATE_FILE="${sf}"
PEERS_DIR="${pd}"
DEPLOY_DIR="${dd}"
FW_SCRIPT="${fw}"

[[ -f "\$STATE_FILE" ]] && source "\$STATE_FILE" || { echo "中转机未初始化"; exit 1; }

SHOW_PEER=""
[[ "\${1:-}" == "--peer" && -n "\${2:-}" ]] && SHOW_PEER="\$2"

echo -e "\${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              中转机信息速查 · relay-info                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "\${NC}"

echo -e "\${YELLOW}【中转机】\${NC}"
echo -e "  公网 IP    : \${GREEN}\${RELAY_IP}\${NC}"
echo -e "  WG 端口    : \${GREEN}\${WG_PORT}/UDP\${NC}"
echo -e "  WG 公钥    : \${GREEN}\${RELAY_PUB}\${NC}"
echo -e "  落地机数量 : \${GREEN}\${PEER_COUNT} 台\${NC}"
echo ""

if [[ -n "\$SHOW_PEER" ]]; then
    pf="\$PEERS_DIR/\${SHOW_PEER}.state"
    if [[ ! -f "\$pf" ]]; then
        echo -e "\${RED}落地机 '\${SHOW_PEER}' 不存在\${NC}"
        echo "已有: \$(ls "\$PEERS_DIR"/*.state 2>/dev/null | xargs -I{} basename {} .state | tr '\n' ' ' || echo 无)"
        exit 1
    fi
    unset PEER_NAME WG_IP WG_PRIVKEY WG_PUBKEY PEER_UUID CREATED_AT PUBLIC_IP
    source "\$pf"
    echo -e "\${YELLOW}【落地机: \${PEER_NAME}】完整参数\${NC}"
    echo -e "  虚拟 IP    : \${GREEN}\${WG_IP}/32\${NC}"
    echo -e "  WG 私钥    : \${GREEN}\${WG_PRIVKEY}\${NC}"
    echo -e "  WG 公钥    : \${GREEN}\${WG_PUBKEY}\${NC}"
    echo -e "  UUID       : \${GREEN}\${PEER_UUID}\${NC}"
    echo -e "  创建时间   : \${CREATED_AT:-未知}"
    echo -e "  公网 IP    : \${PUBLIC_IP:-未记录}"
    echo ""
    df="\$DEPLOY_DIR/luodiji_\${PEER_NAME}.sh"
    [[ -f "\$df" ]] && echo -e "  一键脚本   : \${CYAN}\$df\${NC}" \
                    && echo -e "  查看内容   : \${CYAN}cat \$df\${NC}"
    echo ""
    echo -e "\${YELLOW}【落地机重装代理操作步骤】\${NC}"
    echo -e "  方法A（推荐）- 复制一键脚本内容到落地机运行："
    echo -e "    \${CYAN}cat \$df\${NC}  → 复制全部内容 → 粘贴到落地机终端运行"
    echo -e "  方法B - SCP 传输："
    echo -e "    \${CYAN}scp \$df root@<落地机IP>:~/ && ssh root@<落地机IP> 'bash ~/luodiji_\${PEER_NAME}.sh'\${NC}"
    echo -e "  方法C - WireGuard + UUID 不变，只需重装 v2ray-agent"
else
    echo -e "\${YELLOW}【落地机列表】\${NC}"
    found=0
    for f in "\$PEERS_DIR"/*.state; do
        [[ -f "\$f" ]] || continue
        found=1
        unset PEER_NAME WG_IP WG_PRIVKEY WG_PUBKEY PEER_UUID CREATED_AT PUBLIC_IP
        source "\$f"
        HS=\$(wg show wg0 latest-handshakes 2>/dev/null | awk -v pk="\$WG_PUBKEY" '\$1==pk{print \$2}')
        if [[ -n "\${HS:-}" && "\$HS" -gt 0 ]]; then
            AGO=\$(( \$(date +%s) - HS ))
            (( AGO < 180 )) \
                && STATUS="\${GREEN}在线\${NC}(\${AGO}s)" \
                || STATUS="\${YELLOW}可能离线\${NC}(\${AGO}s)"
        else
            STATUS="\${RED}离线\${NC}"
        fi
        REAL_IP=\$(curl -s --max-time 4 --interface "\$WG_IP" https://api.ip.sb/ip 2>/dev/null || echo "—")
        echo -e "  \${GREEN}\${PEER_NAME}\${NC}  虚拟IP:\${CYAN}\${WG_IP}\${NC}  公网IP:\${GREEN}\${REAL_IP}\${NC}  \${STATUS}"
        echo -e "  创建:\${CREATED_AT:-?}  详情: \${CYAN}relay-info --peer \${PEER_NAME}\${NC}"
        echo ""
    done
    [[ \$found -eq 0 ]] && echo "  （暂无落地机，运行中转机脚本新增）"
fi

echo -e "\${CYAN}━━━━━━━━━━━━━━━━━ 实时 WireGuard ━━━━━━━━━━━━━━━━━━\${NC}"
wg show 2>/dev/null || echo "  (未运行)"
echo ""
echo -e "\${YELLOW}管理命令:\${NC}"
echo -e "  relay-info                查看所有落地机状态"
echo -e "  relay-info --peer <名称>  查看单台完整参数 + 重装操作指引"
echo -e "  bash \$FW_SCRIPT --status  防火墙状态"
CMEOF
    chmod +x /usr/local/bin/relay-info
    ok "relay-info 命令已安装/更新"
}

# ============================================================================
# 函数：生成落地机一键部署脚本
# ============================================================================
generate_peer_script() {
    local p_name="$1" p_ip="$2" p_priv="$3" p_pub="$4"
    local p_uuid="$5" r_ip="$6" r_port="$7" r_pub="$8"
    local outfile="$9"
    local created_at="$10"

    # 写入脚本文件
    # 注意：heredoc 中的变量需要精确控制哪些展开、哪些不展开
    cat > "$outfile" << SCRIPT_HEAD
#!/bin/bash
################################################################################
#  落地机一键部署脚本（零交互）
#  落地机名称 : ${p_name}
#  生成时间   : ${created_at}
#  中转机     : ${r_ip}
#
#  用法: bash luodiji_${p_name}.sh
################################################################################
set -uo pipefail

PEER_NAME="${p_name}"
WG_ADDRESS="${p_ip}"
WG_PRIVKEY="${p_priv}"
WG_PUBKEY="${p_pub}"
PEER_UUID="${p_uuid}"
RELAY_IP="${r_ip}"
WG_PORT="${r_port}"
RELAY_PUBKEY="${r_pub}"
RELAY_WG_IP="10.0.0.1"
WORK_DIR="/opt/relay-wg"

SCRIPT_HEAD

    # 追加主体（此段不展开外层变量，用单引号 heredoc）
    cat >> "$outfile" << 'SCRIPT_BODY'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[i]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }

clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
printf "║  落地机: %-51s║\n" "${PEER_NAME}"
printf "║  中转机: %-51s║\n" "${RELAY_IP}   虚拟IP: ${WG_ADDRESS}/32"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

[[ "$EUID" -ne 0 ]] && { err "需要 root 权限"; exit 1; }
[[ -f /etc/os-release ]] && source /etc/os-release
info "系统: ${PRETTY_NAME:-未知}"
mkdir -p "$WORK_DIR/config"

# ── [1/5] 系统优化 ────────────────────────────────────────────────────────────
echo -e "\n${CYAN}[1/5] 系统优化${NC}"
for kv in "net.ipv4.ip_forward=1" "net.ipv4.conf.all.rp_filter=0" "net.ipv4.conf.default.rp_filter=0"; do
    k="${kv%%=*}"; v="${kv##*=}"
    grep -q "^${k}" /etc/sysctl.conf 2>/dev/null \
        && sed -i "s|^${k}.*|${k} = ${v}|" /etc/sysctl.conf \
        || echo "${k} = ${v}" >> /etc/sysctl.conf
done
sysctl -p >/dev/null 2>&1; ok "内核参数已配置"

# ── [2/5] 安装依赖 ────────────────────────────────────────────────────────────
echo -e "\n${CYAN}[2/5] 安装依赖${NC}"
apt-get update -qq
PKGS="wireguard wireguard-tools curl wget net-tools iptables"
ORES=$(apt-cache policy openresolv 2>/dev/null | awk '/Candidate:/{print $2}')
[[ -n "$ORES" && "$ORES" != "(none)" ]] && PKGS="$PKGS openresolv"
# shellcheck disable=SC2086
apt-get install -y $PKGS
modprobe wireguard 2>/dev/null || apt-get install -y wireguard-go
ok "依赖安装完成"

# ── [3/5] 配置 WireGuard ──────────────────────────────────────────────────────
echo -e "\n${CYAN}[3/5] 配置 WireGuard${NC}"
mkdir -p /etc/wireguard; chmod 700 /etc/wireguard
WAN=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
WAN=${WAN:-eth0}
info "出口网卡: $WAN"

cat > /etc/wireguard/wg0.conf << WGEOF
[Interface]
Address = ${WG_ADDRESS}/32
PrivateKey = ${WG_PRIVKEY}

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN} -j MASQUERADE

[Peer]
PublicKey = ${RELAY_PUBKEY}
Endpoint = ${RELAY_IP}:${WG_PORT}
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
WGEOF

systemctl is-active --quiet systemd-resolved 2>/dev/null \
    && sed -i '/^\[Interface\]/a DNS = 8.8.8.8, 1.1.1.1' /etc/wireguard/wg0.conf

chmod 600 /etc/wireguard/wg0.conf; ok "wg0.conf 已生成"

systemctl enable wg-quick@wg0 >/dev/null 2>&1
systemctl is-active --quiet wg-quick@wg0 \
    && systemctl restart wg-quick@wg0 \
    || systemctl start wg-quick@wg0
sleep 3

if wg show wg0 >/dev/null 2>&1; then
    ok "WireGuard 已启动"; wg show wg0
else
    err "WireGuard 启动失败！"; err "journalctl -xe -u wg-quick@wg0"; exit 1
fi

ping -c 3 -W 3 "$RELAY_WG_IP" >/dev/null 2>&1 \
    && ok "隧道连通 ✓  (ping $RELAY_WG_IP)" \
    || warn "隧道暂未连通，稍后可手动测试: ping $RELAY_WG_IP"

# ── [4/5] 防火墙 ──────────────────────────────────────────────────────────────
echo -e "\n${CYAN}[4/5] 配置防火墙${NC}"
FW="$WORK_DIR/port.sh"
if curl -sSL --max-time 15 \
    "https://raw.githubusercontent.com/vpn3288/iptables/refs/heads/main/port.sh" \
    -o "$FW" 2>/dev/null; then
    ok "防火墙脚本已下载"
else
    warn "下载失败，使用内嵌备用版"
    cat > "$FW" << 'FWEOF'
#!/bin/bash
set -uo pipefail
[[ $(id -u) -eq 0 ]] || { echo "需要root"; exit 1; }
SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | grep -oE ':[0-9]+' | grep -oE '[0-9]+' | head -1 || echo 22)
WAN=$(ip route show default 2>/dev/null | awk '/default/{print $5;exit}' || echo eth0)
[[ "${1:-}" == "--status" ]] && { iptables -L -n; exit 0; }
[[ "${1:-}" == "--reset"  ]] && { iptables -P INPUT ACCEPT; iptables -F; iptables -t nat -F; echo "已重置"; exit 0; }
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
chmod +x "$FW"
bash "$FW" --landing <<< "y"
ok "防火墙配置完成"

# ── [5/5] 收尾 ────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}[5/5] 收尾${NC}"
MY_IP=$(curl -s --max-time 8 https://api.ip.sb/ip 2>/dev/null \
      || curl -s --max-time 8 https://ifconfig.me 2>/dev/null || echo "未知")

cat > "$WORK_DIR/config/summary.txt" << EOF
落地机      : ${PEER_NAME}
公网 IP     : ${MY_IP}
WG 虚拟 IP  : ${WG_ADDRESS}/32
UUID        : ${PEER_UUID}
WG 公钥     : ${WG_PUBKEY}
中转机 IP   : ${RELAY_IP}  端口: ${WG_PORT}/UDP
中转机 WG IP: ${RELAY_WG_IP}
EOF
chmod 600 "$WORK_DIR/config/summary.txt"; ok "摘要已保存"

# 尝试把公网 IP 回写到中转机（需要 SSH 免密，无则跳过）
if ping -c 1 -W 2 "$RELAY_WG_IP" >/dev/null 2>&1; then
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        "root@${RELAY_WG_IP}" \
        "f=/opt/relay-wg/config/peers/${PEER_NAME}.state; [[ -f \$f ]] && sed -i 's|^PUBLIC_IP=.*|PUBLIC_IP=\"${MY_IP}\"|' \$f" \
        2>/dev/null || true
fi

cat > /usr/local/bin/relay-info << 'CMEOF'
#!/bin/bash
CYAN='\033[0;36m'; GREEN='\033[0;32m'; NC='\033[0m'
S=/opt/relay-wg/config/summary.txt
echo -e "${CYAN}━━━━━━━━━━━━ 落地机信息 ━━━━━━━━━━━━${NC}"
[[ -f "$S" ]] && cat "$S" || echo "摘要不存在"
echo ""
echo -e "${CYAN}━━━━ WireGuard ━━━━${NC}"; wg show 2>/dev/null || echo "(未运行)"
echo ""
echo -e "${GREEN}公网 IP:${NC}"; curl -s --max-time 5 https://api.ip.sb/ip 2>/dev/null || echo "获取失败"
echo ""
echo -e "${GREEN}隧道 ping 10.0.0.1:${NC}"; ping -c 3 -W 2 10.0.0.1 2>/dev/null || echo "(不通)"
CMEOF
chmod +x /usr/local/bin/relay-info; ok "relay-info 已安装"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
printf "${CYAN}║  ★ 落地机 %-50s║${NC}\n" "${PEER_NAME} 部署完成！"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  公网 IP    → ${GREEN}${MY_IP}${NC}"
echo -e "  WG 虚拟 IP → ${GREEN}${WG_ADDRESS}/32${NC}"
echo -e "  UUID       → ${GREEN}${PEER_UUID}${NC}"
echo ""
echo -e "${YELLOW}下一步：安装代理节点（v2ray-agent）${NC}"
echo -e "  ${CYAN}wget -P /root -N --no-check-certificate https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh && chmod 755 /root/install.sh && bash /root/install.sh${NC}"
echo ""
SCRIPT_BODY

    chmod +x "$outfile"
}

# ============================================================================
# 主程序
# ============================================================================
clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         CN2GIA 中转机管理工具 v4.0                           ║"
echo "║         每次运行 = 新增一台落地机                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

[[ "$EUID" -ne 0 ]] && { err "需要 root 权限"; exit 1; }
[[ -f /etc/os-release ]] && source /etc/os-release
info "系统: ${PRETTY_NAME:-未知}"

load_state

# ============================================================================
if [[ "$INITIALIZED" == "false" ]]; then
# ── 首次运行：初始化中转机 ─────────────────────────────────────────────────────

    info "首次运行，开始初始化中转机..."
    echo ""

    section "初始化 [1/5] · 基本信息"

    info "中转机公网 IP（回车自动获取）"
    echo -ne "${CYAN}IP${NC}: "; read -r RELAY_IP
    if [[ -z "$RELAY_IP" ]]; then
        info "自动获取中..."
        RELAY_IP=$(curl -s --max-time 8 https://api.ip.sb/ip 2>/dev/null \
                || curl -s --max-time 8 https://ifconfig.me 2>/dev/null || true)
    fi
    while ! chk_ip "$RELAY_IP" 2>/dev/null; do
        err "IP 格式错误"; echo -ne "${CYAN}IP${NC}: "; read -r RELAY_IP
    done
    ok "中转机 IP: $RELAY_IP"

    echo ""
    info "WireGuard 监听端口"
    echo -ne "${CYAN}WG 端口${NC} [默认 51820]: "; read -r WG_PORT
    WG_PORT=${WG_PORT:-51820}
    while ! chk_port "$WG_PORT"; do
        err "端口无效"; echo -ne "${CYAN}WG 端口${NC}: "; read -r WG_PORT
    done
    ok "WG 端口: $WG_PORT/UDP"

    pause

    section "初始化 [2/5] · 系统优化"
    for kv in "net.ipv4.ip_forward=1" "net.ipv4.conf.all.rp_filter=0" "net.ipv4.conf.default.rp_filter=0"; do
        k="${kv%%=*}"; v="${kv##*=}"
        grep -q "^${k}" /etc/sysctl.conf 2>/dev/null \
            && sed -i "s|^${k}.*|${k} = ${v}|" /etc/sysctl.conf \
            || echo "${k} = ${v}" >> /etc/sysctl.conf
    done
    sysctl -p >/dev/null 2>&1; ok "内核参数已配置"

    section "初始化 [3/5] · 安装依赖"
    apt-get update -qq
    PKGS="wireguard wireguard-tools curl wget net-tools iptables"
    ORES=$(apt-cache policy openresolv 2>/dev/null | awk '/Candidate:/{print $2}')
    [[ -n "$ORES" && "$ORES" != "(none)" ]] && PKGS="$PKGS openresolv"
    # shellcheck disable=SC2086
    apt-get install -y $PKGS
    modprobe wireguard 2>/dev/null || apt-get install -y wireguard-go
    ok "依赖安装完成"

    section "初始化 [4/5] · WireGuard 服务端"
    mkdir -p /etc/wireguard; chmod 700 /etc/wireguard
    cd /etc/wireguard
    wg genkey | tee relay_privatekey | wg pubkey > relay_publickey
    RELAY_PRIV=$(cat relay_privatekey); RELAY_PUB=$(cat relay_publickey)
    chmod 600 relay_privatekey relay_publickey
    ok "密钥已生成"
    ok "公钥: $RELAY_PUB"

    WAN_IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
    WAN_IFACE=${WAN_IFACE:-eth0}
    ok "出口网卡: $WAN_IFACE"

    cat > /etc/wireguard/wg0.conf << WGEOF
[Interface]
Address = 10.0.0.1/24
ListenPort = $WG_PORT
PrivateKey = $RELAY_PRIV

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o $WAN_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o $WAN_IFACE -j MASQUERADE

WGEOF
    chmod 600 /etc/wireguard/wg0.conf

    systemctl enable wg-quick@wg0 >/dev/null 2>&1
    systemctl start wg-quick@wg0; sleep 2
    wg show wg0 >/dev/null 2>&1 && ok "WireGuard 服务端已启动" \
        || { err "WireGuard 启动失败！journalctl -xe -u wg-quick@wg0"; exit 1; }

    section "初始化 [5/5] · 防火墙"
    install_fw_script
    WG_PORT_VAR="$WG_PORT" bash "$FW_SCRIPT" --relay \
        --wg-port "$WG_PORT" --wg-subnet "10.0.0.0/24" --wg-iface "wg0" <<< "y"
    ok "防火墙配置完成"

    PEER_COUNT=0
    save_state
    install_relay_info

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓ 中转机初始化完成！                                        ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  中转机 IP  → ${CYAN}$RELAY_IP${NC}"
    echo -e "  WG 端口    → ${CYAN}$WG_PORT/UDP${NC}"
    echo -e "  WG 公钥    → ${CYAN}$RELAY_PUB${NC}"
    echo ""
    echo -e "${YELLOW}再次运行此脚本即可新增落地机：${NC}"
    echo -e "  ${CYAN}bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/zhongzhuan.sh)${NC}"
    echo ""

else
# ── 再次运行：新增一台落地机 ──────────────────────────────────────────────────

    info "已初始化的中转机，当前已有 ${PEER_COUNT} 台落地机"
    echo ""

    # 显示已有落地机
    if (( PEER_COUNT > 0 )); then
        echo -e "${YELLOW}【已有落地机】${NC}"
        for f in "$PEERS_DIR"/*.state; do
            [[ -f "$f" ]] || continue
            unset PEER_NAME WG_IP CREATED_AT
            # shellcheck disable=SC1090
            source "$f"
            echo -e "  ${GREEN}${PEER_NAME}${NC}  虚拟IP: ${CYAN}${WG_IP}/32${NC}  创建: ${CREATED_AT:-未知}"
        done
        echo ""
    fi

    section "新增落地机 · 输入名称"

    while true; do
        info "落地机名称（字母/数字/下划线/横杠，如 us-lax-1）"
        echo -ne "${CYAN}名称${NC}: "; read -r NEW_NAME
        chk_name "$NEW_NAME" || { err "名称格式不正确（字母数字下划线横杠，1-32字符）"; continue; }
        [[ -f "$PEERS_DIR/${NEW_NAME}.state" ]] && { err "名称 '${NEW_NAME}' 已存在"; continue; }
        break
    done
    ok "落地机名称: $NEW_NAME"

    # 分配虚拟 IP
    NEW_WG_IP=$(next_wg_ip)
    [[ -z "$NEW_WG_IP" ]] && { err "已无可用虚拟 IP（10.0.0.2-254 全部占用）"; exit 1; }
    ok "分配虚拟 IP: $NEW_WG_IP"

    # 生成密钥
    cd /etc/wireguard
    wg genkey | tee "peer_${NEW_NAME}_privatekey" | wg pubkey > "peer_${NEW_NAME}_publickey"
    chmod 600 "peer_${NEW_NAME}_privatekey" "peer_${NEW_NAME}_publickey"
    NEW_PRIV=$(cat "peer_${NEW_NAME}_privatekey")
    NEW_PUB=$(cat "peer_${NEW_NAME}_publickey")
    NEW_UUID=$(gen_uuid)
    CREATED_AT=$(date '+%Y-%m-%d %H:%M:%S')
    ok "密钥已生成  UUID: $NEW_UUID"

    # 追加到 wg0.conf
    section "更新 WireGuard 配置"
    cat >> /etc/wireguard/wg0.conf << PEEREOF

[Peer]
# ${NEW_NAME}  添加时间: ${CREATED_AT}
PublicKey = ${NEW_PUB}
AllowedIPs = ${NEW_WG_IP}/32
PersistentKeepalive = 25
PEEREOF
    ok "已追加 [Peer] 到 wg0.conf"

    # 热加载（不中断其他已连接落地机）
    if wg show wg0 >/dev/null 2>&1; then
        wg set wg0 peer "$NEW_PUB" allowed-ips "${NEW_WG_IP}/32" persistent-keepalive 25 2>/dev/null \
        && ok "WireGuard 热加载成功（其他落地机不受影响）" \
        || { wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null \
             && ok "WireGuard 已同步配置" \
             || { systemctl restart wg-quick@wg0 && ok "WireGuard 已重启"; }; }
    fi

    # 保存落地机状态
    cat > "$PEERS_DIR/${NEW_NAME}.state" << EOF
PEER_NAME="${NEW_NAME}"
WG_IP="${NEW_WG_IP}"
WG_PRIVKEY="${NEW_PRIV}"
WG_PUBKEY="${NEW_PUB}"
PEER_UUID="${NEW_UUID}"
RELAY_IP="${RELAY_IP}"
WG_PORT="${WG_PORT}"
RELAY_PUBKEY="${RELAY_PUB}"
CREATED_AT="${CREATED_AT}"
PUBLIC_IP=""
EOF
    chmod 600 "$PEERS_DIR/${NEW_NAME}.state"
    ok "参数已持久化: $PEERS_DIR/${NEW_NAME}.state"

    # 更新全局状态
    PEER_COUNT=$(( PEER_COUNT + 1 ))
    save_state

    # 生成一键脚本
    section "生成落地机一键脚本"
    DEPLOY_FILE="$DEPLOY_DIR/luodiji_${NEW_NAME}.sh"
    generate_peer_script \
        "$NEW_NAME" "$NEW_WG_IP" "$NEW_PRIV" "$NEW_PUB" \
        "$NEW_UUID" "$RELAY_IP" "$WG_PORT" "$RELAY_PUB" \
        "$DEPLOY_FILE" "$CREATED_AT"
    ok "一键脚本已生成: $DEPLOY_FILE"

    # 更新 relay-info
    install_relay_info

    # ── 最终输出 ──────────────────────────────────────────────────────────────
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf "${CYAN}║  ★ 落地机 %-50s║${NC}\n" "${NEW_NAME} 参数已生成！"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}【落地机 ${NEW_NAME} 专属参数】${NC}"
    echo -e "  虚拟 IP    → ${GREEN}${NEW_WG_IP}/32${NC}"
    echo -e "  WG 私钥    → ${GREEN}${NEW_PRIV}${NC}"
    echo -e "  WG 公钥    → ${GREEN}${NEW_PUB}${NC}"
    echo -e "  UUID       → ${GREEN}${NEW_UUID}${NC}"
    echo ""
    echo -e "${YELLOW}【中转机公共参数】（每台落地机相同）${NC}"
    echo -e "  中转机 IP  → ${GREEN}${RELAY_IP}${NC}"
    echo -e "  WG 端口    → ${GREEN}${WG_PORT}/UDP${NC}"
    echo -e "  中转机公钥 → ${GREEN}${RELAY_PUB}${NC}"
    echo ""
    echo -e "${YELLOW}【部署此落地机】${NC}"
    echo -e "  一键脚本路径: ${CYAN}${DEPLOY_FILE}${NC}"
    echo ""
    echo -e "  方法A（最方便）— 查看脚本内容，复制粘贴到落地机终端："
    echo -e "  ${CYAN}cat ${DEPLOY_FILE}${NC}"
    echo ""
    echo -e "  方法B — SCP 传输到落地机后运行："
    echo -e "  ${CYAN}scp ${DEPLOY_FILE} root@<落地机IP>:~/${NC}"
    echo -e "  ${CYAN}ssh root@<落地机IP> 'bash ~/luodiji_${NEW_NAME}.sh'${NC}"
    echo ""
    echo -e "${YELLOW}【落地机重装代理时】${NC}"
    echo -e "  在中转机运行: ${CYAN}relay-info --peer ${NEW_NAME}${NC}"
    echo -e "  参数永久保存，一键脚本随时可用"
    echo ""
    echo -e "  当前共 ${GREEN}${PEER_COUNT}${NC} 台落地机。再次运行此脚本可继续新增。"
    echo -e "  ${CYAN}bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/zhongzhuan.sh)${NC}"
    echo ""

fi
