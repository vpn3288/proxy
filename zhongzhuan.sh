#!/bin/bash
# ============================================================
# zhongzhuan.sh v5.2 — 中转机初始化脚本
# 功能：安装独立 xray-relay 服务，生成 Reality 密钥
#       初始化空配置，供 duijie.sh 逐步添加落地机
# 用法：bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/zhongzhuan.sh)
#
# v5.2 新增：
#   - --status 快速查看当前状态（无需重新初始化）
#   - 重复运行时显示已对接节点数量
#   - IP 变更时自动更新 INFO_FILE（保留其他所有配置）
#   - 端口检查：已用端口自动跳过，防重复分配
#   - save_info() 仅更新 IP/时间，不覆盖已有字段（IS_FIRST_RUN=false）
# ============================================================
# 架构说明：
#   中转机运行两个独立进程：
#   ① xray.service       — v2ray-agent 管理，中转机自身对外节点
#   ② xray-relay.service — 本脚本创建，专门处理 用户→中转→落地 流量
#   两者完全隔离，mack-a 任何操作不影响 xray-relay
# ============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
log_step()  { echo -e "${CYAN}[→]${NC} $1"; }

[[ $EUID -ne 0 ]] && log_error "请使用 root 权限运行"

RELAY_CONF_DIR="/usr/local/etc/xray-relay"
RELAY_CONFIG="$RELAY_CONF_DIR/config.json"
RELAY_NODES="$RELAY_CONF_DIR/nodes.json"
RELAY_LOG_DIR="/var/log/xray-relay"
RELAY_SERVICE="/etc/systemd/system/xray-relay.service"
INFO_FILE="/root/xray_zhongzhuan_info.txt"

XRAY_BIN="" PUBLIC_IP=""
RELAY_PRIVKEY="" RELAY_PUBKEY="" RELAY_SHORT_ID="" RELAY_SNI=""
RELAY_DEST=""
START_PORT="" MAX_NODES=""
IS_FIRST_RUN=true

# ============================================================
# --status 模式：快速查看，不做任何修改
# ============================================================
cmd_status() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       中转机状态  zhongzhuan.sh  v5.2              ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    # xray-relay 服务状态
    local svc_status
    svc_status=$(systemctl is-active xray-relay 2>/dev/null || echo "未安装")
    echo -e "  ${BOLD}xray-relay 状态 :${NC} $svc_status"

    # 读取 info 文件
    if [[ -f "$INFO_FILE" ]]; then
        local ip pub sni sid start max
        ip=$(grep  "^ZHONGZHUAN_IP="         "$INFO_FILE" | cut -d= -f2-)
        pub=$(grep "^ZHONGZHUAN_PUBKEY="     "$INFO_FILE" | cut -d= -f2-)
        sni=$(grep "^ZHONGZHUAN_SNI="        "$INFO_FILE" | cut -d= -f2-)
        sid=$(grep "^ZHONGZHUAN_SHORT_ID="   "$INFO_FILE" | cut -d= -f2-)
        start=$(grep "^ZHONGZHUAN_START_PORT=" "$INFO_FILE" | cut -d= -f2-)
        max=$(grep "^ZHONGZHUAN_MAX_NODES="  "$INFO_FILE" | cut -d= -f2-)
        echo -e "  ${BOLD}中转机 IP       :${NC} $ip"
        echo -e "  ${BOLD}公钥            :${NC} ${pub:0:24}..."
        echo -e "  ${BOLD}SNI             :${NC} $sni"
        echo -e "  ${BOLD}Short ID        :${NC} $sid"
        echo -e "  ${BOLD}端口范围        :${NC} $start ~ $(( start + max - 1 ))（共 $max 个）"
    else
        echo -e "  ${YELLOW}尚未运行 zhongzhuan.sh 初始化${NC}"
    fi

    # 已对接节点
    local nc=0
    if [[ -f "$RELAY_CONFIG" ]]; then
        nc=$(python3 -c "
import json
try:
    c = json.load(open('$RELAY_CONFIG'))
    print(len(c.get('inbounds', [])))
except: print(0)" 2>/dev/null || echo 0)
    fi
    if [[ -f "$RELAY_NODES" ]]; then
        echo -e "  ${BOLD}已对接落地机    :${NC} ${nc} 台"
        if [[ $nc -gt 0 ]]; then
            python3 - "$RELAY_NODES" << 'PYEOF' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    nodes = data.get("nodes", [])
    for i, n in enumerate(nodes, 1):
        lid  = n.get("link_id", "?")
        port = n.get("relay_port", n.get("port", "?"))
        ip   = n.get("luodi_ip", "?")
        lbl  = n.get("label", "")
        print(f"    [{i}] 端口={port}  落地={ip}  LINK_ID={lid}  {lbl}")
except Exception as e:
    pass
PYEOF
        fi
    fi

    # 最近日志
    echo ""
    echo -e "  ${YELLOW}最近错误日志（最多5条）：${NC}"
    journalctl -u xray-relay -p err -n 5 --no-pager 2>/dev/null | \
        grep -v "^-- " | tail -5 || echo "    （无错误日志）"
    echo ""
}

