#!/bin/bash
# ============================================================
# zhongzhuan.sh — 中转机安装脚本
# 功能：安装 Xray，配置多入站端口对应多台落地机
# 使用：bash <(curl -s https://your-host/zhongzhuan.sh)
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success() { echo -e "${CYAN}[OK]${NC} $1"; }

CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="$CONFIG_DIR/config.json"
NODES_FILE="$CONFIG_DIR/nodes.json"
INFO_FILE="/root/xray_zhongzhuan_info.txt"
XRAY_BIN="/usr/local/bin/xray"

# ── 检查 root ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

# ── 检测系统 ───────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS=$ID
    else
        error "无法检测操作系统"
    fi
    info "系统: $OS"
}

# ── 安装依赖 ───────────────────────────────────────────────
install_deps() {
    info "安装依赖..."
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get update -qq
        apt-get install -y -qq curl wget unzip jq openssl
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
        yum install -y -q curl wget unzip jq openssl 2>/dev/null || \
        dnf install -y -q curl wget unzip jq openssl
    fi
}

# ── 安装 Xray ──────────────────────────────────────────────
install_xray() {
    if [[ -f "$XRAY_BIN" ]]; then
        warn "Xray 已存在，跳过安装"
        return
    fi
    info "安装 Xray..."

    # 方法1：官方安装脚本（新版语法）
    if bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) \
        install 2>/dev/null && [[ -f "$XRAY_BIN" ]]; then
        success "Xray 安装完成（官方脚本）"
        return
    fi

    # 方法2：直接下载二进制（备用）
    warn "官方脚本安装失败，尝试直接下载二进制..."
    local arch
    arch=$(uname -m)
    local xray_arch
    case "$arch" in
        x86_64)  xray_arch="64" ;;
        aarch64) xray_arch="arm64-v8a" ;;
        armv7*)  xray_arch="arm32-v7a" ;;
        *)       error "不支持的 CPU 架构: $arch" ;;
    esac

    local latest_ver
    latest_ver=$(curl -fsSL \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        2>/dev/null | grep '"tag_name"' | cut -d'"' -f4 || echo "v24.9.30")

    local dl_url="https://github.com/XTLS/Xray-core/releases/download/${latest_ver}/Xray-linux-${xray_arch}.zip"
    info "下载 Xray ${latest_ver} (${xray_arch})..."

    local tmpdir
    tmpdir=$(mktemp -d)
    if curl -fsSL -o "${tmpdir}/xray.zip" "$dl_url" 2>/dev/null; then
        unzip -q "${tmpdir}/xray.zip" -d "${tmpdir}/" 2>/dev/null
        install -m 755 "${tmpdir}/xray" "$XRAY_BIN"
        mkdir -p "$CONFIG_DIR" /var/log/xray
        rm -rf "$tmpdir"
        success "Xray 安装完成（直接下载）"
    else
        rm -rf "$tmpdir"
        error "Xray 安装失败，请检查网络连接后重试"
    fi

    [[ -f "$XRAY_BIN" ]] || error "Xray 安装失败"
    # 注册 systemd 服务
    if [[ ! -f /etc/systemd/system/xray.service ]]; then
        cat > /etc/systemd/system/xray.service << 'SVCEOF'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SVCEOF
        systemctl daemon-reload
    fi
}

# ── 获取公网 IP ────────────────────────────────────────────
get_public_ip() {
    PUBLIC_IP=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
                curl -s4 --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
                echo "unknown")
    info "中转机公网 IP: $PUBLIC_IP"
}

# ── 用户输入 ───────────────────────────────────────────────
get_user_input() {
    echo ""
    echo -e "${YELLOW}── 配置中转机 ─────────────────────────────────────────${NC}"
    echo ""

    # 中转机公网 IP（可自动检测，也允许手动输入）
    read -rp "中转机公网 IP [回车使用自动检测 $PUBLIC_IP]: " INPUT_IP
    [[ -n "$INPUT_IP" ]] && PUBLIC_IP="$INPUT_IP"
    info "中转机 IP: $PUBLIC_IP"

    # 需要对接几台落地机
    while true; do
        read -rp "需要对接几台落地机 (1-20): " NODE_COUNT
        [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] && [[ "$NODE_COUNT" -ge 1 ]] && [[ "$NODE_COUNT" -le 20 ]] && break
        warn "请输入 1-20 之间的数字"
    done
    info "将配置 $NODE_COUNT 个入站端口"

    # 起始端口
    read -rp "入站端口起始值 [回车默认 10001]: " START_PORT
    START_PORT=${START_PORT:-10001}
    info "端口范围: $START_PORT ~ $((START_PORT + NODE_COUNT - 1))"
}

