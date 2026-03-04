#!/bin/bash
# ============================================================
# zhongzhuan.sh — 中转机信息读取脚本 v3.1
# 功能：读取 v2ray-agent 已安装的 Xray 配置
#       初始化中转机节点记录，供 duijie.sh 注入落地机配置
# 修复：动态检测 Xray 路径、Xray 检查改为非强依赖、
#       nodes.json 目录自动创建
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

MACK_A_CONF_DIR="/etc/v2ray-agent/xray/conf"
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
    echo -e "  中转机配置脚本 v3.1 — 读取 v2ray-agent 配置${NC}"
    echo ""
}

# ============================================================
# 动态查找 Xray 二进制路径
# ============================================================
find_xray_bin() {
    local candidates=(
        "/usr/local/bin/xray"
        "/usr/bin/xray"
        "/usr/local/share/xray/xray"
        "/opt/xray/xray"
    )
    for p in "${candidates[@]}"; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    local w
    w=$(command -v xray 2>/dev/null || echo "")
    [[ -n "$w" && -x "$w" ]] && { echo "$w"; return 0; }
    return 1
}

# ============================================================
# 检查 v2ray-agent（中转机不需要用 xray 二进制，检查仅作提示）
# ============================================================
check_mack_a() {
    info "检查 v2ray-agent 安装状态..."

    [[ -d "$MACK_A_CONF_DIR" ]] || \
        error "未找到 v2ray-agent 配置目录 $MACK_A_CONF_DIR\n请先安装 v2ray-agent: https://github.com/mack-a/v2ray-agent"

    # Xray 路径检查：仅提示，不阻断（中转机初始化不需要调用 xray 二进制）
    local xray_bin
    if xray_bin=$(find_xray_bin); then
        info "Xray 路径: $xray_bin"
    else
        warn "未找到 Xray 二进制（常见路径均无），请确认 v2ray-agent 安装正常"
        warn "实际文件: $(find /usr /opt -name 'xray' -type f 2>/dev/null | head -5 || echo '无')"
        warn "继续执行（中转机初始化不需要调用 xray）"
    fi

    # 检查 Xray 服务是否运行
    if systemctl is-active --quiet xray 2>/dev/null; then
        success "Xray 服务运行中"
    else
        warn "Xray 服务未运行，尝试启动..."
        systemctl start xray 2>/dev/null && success "Xray 启动成功" || \
            warn "Xray 启动失败，请检查 v2ray-agent 安装"
    fi

    success "v2ray-agent 配置目录: $MACK_A_CONF_DIR"
}

# ============================================================
# 获取公网 IP
# ============================================================
get_public_ip() {
    info "获取公网 IP..."
    PUBLIC_IP=$(
        curl -s4 --connect-timeout 5 https://api.ipify.org    2>/dev/null || \
        curl -s4 --connect-timeout 5 https://ifconfig.me      2>/dev/null || \
        curl -s4 --connect-timeout 5 https://icanhazip.com    2>/dev/null || \
        curl -s4 --connect-timeout 5 https://ipecho.net/plain 2>/dev/null || \
        echo "unknown"
    )
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '[:space:]')

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
        read -rp "计划对接几台落地机 (1-50): " NODE_COUNT
        [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] && \
        [[ "$NODE_COUNT" -ge 1 ]] && \
        [[ "$NODE_COUNT" -le 50 ]] && break
        warn "请输入 1-50 之间的数字"
    done

    while true; do
        read -rp "入站端口起始值 [回车默认 30001]: " START_PORT
        START_PORT=${START_PORT:-30001}
        [[ "$START_PORT" =~ ^[0-9]+$ ]] && \
        [[ "$START_PORT" -ge 1024 ]] && \
        [[ "$START_PORT" -le 65000 ]] && break
        warn "请输入 1024-65000 之间的合法端口"
    done

    local END_PORT=$(( START_PORT + NODE_COUNT - 1 ))
    info "将为 $NODE_COUNT 台落地机预留端口: $START_PORT ~ $END_PORT"
    echo ""
    echo -e "${YELLOW}注意：duijie.sh 会在此范围内自动分配端口${NC}"
    echo -e "${YELLOW}      请确保安全组/防火墙已放行这些端口${NC}"
}

