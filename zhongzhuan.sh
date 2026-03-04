#!/bin/bash
# ============================================================
# zhongzhuan.sh — 中转机信息读取脚本 v3.0
# 功能：读取 v2ray-agent 已安装的 Xray 配置
#       初始化中转机节点记录，供 duijie.sh 注入落地机配置
# 前提：已通过 v2ray-agent 安装 Xray
# 使用：bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/zhongzhuan.sh)
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success() { echo -e "${CYAN}[OK]${NC} $1"; }

XRAY_BIN="/usr/local/bin/xray"
MACK_A_CONF_DIR="/etc/v2ray-agent/xray/conf"
# 中转机 Xray 配置：在 v2ray-agent 的 conf 目录下新增中转入站
# 不修改 v2ray-agent 原有配置，只追加新文件
RELAY_CONF_DIR="$MACK_A_CONF_DIR"
NODES_FILE="/usr/local/etc/xray/nodes.json"
INFO_FILE="/root/xray_zhongzhuan_info.txt"

[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

# ============================================================
print_banner() {
    echo -e "${CYAN}"
    echo "  ███████╗██╗  ██╗ ██████╗ ███╗   ██╗ ██████╗"
    echo "  ╚══███╔╝██║  ██║██╔═══██╗████╗  ██║██╔════╝"
    echo "    ███╔╝ ███████║██║   ██║██╔██╗ ██║██║  ███╗"
    echo "   ███╔╝  ██╔══██║██║   ██║██║╚██╗██║██║   ██║"
    echo "  ███████╗██║  ██║╚██████╔╝██║ ╚████║╚██████╔╝"
    echo "  ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝"
    echo -e "  中转机配置脚本 v3.0 — 读取 v2ray-agent 配置${NC}"
    echo ""
}

# ============================================================
# 检查 v2ray-agent
# ============================================================
check_mack_a() {
    info "检查 v2ray-agent 安装状态..."
    [[ -d "$MACK_A_CONF_DIR" ]] || \
        error "未找到 v2ray-agent 配置目录\n请先安装 v2ray-agent: https://github.com/mack-a/v2ray-agent"
    [[ -f "$XRAY_BIN" ]] || \
        error "未找到 Xray 二进制，请确认 v2ray-agent 已正确安装"
    success "v2ray-agent 已安装"
}

# ============================================================
# 获取公网 IP
# ============================================================
get_public_ip() {
    PUBLIC_IP=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
                curl -s4 --connect-timeout 5 https://ifconfig.me  2>/dev/null || \
                echo "unknown")
    read -rp "中转机公网 IP [回车使用自动检测 $PUBLIC_IP]: " INPUT_IP
    [[ -n "$INPUT_IP" ]] && PUBLIC_IP="$INPUT_IP"
    info "中转机 IP: $PUBLIC_IP"
}

# ============================================================
# 询问对接规模
# ============================================================
get_user_input() {
    echo ""
    echo -e "${YELLOW}── 配置中转机 ─────────────────────────────────────────${NC}"
    echo ""

    while true; do
        read -rp "计划对接几台落地机 (1-20): " NODE_COUNT
        [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] && \
        [[ "$NODE_COUNT" -ge 1 ]] && \
        [[ "$NODE_COUNT" -le 20 ]] && break
        warn "请输入 1-20 之间的数字"
    done

    read -rp "入站端口起始值 [回车默认 30001]: " START_PORT
    START_PORT=${START_PORT:-30001}

    info "将为 $NODE_COUNT 台落地机预留端口: $START_PORT ~ $((START_PORT + NODE_COUNT - 1))"
    echo ""
    echo -e "${YELLOW}注意：这些端口将添加到 v2ray-agent 的 Xray 配置中${NC}"
    echo -e "${YELLOW}      不会影响 v2ray-agent 原有的节点${NC}"
}

# ============================================================
# 初始化 nodes.json
# ============================================================
init_nodes_file() {
    mkdir -p "$(dirname "$NODES_FILE")"
    if [[ -f "$NODES_FILE" ]]; then
        local existing
        existing=$(python3 -c "import json; d=json.load(open('$NODES_FILE')); print(len(d.get('nodes',[])))" 2>/dev/null || echo 0)
        if [[ "$existing" -gt 0 ]]; then
            warn "nodes.json 已存在，包含 $existing 条记录"
            read -rp "是否保留已有记录继续添加？[Y/n]: " KEEP
            [[ "${KEEP,,}" == "n" ]] && echo '{"nodes":[]}' > "$NODES_FILE" && info "已清空节点记录"
            return
        fi
    fi
    echo '{"nodes":[]}' > "$NODES_FILE"
    info "节点记录文件已初始化: $NODES_FILE"
}

# ============================================================
# 保存中转机信息
# ============================================================
save_info() {
    cat > "$INFO_FILE" << EOF
============================================================
  中转机信息  $(date '+%Y-%m-%d %H:%M:%S')
============================================================
公网 IP           : ${PUBLIC_IP}
预留入站端口      : ${START_PORT} ~ $((START_PORT + NODE_COUNT - 1))
最大落地机数量    : ${NODE_COUNT}
v2ray-agent 目录  : ${MACK_A_CONF_DIR}
节点记录文件      : ${NODES_FILE}

── 说明 ──────────────────────────────────────────────────
duijie.sh 会在落地机上运行，SSH 到本机后：
  1. 在 $MACK_A_CONF_DIR 添加新的入站配置文件
  2. 不修改 v2ray-agent 原有配置
  3. 重启 Xray 生效

── 管理命令 ──────────────────────────────────────────────
查看已对接节点  : cat ${NODES_FILE} | python3 -m json.tool
重启 Xray       : systemctl restart xray
查看 Xray 日志  : journalctl -u xray -f --no-pager
============================================================

ZHONGZHUAN_IP=${PUBLIC_IP}
ZHONGZHUAN_START_PORT=${START_PORT}
ZHONGZHUAN_MAX_NODES=${NODE_COUNT}
ZHONGZHUAN_CONF_DIR=${RELAY_CONF_DIR}
EOF
    success "中转机信息已保存到: $INFO_FILE"
}

# ============================================================
# 打印结果
# ============================================================
print_result() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN}  中转机配置完成！${NC}"
    echo -e "${CYAN}============================================================${NC}"
    cat "$INFO_FILE"
    echo ""
    echo -e "${YELLOW}下一步：在每台落地机上运行 duijie.sh 完成对接${NC}"
    echo ""
}

# ============================================================
# 主流程
# ============================================================
main() {
    print_banner
    check_mack_a
    get_public_ip
    get_user_input
    init_nodes_file
    save_info
    print_result
}

main "$@"