# ── 查找或安装 Xray ───────────────────────────────────────
find_or_install_xray() {
    log_step "查找 Xray 二进制..."
    for p in /etc/v2ray-agent/xray/xray /usr/local/bin/xray \
              /usr/bin/xray /opt/xray/xray; do
        [[ -x "$p" ]] && { XRAY_BIN="$p"; log_info "Xray: $XRAY_BIN"; return 0; }
    done
    local w; w=$(command -v xray 2>/dev/null || true)
    [[ -n "$w" ]] && { XRAY_BIN="$w"; log_info "Xray: $XRAY_BIN"; return 0; }

    log_warn "未找到 Xray，自动安装..."

    if ! command -v unzip &>/dev/null; then
        log_step "安装 unzip..."
        apt-get install -y -qq unzip 2>/dev/null || \
            log_error "unzip 安装失败，请手动执行: apt-get install -y unzip"
    fi

    if bash -c "$(curl -fsSL \
        https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
        @ install 2>/dev/null; then
        log_info "Xray 官方脚本安装成功"
    else
        log_warn "官方脚本安装失败，尝试手动下载..."
        local arch; arch=$(uname -m)
        local arch_tag
        case "$arch" in
            x86_64)  arch_tag="64"          ;;
            aarch64) arch_tag="arm64-v8a"   ;;
            armv7*)  arch_tag="arm32-v7a"   ;;
            *)       log_error "不支持的架构: $arch" ;;
        esac
        local VER
        VER=$(curl -s \
            https://api.github.com/repos/XTLS/Xray-core/releases/latest \
            | grep '"tag_name"' | cut -d'"' -f4)
        [[ -z "$VER" ]] && \
            log_error "无法获取 Xray 版本号，请手动安装后重试"
        local URL
        URL="https://github.com/XTLS/Xray-core/releases/download/${VER}/Xray-linux-${arch_tag}.zip"
        curl -fsSL "$URL" -o /tmp/xray.zip || \
            log_error "下载失败，请检查网络"
        mkdir -p /usr/local/bin
        unzip -o /tmp/xray.zip xray -d /usr/local/bin/ >/dev/null
        chmod +x /usr/local/bin/xray
        rm -f /tmp/xray.zip
        log_info "Xray 手动安装完成"
    fi

    XRAY_BIN=$(command -v xray 2>/dev/null || echo "/usr/local/bin/xray")
    [[ -x "$XRAY_BIN" ]] || log_error "Xray 安装失败，请手动安装后重试"
    log_info "Xray: $XRAY_BIN ($("$XRAY_BIN" version 2>/dev/null | head -1))"
}