# ── 生成初始空配置 ─────────────────────────────────────────
write_base_config() {
    info "写入基础配置..."
    mkdir -p "$CONFIG_DIR"
    mkdir -p /var/log/xray

    # 初始化 nodes.json（存储落地机信息，供 duijie.sh 使用）
    echo '{"nodes":[]}' > "$NODES_FILE"

    # 生成带占位入站的配置（后续由 duijie.sh 动态填充）
    # 先生成一个带有 API 管理的基础配置
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "api": {
    "tag": "api",
    "services": ["HandlerService", "StatsService"]
  },
  "inbounds": [
    {
      "tag": "api-in",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api-in"],
        "outboundTag": "api"
      }
    ]
  }
}
EOF
    success "基础配置写入完成"
}

# ── 配置防火墙 ─────────────────────────────────────────────
setup_firewall() {
    local start=$1
    local count=$2
    info "配置防火墙，放行端口 $start ~ $((start + count - 1))..."
    for ((i=0; i<count; i++)); do
        port=$((start + i))
        if command -v ufw &>/dev/null; then
            ufw allow "$port"/tcp >/dev/null 2>&1 || true
        elif command -v firewall-cmd &>/dev/null; then
            firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1 || true
        fi
    done
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    success "防火墙配置完成"
}

# ── 启动 Xray ──────────────────────────────────────────────
start_xray() {
    info "启动 Xray 服务..."
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        success "Xray 服务运行正常"
    else
        error "Xray 启动失败，请检查: journalctl -u xray -n 50"
    fi
}

# ── 保存中转机信息 ─────────────────────────────────────────
save_info() {
    cat > "$INFO_FILE" <<EOF
============================================================
  中转机信息  $(date '+%Y-%m-%d %H:%M:%S')
============================================================
公网 IP         : ${PUBLIC_IP}
可用入站端口    : ${START_PORT} ~ $((START_PORT + NODE_COUNT - 1))
已对接落地机数  : 0 / ${NODE_COUNT}
配置文件        : ${CONFIG_FILE}
落地机节点记录  : ${NODES_FILE}

── 对接说明 ──────────────────────────────────────────────
在每台落地机上运行 duijie.sh，输入本机 SSH 信息即可自动对接。
duijie.sh 会自动占用下一个可用端口。

── 管理命令 ──────────────────────────────────────────────
查看配置     : cat ${CONFIG_FILE}
查看节点记录 : cat ${NODES_FILE} | jq .
重启服务     : systemctl restart xray
查看状态     : systemctl status xray
查看日志     : journalctl -u xray -f
============================================================

ZHONGZHUAN_IP=${PUBLIC_IP}
ZHONGZHUAN_START_PORT=${START_PORT}
ZHONGZHUAN_MAX_NODES=${NODE_COUNT}
EOF
    success "中转机信息保存到: $INFO_FILE"
}

# ── 打印结果 ───────────────────────────────────────────────
print_result() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN}  中转机安装完成！${NC}"
    echo -e "${CYAN}============================================================${NC}"
    cat "$INFO_FILE"
    echo ""
    echo -e "${YELLOW}下一步：${NC}"
    echo -e "  在每台落地机上运行 duijie.sh 进行自动对接"
    echo ""
}

# ── 主流程 ─────────────────────────────────────────────────
main() {
    echo -e "${CYAN}"
    echo "  ███████╗██╗  ██╗ ██████╗ ███╗   ██╗ ██████╗"
    echo "  ╚══███╔╝██║  ██║██╔═══██╗████╗  ██║██╔════╝"
    echo "    ███╔╝ ███████║██║   ██║██╔██╗ ██║██║  ███╗"
    echo "   ███╔╝  ██╔══██║██║   ██║██║╚██╗██║██║   ██║"
    echo "  ███████╗██║  ██║╚██████╔╝██║ ╚████║╚██████╔╝"
    echo "  ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝"
    echo -e "  中转机安装脚本 v2.0${NC}"
    echo ""

    detect_os
    install_deps
    install_xray
    get_public_ip
    get_user_input
    write_base_config
    setup_firewall "$START_PORT" "$NODE_COUNT"
    start_xray
    save_info
    print_result
}

main "$@"
