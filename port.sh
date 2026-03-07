#!/bin/bash
# ============================================================
# port.sh — iptables 防火墙管理脚本 v7.0
# 架构：Xray 链式代理（中转机 → 落地机）
#
# 角色说明：
#   relay   — 中转机：用户连接此机，Xray 应用层转发到落地机
#             iptables 只需放行用户连接的入站端口（TCP）
#             无需 FORWARD / MASQUERADE（应用层转发，不经内核）
#
#   landing — 落地机：只接受来自中转机的连接，代理端口做
#             IP 白名单（只有中转机 IP 才能访问）
#             MASQUERADE 使代理流量用本机 IP 出互联网
#
# 用法：
#   bash port.sh              交互式配置（自动检测角色）
#   bash port.sh --relay      强制中转机模式
#   bash port.sh --landing    强制落地机模式
#   bash port.sh --status     查看当前规则与链路拓扑
#   bash port.sh --reset      清空所有规则（全部放行）
#   bash port.sh --add-hop    为落地机添加 Hysteria2 端口跳跃
#   bash port.sh --add-relay  为落地机追加新的中转机 IP 白名单
#   bash port.sh --dry-run    预览模式，不实际执行
# ============================================================
set -uo pipefail

# ── 颜色 ────────────────────────────────────────────────────
R="\033[31m" Y="\033[33m" G="\033[32m" C="\033[36m" B="\033[34m" W="\033[0m"
ok()   { echo -e "${G}✓ $*${W}"; }
warn() { echo -e "${Y}⚠ $*${W}"; }
err()  { echo -e "${R}✗ $*${W}"; exit 1; }
info() { echo -e "${C}→ $*${W}"; }
hr()   { echo -e "${B}──────────────────────────────────────────${W}"; }

[[ $(id -u) -eq 0 ]] || err "需要 root 权限"

VERSION="7.0"

# ── 全局变量 ────────────────────────────────────────────────
SSH_PORT=""
ROLE="auto"          # auto | relay | landing
DRY_RUN=false

# 中转机：需要对用户开放的入站端口（TCP）
RELAY_INBOUND_PORTS=()

# 落地机：代理服务端口 + 允许连接的中转机 IP 白名单
LANDING_PROXY_PORTS=()
RELAY_WHITELIST=()   # 允许访问落地机代理端口的中转机 IP 列表

# 端口跳跃（落地机 Hysteria2 用）
HOP_RULES=()         # 格式: "起始-结束->目标端口"

# 信息文件路径（与 zhongzhuan.sh / luodi.sh / duijie.sh 约定一致）
ZHONGZHUAN_INFO="/root/xray_zhongzhuan_info.txt"
LUODI_INFO="/root/xray_luodi_info.txt"
NODES_FILE="/usr/local/etc/xray/nodes.json"

# 危险服务端口黑名单（不开放）
BLACKLIST_PORTS=(
    23 25 53 69 111
    135 137 138 139 445
    110 143 465 587 993 995
    514 631 323 2049
    1433 1521 3306 5432 6379 27017
    3389 5900 5901 5902
)

# 排除系统进程（扫描监听端口时忽略）
EXCLUDE_PROCS="cloudflared|chronyd|dnsmasq|systemd-resolve|named|unbound|ntpd|avahi"

# ── 参数解析 ────────────────────────────────────────────────
_status=0 _reset=0 _addhop=0 _addrelay=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true ;;
        --status)    _status=1 ;;
        --reset)     _reset=1 ;;
        --add-hop)   _addhop=1 ;;
        --add-relay) _addrelay=1 ;;
        --relay)     ROLE="relay" ;;
        --landing)   ROLE="landing" ;;
        --help|-h)
            echo "用法: bash port.sh [选项]"
            echo ""
            echo "  (无参数)      交互式完整配置（自动检测角色）"
            echo "  --relay       强制中转机模式"
            echo "  --landing     强制落地机模式"
            echo "  --status      查看当前防火墙规则与链路拓扑"
            echo "  --reset       清空所有规则（全部放行）"
            echo "  --add-hop     为落地机添加 Hysteria2 端口跳跃"
            echo "  --add-relay   为落地机追加中转机 IP 白名单"
            echo "  --dry-run     预览模式，不实际执行"
            echo ""
            echo "架构说明："
            echo "  用户 → 中转机(Xray入站) ──Xray出站──→ 落地机(Xray入站) → 互联网"
            exit 0 ;;
        *) err "未知参数: $1，使用 --help 查看帮助" ;;
    esac
    shift
done

# ============================================================
# 工具函数
# ============================================================

get_default_iface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' \
        || ip link show 2>/dev/null | awk -F': ' '/^[0-9]+: [^lo]/{print $2; exit}' \
        || echo "eth0"
}

get_public_ports() {
    ss -tulnp 2>/dev/null \
        | grep -vE '[[:space:]](127\.|::1)[^[:space:]]' \
        | grep -vE "($EXCLUDE_PROCS)" \
        | grep -oE '(\*|0\.0\.0\.0|\[?::\]?):[0-9]+' \
        | grep -oE '[0-9]+$' \
        | while read -r p; do
            [[ "$p" -lt 32768 ]] && echo "$p" || true
          done \
        | sort -un || true
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 && "$1" -le 65535 ]]
}

is_valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'; read -ra parts <<< "$1"
    for p in "${parts[@]}"; do (( p <= 255 )) || return 1; done
}