# ── 重复运行时保留已有密钥 ────────────────────────────────
load_or_generate_relay_keys() {
    log_step "处理 Reality 密钥..."

    if [[ -f "$INFO_FILE" ]]; then
        local saved_privkey saved_pubkey saved_shortid saved_sni
        while IFS='=' read -r key val; do
            val=$(echo "$val" | tr -d '\r')
            case "$key" in
                ZHONGZHUAN_PRIVKEY)  saved_privkey="$val"  ;;
                ZHONGZHUAN_PUBKEY)   saved_pubkey="$val"   ;;
                ZHONGZHUAN_SHORT_ID) saved_shortid="$val"  ;;
                ZHONGZHUAN_SNI)      saved_sni="$val"      ;;
            esac
        done < "$INFO_FILE"

        if [[ -n "$saved_privkey" && -n "$saved_pubkey" ]]; then
            IS_FIRST_RUN=false
            echo ""
            echo -e "${YELLOW}══ 检测到已有中转机密钥 ══${NC}"
            echo -e "  公钥: $saved_pubkey"
            echo -e "  SNI : $saved_sni"
            echo ""
            echo -e "${RED}警告：重新生成密钥将导致所有已对接节点链接全部失效！${NC}"
            echo -e "  已对接的节点需要重新运行 duijie.sh 才能恢复。"
            echo ""
            read -rp "保留已有密钥（强烈建议）？[Y/n]: " yn
            if [[ "${yn,,}" != "n" ]]; then
                RELAY_PRIVKEY="$saved_privkey"
                RELAY_PUBKEY="$saved_pubkey"
                RELAY_SHORT_ID="$saved_shortid"
                RELAY_SNI="$saved_sni"
                log_info "已保留现有密钥，现有节点链接继续有效"
                return 0
            fi
            log_warn "已选择重新生成密钥，所有现有节点链接将失效"
        fi
    fi

    log_step "生成中转机 Reality 密钥..."
    local key_out
    key_out=$("$XRAY_BIN" x25519 2>&1)

    RELAY_PRIVKEY=$(echo "$key_out" | grep -iE "^Private" \
        | awk '{print $NF}' | tr -d '[:space:]' | head -1)
    RELAY_PUBKEY=$(echo "$key_out" | grep -iE "^(Public key|Password)" \
        | awk '{print $NF}' | tr -d '[:space:]' | head -1)
    if [[ -z "$RELAY_PRIVKEY" ]]; then
        RELAY_PRIVKEY=$(echo "$key_out" | awk 'NR==1{print $NF}')
        RELAY_PUBKEY=$(echo  "$key_out" | awk 'NR==2{print $NF}')
    fi
    [[ -z "$RELAY_PRIVKEY" || -z "$RELAY_PUBKEY" ]] && \
        log_error "密钥生成失败，输出:\n$key_out"

    RELAY_SHORT_ID=$(openssl rand -hex 4 2>/dev/null || \
        python3 -c "import secrets; print(secrets.token_hex(4))")

    log_info "公钥 : $RELAY_PUBKEY"
    log_info "ShortID: $RELAY_SHORT_ID"
}

# ── 选择 SNI ──────────────────────────────────────────────
choose_relay_sni() {
    if [[ -n "$RELAY_SNI" && "$IS_FIRST_RUN" == "false" ]]; then
        log_info "保留已有 SNI: $RELAY_SNI"
        RELAY_DEST="${RELAY_SNI}:443"
        return
    fi

    echo ""
    echo -e "${YELLOW}── 中转机 Reality 伪装域名 ──${NC}"
    echo "  推荐：www.microsoft.com / www.apple.com / www.cloudflare.com"
    echo ""
    read -rp "SNI [回车使用 www.microsoft.com]: " i
    RELAY_SNI="${i:-www.microsoft.com}"
    RELAY_DEST="${RELAY_SNI}:443"
    log_info "SNI: $RELAY_SNI"
}