# ============================================================
# 初始化 nodes.json
# ============================================================
init_nodes_file() {
    local nodes_dir
    nodes_dir="$(dirname "$NODES_FILE")"
    mkdir -p "$nodes_dir"

    if [[ -f "$NODES_FILE" ]]; then
        local existing
        existing=$(python3 -c "
import json, sys
try:
    d = json.load(open('$NODES_FILE'))
    print(len(d.get('nodes', [])))
except Exception as e:
    print(0)
" 2>/dev/null || echo 0)

        if [[ "$existing" -gt 0 ]]; then
            warn "nodes.json 已存在，包含 $existing 条记录"
            read -rp "是否保留已有记录继续添加？[Y/n]: " KEEP
            if [[ "${KEEP,,}" == "n" ]]; then
                echo '{"nodes":[]}' > "$NODES_FILE"
                info "已清空节点记录"
            else
                info "保留已有 $existing 条记录"
            fi
            return
        fi
    fi

    echo '{"nodes":[]}' > "$NODES_FILE"
    info "节点记录文件已初始化: $NODES_FILE"
}

# ============================================================
# 检查并开放防火墙端口（ufw / iptables）
# ============================================================
open_firewall_ports() {
    local end_port=$(( START_PORT + NODE_COUNT - 1 ))
    echo ""
    read -rp "是否自动开放防火墙端口 $START_PORT~$END_PORT？[Y/n]: " DO_FW
    if [[ "${DO_FW,,}" != "n" ]]; then
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            info "通过 ufw 开放端口..."
            ufw allow "${START_PORT}:${end_port}/tcp" >/dev/null 2>&1 && \
                success "ufw 已放行 ${START_PORT}:${end_port}/tcp" || \
                warn "ufw 开放失败，请手动处理"
        elif command -v iptables &>/dev/null; then
            info "通过 iptables 开放端口..."
            iptables -I INPUT -p tcp --dport "${START_PORT}:${end_port}" -j ACCEPT 2>/dev/null && \
                success "iptables 已放行 ${START_PORT}:${end_port}/tcp" || \
                warn "iptables 开放失败，请手动处理"
        else
            warn "未检测到 ufw/iptables，请手动在安全组放行端口 ${START_PORT}~${end_port}"
        fi
    fi
}

# ============================================================
# 保存中转机信息
# ============================================================
save_info() {
    local END_PORT=$(( START_PORT + NODE_COUNT - 1 ))
    cat > "$INFO_FILE" << EOF
============================================================
  中转机信息  $(date '+%Y-%m-%d %H:%M:%S')
============================================================
公网 IP           : ${PUBLIC_IP}
预留入站端口      : ${START_PORT} ~ ${END_PORT}
最大落地机数量    : ${NODE_COUNT}
v2ray-agent 目录  : ${MACK_A_CONF_DIR}
节点记录文件      : ${NODES_FILE}

── 说明 ──────────────────────────────────────────────────
duijie.sh 在落地机上运行，SSH 连接到本机后：
  1. 在 $MACK_A_CONF_DIR 添加三个独立配置文件（入站/出站/路由）
  2. 不修改 v2ray-agent 原有配置
  3. 重启 Xray 生效

── 管理命令 ──────────────────────────────────────────────
查看已对接节点  : cat ${NODES_FILE} | python3 -m json.tool
重启 Xray       : systemctl restart xray
查看 Xray 状态  : systemctl status xray
查看 Xray 日志  : journalctl -u xray -n 50 --no-pager
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
    open_firewall_ports
    save_info
    print_result
}

main "$@"