is_blacklisted() {
    local p=$1
    [[ "$p" == "$SSH_PORT" ]] && return 1
    for b in "${BLACKLIST_PORTS[@]}"; do [[ "$p" == "$b" ]] && return 0; done
    return 1
}

port_in_hop_range() {
    local p=$1
    for rule in "${HOP_RULES[@]:-}"; do
        [[ -z "$rule" ]] && continue
        local s e
        s=$(echo "$rule" | cut -d'-' -f1)
        e=$(echo "$rule" | cut -d'-' -f2 | cut -d'>' -f1 | tr -d '>')
        [[ "$p" -ge "$s" && "$p" -le "$e" ]] && return 0
    done
    return 1
}

add_relay_port() {
    local p=$1
    is_valid_port "$p"   || return 0
    is_blacklisted "$p"  && { warn "端口 $p 在黑名单，跳过"; return 0; }
    [[ " ${RELAY_INBOUND_PORTS[*]:-} " =~ " $p " ]] && return 0
    RELAY_INBOUND_PORTS+=("$p")
}

add_landing_port() {
    local p=$1
    is_valid_port "$p"           || return 0
    is_blacklisted "$p"          && { warn "端口 $p 在黑名单，跳过"; return 0; }
    port_in_hop_range "$p"       && return 0
    [[ " ${LANDING_PROXY_PORTS[*]:-} " =~ " $p " ]] && return 0
    LANDING_PROXY_PORTS+=("$p")
}

add_relay_ip() {
    local ip=$1
    is_valid_ip "$ip" || { warn "IP 格式无效: $ip，跳过"; return 0; }
    [[ " ${RELAY_WHITELIST[*]:-} " =~ " $ip " ]] && return 0
    RELAY_WHITELIST+=("$ip")
}

parse_hop() {
    local rule=$1
    HOP_S=$(echo "$rule" | cut -d'-' -f1)
    HOP_E=$(echo "$rule" | cut -d'-' -f2 | cut -d'>' -f1 | tr -d '>')
    HOP_T=$(echo "$rule" | grep -oE '[0-9]+$')
}

# ============================================================
# 初始化：禁用冲突防火墙 + 安装依赖 + sysctl
# ============================================================
install_deps() {
    info "初始化环境..."

    # 完全禁用 nftables（防止与 iptables 冲突）
    systemctl stop    nftables &>/dev/null || true
    systemctl disable nftables &>/dev/null || true
    systemctl mask    nftables &>/dev/null || true
    command -v nft &>/dev/null && nft flush ruleset 2>/dev/null || true
    [[ -f /etc/nftables.conf ]] && > /etc/nftables.conf || true
    ok "nftables 已禁用"

    # 禁用其他防火墙管理工具
    for svc in ufw firewalld; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            systemctl stop    "$svc" &>/dev/null || true
            systemctl disable "$svc" &>/dev/null || true
            systemctl mask    "$svc" &>/dev/null || true
            ok "已禁用 $svc"
        fi
    done

    # 安装缺失依赖
    local pkgs=()
    command -v iptables      &>/dev/null || pkgs+=(iptables)
    command -v iptables-save &>/dev/null || pkgs+=(iptables)
    command -v ss            &>/dev/null || pkgs+=(iproute2)
    command -v python3       &>/dev/null || pkgs+=(python3)

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        info "安装依赖: ${pkgs[*]}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq 2>/dev/null || true
            apt-get install -y -qq "${pkgs[@]}" iptables-persistent 2>/dev/null || \
            apt-get install -y -qq "${pkgs[@]}" 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf install -y iptables iptables-services iproute python3 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum install -y iptables iptables-services iproute python3 2>/dev/null || true
        fi
        command -v iptables &>/dev/null || err "iptables 安装失败，请手动安装"
    fi

    # 切换为 legacy 模式
    if command -v update-alternatives &>/dev/null; then
        update-alternatives --set iptables  /usr/sbin/iptables-legacy  &>/dev/null || true
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy &>/dev/null || true
        ok "iptables 已切换为 legacy 模式"
    fi

    # sysctl
    cat > /etc/sysctl.d/98-fw.conf << 'EOF'
# port.sh v7.0 - Xray chain proxy
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
    sysctl -p /etc/sysctl.d/98-fw.conf &>/dev/null || true
    ok "sysctl 配置完成"
}

# ── 检测 SSH 端口 ────────────────────────────────────────────
detect_ssh() {
    SSH_PORT=$(ss -tlnp 2>/dev/null \
        | grep sshd | grep -oE ':[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
    [[ -z "$SSH_PORT" ]] && \
        SSH_PORT=$(awk '/^Port /{print $2;exit}' /etc/ssh/sshd_config 2>/dev/null || true)
    [[ -z "$SSH_PORT" ]] && SSH_PORT=22
    ok "SSH 端口: $SSH_PORT"
}

# ============================================================
# 角色自动检测
# ============================================================
detect_role() {
    if [[ "$ROLE" != "auto" ]]; then
        ok "角色已手动指定: $ROLE"
        return
    fi

    # 优先级1：中转机 — 有 nodes.json 或 zhongzhuan_info
    if [[ -f "$NODES_FILE" ]] || [[ -f "$ZHONGZHUAN_INFO" ]]; then
        local nc=0
        [[ -f "$NODES_FILE" ]] && \
            nc=$(python3 -c "import json; d=json.load(open('$NODES_FILE')); print(len(d.get('nodes',[])))" 2>/dev/null || echo 0)
        ROLE="relay"
        ok "自动检测角色: 中转机 (relay) — 已对接 ${nc} 台落地机"
        return
    fi

    # 优先级2：落地机 — 有 luodi_info 或 v2ray-agent
    if [[ -f "$LUODI_INFO" ]] || \
       [[ -d /etc/v2ray-agent/xray/conf ]] || \
       [[ -d /etc/v2ray-agent/sing-box/conf ]]; then
        ROLE="landing"
        ok "自动检测角色: 落地机 (landing)"
        return
    fi

    # 默认询问
    echo ""
    echo -e "${Y}无法自动检测角色，请手动选择：${W}"
    echo "  1) 中转机 (relay)   — 用户连接此机，转发到落地机"
    echo "  2) 落地机 (landing) — 接受中转机连接，出口互联网"
    read -rp "选择 [1/2]: " _r
    case "${_r:-}" in
        1) ROLE="relay"   ;;
        2) ROLE="landing" ;;
        *) err "请输入 1 或 2" ;;
    esac
    ok "角色: $ROLE"
}