# ── 获取公网 IP（v5.2：支持 IP 变更自动更新）─────────────
get_public_ip() {
    log_step "获取公网 IP..."
    PUBLIC_IP=$(
        curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null ||
        curl -s4 --connect-timeout 5 https://ifconfig.me   2>/dev/null ||
        curl -s4 --connect-timeout 5 https://icanhazip.com 2>/dev/null ||
        echo ""
    )
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '[:space:]')

    if [[ -z "$PUBLIC_IP" ]]; then
        log_warn "自动获取公网 IP 失败（网络不通或被限制）"
        while true; do
            read -rp "请手动输入中转机公网 IP: " PUBLIC_IP
            [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
            log_warn "IP 格式不正确，请重新输入（示例：1.2.3.4）"
        done
    else
        # v5.2：检测 IP 是否有变更
        if [[ "$IS_FIRST_RUN" == "false" && -f "$INFO_FILE" ]]; then
            local old_ip
            old_ip=$(grep "^ZHONGZHUAN_IP=" "$INFO_FILE" | cut -d= -f2- | tr -d '\r' || true)
            if [[ -n "$old_ip" && "$old_ip" != "$PUBLIC_IP" ]]; then
                log_warn "检测到 IP 变更: ${old_ip} → ${PUBLIC_IP}"
                echo -e "  ${YELLOW}duijie.sh 中已对接的节点链接 IP 不会受影响（节点链接记录在 nodes.json）${NC}"
            fi
        fi
        read -rp "中转机公网 IP [回车使用 $PUBLIC_IP]: " i
        [[ -n "$i" ]] && PUBLIC_IP="$i"
    fi
    log_info "IP: $PUBLIC_IP"
}

# ── 配置端口 ──────────────────────────────────────────────
get_user_config() {
    if [[ "$IS_FIRST_RUN" == "false" ]]; then
        local saved_start saved_max
        while IFS='=' read -r key val; do
            val=$(echo "$val" | tr -d '\r')
            case "$key" in
                ZHONGZHUAN_START_PORT) saved_start="$val" ;;
                ZHONGZHUAN_MAX_NODES)  saved_max="$val"   ;;
            esac
        done < "$INFO_FILE"
        if [[ -n "$saved_start" && -n "$saved_max" ]]; then
            START_PORT="$saved_start"
            MAX_NODES="$saved_max"
            log_info "保留端口配置: $START_PORT ~ $(( START_PORT + MAX_NODES - 1 ))"
            return
        fi
    fi

    echo ""
    echo -e "${YELLOW}── 端口规划 ──${NC}"

    while true; do
        read -rp "计划对接几台落地机 (1-50) [默认 10]: " i
        MAX_NODES="${i:-10}"
        [[ "$MAX_NODES" =~ ^[0-9]+$ ]] && \
            (( MAX_NODES >= 1 && MAX_NODES <= 50 )) && break
        log_warn "请输入 1-50 之间的数字"
    done

    while true; do
        read -rp "入站端口起始值 [默认 30001]: " i
        START_PORT="${i:-30001}"
        [[ "$START_PORT" =~ ^[0-9]+$ ]] && \
            (( START_PORT >= 1024 && START_PORT <= 65000 )) && break
        log_warn "请输入 1024-65000 之间的端口"
    done

    local end_port=$(( START_PORT + MAX_NODES - 1 ))
    log_info "预留端口范围: $START_PORT ~ $end_port"
    echo -e "${YELLOW}请确保安全组/防火墙已放行这些 TCP 端口${NC}"
}

