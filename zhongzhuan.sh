#!/bin/bash
# ============================================================
# zhongzhuan.sh v5.0 — 中转机初始化脚本
# 功能：安装独立 xray-relay 服务，生成 Reality 密钥
#       初始化空配置，供 duijie.sh 逐步添加落地机
# 用法：bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/zhongzhuan.sh)
# ============================================================
# 架构说明：
#   中转机运行两个独立进程：
#   ① xray.service      — v2ray-agent 管理，中转机自身对外节点（可选）
#   ② xray-relay.service — 本脚本创建，专门处理 用户→中转→落地 流量
#   两者互不干扰，mack-a 操作不影响 xray-relay
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
START_PORT="" MAX_NODES=""

# ── 查找或安装 Xray ───────────────────────────────────────
find_or_install_xray() {
    log_step "查找 Xray 二进制..."
    for p in /etc/v2ray-agent/xray/xray /usr/local/bin/xray /usr/bin/xray /opt/xray/xray; do
        [[ -x "$p" ]] && { XRAY_BIN="$p"; log_info "Xray: $XRAY_BIN"; return 0; }
    done
    local w; w=$(command -v xray 2>/dev/null || true)
    [[ -n "$w" ]] && { XRAY_BIN="$w"; log_info "Xray: $XRAY_BIN"; return 0; }

    log_warn "未找到 Xray，自动安装..."
    # 使用官方安装脚本
    if ! bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
        @ install 2>/dev/null; then
        # 备用：手动下载
        log_warn "官方脚本安装失败，尝试手动下载..."
        local arch; arch=$(uname -m)
        case "$arch" in
            x86_64)  arch="64" ;;
            aarch64) arch="arm64-v8a" ;;
            armv7*)  arch="arm32-v7a" ;;
            *)       log_error "不支持的架构: $arch" ;;
        esac
        local VER; VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
            | grep '"tag_name"' | cut -d'"' -f4)
        [[ -z "$VER" ]] && log_error "无法获取 Xray 版本号，请手动安装 Xray 后重试"
        local URL="https://github.com/XTLS/Xray-core/releases/download/${VER}/Xray-linux-${arch}.zip"
        mkdir -p /usr/local/bin
        curl -fsSL "$URL" -o /tmp/xray.zip
        unzip -o /tmp/xray.zip xray -d /usr/local/bin/ >/dev/null
        chmod +x /usr/local/bin/xray
        rm -f /tmp/xray.zip
    fi

    XRAY_BIN=$(command -v xray 2>/dev/null || true)
    [[ -z "$XRAY_BIN" ]] && XRAY_BIN="/usr/local/bin/xray"
    [[ -x "$XRAY_BIN" ]] || log_error "Xray 安装失败，请手动安装后重试"
    log_info "Xray 安装完成: $XRAY_BIN ($(${XRAY_BIN} version 2>/dev/null | head -1))"
}

# ── 生成 Reality 密钥 ─────────────────────────────────────
generate_relay_keys() {
    log_step "生成中转机 Reality 密钥..."

    local key_out
    key_out=$("$XRAY_BIN" x25519 2>&1)
    # 兼容 v24（Private key:/Public key:）和 v26（Private:/Password:）
    RELAY_PRIVKEY=$(echo "$key_out" | grep -iE "^Private" \
        | awk '{print $NF}' | tr -d '[:space:]' | head -1)
    RELAY_PUBKEY=$(echo "$key_out" | grep -iE "^(Public key|Password)" \
        | awk '{print $NF}' | tr -d '[:space:]' | head -1)
    [[ -z "$RELAY_PRIVKEY" ]] && {
        RELAY_PRIVKEY=$(echo "$key_out" | awk 'NR==1{print $NF}')
        RELAY_PUBKEY=$(echo  "$key_out" | awk 'NR==2{print $NF}')
    }
    [[ -z "$RELAY_PRIVKEY" || -z "$RELAY_PUBKEY" ]] && \
        log_error "密钥生成失败，输出:\n$key_out"

    # 生成 Short ID（随机 8 位 hex）
    RELAY_SHORT_ID=$(openssl rand -hex 4 2>/dev/null || \
        python3 -c "import secrets; print(secrets.token_hex(4))")

    log_info "公钥 (pubkey): $RELAY_PUBKEY"
    log_info "Short ID     : $RELAY_SHORT_ID"
}

# ── 选择 SNI ──────────────────────────────────────────────
choose_relay_sni() {
    echo ""
    echo -e "${YELLOW}── 中转机 Reality 伪装域名 ──${NC}"
    echo "  用于用户连接时的 TLS 伪装，选一个你喜欢的域名"
    echo "  常用选项：www.microsoft.com / www.apple.com / www.cloudflare.com"
    echo ""
    read -rp "SNI [回车使用 www.microsoft.com]: " i
    RELAY_SNI="${i:-www.microsoft.com}"
    log_info "SNI: $RELAY_SNI"
}

# ── 获取公网 IP ───────────────────────────────────────────
get_public_ip() {
    log_step "获取公网 IP..."
    PUBLIC_IP=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null ||
                curl -s4 --connect-timeout 5 https://ifconfig.me   2>/dev/null ||
                curl -s4 --connect-timeout 5 https://icanhazip.com 2>/dev/null || echo "unknown")
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '[:space:]')
    read -rp "中转机公网 IP [回车使用 $PUBLIC_IP]: " i; [[ -n "$i" ]] && PUBLIC_IP="$i"
    log_info "IP: $PUBLIC_IP"
}

