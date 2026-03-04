#!/bin/bash
# ============================================================
# luodi.sh — 落地机信息读取脚本 v3.0
# 功能：读取 v2ray-agent 已安装的 Xray VLESS Reality 配置
#       生成落地机信息文件，供 duijie.sh 对接使用
# 前提：已通过 v2ray-agent 安装 Xray + VLESS Reality
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
XRAY_BIN="/usr/local/bin/xray"
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
    echo -e "  落地机信息读取脚本 v3.0 — 读取 v2ray-agent 配置${NC}"
    echo ""
}

# ============================================================
# 检查 v2ray-agent 是否已安装
# ============================================================
check_mack_a() {
    info "检查 v2ray-agent 安装状态..."

    [[ -d "$MACK_A_CONF_DIR" ]] || \
        error "未找到 v2ray-agent 配置目录 $MACK_A_CONF_DIR\n请先安装 v2ray-agent: https://github.com/mack-a/v2ray-agent"

    [[ -f "$XRAY_BIN" ]] || \
        error "未找到 Xray 二进制 $XRAY_BIN，请确认 v2ray-agent 已正确安装"

    systemctl is-active --quiet xray || \
        warn "Xray 服务未运行，尝试启动..."
    systemctl is-active --quiet xray || systemctl start xray || \
        warn "Xray 服务启动失败，但继续读取配置"

    success "v2ray-agent 已安装，Xray 运行正常"
}

# ============================================================
# 从 v2ray-agent 配置中提取 VLESS Reality 参数
# ============================================================
read_vless_reality() {
    info "从 v2ray-agent 配置读取 VLESS Reality 参数..."

    # v2ray-agent 的 Reality 配置通常在这些文件中
    # 优先级：专用 reality 配置文件 > 通用入站配置
    local conf_files=(
        "$MACK_A_CONF_DIR/07_VLESS_vision_reality_inbounds.json"
        "$MACK_A_CONF_DIR/07_VLESS_reality_inbounds.json"
        "$MACK_A_CONF_DIR/VLESS_vision_reality_inbounds.json"
        "$MACK_A_CONF_DIR"/*.json
    )

    # 用 Python 扫描所有配置文件，找 VLESS Reality 入站
    local found
    found=$(python3 - "$MACK_A_CONF_DIR" << 'PYEOF'
import json, os, sys, glob

conf_dir = sys.argv[1]
result = {}

# 扫描所有 json 文件
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
        # 只处理 VLESS 协议
        if ib.get("protocol", "").lower() != "vless":
            continue

        stream = ib.get("streamSettings", {})
        if stream.get("security") != "reality":
            continue

        reality_cfg = stream.get("realitySettings", {})
        if not reality_cfg:
            continue

        # 提取端口
        port = ib.get("port")
        if not port:
            continue

        # 提取 UUID（取第一个 client）
        clients = ib.get("settings", {}).get("clients", [])
        uuid = clients[0].get("id", "") if clients else ""

        # 提取 Reality 参数
        private_key = reality_cfg.get("privateKey", "")
        short_ids   = reality_cfg.get("shortIds", [""])
        short_id    = short_ids[0] if short_ids else ""
        server_names = reality_cfg.get("serverNames", [""])
        sni          = server_names[0] if server_names else ""
        dest         = reality_cfg.get("dest", "")

        # 必须有私钥才算有效
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
        break  # 找到第一个有效的就停止

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

    # 解析 Python 输出的变量
    eval "$found"

    info "来源文件: $SOURCE_FILE"
    info "监听端口: $PORT"
    info "UUID    : $UUID"
    info "SNI     : $SNI"
}

# ============================================================
# 用私钥推导公钥
# ============================================================
derive_public_key() {
    info "从私钥推导公钥..."

    # 用 xray x25519 -i <私钥> 推导公钥
    # v26 新格式输出：PrivateKey / Password(公钥) / Hash32
    local key_out
    key_out=$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY" 2>/dev/null) || \
    key_out=$("$XRAY_BIN" x25519 2>/dev/null)  # fallback：生成新密钥对

    # 兼容 v26 新格式（PrivateKey/Password）和旧格式（Private key/Public key）
    PUBLIC_KEY=$(echo "$key_out" | grep -i "^Password:"   | awk '{print $NF}' | tr -d '[:space:]')
    [[ -z "$PUBLIC_KEY" ]] && \
    PUBLIC_KEY=$(echo "$key_out" | grep -i "^Public key:" | awk '{print $NF}' | tr -d '[:space:]')

    if [[ -z "$PUBLIC_KEY" ]]; then
        error "无法推导公钥，原始输出:\n$key_out"
    fi

    success "公钥: $PUBLIC_KEY"
}

# ============================================================
# 获取公网 IP
# ============================================================
get_public_ip() {
    PUBLIC_IP=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
                curl -s4 --connect-timeout 5 https://ifconfig.me  2>/dev/null || \
                curl -s4 --connect-timeout 5 https://icanhazip.com 2>/dev/null || \
                echo "unknown")
    info "公网 IP: $PUBLIC_IP"
}

# ============================================================
# 保存落地机信息文件
# ============================================================
save_info() {
    # 生成直连测试链接
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
