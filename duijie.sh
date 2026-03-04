#!/bin/bash

################################################################################
#                                                                              #
#              落地机代理节点对接中转机一键脚本                                  #
#                         v1.00                                                #
#                                                                              #
#  前提条件：                                                                   #
#    1. 已运行 luodi.sh，WireGuard 隧道已建立                                   #
#    2. 已安装 v2ray-agent（Xray 或 Sing-box）                                  #
#                                                                              #
#  本脚本做的事：                                                                #
#    1. 读取本机已有的中转机信息（relay-info）                                    #
#    2. 自动检测代理协议和端口                                                   #
#    3. SSH 到中转机（10.0.0.1），自动添加端口转发规则                            #
#    4. 输出最终节点链接（入口=中转机IP，出站=落地机IP）                           #
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
    echo "║           落地机代理节点 ↔ 中转机 一键对接工具                  ║"
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
# 主程序
# ============================================================================

print_title

if [[ "$EUID" -ne 0 ]]; then
    print_error "必须使用 root 权限运行此脚本！"
    exit 1
fi

# ============================================================================
print_section "步骤 1/5: 读取本机信息"
# ============================================================================

# ---- 读取 luodi.sh 保存的摘要 ----
# 兼容新版(peer-summary.txt)和旧版(summary.txt)
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
    print_error "查找路径："
    print_error "  /opt/relay-wg/config/peer-summary.txt"
    print_error "  /opt/relay-wg/config/summary.txt"
    print_error "请先运行 luodi.sh 完成 WireGuard 部署"
    exit 1
fi

print_info "读取摘要: $SUMMARY_FILE"

# 提取落地机公网IP（【本落地机】段落下的公网IP）
LANDING_IP=$(awk '/本落地机/{found=1} /中转机信息/{found=0} found && /公网 IP/{match($0,/([0-9]{1,3}\.){3}[0-9]{1,3}/); if(RLENGTH>0){print substr($0,RSTART,RLENGTH); exit}}' "$SUMMARY_FILE")

# 提取中转机IP（【中转机信息】段落下的公网IP）
RELAY_IP=$(awk '/中转机信息/{found=1} found && /公网 IP/{match($0,/([0-9]{1,3}\.){3}[0-9]{1,3}/); if(RLENGTH>0){print substr($0,RSTART,RLENGTH); exit}}' "$SUMMARY_FILE")

