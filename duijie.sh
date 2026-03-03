#!/bin/bash

################################################################################
#                                                                              #
#              落地机代理节点对接中转机一键脚本                                  #
#                         v1.03                                                #
#                                                                              #
#  前提条件：                                                                   #
#    1. 已运行 luodi.sh，WireGuard 隧道已建立                                   #
#    2. 已安装 v2ray-agent（Xray 或 Sing-box）                                  #
#                                                                              #
#  本脚本做的事：                                                                #
#    1. 读取本机已有的中转机信息（relay-info）                                    #
#    2. 自动检测代理协议和端口                                                   #
#    3. SSH 到中转机（10.0.0.1），自动添加端口转发规则                            #
#       - DNAT：将入站流量转发至落地机                                           #
#       - SNAT：将源地址改为中转机自身IP，确保回包经过中转机                      #
#       - INPUT：在全局 DROP 之前插入放行规则（行号插入）                         #
#    4. 输出最终节点链接（入口=中转机IP，出站=落地机IP）                           #
#                                                                              #
################################################################################

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_title() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║           落地机代理节点 ↔ 中转机 一键对接工具                  ║"
    echo "║                       v1.03                                   ║"
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

print_title

if [[ "$EUID" -ne 0 ]]; then
    print_error "必须使用 root 权限运行此脚本！"
    exit 1
fi

# ============================================================================
print_section "步骤 1/5: 读取本机信息"
# ============================================================================

SUMMARY_FILE=""
for f in \
    "/opt/relay-wg/config/peer-summary.txt" \
    "/opt/relay-wg/config/summary.txt"; do
    if [[ -f "$f" ]]; then
        SUMMARY_FILE="$f"
        break
    fi
done

if [[ -z "$SUMMARY_FILE" ]]; then
    print_error "未找到落地机摘要文件"
    print_error "  /opt/relay-wg/config/peer-summary.txt"
    print_error "  /opt/relay-wg/config/summary.txt"
    print_error "请先运行 luodi.sh 完成 WireGuard 部署"
    exit 1
fi

print_info "读取摘要: $SUMMARY_FILE"

LANDING_IP=$(awk '/本落地机/{found=1} /中转机信息/{found=0} found && /公网 IP/{match($0,/([0-9]{1,3}\.){3}[0-9]{1,3}/); if(RLENGTH>0){print substr($0,RSTART,RLENGTH); exit}}' "$SUMMARY_FILE")
RELAY_IP=$(awk '/中转机信息/{found=1} found && /公网 IP/{match($0,/([0-9]{1,3}\.){3}[0-9]{1,3}/); if(RLENGTH>0){print substr($0,RSTART,RLENGTH); exit}}' "$SUMMARY_FILE")

