#!/bin/bash
# ============================================================
# luodi.sh — 落地机安装脚本
# 功能：自动安装 Xray + VLESS Reality，输出节点信息
# 使用：bash <(curl -s https://your-host/luodi.sh)
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
INFO_FILE="/root/xray_luodi_info.txt"
XRAY_BIN="/usr/local/bin/xray"

# ── 检查 root ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

# ── 检测系统 ───────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS=$ID
        OS_VER=$VERSION_ID
    else
        error "无法检测操作系统"
    fi
    info "系统: $OS $OS_VER"
}

# ── 安装依赖 ───────────────────────────────────────────────
install_deps() {
    info "安装依赖..."
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get update -qq
        apt-get install -y -qq curl wget unzip openssl uuid-runtime jq 2>/dev/null || \
        apt-get install -y -qq curl wget unzip openssl jq
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
        yum install -y -q curl wget unzip openssl jq 2>/dev/null || \
        dnf install -y -q curl wget unzip openssl jq
    else
        warn "未知系统，尝试继续..."
    fi
}

# ── 安装 Xray ──────────────────────────────────────────────
install_xray() {
    if [[ -f "$XRAY_BIN" ]]; then
        warn "Xray 已存在，跳过安装"
        return
    fi
    info "安装 Xray..."

    # 方法1：官方安装脚本（新版语法，无 @ latest 参数）
    if bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) \
        install 2>/dev/null && [[ -f "$XRAY_BIN" ]]; then
        success "Xray 安装完成（官方脚本）"
        return
    fi

    # 方法2：直接下载二进制（备用，适合网络受限环境）
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
    # 注册 systemd 服务（直接下载不自带服务文件）
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

# ── 生成密钥 ───────────────────────────────────────────────
gen_keys() {
    info "生成 Reality 密钥对..."
    KEYS=$("$XRAY_BIN" x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYS"  | grep "Public key:"  | awk '{print $3}')
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || "$XRAY_BIN" uuid)
    SHORT_ID=$(openssl rand -hex 8)
    info "UUID: $UUID"
    info "Public Key: $PUBLIC_KEY"
    info "Short ID: $SHORT_ID"
}

# ── 选择伪装域名 ───────────────────────────────────────────
choose_dest() {
    # 自动选择一个稳定的伪装目标（支持 TLSv1.3 + H2 的网站）
    DEST="www.microsoft.com"
    DEST_PORT=443
    info "伪装目标: $DEST:$DEST_PORT"
}

# ── 选择监听端口 ───────────────────────────────────────────
choose_port() {
    # 默认端口，若被占用则随机选一个
    VLESS_PORT=443
    if ss -tlnp | grep -q ":$VLESS_PORT "; then
        VLESS_PORT=$(shuf -i 10000-60000 -n 1)
        warn "443 端口被占用，使用随机端口: $VLESS_PORT"
    fi
    info "VLESS 监听端口: $VLESS_PORT"
}

# ── 写入配置 ───────────────────────────────────────────────
write_config() {
    info "写入 Xray 配置..."
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:${DEST_PORT}",
          "xver": 0,
          "serverNames": [
            "${DEST}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
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
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "outboundTag": "direct"
      }
    ]
  }
}
EOF
    mkdir -p /var/log/xray
    success "配置写入完成"
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

# ── 配置防火墙 ─────────────────────────────────────────────
setup_firewall() {
    info "配置防火墙..."
    if command -v ufw &>/dev/null; then
        ufw allow "$VLESS_PORT"/tcp >/dev/null 2>&1 || true
        success "ufw 已放行 $VLESS_PORT/tcp"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="$VLESS_PORT"/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        success "firewalld 已放行 $VLESS_PORT/tcp"
    else
        warn "未检测到防火墙工具，请手动放行端口 $VLESS_PORT/tcp"
    fi
}

# ── 获取公网 IP ────────────────────────────────────────────
get_public_ip() {
    PUBLIC_IP=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
                curl -s4 --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
                curl -s4 --connect-timeout 5 https://icanhazip.com 2>/dev/null || \
                echo "unknown")
    info "公网 IP: $PUBLIC_IP"
}

# ── 保存节点信息 ───────────────────────────────────────────
save_info() {
    # 生成 VLESS 链接
    VLESS_LINK="vless://${UUID}@${PUBLIC_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#LuoDi-${PUBLIC_IP}"

    cat > "$INFO_FILE" <<EOF
============================================================
  落地机节点信息  $(date '+%Y-%m-%d %H:%M:%S')
============================================================
公网 IP     : ${PUBLIC_IP}
VLESS 端口  : ${VLESS_PORT}
UUID        : ${UUID}
公钥(pubkey): ${PUBLIC_KEY}
私钥(prikey): ${PRIVATE_KEY}
Short ID    : ${SHORT_ID}
伪装域名    : ${DEST}

── 供中转机对接使用（duijie.sh 需要以下信息）──────────────
LUODI_IP=${PUBLIC_IP}
LUODI_PORT=${VLESS_PORT}
LUODI_UUID=${UUID}
LUODI_PUBKEY=${PUBLIC_KEY}
LUODI_SHORTID=${SHORT_ID}
LUODI_SNI=${DEST}

── VLESS 直连链接（可直接导入客户端测试）─────────────────
${VLESS_LINK}
============================================================
EOF
    success "节点信息已保存到: $INFO_FILE"
}

# ── 打印结果 ───────────────────────────────────────────────
print_result() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN}  落地机安装完成！${NC}"
    echo -e "${CYAN}============================================================${NC}"
    cat "$INFO_FILE"
    echo ""
    echo -e "${YELLOW}提示：${NC}"
    echo -e "  1. 将以上信息发给中转机操作员，在中转机上运行 duijie.sh 完成对接"
    echo -e "  2. 落地机端口 ${VLESS_PORT} 只需对中转机IP开放，无需对外公开"
    echo -e "  3. 再次查看信息: cat $INFO_FILE"
    echo ""
}

# ── 主流程 ─────────────────────────────────────────────────
main() {
    echo -e "${CYAN}"
    echo "  ██╗     ██╗   ██╗ ██████╗ ██████╗ ██╗"
    echo "  ██║     ██║   ██║██╔═══██╗██╔══██╗██║"
    echo "  ██║     ██║   ██║██║   ██║██║  ██║██║"
    echo "  ██║     ██║   ██║██║   ██║██║  ██║██║"
    echo "  ███████╗╚██████╔╝╚██████╔╝██████╔╝██║"
    echo "  ╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝ ╚═╝"
    echo -e "  落地机安装脚本 v2.0 — VLESS Reality${NC}"
    echo ""

    detect_os
    install_deps
    install_xray
    gen_keys
    choose_dest
    choose_port
    write_config
    setup_firewall
    start_xray
    get_public_ip
    save_info
    print_result
}

main "$@"
