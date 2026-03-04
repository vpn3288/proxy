#!/bin/bash
# ============================================================
# luodi.sh — 落地机信息读取脚本 v3.1
# 功能：读取 v2ray-agent 已安装的 Xray VLESS Reality 配置
#       生成落地机信息文件，供 duijie.sh 对接使用
# 修复：动态检测 Xray 路径、公钥推导容错、v26 格式兼容
# 使用：bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/luodi.sh)
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

INFO_FILE="/root/xray_luodi_info.txt"
MACK_A_CONF_DIR="/etc/v2ray-agent/xray/conf"

[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

# ============================================================
# 打印 Banner
# ============================================================
print_banner() {
    echo -e "${CYAN}"
    echo "  ██╗     ██╗   ██╗ ██████╗ ██████╗ ██╗"
    echo "  ██║     ██║   ██║██╔═══██╗██╔══██╗██║"
    echo "  ██║     ██║   ██║██║   ██║██║  ██║██║"
    echo "  ██║     ██║   ██║██║   ██║██║  ██║██║"
    echo "  ███████╗╚██████╔╝╚██████╔╝██████╔╝██║"
    echo "  ╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝ ╚═╝"
    echo -e "  落地机信息读取脚本 v3.1 — 读取 v2ray-agent 配置${NC}"
    echo ""
}

# ============================================================
# 动态查找 Xray 二进制路径（五级兜底，适配任意安装位置）
# ============================================================
find_xray_bin() {
    # 方法1: 常见固定路径（含 v2ray-agent 实际安装路径）
    local candidates=(
        "/etc/v2ray-agent/xray/xray"
        "/usr/local/bin/xray"
        "/usr/bin/xray"
        "/usr/local/share/xray/xray"
        "/opt/xray/xray"
    )
    for p in "${candidates[@]}"; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    # 方法2: PATH 查找
    local w
    w=$(command -v xray 2>/dev/null || echo "")
    [[ -n "$w" && -x "$w" ]] && { echo "$w"; return 0; }
    # 方法3: 从 systemd 服务文件提取实际路径（兼容不支持 grep -P 的系统）
    local svc_bin
    svc_bin=$(systemctl show xray --property=ExecStart 2>/dev/null         | grep -o 'path=[^;]*' | head -1 | sed 's/path=//' | tr -d ' ')
    [[ -n "$svc_bin" && -x "$svc_bin" ]] && { echo "$svc_bin"; return 0; }
    # 方法4: 从运行中的进程提取
    local proc_bin
    proc_bin=$(ps -eo cmd --no-headers 2>/dev/null         | grep -v grep | grep -i 'xray' | awk '{print $1}' | head -1)
    [[ -n "$proc_bin" && -x "$proc_bin" ]] && { echo "$proc_bin"; return 0; }
    # 方法5: 全盘搜索（兜底，覆盖任意安装位置）
    local found
    found=$(find / -maxdepth 6 -name 'xray' -type f         -perm /111 2>/dev/null | grep -v proc | head -1)
    [[ -n "$found" ]] && { echo "$found"; return 0; }
    return 1
}

# ============================================================
# 检查 v2ray-agent 是否已安装
# ============================================================
check_mack_a() {
    info "检查 v2ray-agent 安装状态..."

    [[ -d "$MACK_A_CONF_DIR" ]] || \
        error "未找到 v2ray-agent 配置目录 $MACK_A_CONF_DIR\n请先安装 v2ray-agent: https://github.com/mack-a/v2ray-agent"

    XRAY_BIN=$(find_xray_bin) || {
        echo -e "${RED}[ERROR]${NC} 未找到 Xray 二进制文件"
        echo "  全盘搜索结果: $(find /usr /opt /root -name 'xray' -type f 2>/dev/null | head -5 || echo '无')"
        echo "  systemd 服务: $(systemctl show xray --property=ExecStart 2>/dev/null | head -1 || echo '无')"
        echo "  运行中进程 : $(ps -eo cmd --no-headers 2>/dev/null | grep -v grep | grep -i xray | head -2 || echo '无')"
        echo ""
        echo "  请确认 v2ray-agent 已正确安装，或手动运行: vasma"
        exit 1
    }

    info "Xray 路径: $XRAY_BIN"

    if ! systemctl is-active --quiet xray 2>/dev/null; then
        warn "Xray 服务未运行，尝试启动..."
        systemctl start xray 2>/dev/null || warn "Xray 启动失败，但继续读取配置"
    fi

    success "v2ray-agent 已安装，Xray 路径: $XRAY_BIN"
}

# ============================================================
# 从 v2ray-agent 配置中提取 VLESS Reality 参数
# ============================================================
read_vless_reality() {
    info "从 v2ray-agent 配置读取 VLESS Reality 参数..."

    local found
    found=$(python3 - "$MACK_A_CONF_DIR" << 'PYEOF'
import json, os, sys, glob

conf_dir = sys.argv[1]
result = {}

for fpath in sorted(glob.glob(os.path.join(conf_dir, "*.json"))):
    try:
        with open(fpath) as f:
            data = json.load(f)
    except Exception:
        continue

    inbounds = data.get("inbounds", [])
    if not isinstance(inbounds, list):
        continue

    for ib in inbounds:
        if not isinstance(ib, dict):
            continue
        if ib.get("protocol", "").lower() != "vless":
            continue

        stream = ib.get("streamSettings", {})
        if stream.get("security") != "reality":
            continue

        reality_cfg = stream.get("realitySettings", {})
        if not reality_cfg:
            continue

        port = ib.get("port")
        if not port:
            continue

        clients = ib.get("settings", {}).get("clients", [])
        uuid = clients[0].get("id", "") if clients else ""

        private_key  = reality_cfg.get("privateKey", "")
        short_ids    = reality_cfg.get("shortIds", [""])
        short_id     = short_ids[0] if short_ids else ""
        server_names = reality_cfg.get("serverNames", [""])
        sni          = server_names[0] if server_names else ""
        dest         = reality_cfg.get("dest", "")

        if not private_key:
            continue

        result = {
            "port":        port,
            "uuid":        uuid,
            "private_key": private_key,
            "short_id":    short_id,
            "sni":         sni,
            "dest":        dest,
            "file":        fpath
        }
        break

    if result:
        break

if result:
    print(f"PORT={result['port']}")
    print(f"UUID={result['uuid']}")
    print(f"PRIVATE_KEY={result['private_key']}")
    print(f"SHORT_ID={result['short_id']}")
    print(f"SNI={result['sni']}")
    print(f"DEST={result['dest']}")
    print(f"SOURCE_FILE={result['file']}")
else:
    print("NOT_FOUND")
PYEOF
)

    if [[ "$found" == "NOT_FOUND" ]] || [[ -z "$found" ]]; then
        error "未在 $MACK_A_CONF_DIR 中找到 VLESS Reality 入站配置\n请确认 v2ray-agent 已安装 VLESS Vision Reality 协议"
    fi

    eval "$found"

    info "来源文件: $SOURCE_FILE"
    info "监听端口: $PORT"
    info "UUID    : $UUID"
    info "SNI     : $SNI"

    # ── 允许用户手动确认或修改关键参数 ──────────────────────
    echo ""
    echo -e "${YELLOW}── 请确认/修改以下参数（直接回车保留自动读取值）──${NC}"

    read -rp "VLESS 端口 [当前: $PORT]: " INPUT_PORT
    [[ -n "$INPUT_PORT" ]] && PORT="$INPUT_PORT"

    read -rp "UUID    [当前: $UUID]: " INPUT_UUID
    [[ -n "$INPUT_UUID" ]] && UUID="$INPUT_UUID"

    read -rp "SNI 伪装域名 [当前: $SNI]: " INPUT_SNI
    [[ -n "$INPUT_SNI" ]] && SNI="$INPUT_SNI"

    read -rp "Short ID [当前: ${SHORT_ID:-（空）}]: " INPUT_SID
    [[ -n "$INPUT_SID" ]] && SHORT_ID="$INPUT_SID"

    echo ""
    info "最终使用 → 端口: $PORT | UUID: $UUID | SNI: $SNI | ShortID: ${SHORT_ID:-（空）}"
}

# ============================================================
# 用私钥推导公钥（修复：禁止 fallback 生成新密钥）
# ============================================================
derive_public_key() {
    info "从私钥推导公钥..."

    local key_out
    # 必须用已有私钥推导，禁止无参数 fallback
    key_out=$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY" 2>&1) || {
        error "xray x25519 -i 执行失败，输出:\n$key_out"
    }

    # 兼容 v26 新格式（Password:）和旧格式（Public key:）
    PUBLIC_KEY=$(echo "$key_out" | grep -i "^Password:"   | awk '{print $NF}' | tr -d '[:space:]')
    [[ -z "$PUBLIC_KEY" ]] && \
    PUBLIC_KEY=$(echo "$key_out" | grep -i "^Public key:" | awk '{print $NF}' | tr -d '[:space:]')

    # 再尝试第二行（某些版本直接输出两行 key）
    if [[ -z "$PUBLIC_KEY" ]]; then
        PUBLIC_KEY=$(echo "$key_out" | sed -n '2p' | tr -d '[:space:]')
    fi

    [[ -z "$PUBLIC_KEY" ]] && \
        error "无法从私钥推导公钥。\nXray 版本: $($XRAY_BIN version 2>/dev/null | head -1)\n原始输出:\n$key_out"

    success "公钥: $PUBLIC_KEY"
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
    info "公网 IP: $PUBLIC_IP"
}