# ============================================================
# 中转机：检测用户侧入站端口
# ============================================================
detect_relay_ports() {
    info "读取中转机入站端口..."

    # 方法1：从 nodes.json 读取 duijie.sh 记录的端口
    if [[ -f "$NODES_FILE" ]]; then
        while read -r port; do
            [[ "$port" =~ ^[0-9]+$ ]] && add_relay_port "$port"
        done < <(python3 -c "
import json
with open('$NODES_FILE') as f:
    d = json.load(f)
for n in d.get('nodes', []):
    p = n.get('inbound_port')
    if p: print(p)
" 2>/dev/null || true)
    fi

    # 方法2：扫描 Xray 配置目录中的 relay_inbound_*.json
    local conf_dir
    conf_dir=$(grep "^ZHONGZHUAN_CONF_DIR=" "$ZHONGZHUAN_INFO" 2>/dev/null \
        | cut -d= -f2 | tr -d '[:space:]') || true
    conf_dir="${conf_dir:-/etc/v2ray-agent/xray/conf}"

    if [[ -d "$conf_dir" ]]; then
        for f in "$conf_dir"/relay_inbound_*.json; do
            [[ -f "$f" ]] || continue
            while read -r port; do
                add_relay_port "$port"
            done < <(python3 -c "
import json, sys
try:
    d = json.load(open('$f'))
    for ib in d.get('inbounds', []):
        p = ib.get('port')
        if isinstance(p, int): print(p)
except: pass
" 2>/dev/null || true)
        done
    fi

    # 方法3：ss 扫描当前 Xray 监听端口（兜底）
    while read -r port; do add_relay_port "$port"; done < <(get_public_ports)

    # 过滤掉 SSH 端口
    local filtered=()
    for p in "${RELAY_INBOUND_PORTS[@]:-}"; do
        [[ "$p" == "$SSH_PORT" ]] && continue
        filtered+=("$p")
    done
    RELAY_INBOUND_PORTS=("${filtered[@]:-}")

    if [[ ${#RELAY_INBOUND_PORTS[@]} -eq 0 ]]; then
        warn "未自动检测到入站端口，请手动输入"
        _ask_relay_ports
    else
        ok "检测到入站端口: ${RELAY_INBOUND_PORTS[*]}"
        echo ""
        read -rp "$(echo -e "${Y}手动补充额外入站端口（空格分隔，回车跳过）: ${W}")" _extra
        for p in ${_extra:-}; do add_relay_port "$p"; done
    fi
}

_ask_relay_ports() {
    echo ""
    read -rp "$(echo -e "${Y}请输入中转机用户侧入站端口（空格分隔）: ${W}")" _ports
    [[ -z "${_ports:-}" ]] && err "入站端口不能为空"
    for p in $_ports; do add_relay_port "$p"; done
}

# ============================================================
# 落地机：检测代理端口 + 收集中转机 IP 白名单
# ============================================================
detect_landing_config() {
    info "读取落地机配置..."

    # ── 步骤1：检测代理服务端口 ──────────────────────────────
    _detect_landing_ports

    # ── 步骤2：收集中转机 IP 白名单 ──────────────────────────
    _collect_relay_ips
}

_detect_landing_ports() {
    # 方法1：从 luodi_info 读取
    if [[ -f "$LUODI_INFO" ]]; then
        local p
        p=$(grep "^LUODI_PORT=" "$LUODI_INFO" | cut -d= -f2 | tr -d '[:space:]' || true)
        [[ -n "$p" ]] && add_landing_port "$p" && ok "从 luodi_info 读取端口: $p"
    fi

    # 方法2：扫描 v2ray-agent 配置文件
    for conf_dir in /etc/v2ray-agent/xray/conf \
                    /etc/v2ray-agent/sing-box/conf \
                    /etc/sing-box \
                    /usr/local/etc/sing-box; do
        [[ -d "$conf_dir" ]] || continue
        for f in "$conf_dir"/*.json; do
            [[ -f "$f" ]] || continue
            while read -r port; do
                add_landing_port "$port"
            done < <(python3 -c "
import json, sys
try:
    d = json.load(open('$f'))
    LOCAL = ('127.', '::1', 'localhost')
    for ib in d.get('inbounds', []) + d.get('inbound', []):
        if not isinstance(ib, dict): continue
        listen = str(ib.get('listen', ib.get('listen_field', '')) or '')
        if any(listen.startswith(x) for x in LOCAL): continue
        for key in ('port', 'listen_port'):
            p = ib.get(key)
            if isinstance(p, int) and 1 <= p <= 65535:
                print(p)
except: pass
" 2>/dev/null || true)
        done
    done

    # 方法3：ss 扫描（兜底）
    while read -r port; do add_landing_port "$port"; done < <(get_public_ports)

    # 过滤 SSH
    local filtered=()
    for p in "${LANDING_PROXY_PORTS[@]:-}"; do
        [[ "$p" == "$SSH_PORT" ]] && continue
        filtered+=("$p")
    done
    LANDING_PROXY_PORTS=("${filtered[@]:-}")

    if [[ ${#LANDING_PROXY_PORTS[@]} -eq 0 ]]; then
        warn "未自动检测到代理端口，请手动输入"
        read -rp "$(echo -e "${Y}代理端口（空格分隔）: ${W}")" _ports
        for p in ${_ports:-}; do add_landing_port "$p"; done
    else
        ok "检测到代理端口: ${LANDING_PROXY_PORTS[*]}"
        echo ""
        read -rp "$(echo -e "${Y}手动补充额外端口（回车跳过）: ${W}")" _extra
        for p in ${_extra:-}; do add_landing_port "$p"; done
    fi
}

_collect_relay_ips() {
    echo ""
    hr
    echo -e "${C}   配置中转机 IP 白名单${W}"
    hr
    echo -e "  落地机代理端口将 ${R}只允许白名单内的中转机 IP 访问${W}"
    echo -e "  其他 IP（包括黑客扫描）会被直接 DROP"
    echo ""

    # 从 luodi_info 尝试读取（目前未存 relay IP，显示提示）
    if [[ -f "$LUODI_INFO" ]]; then
        local relay_ip
        relay_ip=$(grep "^RELAY_IP=" "$LUODI_INFO" 2>/dev/null \
            | cut -d= -f2 | tr -d '[:space:]' || true)
        if [[ -n "$relay_ip" ]]; then
            ok "从 luodi_info 检测到中转机 IP: $relay_ip"
            add_relay_ip "$relay_ip"
        fi
    fi

    # 交互输入（支持多个）
    local idx=1
    while true; do
        if [[ ${#RELAY_WHITELIST[@]} -gt 0 ]]; then
            echo -e "  已添加: ${G}${RELAY_WHITELIST[*]}${W}"
            echo ""
            read -rp "$(echo -e "${Y}继续添加中转机 IP？（回车结束）: ${W}")" _ip
        else
            read -rp "$(echo -e "${Y}输入第 ${idx} 台中转机的 IP: ${W}")" _ip
        fi

        [[ -z "${_ip:-}" ]] && break

        if is_valid_ip "$_ip"; then
            add_relay_ip "$_ip"
            ok "已添加: $_ip"
            (( idx++ ))
        else
            warn "IP 格式无效: $_ip（示例: 185.201.226.132）"
        fi
    done

    if [[ ${#RELAY_WHITELIST[@]} -eq 0 ]]; then
        echo ""
        warn "未添加任何中转机 IP！"
        echo -e "${Y}选择处理方式：${W}"
        echo "  1) 代理端口完全开放（任意 IP 可访问，安全性低）"
        echo "  2) 重新输入中转机 IP"
        read -rp "选择 [1/2]: " _c
        case "${_c:-}" in
            2) _collect_relay_ips ;;
            *) warn "代理端口将完全开放（无 IP 限制）" ;;
        esac
    fi
}

# ============================================================
# 从已有规则提取端口跳跃配置（保留已有设置）
# ============================================================
detect_existing_hop_rules() {
    while IFS= read -r line; do
        [[ "$line" == *DNAT* ]] || continue
        local range target
        range=$(echo "$line" | grep -oE 'dpts:[0-9]+:[0-9]+' \
                | grep -oE '[0-9]+:[0-9]+' | tr ':' '-')
        target=$(echo "$line" | grep -oE 'to::[0-9]+' | grep -oE '[0-9]+$')
        [[ -n "$range" && -n "$target" ]] || continue
        local rule="${range}->${target}"
        [[ " ${HOP_RULES[*]:-} " =~ " ${rule} " ]] || HOP_RULES+=("$rule")
    done < <(iptables -t nat -L PREROUTING -n 2>/dev/null || true)
}

# ============================================================
# 清理旧规则
# ============================================================
flush_rules() {
    info "清理旧 iptables 规则..."
    iptables  -P INPUT   ACCEPT 2>/dev/null || true
    iptables  -P FORWARD ACCEPT 2>/dev/null || true
    iptables  -P OUTPUT  ACCEPT 2>/dev/null || true
    iptables  -F         2>/dev/null || true
    iptables  -X         2>/dev/null || true
    iptables  -t nat    -F 2>/dev/null || true
    iptables  -t nat    -X 2>/dev/null || true
    iptables  -t mangle -F 2>/dev/null || true
    iptables  -t raw    -F 2>/dev/null || true
    ip6tables -P INPUT   ACCEPT 2>/dev/null || true
    ip6tables -P FORWARD ACCEPT 2>/dev/null || true
    ip6tables -P OUTPUT  ACCEPT 2>/dev/null || true
    ip6tables -F         2>/dev/null || true
    ip6tables -t nat    -F 2>/dev/null || true
    ok "旧规则已清空"
}

# ============================================================
# 端口跳跃 NAT（落地机 Hysteria2 用）
# ============================================================
apply_hop_rule() {
    local s=$1 e=$2 t=$3

    # 删除同范围旧规则
    local nums
    nums=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null \
        | grep "dpts:${s}:${e}" | awk '{print $1}' | sort -rn || true)
    for n in $nums; do
        iptables -t nat -D PREROUTING "$n" 2>/dev/null || true
    done

    iptables -t nat -A PREROUTING -p udp --dport "${s}:${e}" \
        -j DNAT --to-destination ":${t}"
    iptables -t nat -A PREROUTING -p tcp --dport "${s}:${e}" \
        -j DNAT --to-destination ":${t}"

    iptables -C INPUT -p udp --dport "${s}:${e}" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p udp --dport "${s}:${e}" -j ACCEPT
    iptables -C INPUT -p tcp --dport "${s}:${e}" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "${s}:${e}" -j ACCEPT
}

# ============================================================
# 核心：应用防火墙规则
# ============================================================
apply_rules() {
    local wan_iface
    wan_iface=$(get_default_iface)
    info "出口网卡: $wan_iface"

    if [[ "$DRY_RUN" == true ]]; then
        hr
        info "[预览模式] 以下配置不会实际应用"
        info "角色        : $ROLE"
        info "SSH 端口    : $SSH_PORT"
        case "$ROLE" in
            relay)
                info "入站端口    : ${RELAY_INBOUND_PORTS[*]:-无}"
                ;;
            landing)
                info "代理端口    : ${LANDING_PROXY_PORTS[*]:-无}"
                info "中转机白名单: ${RELAY_WHITELIST[*]:-（全开放）}"
                for rule in "${HOP_RULES[@]:-}"; do
                    [[ -z "$rule" ]] && continue
                    parse_hop "$rule"
                    info "端口跳跃    : ${HOP_S}-${HOP_E} → ${HOP_T}"
                done
                ;;
        esac
        hr
        return 0
    fi

    flush_rules

    # ════════════════════════════════════════════════════════
    # 通用基础规则
    # ════════════════════════════════════════════════════════
    info "应用基础规则..."

    iptables -P INPUT   DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT  ACCEPT

    # 本地回环
    iptables -A INPUT -i lo -j ACCEPT

    # 已建立/关联连接
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # ICMP 限速
    iptables -A INPUT -p icmp --icmp-type echo-request \
        -m limit --limit 10/sec --limit-burst 20 -j ACCEPT
    iptables -A INPUT -p icmp -j DROP

    # SSH 防暴力破解（60秒内超过6次新连接则丢弃）
    iptables -N SSH_PROTECT 2>/dev/null || iptables -F SSH_PROTECT
    iptables -A SSH_PROTECT -m recent --name SSH_BF --set
    iptables -A SSH_PROTECT -m recent --name SSH_BF \
        --update --seconds 60 --hitcount 6 -j DROP
    iptables -A SSH_PROTECT -j ACCEPT
    iptables -A INPUT -p tcp --dport "$SSH_PORT" \
        -m conntrack --ctstate NEW -j SSH_PROTECT

    ok "基础规则已应用（SSH: $SSH_PORT 防暴力）"

    # ════════════════════════════════════════════════════════
    # 角色专用规则
    # ════════════════════════════════════════════════════════
    case "$ROLE" in
        relay)   _apply_relay_rules   ;;
        landing) _apply_landing_rules "$wan_iface" ;;
    esac

    # 兜底丢弃 + 日志
    iptables -A INPUT -m limit --limit 3/min -j LOG \
        --log-prefix "[FW-DROP] " --log-level 4
    iptables -A INPUT -j DROP

    ok "所有规则应用完成"
}

# ── 中转机规则 ──────────────────────────────────────────────
# 架构：用户 → 中转机 Xray 入站 → Xray 出站 → 落地机
# Xray 是应用层转发，iptables 只需：
#   1. 放行用户连接的入站端口（TCP）
#   2. OUTPUT ACCEPT（Xray 主动连落地机，默认已放行）
#   无需 FORWARD 或 MASQUERADE
_apply_relay_rules() {
    info "应用中转机规则..."

    if [[ ${#RELAY_INBOUND_PORTS[@]} -eq 0 ]]; then
        warn "没有入站端口，中转机将无法服务用户"
    fi

    for port in "${RELAY_INBOUND_PORTS[@]:-}"; do
        [[ -z "$port" ]] && continue
        iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
        ok "放行用户入站: TCP $port"
    done

    # FORWARD：仅放行已建立连接（保险措施，理论上 Xray 不走 FORWARD）
    iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    ok "中转机规则完成（${#RELAY_INBOUND_PORTS[@]} 个入站端口）"
    echo ""
    echo -e "${Y}架构提示：${W}"
    echo -e "  Xray 在应用层完成转发，不经过内核 FORWARD"
    echo -e "  OUTPUT 默认 ACCEPT，Xray 主动连接落地机无需额外规则"
    echo -e "  安全组/VPC 层面还需放行这些端口: ${RELAY_INBOUND_PORTS[*]:-无}"
}

# ── 落地机规则 ──────────────────────────────────────────────
# 架构：中转机 → 落地机 Xray 入站 → 代理出互联网
# 关键安全设计：
#   1. 代理端口只允许白名单中转机 IP 访问（IP 白名单）
#   2. MASQUERADE：落地机作为出口，用本机 IP 出互联网
#   3. 端口跳跃 NAT（如有 Hysteria2）
_apply_landing_rules() {
    local wan_iface=$1
    info "应用落地机规则..."

    if [[ ${#LANDING_PROXY_PORTS[@]} -eq 0 ]]; then
        warn "没有代理端口！"
    fi

    # 代理端口：根据是否有白名单决定策略
    for port in "${LANDING_PROXY_PORTS[@]:-}"; do
        [[ -z "$port" ]] && continue

        if [[ ${#RELAY_WHITELIST[@]} -gt 0 ]]; then
            # 有白名单：只允许指定中转机 IP 访问
            for relay_ip in "${RELAY_WHITELIST[@]}"; do
                iptables -A INPUT -p tcp -s "$relay_ip" --dport "$port" -j ACCEPT
                ok "代理端口 TCP $port ← 仅允许 $relay_ip"
            done
            # 明确拒绝其他 IP（记录日志，方便排查）
            iptables -A INPUT -p tcp --dport "$port" \
                -m limit --limit 5/min -j LOG \
                --log-prefix "[BLOCKED-$port] " --log-level 4
            iptables -A INPUT -p tcp --dport "$port" -j DROP
        else
            # 无白名单：全开放（安全性低，已提示用户）
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            iptables -A INPUT -p udp --dport "$port" -j ACCEPT
            warn "代理端口 $port 完全开放（建议配置中转机 IP 白名单）"
        fi
    done

    # FORWARD：允许已建立连接和 DNAT 后的包通过
    iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -m conntrack --ctstate DNAT -j ACCEPT

    # MASQUERADE：落地机代理出互联网，用本机 IP 出站
    iptables -t nat -A POSTROUTING -o "$wan_iface" -j MASQUERADE
    ok "MASQUERADE 已启用 → $wan_iface"

    # 端口跳跃（Hysteria2 用）
    if [[ ${#HOP_RULES[@]} -gt 0 ]]; then
        for rule in "${HOP_RULES[@]:-}"; do
            [[ -z "$rule" ]] && continue
            parse_hop "$rule"
            [[ -z "${HOP_S:-}" || -z "${HOP_E:-}" || -z "${HOP_T:-}" ]] && continue
            apply_hop_rule "$HOP_S" "$HOP_E" "$HOP_T"
            ok "端口跳跃: ${HOP_S}-${HOP_E} → :${HOP_T}"
        done
    fi

    ok "落地机规则完成"
}

# ============================================================
# 持久化
# ============================================================
save_rules() {
    [[ "$DRY_RUN" == true ]] && return 0

    mkdir -p /etc/iptables
    iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save &>/dev/null || true
        ok "规则已通过 netfilter-persistent 持久化"
        return 0
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q "^iptables\.service"; then
        systemctl enable iptables &>/dev/null || true
        service iptables save &>/dev/null || true
        ok "规则已通过 iptables-services 持久化"
        return 0
    fi

    cat > /etc/systemd/system/iptables-restore.service << 'SVC'
[Unit]
Description=Restore iptables rules (port.sh v7.0)
Before=network-pre.target
Wants=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'iptables-restore < /etc/iptables/rules.v4; ip6tables-restore < /etc/iptables/rules.v6 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload &>/dev/null || true
    systemctl enable iptables-restore.service &>/dev/null || true
    ok "规则已保存至 /etc/iptables/rules.v4，开机自动恢复"
}

# ============================================================
# 确认界面
# ============================================================
show_confirm() {
    hr
    echo -e "${G}   配置预览（角色: ${ROLE}）${W}"
    hr
    echo -e "${C}SSH 端口   :${W} $SSH_PORT  ${Y}（防暴力破解已开启）${W}"

    case "$ROLE" in
        relay)
            echo -e "${C}角色       :${W} 中转机 (relay)"
            echo -e "${C}用户入站端口:${W}"
            if [[ ${#RELAY_INBOUND_PORTS[@]} -gt 0 ]]; then
                for p in "${RELAY_INBOUND_PORTS[@]}"; do
                    echo -e "  ${G}•${W} TCP $p"
                done
            else
                echo -e "  ${Y}无（中转机将无法服务用户）${W}"
            fi
            echo ""
            echo -e "  ${Y}注：中转机使用 Xray 应用层转发，无需 FORWARD/MASQUERADE${W}"
            ;;
        landing)
            echo -e "${C}角色       :${W} 落地机 (landing)"
            echo -e "${C}代理端口   :${W}"
            for p in "${LANDING_PROXY_PORTS[@]:-}"; do
                echo -e "  ${G}•${W} TCP $p"
            done
            echo -e "${C}中转机白名单:${W}"
            if [[ ${#RELAY_WHITELIST[@]} -gt 0 ]]; then
                for ip in "${RELAY_WHITELIST[@]}"; do
                    echo -e "  ${G}•${W} $ip  ${G}（仅此 IP 可访问代理端口）${W}"
                done
            else
                echo -e "  ${Y}无限制（代理端口完全开放）${W}"
            fi
            if [[ ${#HOP_RULES[@]} -gt 0 ]]; then
                echo -e "${C}端口跳跃   :${W}"
                for rule in "${HOP_RULES[@]:-}"; do
                    [[ -z "$rule" ]] && continue
                    parse_hop "$rule"
                    echo -e "  ${G}•${W} ${HOP_S}-${HOP_E} → ${HOP_T}"
                done
            fi
            echo -e "${C}MASQUERADE :${W} 启用（出口 NAT）"
            ;;
    esac
    hr
}

# ============================================================
# 完成摘要
# ============================================================
show_summary() {
    hr
    echo -e "${G}🎉 防火墙配置完成！${W}"
    hr
    echo -e "${C}角色       :${W} $ROLE"
    echo -e "${C}SSH 端口   :${W} $SSH_PORT（防暴力）"
    case "$ROLE" in
        relay)
            echo -e "${C}入站端口   :${W} ${RELAY_INBOUND_PORTS[*]:-无}"
            echo ""
            echo -e "${Y}链路：用户 → 本机:PORT → Xray → 落地机${W}"
            ;;
        landing)
            echo -e "${C}代理端口   :${W} ${LANDING_PROXY_PORTS[*]:-无}"
            echo -e "${C}中转机白名单:${W} ${RELAY_WHITELIST[*]:-全开放}"
            if [[ ${#HOP_RULES[@]} -gt 0 ]]; then
                echo -e "${C}端口跳跃   :${W}"
                for rule in "${HOP_RULES[@]:-}"; do
                    [[ -z "$rule" ]] && continue
                    parse_hop "$rule"
                    echo -e "  • ${HOP_S}-${HOP_E} → ${HOP_T}"
                done
            fi
            echo ""
            echo -e "${Y}链路：中转机 → 本机:PORT → Xray → 互联网${W}"
            ;;
    esac
    hr
    echo -e "${Y}常用命令:${W}"
    echo "  查看状态      : bash port.sh --status"
    echo "  添加中转机IP  : bash port.sh --add-relay"
    echo "  添加端口跳跃  : bash port.sh --add-hop"
    echo "  重置防火墙    : bash port.sh --reset"
    echo "  查看 INPUT 规则: iptables -L INPUT -n -v"
    hr
}

# ============================================================
# --status：显示当前状态与链路拓扑
# ============================================================
show_status() {
    hr
    echo -e "${C}   Xray 链式代理防火墙状态${W}"
    hr

    echo -e "${G}▸ 角色检测:${W}"
    detect_role 2>/dev/null || true
    echo "  • 当前角色: $ROLE"

    echo -e "\n${G}▸ iptables 后端:${W}"
    if command -v iptables &>/dev/null; then
        local ver; ver=$(iptables --version 2>/dev/null | head -1)
        echo "  • $ver"
        [[ "$ver" == *"legacy"* ]] \
            && ok "  使用 legacy 后端（正确）" \
            || warn "  可能使用 nft 后端，建议切换"
    fi

    echo -e "\n${G}▸ nftables（应为禁用）:${W}"
    systemctl is-active nftables &>/dev/null \
        && warn "  nftables 仍在运行！可能与 iptables 冲突" \
        || ok   "  nftables 已禁用"

    echo -e "\n${G}▸ INPUT 放行规则:${W}"
    iptables -L INPUT -n --line-numbers 2>/dev/null \
        | grep -v "^num\|^Chain\|^target\|^$" \
        | sed 's/^/  /' \
        || echo "  无规则"

    echo -e "\n${G}▸ POSTROUTING NAT（落地机出口）:${W}"
    iptables -t nat -L POSTROUTING -n 2>/dev/null \
        | grep -v "^target\|^Chain\|^$" \
        | sed 's/^/  /' \
        || echo "  无"

    echo -e "\n${G}▸ 端口跳跃 PREROUTING：${W}"
    local has_hop=0
    while IFS= read -r line; do
        [[ "$line" == *DNAT* ]] || continue
        echo "  • $line"
        has_hop=1
    done < <(iptables -t nat -L PREROUTING -n 2>/dev/null || true)
    [[ $has_hop -eq 0 ]] && echo "  无"

    echo -e "\n${G}▸ 公网监听端口（ss）:${W}"
    local found=0
    while read -r p; do
        local proc
        proc=$(ss -tulnp 2>/dev/null | grep ":${p}[^0-9]" \
            | grep -oE '"[^"]+"' | head -1 | tr -d '"' || true)
        printf "  • %-6s %s\n" "$p" "${proc:-(未知)}"
        found=1
    done < <(get_public_ports)
    [[ $found -eq 0 ]] && echo "  无公网监听端口"

    echo -e "\n${G}▸ Xray 链路拓扑:${W}"
    if [[ -f "$NODES_FILE" ]]; then
        python3 - << PYEOF 2>/dev/null || echo "  解析失败"
import json
with open("$NODES_FILE") as f:
    d = json.load(f)
nodes = d.get("nodes", [])
if not nodes:
    print("  无已对接落地机")
else:
    print(f"  中转机已对接 {len(nodes)} 台落地机：")
    for n in nodes:
        tag   = n.get('tag','-')
        lport = n.get('luodi_port','-')
        iport = n.get('inbound_port','-')
        lip   = n.get('luodi_ip','-')
        print(f"  • 用户端口 {iport} → 落地机 {lip}:{lport}  [{tag}]")
PYEOF
    elif [[ -f "$LUODI_INFO" ]]; then
        local lip lport
        lip=$(grep "^LUODI_IP="   "$LUODI_INFO" | cut -d= -f2 || true)
        lport=$(grep "^LUODI_PORT=" "$LUODI_INFO" | cut -d= -f2 || true)
        echo "  本机是落地机，IP: ${lip:-?}，代理端口: ${lport:-?}"
    else
        echo "  无链路信息文件"
    fi

    echo -e "\n${G}▸ sysctl 关键参数:${W}"
    for param in net.ipv4.ip_forward net.ipv4.conf.all.rp_filter; do
        printf "  • %-40s = %s\n" "$param" \
            "$(sysctl -n "$param" 2>/dev/null || echo 未知)"
    done

    hr
}

# ============================================================
# --reset：清空所有规则
# ============================================================
do_reset() {
    echo -e "${R}⚠ 将清空所有防火墙规则并全部放行，确认？[y/N]: ${W}"
    read -r ans
    [[ "${ans,,}" == y ]] || { info "已取消"; exit 0; }

    iptables  -P INPUT   ACCEPT; iptables  -P FORWARD ACCEPT; iptables  -P OUTPUT  ACCEPT
    iptables  -F; iptables  -X
    iptables  -t nat    -F; iptables  -t nat    -X
    iptables  -t mangle -F; iptables  -t raw    -F
    ip6tables -P INPUT   ACCEPT 2>/dev/null || true
    ip6tables -P FORWARD ACCEPT 2>/dev/null || true
    ip6tables -P OUTPUT  ACCEPT 2>/dev/null || true
    ip6tables -F 2>/dev/null || true
    ip6tables -t nat -F 2>/dev/null || true

    save_rules
    ok "防火墙已重置，所有流量放行"
}

# ============================================================
# --add-hop：为落地机追加端口跳跃
# ============================================================
add_hop_interactive() {
    detect_ssh
    hr
    echo -e "${C}添加端口跳跃规则（Hysteria2 portHopping）${W}"
    hr
    echo "说明：客户端在端口范围内随机连接，服务器 DNAT 到代理实际端口"
    echo ""
    read -rp "$(echo -e "${Y}端口范围（如 20000-50000）: ${W}")" hop_range
    read -rp "$(echo -e "${Y}目标端口（代理实际监听端口，如 8443）: ${W}")" target_port

    [[ "$hop_range"   =~ ^[0-9]+-[0-9]+$ ]] || err "范围格式错误，示例: 20000-50000"
    [[ "$target_port" =~ ^[0-9]+$         ]] || err "目标端口格式错误"

    local s e
    s=$(echo "$hop_range" | cut -d- -f1)
    e=$(echo "$hop_range" | cut -d- -f2)
    [[ "$s" -ge "$e" ]] && err "起始端口须小于结束端口"

    apply_hop_rule "$s" "$e" "$target_port"
    save_rules
    ok "端口跳跃 ${hop_range} → ${target_port} 添加成功"
}

# ============================================================
# --add-relay：为落地机追加新中转机 IP 白名单
# ============================================================
add_relay_interactive() {
    detect_ssh
    hr
    echo -e "${C}为落地机追加中转机 IP 白名单${W}"
    hr

    read -rp "$(echo -e "${Y}新中转机 IP: ${W}")" new_ip
    is_valid_ip "$new_ip" || err "IP 格式无效: $new_ip"

    # 检测已有代理端口（从当前 INPUT 规则中读取）
    local ports=()
    while read -r port; do
        ports+=("$port")
    done < <(iptables -L INPUT -n 2>/dev/null \
        | grep "^ACCEPT" | grep -oE 'dpt:[0-9]+' | grep -oE '[0-9]+' \
        | grep -v "^${SSH_PORT}$" | sort -un || true)

    if [[ ${#ports[@]} -eq 0 ]]; then
        read -rp "$(echo -e "${Y}请输入代理端口（空格分隔）: ${W}")" _ports
        for p in ${_ports:-}; do ports+=("$p"); done
    fi

    echo "  代理端口: ${ports[*]:-无}"
    echo "  添加 IP: $new_ip"
    read -rp "确认？[y/N]: " _c
    [[ "${_c,,}" == y ]] || { info "已取消"; exit 0; }

    for port in "${ports[@]:-}"; do
        [[ -z "$port" ]] && continue
        iptables -A INPUT -p tcp -s "$new_ip" --dport "$port" -j ACCEPT
        ok "已添加: TCP $port ← $new_ip"
    done

    save_rules
    ok "白名单更新完成"
}

# ============================================================
# 主流程
# ============================================================
main() {
    trap 'echo -e "\n${R}已中断${W}"; exit 130' INT TERM
    hr
    echo -e "${G}   iptables 防火墙 v${VERSION} — Xray 链式代理专用${W}"
    hr

    [[ $_status   -eq 1 ]] && { detect_ssh; show_status;       exit 0; }
    [[ $_reset    -eq 1 ]] && { do_reset;                       exit 0; }
    [[ $_addhop   -eq 1 ]] && { add_hop_interactive;            exit 0; }
    [[ $_addrelay -eq 1 ]] && { add_relay_interactive;          exit 0; }

    # ── 完整配置流程 ─────────────────────────────────────────
    install_deps
    detect_ssh
    detect_role

    case "$ROLE" in
        relay)
            detect_relay_ports
            detect_existing_hop_rules   # 保留已有跳跃规则
            ;;
        landing)
            detect_existing_hop_rules   # 先读已有跳跃规则
            _detect_landing_ports
            _collect_relay_ips
            ;;
    esac

    # 显示确认界面
    show_confirm

    echo ""
    read -rp "$(echo -e "${Y}确认应用以上配置？[y/N]: ${W}")" ans
    [[ "${ans,,}" == y ]] || { info "已取消，未做任何修改"; exit 0; }

    apply_rules
    save_rules
    show_summary
}

main "$@"