# 兼容新版摘要格式（peer-summary.txt）
if [[ -z "$RELAY_IP" ]]; then
    RELAY_IP=$(grep '中转机公网IP' "$SUMMARY_FILE" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
fi

# 兼容两种格式提取本机WG IP
WG_LOCAL_IP=$(grep -E 'WireGuard地址|WireGuard IP' "$SUMMARY_FILE" \
    | grep -oE '10\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)

# 如果摘要里没有落地机公网IP，实时获取
if [[ -z "$LANDING_IP" ]]; then
    print_info "正在获取本机公网IP..."
    LANDING_IP=$(curl -s --max-time 5 https://api.ip.sb/ip 2>/dev/null \
        || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || echo "")
fi

if [[ -z "$RELAY_IP" ]]; then
    print_error "无法从摘要文件读取中转机IP，请检查 $SUMMARY_FILE"
    exit 1
fi

if [[ -z "$WG_LOCAL_IP" ]]; then
    # 尝试从 wg0 接口直接获取
    WG_LOCAL_IP=$(ip addr show wg0 2>/dev/null | grep -oE '10\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
fi

print_success "中转机IP:   $RELAY_IP"
print_success "本机WG IP:  ${WG_LOCAL_IP:-未知}"
print_success "本机公网IP: ${LANDING_IP:-未知}"

# ---- 验证 WireGuard 隧道 ----
echo ""
print_info "验证 WireGuard 隧道..."
if ! wg show wg0 &>/dev/null; then
    print_error "WireGuard wg0 接口未运行！"
    print_error "请先运行: systemctl start wg-quick@wg0"
    exit 1
fi

if ! ping -c 1 -W 3 10.0.0.1 &>/dev/null; then
    print_error "无法 ping 通中转机内网 10.0.0.1，隧道可能断开"
    print_error "请检查: wg show"
    exit 1
fi
print_success "WireGuard 隧道正常（延迟: $(ping -c 1 -W 3 10.0.0.1 2>/dev/null | grep -oE 'time=[0-9.]+' | head -1)ms）"

pause_input

# ============================================================================
print_section "步骤 2/5: 检测代理节点"
# ============================================================================

# ---- 检测 v2ray-agent 类型 ----
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
    print_error "未检测到 v2ray-agent！请先安装代理节点"
    print_info "安装地址: https://github.com/mack-a/v2ray-agent"
    exit 1
fi

# ---- 检测代理端口和协议 ----
echo ""
print_info "扫描代理节点配置..."

declare -a NODE_PORTS=()
declare -a NODE_PROTOS=()
declare -a NODE_LINKS=()

if [[ "$AGENT_TYPE" == "xray" ]]; then
    # 扫描所有 inbound 配置文件
    for conf_file in "$CONF_DIR"/*inbound*.json; do
        [[ -f "$conf_file" ]] || continue

        # 提取端口
        while IFS= read -r line; do
            port=$(echo "$line" | grep -oE '"port"\s*:\s*[0-9]+' | grep -oE '[0-9]+' | head -1)
            [[ -z "$port" ]] && continue
            [[ "$port" -lt 1 || "$port" -gt 65535 ]] && continue

            # 判断协议
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

            # 去重
            already=false
            for p in "${NODE_PORTS[@]:-}"; do
                [[ "$p" == "$port" ]] && already=true && break
            done
            $already && continue

            NODE_PORTS+=("$port")
            NODE_PROTOS+=("$proto")
        done < <(grep -oE '"port"\s*:\s*[0-9]+' "$conf_file" 2>/dev/null)
    done

    # 也扫描实际监听端口（补充配置文件没覆盖的）
    while read -r port; do
        already=false
        for p in "${NODE_PORTS[@]:-}"; do
            [[ "$p" == "$port" ]] && already=true && break
        done
        $already && continue
        # 排除 SSH 和系统端口
        [[ "$port" -le 1024 ]] && continue
        NODE_PORTS+=("$port")
        NODE_PROTOS+=("unknown")
    done < <(ss -tulnp 2>/dev/null \
        | grep -E 'xray' \
        | grep -oE ':[0-9]+' \
        | grep -oE '[0-9]+' \
        | sort -un)
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
        print_error "端口格式错误，请重新输入"
    done
fi

echo ""
print_success "检测到以下代理节点："
echo ""
for (( i=0; i<${#NODE_PORTS[@]}; i++ )); do
    echo -e "  ${CYAN}[$((i+1))]${NC} 端口: ${GREEN}${NODE_PORTS[$i]}${NC}  协议: ${NODE_PROTOS[$i]}"
done
echo ""

# ---- 如果有多个节点，让用户选择要对接哪些 ----
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
print_info "添加 DNAT + SNAT + INPUT 规则（SNAT解决非对称路由）"
echo ""

# ---- SSH 基本参数 ----
read -rp "$(echo -e "${CYAN}")SSH端口${NC} [默认: 22]: " RELAY_SSH_PORT
RELAY_SSH_PORT=${RELAY_SSH_PORT:-22}
read -rp "$(echo -e "${CYAN}")用户名${NC} [默认: root]: " RELAY_SSH_USER
RELAY_SSH_USER=${RELAY_SSH_USER:-root}

# ---- 认证方式 ----
echo ""
print_info "选择 SSH 认证方式："
echo -e "  ${CYAN}[1]${NC} 密码登录"
echo -e "  ${CYAN}[2]${NC} 密钥登录（本机 ~/.ssh/id_rsa 或指定路径）"
echo -e "  ${CYAN}[3]${NC} 跳过自动配置（显示手动命令）"
read -rp "$(echo -e "${CYAN}")选择${NC} [默认: 1]: " auth_choice
auth_choice=${auth_choice:-1}

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p $RELAY_SSH_PORT"
SSH_CMD=""
RELAY_SSH_PASS=""
KEY_FILE=""

case "$auth_choice" in
    1)
        read -rsp "$(echo -e "${CYAN}")SSH密码${NC}: " RELAY_SSH_PASS
        echo ""
        if ! command -v sshpass &>/dev/null; then
            print_info "安装 sshpass..."
            apt-get install -y -qq sshpass 2>/dev/null || true
        fi
        if command -v sshpass &>/dev/null && [[ -n "$RELAY_SSH_PASS" ]]; then
            SSH_CMD="sshpass -p '$RELAY_SSH_PASS' ssh $SSH_OPTS"
        else
            print_warn "sshpass 不可用或密码为空，降级为手动模式"
            auth_choice=3
        fi
        ;;
    2)
        read -rp "$(echo -e "${CYAN}")密钥文件路径${NC} [默认: ~/.ssh/id_rsa]: " KEY_FILE
        KEY_FILE=${KEY_FILE:-~/.ssh/id_rsa}
        KEY_FILE="${KEY_FILE/#\~/$HOME}"
        if [[ ! -f "$KEY_FILE" ]]; then
            print_warn "密钥文件不存在: $KEY_FILE，降级为手动模式"
            auth_choice=3
        else
            SSH_CMD="ssh $SSH_OPTS -i '$KEY_FILE'"
        fi
        ;;
    3)
        print_info "已选择手动模式"
        ;;
    *)
        auth_choice=3
        ;;
esac

# ---- 构建远程命令（DNAT + SNAT + INPUT行号插入）----
build_relay_cmds() {
    printf 'set -e\n'
    printf 'echo 1 > /proc/sys/net/ipv4/ip_forward\n'
    for port in "${SELECTED_PORTS[@]}"; do
        printf 'echo "[+] 配置端口 %s..."\n' "$port"
        # 清除旧规则
        printf 'iptables -t nat -D PREROUTING -p tcp --dport %s -j DNAT --to-destination %s:%s 2>/dev/null || true\n' "$port" "$LANDING_IP" "$port"
        printf 'iptables -t nat -D PREROUTING -p udp --dport %s -j DNAT --to-destination %s:%s 2>/dev/null || true\n' "$port" "$LANDING_IP" "$port"
        printf 'iptables -t nat -D POSTROUTING -p tcp -d %s --dport %s -j SNAT --to-source %s 2>/dev/null || true\n' "$LANDING_IP" "$port" "$RELAY_IP"
        printf 'iptables -t nat -D POSTROUTING -p udp -d %s --dport %s -j SNAT --to-source %s 2>/dev/null || true\n' "$LANDING_IP" "$port" "$RELAY_IP"
        printf 'iptables -D FORWARD -p tcp -d %s --dport %s -j ACCEPT 2>/dev/null || true\n' "$LANDING_IP" "$port"
        printf 'iptables -D FORWARD -p udp -d %s --dport %s -j ACCEPT 2>/dev/null || true\n' "$LANDING_IP" "$port"
        # 添加 DNAT
        printf 'iptables -t nat -A PREROUTING -p tcp --dport %s -j DNAT --to-destination %s:%s\n' "$port" "$LANDING_IP" "$port"
        printf 'iptables -t nat -A PREROUTING -p udp --dport %s -j DNAT --to-destination %s:%s\n' "$port" "$LANDING_IP" "$port"
        # 添加 SNAT（解决非对称路由）
        printf 'iptables -t nat -A POSTROUTING -p tcp -d %s --dport %s -j SNAT --to-source %s\n' "$LANDING_IP" "$port" "$RELAY_IP"
        printf 'iptables -t nat -A POSTROUTING -p udp -d %s --dport %s -j SNAT --to-source %s\n' "$LANDING_IP" "$port" "$RELAY_IP"
        # FORWARD
        printf 'iptables -A FORWARD -p tcp -d %s --dport %s -j ACCEPT\n' "$LANDING_IP" "$port"
        printf 'iptables -A FORWARD -p udp -d %s --dport %s -j ACCEPT\n' "$LANDING_IP" "$port"
        # INPUT — 插到全局 DROP 之前
        printf 'for _proto in tcp udp; do\n'
        printf '  iptables -D INPUT -p $_proto --dport %s -j ACCEPT 2>/dev/null || true\n' "$port"
        printf '  _drop=$(iptables -L INPUT --line-numbers -n 2>/dev/null | awk '"'"'/^\s*[0-9].*DROP/{print $1; exit}'"'"')\n'
        printf '  if [[ -n "$_drop" ]]; then\n'
        printf '    iptables -I INPUT "$_drop" -p $_proto --dport %s -j ACCEPT\n' "$port"
        printf '  else\n'
        printf '    iptables -A INPUT -p $_proto --dport %s -j ACCEPT\n' "$port"
        printf '  fi\n'
        printf 'done\n'
        printf 'echo "[✓] 端口 %s 完成"\n' "$port"
    done
    printf 'mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4\n'
    printf 'echo "[✓] 规则已保存"\n'
}

# ---- 显示手动命令 ----
show_manual_cmds() {
    print_warn "请手动在中转机上执行以下命令："
    echo ""
    for port in "${SELECTED_PORTS[@]}"; do
        echo -e "${CYAN}# 端口 $port${NC}"
        echo "iptables -t nat -A PREROUTING -p tcp --dport $port -j DNAT --to-destination ${LANDING_IP}:${port}"
        echo "iptables -t nat -A PREROUTING -p udp --dport $port -j DNAT --to-destination ${LANDING_IP}:${port}"
        echo "iptables -t nat -A POSTROUTING -p tcp -d ${LANDING_IP} --dport $port -j SNAT --to-source ${RELAY_IP}"
        echo "iptables -t nat -A POSTROUTING -p udp -d ${LANDING_IP} --dport $port -j SNAT --to-source ${RELAY_IP}"
        echo "iptables -A FORWARD -p tcp -d ${LANDING_IP} --dport $port -j ACCEPT"
        echo "iptables -A FORWARD -p udp -d ${LANDING_IP} --dport $port -j ACCEPT"
        echo 'DROP_LINE=$(iptables -L INPUT --line-numbers -n | awk '"'"'/DROP/{print $1; exit}'"'"')'
        echo "iptables -I \"\$DROP_LINE\" -p tcp --dport $port -j ACCEPT"
        echo "iptables -I \"\$DROP_LINE\" -p udp --dport $port -j ACCEPT"
        echo ""
    done
    echo "iptables-save > /etc/iptables/rules.v4"
    echo ""
}

# ---- 执行 SSH ----
if [[ "$auth_choice" == "3" ]]; then
    show_manual_cmds
else
    RELAY_CMDS=$(build_relay_cmds)
    print_info "正在连接中转机 10.0.0.1:${RELAY_SSH_PORT}..."
    SSH_RESULT=0
    if [[ "$auth_choice" == "1" ]]; then
        sshpass -p "$RELAY_SSH_PASS" ssh $SSH_OPTS "${RELAY_SSH_USER}@10.0.0.1" "bash -s" <<< "$RELAY_CMDS" 2>&1 || SSH_RESULT=$?
    else
        ssh $SSH_OPTS -i "$KEY_FILE" "${RELAY_SSH_USER}@10.0.0.1" "bash -s" <<< "$RELAY_CMDS" 2>&1 || SSH_RESULT=$?
    fi
    if [[ $SSH_RESULT -eq 0 ]]; then
        print_success "中转机 DNAT+SNAT+INPUT 规则已配置"
    else
        print_error "SSH 失败（退出码: $SSH_RESULT）"
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

        # 找对应的 inbound 配置文件
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
            print_warn "端口 $port 未找到对应配置文件，跳过生成链接"
            continue
        fi

        # 提取节点参数（兼容 v2ray-agent 的 Reality 配置格式）
        UUID=$(grep -oE '"id"\s*:\s*"[^"]+"' "$conf_file" 2>/dev/null \
            | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1)

        # SNI: 优先取 serverNames 数组第一个，兜底取 serverName
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
" 2>/dev/null || \
            grep -oE '"serverNames"\s*:\s*\[[^]]+\]' "$conf_file" 2>/dev/null \
            | grep -oE '"[a-zA-Z0-9._-]+"' | grep -v '^""$' | head -1 | tr -d '"')

        # 公钥
        PBK=$(python3 -c "
import json, sys
try:
    data = json.load(open('$conf_file'))
    for inb in data.get('inbounds', []):
        pk = inb.get('streamSettings',{}).get('realitySettings',{}).get('publicKey','')
        if pk: print(pk); sys.exit()
except: pass
" 2>/dev/null || \
            grep -oE '"publicKey"\s*:\s*"[^"]+"' "$conf_file" 2>/dev/null \
            | grep -oE ':\s*"[^"]+"' | tr -d ': "' | head -1)

        # shortId: 取非空的第一个
        SID=$(python3 -c "
import json, sys
try:
    data = json.load(open('$conf_file'))
    for inb in data.get('inbounds', []):
        ids = inb.get('streamSettings',{}).get('realitySettings',{}).get('shortIds', [])
        for sid in ids:
            if sid: print(sid); sys.exit()
except: pass
" 2>/dev/null || \
            grep -oE '"shortIds"\s*:\s*\[[^]]+\]' "$conf_file" 2>/dev/null \
            | grep -oE '"[a-f0-9]+"' | head -1 | tr -d '"')

        # fingerprint（v2ray-agent 默认 chrome）
        FP=$(grep -oE '"fingerprint"\s*:\s*"[^"]+"' "$conf_file" 2>/dev/null \
            | grep -oE ':\s*"[^"]+"' | tr -d ': "' | head -1)
        FP=${FP:-chrome}

        # flow
        FLOW=$(grep -oE '"flow"\s*:\s*"[^"]+"' "$conf_file" 2>/dev/null \
            | grep -oE ':\s*"[^"]+"' | tr -d ': "' | head -1)

        # network（dokodemo-door 转发结构，实际是 tcp）
        NETWORK="tcp"

        if [[ -z "$UUID" ]]; then
            print_warn "端口 $port 无法提取 UUID，跳过"
            continue
        fi

        # 生成链接（入口IP改为中转机）
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
            # VMess JSON 格式
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

# ---- 保存节点链接 ----
NODES_FILE="/opt/relay-wg/config/nodes.txt"
cat > "$NODES_FILE" <<EOF
========================================
  对接节点链接
  生成时间: $(date '+%Y-%m-%d %H:%M:%S')
  入口: 中转机 $RELAY_IP (CN2GIA)
  出站: 落地机 ${LANDING_IP:-未知}
========================================

EOF

for (( i=0; i<${#SELECTED_PORTS[@]}; i++ )); do
    port="${SELECTED_PORTS[$i]}"
    proto="${SELECTED_PROTOS[$i]}"
    echo "【端口 $port | $proto】" >> "$NODES_FILE"
    # 找对应链接
    for link in "${FINAL_LINKS[@]:-}"; do
        if [[ "$link" == *":${port}?"* || "$link" == *"port\":\"${port}\""* ]]; then
            echo "$link" >> "$NODES_FILE"
        fi
    done
    echo "" >> "$NODES_FILE"
done

chmod 600 "$NODES_FILE"
print_success "节点链接已保存: $NODES_FILE"

# ---- 更新 relay-info 命令，加入节点信息 ----
cat > /usr/local/bin/relay-info << 'CMEOF'
#!/bin/bash
CYAN='\033[0;36m' YELLOW='\033[1;33m' GREEN='\033[0;32m' NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              落地机信息速查                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# 基础信息
SUMMARY=/opt/relay-wg/config/peer-summary.txt
[[ -f "$SUMMARY" ]] && cat "$SUMMARY"

# 节点链接
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
CMEOF
chmod +x /usr/local/bin/relay-info

# ---- 最终展示 ----
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║               ★ 对接完成！节点信息如下 ★                      ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【流量路径】                                               │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
echo -e "  用户连接   → ${GREEN}${RELAY_IP}${NC} (中转机 CN2GIA 入口)"
echo -e "  隧道传输   → ${GREEN}WireGuard 加密隧道${NC}"
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
    print_warn "链接生成失败，请查看 $NODES_FILE 或手动生成"
    echo ""
    for (( i=0; i<${#SELECTED_PORTS[@]}; i++ )); do
        port="${SELECTED_PORTS[$i]}"
        echo -e "  端口 ${GREEN}$port${NC} → 中转机入口: ${GREEN}${RELAY_IP}:${port}${NC}"
    done
fi
echo ""

echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  【中转机端口转发】 — 已在中转机添加                       │${NC}"
echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
for port in "${SELECTED_PORTS[@]}"; do
    echo -e "  ${RELAY_IP}:${GREEN}${port}${NC} → ${LANDING_IP:-落地机}:${GREEN}${port}${NC}"
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