# ============================================================
# 保存落地机信息文件
# ============================================================
save_info() {
    local VLESS_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#LuoDi-${PUBLIC_IP}"

    cat > "$INFO_FILE" << EOF
============================================================
  落地机节点信息  $(date '+%Y-%m-%d %H:%M:%S')
  来源: v2ray-agent (${SOURCE_FILE##*/})
============================================================
公网 IP     : ${PUBLIC_IP}
VLESS 端口  : ${PORT}
UUID        : ${UUID}
公钥(pubkey): ${PUBLIC_KEY}
私钥(prikey): ${PRIVATE_KEY}
Short ID    : ${SHORT_ID}
伪装域名    : ${SNI}
伪装目标    : ${DEST}

── 供 duijie.sh 对接使用 ─────────────────────────────────
LUODI_IP=${PUBLIC_IP}
LUODI_PORT=${PORT}
LUODI_UUID=${UUID}
LUODI_PUBKEY=${PUBLIC_KEY}
LUODI_PRIVKEY=${PRIVATE_KEY}
LUODI_SHORTID=${SHORT_ID}
LUODI_SNI=${SNI}

── VLESS 直连测试链接 ────────────────────────────────────
${VLESS_LINK}
============================================================
EOF
    success "信息已保存到: $INFO_FILE"
}

# ============================================================
# 打印结果
# ============================================================
print_result() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN}  落地机信息读取完成！${NC}"
    echo -e "${CYAN}============================================================${NC}"
    cat "$INFO_FILE"
    echo ""
    echo -e "${YELLOW}提示：${NC}"
    echo -e "  1. 在落地机上运行 duijie.sh 完成与中转机的对接"
    echo -e "  2. 再次查看信息: cat $INFO_FILE"
    echo ""
}

# ============================================================
# 主流程
# ============================================================
main() {
    print_banner
    check_mack_a
    read_vless_reality
    derive_public_key
    get_public_ip
    save_info
    print_result
}

main "$@"