# ── 配置参数 ──────────────────────────────────────────────
get_user_config() {
    echo ""
    echo -e "${YELLOW}── 端口规划 ──${NC}"

    while true; do
        read -rp "计划对接几台落地机 (1-50) [默认 10]: " i
        MAX_NODES="${i:-10}"
        [[ "$MAX_NODES" =~ ^[0-9]+$ ]] && (( MAX_NODES >= 1 && MAX_NODES <= 50 )) && break
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

    # 初始化空配置（如已存在则保留）
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
        log_warn "配置文件已存在，保留已有节点记录"
        local node_count
        node_count=$(python3 -c "
import json
try:
    c = json.load(open('$RELAY_CONFIG'))
    print(len(c.get('inbounds', [])))
except: print(0)" 2>/dev/null || echo 0)
        log_info "当前已配置 $node_count 个落地节点"
    fi

    # 初始化节点注册表
    if [[ ! -f "$RELAY_NODES" ]]; then
        echo '{"nodes":[]}' > "$RELAY_NODES"
        log_info "初始化节点注册表: $RELAY_NODES"
    fi

    # 写入 systemd 服务文件
    cat > "$RELAY_SERVICE" << EOF
[Unit]
Description=Xray Relay Service
Documentation=https://github.com/vpn3288/proxy
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_BIN} run -config ${RELAY_CONFIG}
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
        log_info "xray-relay 服务已启动"
    else
        log_error "xray-relay 启动失败：journalctl -u xray-relay -n 20"
    fi
}

# ── 开放防火墙端口 ────────────────────────────────────────
open_firewall_ports() {
    local end_port=$(( START_PORT + MAX_NODES - 1 ))
    echo ""
    read -rp "自动开放防火墙 TCP ${START_PORT}~${end_port}？[Y/n]: " yn
    [[ "${yn,,}" == "n" ]] && {
        log_warn "跳过防火墙配置，请手动在安全组放行 TCP $START_PORT~$end_port"
        return
    }

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${START_PORT}:${end_port}/tcp" >/dev/null 2>&1 && \
            log_info "ufw 已放行 TCP ${START_PORT}~${end_port}" || \
            log_warn "ufw 操作失败，请手动放行"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "${START_PORT}:${end_port}" -j ACCEPT 2>/dev/null && \
            log_info "iptables 已放行 TCP ${START_PORT}~${end_port}" || \
            log_warn "iptables 操作失败，请手动放行"
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    else
        log_warn "未检测到防火墙工具，请手动在安全组放行 TCP $START_PORT~$end_port"
    fi
}

# ── 保存信息 ──────────────────────────────────────────────
save_info() {
    local end_port=$(( START_PORT + MAX_NODES - 1 ))
    cat > "$INFO_FILE" << EOF
============================================================
  中转机信息  $(date '+%Y-%m-%d %H:%M:%S')
============================================================
ZHONGZHUAN_IP=${PUBLIC_IP}
ZHONGZHUAN_PRIVKEY=${RELAY_PRIVKEY}
ZHONGZHUAN_PUBKEY=${RELAY_PUBKEY}
ZHONGZHUAN_SHORT_ID=${RELAY_SHORT_ID}
ZHONGZHUAN_SNI=${RELAY_SNI}
ZHONGZHUAN_DEST=${RELAY_SNI}:443
ZHONGZHUAN_START_PORT=${START_PORT}
ZHONGZHUAN_MAX_NODES=${MAX_NODES}
ZHONGZHUAN_CONF_DIR=${RELAY_CONF_DIR}
ZHONGZHUAN_CONFIG=${RELAY_CONFIG}
ZHONGZHUAN_NODES=${RELAY_NODES}
ZHONGZHUAN_XRAY_BIN=${XRAY_BIN}

── 端口规划 ──────────────────────────────────────────────
预留端口: ${START_PORT} ~ ${end_port}（共 ${MAX_NODES} 个）

── 管理命令 ──────────────────────────────────────────────
查看节点列表    : python3 -m json.tool ${RELAY_NODES}
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
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  ${GREEN}${BOLD}✓ 中转机初始化完成${NC}                                   ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}中转机 IP     :${NC} $PUBLIC_IP"
    echo -e "  ${BOLD}公钥 (pubkey) :${NC} $RELAY_PUBKEY"
    echo -e "  ${BOLD}SNI           :${NC} $RELAY_SNI"
    echo -e "  ${BOLD}Short ID      :${NC} $RELAY_SHORT_ID"
    echo -e "  ${BOLD}端口范围      :${NC} $START_PORT ~ $end_port"
    echo -e "  ${BOLD}xray-relay    :${NC} $(systemctl is-active xray-relay 2>/dev/null)"
    echo ""
    echo -e "${YELLOW}下一步：${NC}"
    echo -e "  在每台落地机上依次运行："
    echo -e "  1. ${CYAN}bash luodi.sh${NC}  — 落地机配置"
    echo -e "  2. ${CYAN}bash duijie.sh${NC} — 对接中转机（SSH 到中转机自动写入）"
    echo ""
}

main() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       中转机初始化脚本  zhongzhuan.sh  v5.0         ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    find_or_install_xray
    generate_relay_keys
    choose_relay_sni
    get_public_ip
    get_user_config
    init_xray_relay_service
    open_firewall_ports
    save_info
    print_result
}

main "$@"