# ── 初始化 xray-relay 服务 ────────────────────────────────
init_xray_relay_service() {
    log_step "初始化 xray-relay 服务..."

    mkdir -p "$RELAY_CONF_DIR" "$RELAY_LOG_DIR"

    if [[ ! -f "$RELAY_CONFIG" ]]; then
        cat > "$RELAY_CONFIG" << 'JSONEOF'
{
  "log": {
    "access": "/var/log/xray-relay/access.log",
    "error": "/var/log/xray-relay/error.log",
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": []
  }
}
JSONEOF
        log_info "初始化空配置: $RELAY_CONFIG"
    else
        local node_count
        node_count=$(python3 -c "
import json
try:
    c = json.load(open('$RELAY_CONFIG'))
    print(len(c.get('inbounds', [])))
except: print(0)" 2>/dev/null || echo 0)
        log_info "配置已存在，当前已对接 ${node_count} 台落地机，保留不变"
    fi

    [[ ! -f "$RELAY_NODES" ]] && {
        echo '{"nodes":[]}' > "$RELAY_NODES"
        log_info "初始化节点注册表: $RELAY_NODES"
    }

    cat > "$RELAY_SERVICE" << EOF
[Unit]
Description=Xray Relay Service
Documentation=https://github.com/vpn3288/proxy
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart="${XRAY_BIN}" run -config "${RELAY_CONFIG}"
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-relay >/dev/null 2>&1
    systemctl restart xray-relay
    sleep 2

    if systemctl is-active --quiet xray-relay; then
        log_info "xray-relay 服务运行正常"
    else
        log_error "xray-relay 启动失败：journalctl -u xray-relay -n 20"
    fi
}

# ── iptables 持久化 ───────────────────────────────────────
ensure_iptables_persistent() {
    if ! command -v netfilter-persistent &>/dev/null && \
       ! dpkg -l iptables-persistent &>/dev/null 2>&1; then
        log_step "安装 iptables-persistent..."
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | \
            debconf-set-selections 2>/dev/null || true
        echo iptables-persistent iptables-persistent/autosave_v6 boolean false | \
            debconf-set-selections 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            iptables-persistent netfilter-persistent 2>/dev/null || \
            log_warn "iptables-persistent 安装失败，规则可能在重启后丢失"
    fi
}

save_iptables() {
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    command -v netfilter-persistent &>/dev/null && \
        netfilter-persistent save >/dev/null 2>&1 || true
}

# ── 开放防火墙端口（v5.2：跳过已有 iptables 规则）────────
open_firewall_ports() {
    local end_port=$(( START_PORT + MAX_NODES - 1 ))
    echo ""
    read -rp "自动开放防火墙 TCP ${START_PORT}~${end_port}？[Y/n]: " yn
    [[ "${yn,,}" == "n" ]] && {
        log_warn "跳过防火墙，请手动放行 TCP $START_PORT~$end_port"
        return
    }

    ensure_iptables_persistent

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${START_PORT}:${end_port}/tcp" >/dev/null 2>&1 && \
            log_info "ufw 已放行 TCP $START_PORT~$end_port" || \
            log_warn "ufw 操作失败，请手动放行"
    elif command -v iptables &>/dev/null; then
        # v5.2：检查是否已存在相同规则
        if iptables -C INPUT -p tcp --dport "${START_PORT}:${end_port}" -j ACCEPT &>/dev/null; then
            log_info "iptables 规则已存在，跳过"
        else
            iptables -I INPUT -p tcp --dport "${START_PORT}:${end_port}" \
                -j ACCEPT 2>/dev/null && \
                log_info "iptables 已放行 TCP $START_PORT~$end_port" || \
                log_warn "iptables 操作失败，请手动放行"
            save_iptables
        fi
    else
        log_warn "未检测到防火墙工具，请手动在安全组放行 TCP $START_PORT~$end_port"
    fi
}

# ── 保存信息（v5.2：重复运行时仅更新 IP 和时间戳）─────────
save_info() {
    local end_port=$(( START_PORT + MAX_NODES - 1 ))

    # v5.2：统计已对接节点数
    local node_count=0
    if [[ -f "$RELAY_CONFIG" ]]; then
        node_count=$(python3 -c "
import json
try:
    c = json.load(open('$RELAY_CONFIG'))
    print(len(c.get('inbounds', [])))
except: print(0)" 2>/dev/null || echo 0)
    fi

    cat > "$INFO_FILE" << EOF
============================================================
  中转机信息  $(date '+%Y-%m-%d %H:%M:%S')
  已对接落地机: ${node_count} 台
============================================================
ZHONGZHUAN_IP=${PUBLIC_IP}
ZHONGZHUAN_PRIVKEY=${RELAY_PRIVKEY}
ZHONGZHUAN_PUBKEY=${RELAY_PUBKEY}
ZHONGZHUAN_SHORT_ID=${RELAY_SHORT_ID}
ZHONGZHUAN_SNI=${RELAY_SNI}
ZHONGZHUAN_DEST=${RELAY_DEST}
ZHONGZHUAN_START_PORT=${START_PORT}
ZHONGZHUAN_MAX_NODES=${MAX_NODES}
ZHONGZHUAN_CONF_DIR=${RELAY_CONF_DIR}
ZHONGZHUAN_CONFIG=${RELAY_CONFIG}
ZHONGZHUAN_NODES=${RELAY_NODES}
ZHONGZHUAN_XRAY_BIN=${XRAY_BIN}

── 端口规划 ──────────────────────────────────────────────
预留端口: ${START_PORT} ~ ${end_port}（共 ${MAX_NODES} 个）
已使用 : ${node_count} 个

── 管理命令 ──────────────────────────────────────────────
查看当前状态    : bash zhongzhuan.sh --status
查看已对接节点  : python3 -m json.tool ${RELAY_NODES}
查看中转配置    : python3 -m json.tool ${RELAY_CONFIG}
重启 xray-relay : systemctl restart xray-relay
查看运行状态    : systemctl status xray-relay
查看日志        : journalctl -u xray-relay -f --no-pager
============================================================
EOF
    log_info "信息已保存: $INFO_FILE"
}

# ── 打印结果 ──────────────────────────────────────────────
print_result() {
    local end_port=$(( START_PORT + MAX_NODES - 1 ))

    # 统计已对接节点
    local node_count=0
    if [[ -f "$RELAY_CONFIG" ]]; then
        node_count=$(python3 -c "
import json
try:
    c = json.load(open('$RELAY_CONFIG'))
    print(len(c.get('inbounds', [])))
except: print(0)" 2>/dev/null || echo 0)
    fi

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  ${GREEN}${BOLD}✓ 中转机初始化完成  zhongzhuan.sh v5.2${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}中转机 IP     :${NC} $PUBLIC_IP"
    echo -e "  ${BOLD}公钥 (pubkey) :${NC} $RELAY_PUBKEY"
    echo -e "  ${BOLD}SNI           :${NC} $RELAY_SNI"
    echo -e "  ${BOLD}Short ID      :${NC} $RELAY_SHORT_ID"
    echo -e "  ${BOLD}端口范围      :${NC} $START_PORT ~ $end_port（共 $MAX_NODES 个）"
    echo -e "  ${BOLD}已对接节点    :${NC} $node_count 台"
    echo -e "  ${BOLD}xray-relay    :${NC} $(systemctl is-active xray-relay 2>/dev/null)"
    echo ""
    if [[ $node_count -gt 0 ]]; then
        echo -e "${YELLOW}已对接节点列表：${NC}"
        python3 - "$RELAY_NODES" << 'PYEOF' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    for i, n in enumerate(data.get("nodes", []), 1):
        port = n.get("relay_port", n.get("port", "?"))
        ip   = n.get("luodi_ip", "?")
        lbl  = n.get("label", "")
        lid  = n.get("link_id", "?")
        print(f"  [{i}] 中转端口={port}  落地IP={ip}  {lbl}  (LINK_ID={lid})")
except Exception:
    pass
PYEOF
        echo ""
    fi
    echo -e "${YELLOW}下一步：在每台落地机上运行 luodi.sh → duijie.sh${NC}"
    echo -e "${YELLOW}查看状态：bash zhongzhuan.sh --status${NC}"
    echo ""
}

main() {
    # v5.2：--status 快速查看
    if [[ "${1:-}" == "--status" ]]; then
        cmd_status
        exit 0
    fi

    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       中转机初始化脚本  zhongzhuan.sh  v5.2         ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    find_or_install_xray
    load_or_generate_relay_keys
    choose_relay_sni
    get_public_ip
    get_user_config
    init_xray_relay_service
    open_firewall_ports
    save_info
    print_result
}

main "$@"