if [[ -z "$RELAY_IP" ]]; then
    RELAY_IP=$(grep '中转机公网IP' "$SUMMARY_FILE" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
fi

WG_LOCAL_IP=$(grep -E 'WireGuard地址|WireGuard IP' "$SUMMARY_FILE" \
    | grep -oE '10\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)

if [[ -z "$LANDING_IP" ]]; then
    print_info "正在获取本机公网IP..."
    LANDING_IP=$(curl -s --max-time 5 https://api.ip.sb/ip 2>/dev/null \
        || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || echo "")
fi

if [[ -z "$RELAY_IP" ]]; then
    print_error "无法从摘要文件读取中转机IP"
    exit 1
fi

if [[ -z "$WG_LOCAL_IP" ]]; then
    WG_LOCAL_IP=$(ip addr show wg0 2>/dev/null | grep -oE '10\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
fi

print_success "中转机IP:   $RELAY_IP"
print_success "本机WG IP:  ${WG_LOCAL_IP:-未知}"
print_success "本机公网IP: ${LANDING_IP:-未知}"

echo ""
print_info "验证 WireGuard 隧道..."
if ! wg show wg0 &>/dev/null; then
    print_error "WireGuard wg0 接口未运行！"
    print_error "请先运行: systemctl start wg-quick@wg0"
    exit 1
fi

if ! ping -c 1 -W 3 10.0.0.1 &>/dev/null; then
    print_error "无法 ping 通中转机内网 10.0.0.1，隧道可能断开"
    exit 1
fi
print_success "WireGuard 隧道正常（延迟: $(ping -c 1 -W 3 10.0.0.1 2>/dev/null | grep -oE 'time=[0-9.]+' | head -1)ms）"

pause_input

# ============================================================================
print_section "步骤 2/5: 检测代理节点"
# ============================================================================

AGENT_TYPE=""
CONF_DIR=""

if [[ -d /etc/v2ray-agent/xray/conf ]]; then
    AGENT_TYPE="xray"
    CONF_DIR="/etc/v2ray-agent/xray/conf"
    print_success "检测到 Xray (v2ray-agent)"
elif [[ -d /etc/v2ray-agent/sing-box/conf ]]; then
    AGENT_TYPE="singbox"
    CONF_DIR="/etc/v2ray-agent/sing-box/conf"
    print_success "检测到 Sing-box (v2ray-agent)"
else
    print_error "未检测到 v2ray-agent！"
    print_info "安装地址: https://github.com/mack-a/v2ray-agent"
    exit 1
fi

echo ""
print_info "扫描代理节点配置..."

declare -a NODE_PORTS=()
declare -a NODE_PROTOS=()

if [[ "$AGENT_TYPE" == "xray" ]]; then
    for conf_file in "$CONF_DIR"/*inbound*.json; do
        [[ -f "$conf_file" ]] || continue
        while IFS= read -r line; do
            port=$(echo "$line" | grep -oE '"port"\s*:\s*[0-9]+' | grep -oE '[0-9]+' | head -1)
            [[ -z "$port" ]] && continue
            [[ "$port" -lt 1 || "$port" -gt 65535 ]] && continue

            proto="unknown"
            fname=$(basename "$conf_file")
            if [[ "$fname" == *"VLESS"* || "$fname" == *"vless"* ]]; then
                if [[ "$fname" == *"reality"* || "$fname" == *"Reality"* ]]; then
                    proto="vless-reality"
                elif [[ "$fname" == *"vision"* ]]; then
                    proto="vless-vision"
                else
                    proto="vless"
                fi
            elif [[ "$fname" == *"VMess"* || "$fname" == *"vmess"* ]]; then
                proto="vmess"
            elif [[ "$fname" == *"trojan"* || "$fname" == *"Trojan"* ]]; then
                proto="trojan"
            elif [[ "$fname" == *"hysteria"* || "$fname" == *"Hysteria"* ]]; then
                proto="hysteria2"
            fi

            already=false
            for p in "${NODE_PORTS[@]:-}"; do
                [[ "$p" == "$port" ]] && already=true && break
            done
            $already && continue

            NODE_PORTS+=("$port")
            NODE_PROTOS+=("$proto")
        done < <(grep -oE '"port"\s*:\s*[0-9]+' "$conf_file" 2>/dev/null)
    done

    while read -r port; do
        already=false
        for p in "${NODE_PORTS[@]:-}"; do
            [[ "$p" == "$port" ]] && already=true && break
        done
        $already && continue
        [[ "$port" -le 1024 ]] && continue
        NODE_PORTS+=("$port")
        NODE_PROTOS+=("unknown")
    done < <(ss -tulnp 2>/dev/null | grep -E 'xray' | grep -oE ':[0-9]+' | grep -oE '[0-9]+' | sort -un)
fi

if [[ ${#NODE_PORTS[@]} -eq 0 ]]; then
    print_warn "未自动检测到代理端口，请手动输入"
    while true; do
        read -rp "$(echo -e "${CYAN}")代理端口${NC}: " manual_port
        if [[ "$manual_port" =~ ^[0-9]+$ ]] && (( manual_port >= 1 && manual_port <= 65535 )); then
            NODE_PORTS+=("$manual_port")
            NODE_PROTOS+=("unknown")
            break
        fi
        print_error "端口格式错误"
    done
fi

echo ""
print_success "检测到以下代理节点："
echo ""
for (( i=0; i<${#NODE_PORTS[@]}; i++ )); do
    echo -e "  ${CYAN}[$((i+1))]${NC} 端口: ${GREEN}${NODE_PORTS[$i]}${NC}  协议: ${NODE_PROTOS[$i]}"
done
echo ""

declare -a SELECTED_PORTS=()
declare -a SELECTED_PROTOS=()

if [[ ${#NODE_PORTS[@]} -eq 1 ]]; then
    SELECTED_PORTS=("${NODE_PORTS[0]}")
    SELECTED_PROTOS=("${NODE_PROTOS[0]}")
    print_info "只有一个节点，自动选择端口 ${NODE_PORTS[0]}"
else
    print_input "请选择要对接到中转机的节点编号（多个用空格分隔，直接回车选择全部）"
    read -rp "$(echo -e "${CYAN}")选择${NC}: " selection
    if [[ -z "$selection" ]]; then
        SELECTED_PORTS=("${NODE_PORTS[@]}")
        SELECTED_PROTOS=("${NODE_PROTOS[@]}")
        print_info "已选择全部 ${#NODE_PORTS[@]} 个节点"
    else
        for idx in $selection; do
            if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#NODE_PORTS[@]} )); then
                SELECTED_PORTS+=("${NODE_PORTS[$((idx-1))]}")
                SELECTED_PROTOS+=("${NODE_PROTOS[$((idx-1))]}")
            fi
        done
        print_info "已选择 ${#SELECTED_PORTS[@]} 个节点"
    fi
fi

pause_input

# ============================================================================
print_section "步骤 3/5: SSH 到中转机添加转发规则"
# ============================================================================

print_info "将通过 WireGuard 隧道（10.0.0.1）SSH 到中转机"
print_info "添加规则："
print_info "  DNAT  : 中转机:端口 → 落地机(${LANDING_IP}):端口"
print_info "  SNAT  : 回包源地址改为中转机IP（流量对称，客户端可正常收到响应）"
print_info "  INPUT : 在全局 DROP 规则前插入放行（按行号插入）"
echo ""

print_input "中转机 SSH 端口"
read -rp "$(echo -e "${CYAN}")SSH端口${NC} [默认: 22]: " RELAY_SSH_PORT
RELAY_SSH_PORT=${RELAY_SSH_PORT:-22}

print_input "中转机 SSH 用户名"
read -rp "$(echo -e "${CYAN}")用户名${NC} [默认: root]: " RELAY_SSH_USER
RELAY_SSH_USER=${RELAY_SSH_USER:-root}

print_input "中转机 SSH 密码"
read -rsp "$(echo -e "${CYAN}")密码${NC}: " RELAY_SSH_PASS
echo ""

if ! command -v sshpass &>/dev/null; then
    print_info "安装 sshpass..."
    apt-get install -y -qq sshpass 2>/dev/null || true
fi

# 展示手动命令
show_manual_cmds() {
    print_warn "请手动在中转机上执行以下命令："
    echo ""
    for port in "${SELECTED_PORTS[@]}"; do
        echo -e "${CYAN}# ── 端口 ${port} ──${NC}"
        echo ""
        echo "# 1. 清除旧规则"
        echo "iptables -t nat -D PREROUTING -p tcp --dport ${port} -j DNAT --to-destination ${LANDING_IP}:${port} 2>/dev/null || true"
        echo "iptables -t nat -D PREROUTING -p udp --dport ${port} -j DNAT --to-destination ${LANDING_IP}:${port} 2>/dev/null || true"
        echo "iptables -t nat -D POSTROUTING -p tcp -d ${LANDING_IP} --dport ${port} -j SNAT --to-source ${RELAY_IP} 2>/dev/null || true"
        echo "iptables -t nat -D POSTROUTING -p udp -d ${LANDING_IP} --dport ${port} -j SNAT --to-source ${RELAY_IP} 2>/dev/null || true"
        echo "iptables -D FORWARD -p tcp -d ${LANDING_IP} --dport ${port} -j ACCEPT 2>/dev/null || true"
        echo "iptables -D FORWARD -p udp -d ${LANDING_IP} --dport ${port} -j ACCEPT 2>/dev/null || true"
        echo ""
        echo "# 2. DNAT"
        echo "iptables -t nat -A PREROUTING -p tcp --dport ${port} -j DNAT --to-destination ${LANDING_IP}:${port}"
        echo "iptables -t nat -A PREROUTING -p udp --dport ${port} -j DNAT --to-destination ${LANDING_IP}:${port}"
        echo ""
        echo "# 3. SNAT（回包源地址改为中转机公网IP）"
        echo "iptables -t nat -A POSTROUTING -p tcp -d ${LANDING_IP} --dport ${port} -j SNAT --to-source ${RELAY_IP}"
        echo "iptables -t nat -A POSTROUTING -p udp -d ${LANDING_IP} --dport ${port} -j SNAT --to-source ${RELAY_IP}"
        echo ""
        echo "# 4. FORWARD 放行"
        echo "iptables -A FORWARD -p tcp -d ${LANDING_IP} --dport ${port} -j ACCEPT"
        echo "iptables -A FORWARD -p udp -d ${LANDING_IP} --dport ${port} -j ACCEPT"
        echo ""
        echo "# 5. INPUT 放行（插到 DROP 之前）"
        echo 'for proto in tcp udp; do'
        echo "  iptables -D INPUT -p \$proto --dport ${port} -j ACCEPT 2>/dev/null || true"
        echo '  DROP_LINE=$(iptables -L INPUT --line-numbers -n | awk '"'"'/DROP/{print $1; exit}'"'"')'
        echo '  if [[ -n "$DROP_LINE" ]]; then'
        echo "    iptables -I INPUT \"\$DROP_LINE\" -p \$proto --dport ${port} -j ACCEPT"
        echo '  else'
        echo "    iptables -A INPUT -p \$proto --dport ${port} -j ACCEPT"
        echo '  fi'
        echo 'done'
        echo ""
    done
    echo "# 6. 开启 IP 转发"
    echo "echo 1 > /proc/sys/net/ipv4/ip_forward"
    echo "grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf"
    echo ""
    echo "# 7. 保存规则"
    echo "mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4"
    echo ""
}

# 构建远程命令（通过 printf 避免 heredoc 嵌套问题）
build_relay_cmds() {
    printf '%s\n' 'set -e'
    printf '%s\n' "echo '[+] 开启 IP 转发...'"
    printf '%s\n' 'echo 1 > /proc/sys/net/ipv4/ip_forward'
    printf '%s\n' "grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf"

    for port in "${SELECTED_PORTS[@]}"; do
        printf '\n'
        printf '%s\n' "echo '[+] 配置端口 ${port} 规则...'"

        # 清除旧规则
        printf '%s\n' "iptables -t nat -D PREROUTING -p tcp --dport ${port} -j DNAT --to-destination ${LANDING_IP}:${port} 2>/dev/null || true"
        printf '%s\n' "iptables -t nat -D PREROUTING -p udp --dport ${port} -j DNAT --to-destination ${LANDING_IP}:${port} 2>/dev/null || true"
        printf '%s\n' "iptables -t nat -D POSTROUTING -p tcp -d ${LANDING_IP} --dport ${port} -j SNAT --to-source ${RELAY_IP} 2>/dev/null || true"
        printf '%s\n' "iptables -t nat -D POSTROUTING -p udp -d ${LANDING_IP} --dport ${port} -j SNAT --to-source ${RELAY_IP} 2>/dev/null || true"
        printf '%s\n' "iptables -D FORWARD -p tcp -d ${LANDING_IP} --dport ${port} -j ACCEPT 2>/dev/null || true"
        printf '%s\n' "iptables -D FORWARD -p udp -d ${LANDING_IP} --dport ${port} -j ACCEPT 2>/dev/null || true"

        # DNAT
        printf '%s\n' "iptables -t nat -A PREROUTING -p tcp --dport ${port} -j DNAT --to-destination ${LANDING_IP}:${port}"
        printf '%s\n' "iptables -t nat -A PREROUTING -p udp --dport ${port} -j DNAT --to-destination ${LANDING_IP}:${port}"

        # SNAT
        printf '%s\n' "# SNAT: 回包源地址改为中转机公网IP，确保流量对称"
        printf '%s\n' "iptables -t nat -A POSTROUTING -p tcp -d ${LANDING_IP} --dport ${port} -j SNAT --to-source ${RELAY_IP}"
        printf '%s\n' "iptables -t nat -A POSTROUTING -p udp -d ${LANDING_IP} --dport ${port} -j SNAT --to-source ${RELAY_IP}"

        # FORWARD
        printf '%s\n' "iptables -A FORWARD -p tcp -d ${LANDING_IP} --dport ${port} -j ACCEPT"
        printf '%s\n' "iptables -A FORWARD -p udp -d ${LANDING_IP} --dport ${port} -j ACCEPT"

        # INPUT（行号插入，确保在全局 DROP 之前）
        printf '%s\n' "for proto in tcp udp; do"
        printf '%s\n' "  iptables -D INPUT -p \$proto --dport ${port} -j ACCEPT 2>/dev/null || true"
        printf '%s\n' "  DROP_LINE=\$(iptables -L INPUT --line-numbers -n 2>/dev/null | awk '/DROP/{print \$1; exit}')"
        printf '%s\n' '  if [[ -n "$DROP_LINE" ]]; then'
        printf '%s\n' "    iptables -I INPUT \"\$DROP_LINE\" -p \$proto --dport ${port} -j ACCEPT"
        printf '%s\n' "  else"
        printf '%s\n' "    iptables -A INPUT -p \$proto --dport ${port} -j ACCEPT"
        printf '%s\n' "  fi"
        printf '%s\n' "done"

        printf '%s\n' "echo '[✓] 端口 ${port} 规则完成'"
    done

    printf '\n'
    printf '%s\n' "echo '[+] 保存 iptables 规则...'"
    printf '%s\n' 'mkdir -p /etc/iptables'
    printf '%s\n' 'iptables-save > /etc/iptables/rules.v4'
    printf '%s\n' "echo '[✓] 规则已保存'"
    printf '\n'
    printf '%s\n' "echo ''"
    printf '%s\n' "echo '[i] 当前 DNAT 规则：'"
    printf '%s\n' "iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -E 'Chain|DNAT' || true"
    printf '%s\n' "echo ''"
    printf '%s\n' "echo '[i] 当前 SNAT 规则：'"
    printf '%s\n' "iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep -E 'Chain|SNAT|MASQ' || true"
}

if ! command -v sshpass &>/dev/null; then
    print_error "sshpass 安装失败，无法自动 SSH"
    show_manual_cmds
    RELAY_SSH_PASS=""
fi

if [[ -n "$RELAY_SSH_PASS" ]]; then
    print_info "正在 SSH 到中转机 10.0.0.1:${RELAY_SSH_PORT}..."

    SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p $RELAY_SSH_PORT"
    RELAY_CMDS=$(build_relay_cmds)

    if sshpass -p "$RELAY_SSH_PASS" ssh $SSH_OPTS \
        "${RELAY_SSH_USER}@10.0.0.1" \
        "bash -s" <<< "$RELAY_CMDS" 2>&1; then
        print_success "中转机端口转发规则（DNAT + SNAT + INPUT）已添加"
    else
        print_error "SSH 连接失败！请检查密码或端口"
        show_manual_cmds
    fi
fi

pause_input

# ============================================================================
print_section "步骤 4/5: 生成节点链接"
# ============================================================================

print_info "读取 Xray 节点配置，生成中转机入口链接..."
echo ""

declare -a FINAL_LINKS=()

if [[ "$AGENT_TYPE" == "xray" ]]; then
    for (( i=0; i<${#SELECTED_PORTS[@]}; i++ )); do
        port="${SELECTED_PORTS[$i]}"
        proto="${SELECTED_PROTOS[$i]}"

        conf_file=""
        for f in "$CONF_DIR"/*inbound*.json; do
            [[ -f "$f" ]] || continue
            if grep -q "\"port\".*:.*$port\b" "$f" 2>/dev/null || \
               grep -q "\"port\": $port" "$f" 2>/dev/null; then
                conf_file="$f"
                break
            fi
        done

        if [[ -z "$conf_file" ]]; then
            print_warn "端口 $port 未找到对应配置文件，跳过"
            continue
        fi

        UUID=$(grep -oE '"id"\s*:\s*"[^"]+"' "$conf_file" 2>/dev/null \
            | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1)

        SNI=$(python3 -c "
import json, sys
try:
    data = json.load(open('$conf_file'))
    for inb in data.get('inbounds', []):
        rs = inb.get('streamSettings',{}).get('realitySettings',{})
        names = rs.get('serverNames', [])
        if names:
            print(names[0]); sys.exit()
        sn = rs.get('serverName','')
        if sn:
            print(sn); sys.exit()
except: pass
" 2>/dev/null || grep -oE '"serverNames"\s*:\s*\[[^]]+\]' "$conf_file" 2>/dev/null \
            | grep -oE '"[a-zA-Z0-9._-]+"' | grep -v '^""$' | head -1 | tr -d '"')

        PBK=$(python3 -c "
import json, sys
try:
    data = json.load(open('$conf_file'))
    for inb in data.get('inbounds', []):
        pk = inb.get('streamSettings',{}).get('realitySettings',{}).get('publicKey','')
        if pk: print(pk); sys.exit()
except: pass
" 2>/dev/null || grep -oE '"publicKey"\s*:\s*"[^"]+"' "$conf_file" 2>/dev/null \
            | grep -oE ':\s*"[^"]+"' | tr -d ': "' | head -1)

        SID=$(python3 -c "
import json, sys
try:
    data = json.load(open('$conf_file'))
    for inb in data.get('inbounds', []):
        ids = inb.get('streamSettings',{}).get('realitySettings',{}).get('shortIds', [])
        for sid in ids:
            if sid: print(sid); sys.exit()
except: pass
" 2>/dev/null || grep -oE '"shortIds"\s*:\s*\[[^]]+\]' "$conf_file" 2>/dev/null \
            | grep -oE '"[a-f0-9]+"' | head -1 | tr -d '"')

        FP=$(grep -oE '"fingerprint"\s*:\s*"[^"]+"' "$conf_file" 2>/dev/null \
            | grep -oE ':\s*"[^"]+"' | tr -d ': "' | head -1)
        FP=${FP:-chrome}

        FLOW=$(grep -oE '"flow"\s*:\s*"[^"]+"' "$conf_file" 2>/dev/null \
            | grep -oE ':\s*"[^"]+"' | tr -d ': "' | head -1)

        NETWORK="tcp"

        if [[ -z "$UUID" ]]; then
            print_warn "端口 $port 无法提取 UUID，跳过"
            continue
        fi

        link=""
        tag="${proto}-${port}-via-CN2GIA"

        if [[ "$proto" == "vless-reality" || "$proto" == "vless-vision" || "$proto" == *"vless"* ]]; then
            params="encryption=none"
            [[ -n "$FLOW" ]] && params+="&flow=${FLOW}"
            if [[ -n "$PBK" ]]; then
                params+="&security=reality&type=${NETWORK}"
                [[ -n "$SNI" ]] && params+="&sni=${SNI}"
                [[ -n "$FP"  ]] && params+="&fp=${FP}"
                params+="&pbk=${PBK}"
                [[ -n "$SID" ]] && params+="&sid=${SID}"
            else
                params+="&security=tls&type=${NETWORK}"
                [[ -n "$SNI" ]] && params+="&sni=${SNI}"
            fi
            link="vless://${UUID}@${RELAY_IP}:${port}?${params}#${tag}"

        elif [[ "$proto" == "vmess" ]]; then
            link=$(python3 -c "
import json, base64
config = {
    'v':'2','ps':'${tag}','add':'${RELAY_IP}','port':'${port}',
    'id':'${UUID}','aid':'0','net':'${NETWORK}','type':'none',
    'host':'${SNI:-}','path':'','tls':'tls'
}
print('vmess://' + base64.b64encode(json.dumps(config).encode()).decode())
" 2>/dev/null || echo "")

        elif [[ "$proto" == "trojan" ]]; then
            link="trojan://${UUID}@${RELAY_IP}:${port}?security=tls&sni=${SNI:-}&type=${NETWORK}#${tag}"
        fi

        if [[ -n "$link" ]]; then
            FINAL_LINKS+=("$link")
            print_success "端口 $port 链接已生成"
        fi
    done
fi

pause_input

# ============================================================================
print_section "步骤 5/5: 完成总结"
# ============================================================================

NODES_FILE="/opt/relay-wg/config/nodes.txt"
mkdir -p "$(dirname "$NODES_FILE")"
{
    echo "========================================"
    echo "  对接节点链接"
    echo "  生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  入口: 中转机 $RELAY_IP (CN2GIA)"
    echo "  出站: 落地机 ${LANDING_IP:-未知}"
    echo "  SNAT: 已启用（流量对称，回包经中转机）"
    echo "========================================"
    echo ""
} > "$NODES_FILE"

for (( i=0; i<${#SELECTED_PORTS[@]}; i++ )); do
    port="${SELECTED_PORTS[$i]}"
    proto="${SELECTED_PROTOS[$i]}"
    echo "【端口 $port | $proto】" >> "$NODES_FILE"
    for link in "${FINAL_LINKS[@]:-}"; do
        if [[ "$link" == *":${port}?"* || "$link" == *"port\":\"${port}\""* ]]; then
            echo "$link" >> "$NODES_FILE"
        fi
    done
    echo "" >> "$NODES_FILE"
done

chmod 600 "$NODES_FILE"
print_success "节点链接已保存: $NODES_FILE"

# 更新 relay-info
cat > /usr/local/bin/relay-info << 'CMEOF'
#!/bin/bash
CYAN='\033[0;36m' GREEN='\033[0;32m' NC='\033[0m'
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              落地机信息速查                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
SUMMARY=/opt/relay-wg/config/peer-summary.txt
[[ -f "$SUMMARY" ]] && cat "$SUMMARY"
NODES=/opt/relay-wg/config/nodes.txt
if [[ -f "$NODES" ]]; then
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━ 节点链接 ━━━━━━━━━━━━━━━━━${NC}"
    cat "$NODES"
fi
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━ 实时状态 ━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}▸ WireGuard:${NC}"
wg show 2>/dev/null || echo "  (未运行)"
echo ""
echo -e "${GREEN}▸ 本机公网 IP:${NC}"
curl -s --max-time 5 https://api.ip.sb/ip 2>/dev/null || echo "  (获取失败)"
echo ""
echo -e "${GREEN}▸ 隧道连通性 (ping 10.0.0.1):${NC}"
ping -c 3 -W 2 10.0.0.1 2>/dev/null || echo "  (不通，检查WireGuard)"
echo ""
echo -e "${GREEN}▸ 中转机 NAT 规则（当前）:${NC}"
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@10.0.0.1 \
    "echo '--- DNAT ---'; iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep DNAT; echo '--- SNAT ---'; iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep -E 'SNAT|MASQ'" 2>/dev/null || echo "  (SSH 到中转机失败，可忽略)"
CMEOF
chmod +x /usr/local/bin/relay-info

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║               ★ 对接完成！节点信息如下 ★                      ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【流量路径】                                               │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
echo -e "  用户连接   → ${GREEN}${RELAY_IP}${NC} (中转机 CN2GIA 入口)"
echo -e "  DNAT 转发  → ${GREEN}${LANDING_IP:-落地机}${NC}:端口"
echo -e "  SNAT 回包  → 源地址改为 ${GREEN}${RELAY_IP}${NC}（流量对称）"
echo -e "  流量出站   → ${GREEN}${LANDING_IP:-落地机}${NC} (干净IP，解锁流媒体)"
echo ""
echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【节点链接】 — 导入到客户端使用                           │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
if [[ ${#FINAL_LINKS[@]} -gt 0 ]]; then
    for (( i=0; i<${#FINAL_LINKS[@]}; i++ )); do
        echo -e "  ${CYAN}节点 $((i+1)):${NC}"
        echo -e "  ${GREEN}${FINAL_LINKS[$i]}${NC}"
        echo ""
    done
else
    print_warn "链接生成失败，请查看 $NODES_FILE"
    for (( i=0; i<${#SELECTED_PORTS[@]}; i++ )); do
        echo -e "  端口 ${GREEN}${SELECTED_PORTS[$i]}${NC} → ${GREEN}${RELAY_IP}:${SELECTED_PORTS[$i]}${NC}"
    done
fi
echo ""
echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【中转机端口转发规则】（已自动配置）                       │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
for port in "${SELECTED_PORTS[@]}"; do
    echo -e "  DNAT  ${RELAY_IP}:${GREEN}${port}${NC} → ${LANDING_IP:-落地机}:${GREEN}${port}${NC}"
    echo -e "  SNAT  回包源地址 → ${GREEN}${RELAY_IP}${NC}"
done
echo ""
echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【常用命令】                                               │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
echo -e "  查看所有信息:  ${CYAN}relay-info${NC}"
echo -e "  查看节点链接:  ${CYAN}cat /opt/relay-wg/config/nodes.txt${NC}"
echo -e "  查看WG状态:    ${CYAN}wg show${NC}"
echo -e "  重新对接:      ${CYAN}bash duijie.sh${NC}"
echo ""
echo -e "${GREEN}随时运行 ${CYAN}relay-info${GREEN} 查看节点链接和连接状态${NC}"
echo ""
