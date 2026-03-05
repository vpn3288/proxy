#!/bin/bash
# ============================================================
# luodi.sh v5.0 — 落地机配置脚本
# 功能：读取 v2ray-agent VLESS Reality 配置
#       添加中转机专用直连入站（0.0.0.0，绕过 nginx）
# 用法：bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/luodi.sh)
# ============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
log_step()  { echo -e "${CYAN}[→]${NC} $1"; }

[[ $EUID -ne 0 ]] && log_error "请使用 root 权限运行"

CONF_DIR="/etc/v2ray-agent/xray/conf"
INFO_FILE="/root/xray_luodi_info.txt"
RELAY_INBOUND_FILE="$CONF_DIR/relay_dedicated_inbound.json"

XRAY_BIN="" PUBLIC_IP="" VLESS_PORT="" UUID=""
PRIVATE_KEY="" PUBLIC_KEY="" SHORT_ID="" SNI="" DEST=""
RELAY_DEDICATED_PORT="" RELAY_IP_RESTRICTION=""

# ── 查找 Xray 二进制 ──────────────────────────────────────
find_xray_bin() {
    for p in /etc/v2ray-agent/xray/xray /usr/local/bin/xray /usr/bin/xray /opt/xray/xray; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    local w; w=$(command -v xray 2>/dev/null || true)
    [[ -n "$w" ]] && { echo "$w"; return 0; }
    local s; s=$(systemctl show xray --property=ExecStart 2>/dev/null \
        | grep -o 'path=[^;]*' | head -1 | sed 's/path=//' | tr -d ' ')
    [[ -n "$s" && -x "$s" ]] && { echo "$s"; return 0; }
    return 1
}

# ── 读取 Reality 配置 ─────────────────────────────────────
read_reality_config() {
    log_step "检查 v2ray-agent..."
    [[ -d "$CONF_DIR" ]] || log_error "未找到 $CONF_DIR，请先安装 v2ray-agent"
    XRAY_BIN=$(find_xray_bin) || log_error "未找到 Xray 二进制"
    log_info "Xray: $XRAY_BIN"
    systemctl is-active --quiet xray 2>/dev/null || \
        { log_warn "Xray 未运行，尝试启动..."; systemctl start xray 2>/dev/null || true; }

    log_step "读取 VLESS Reality 配置..."
    local result
    result=$(python3 - "$CONF_DIR" << 'PYEOF'
import json, glob, sys, os
conf_dir = sys.argv[1]
for fpath in sorted(glob.glob(os.path.join(conf_dir, "*.json"))):
    try: d = json.load(open(fpath))
    except: continue
    for ib in d.get("inbounds", []):
        ss = ib.get("streamSettings", {})
        if ss.get("security") != "reality": continue
        rc = ss.get("realitySettings", {})
        if not rc.get("privateKey"): continue
        clients = ib.get("settings", {}).get("clients", [])
        uuid = clients[0].get("id", "") if clients else ""
        print(f"PORT={ib.get('port','')}")
        print(f"UUID={uuid}")
        print(f"PRIVATE_KEY={rc.get('privateKey','')}")
        print(f"SNI={(rc.get('serverNames') or [''])[0]}")
        print(f"SHORT_ID={(rc.get('shortIds') or [''])[0]}")
        print(f"DEST={rc.get('dest','')}")
        sys.exit(0)
print("NOT_FOUND")
PYEOF
)
    [[ "$result" == "NOT_FOUND" || -z "$result" ]] && \
        log_error "未找到 VLESS Reality 配置，请确认 v2ray-agent 已安装该协议"

    while IFS='=' read -r key val; do
        case "$key" in
            PORT) VLESS_PORT="$val" ;; UUID) UUID="$val" ;;
            PRIVATE_KEY) PRIVATE_KEY="$val" ;; SNI) SNI="$val" ;;
            SHORT_ID) SHORT_ID="$val" ;; DEST) DEST="$val" ;;
        esac
    done <<< "$result"
    log_info "端口: $VLESS_PORT | SNI: $SNI | ShortID: ${SHORT_ID:-空}"

    echo ""
    echo -e "${YELLOW}── 确认参数（直接回车保留自动读取值）──${NC}"
    read -rp "VLESS 端口  [${VLESS_PORT}]: "        i; [[ -n "$i" ]] && VLESS_PORT="$i"
    read -rp "UUID        [${UUID}]: "              i; [[ -n "$i" ]] && UUID="$i"
    read -rp "SNI         [${SNI}]: "               i; [[ -n "$i" ]] && SNI="$i"
    read -rp "Short ID    [${SHORT_ID:-空}]: "      i; [[ -n "$i" ]] && SHORT_ID="$i"
}

# ── 推导公钥 ──────────────────────────────────────────────
derive_pubkey() {
    log_step "推导公钥..."
    local out; out=$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY" 2>&1) || true
    PUBLIC_KEY=$(echo "$out" | grep -iE "^(Public key|Password):" \
        | awk '{print $NF}' | tr -d '[:space:]' | head -1)
    [[ -z "$PUBLIC_KEY" ]] && \
        PUBLIC_KEY=$(echo "$out" | awk 'NR==2{print $NF}' | tr -d '[:space:]')
    [[ -z "$PUBLIC_KEY" ]] && log_error "公钥推导失败：$out"
    log_info "公钥: $PUBLIC_KEY"
}

# ── 获取公网 IP ───────────────────────────────────────────
get_public_ip() {
    log_step "获取公网 IP..."
    PUBLIC_IP=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null ||
                curl -s4 --connect-timeout 5 https://ifconfig.me   2>/dev/null ||
                curl -s4 --connect-timeout 5 https://icanhazip.com 2>/dev/null || echo "unknown")
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '[:space:]')
    read -rp "落地机公网 IP [回车使用 $PUBLIC_IP]: " i; [[ -n "$i" ]] && PUBLIC_IP="$i"
    log_info "IP: $PUBLIC_IP"
}

# ── 配置中转专用入站 ──────────────────────────────────────
setup_relay_inbound() {
    log_step "配置中转机专用直连入站..."

    # 检测已有端口
    local existing_port=""
    if [[ -f "$RELAY_INBOUND_FILE" ]]; then
        existing_port=$(python3 -c "
import json
try:
    d=json.load(open('$RELAY_INBOUND_FILE'))
    print(d.get('inbounds',[{}])[0].get('port',''))
except: pass" 2>/dev/null || true)
        [[ -n "$existing_port" ]] && \
            log_warn "已存在中转专用入站（端口 $existing_port），将覆盖更新"
    fi

    # 推荐端口
    local suggest=45001
    [[ -n "$existing_port" ]] && suggest="$existing_port"
    while [[ -z "$existing_port" ]] && \
          ss -tlnp 2>/dev/null | grep -q ":${suggest} "; do
        suggest=$((suggest + 1))
    done

    read -rp "中转专用端口 [回车使用 $suggest]: " i
    RELAY_DEDICATED_PORT="${i:-$suggest}"

    echo ""
    echo -e "${YELLOW}安全建议：限制只允许中转机 IP 访问此端口${NC}"
    read -rp "中转机公网 IP（留空=不限制，依靠 Reality+UUID 保护）: " RELAY_IP_RESTRICTION

    # 写入 JSON 配置
    # 用 python3 heredoc 但把 bash 变量直接展开进去
    python3 << PYEOF
import json
config = {
    "inbounds": [{
        "tag": "relay-dedicated-in-${RELAY_DEDICATED_PORT}",
        "port": ${RELAY_DEDICATED_PORT},
        "listen": "0.0.0.0",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": "${DEST}",
                "xver": 0,
                "serverNames": ["${SNI}"],
                "privateKey": "${PRIVATE_KEY}",
                "shortIds": ["${SHORT_ID}"]
            }
        }
    }]
}
with open("${RELAY_INBOUND_FILE}", "w") as f:
    json.dump(config, f, indent=2)
print("配置文件已写入")
PYEOF
    log_info "配置文件: $RELAY_INBOUND_FILE"
}

# ── 防火墙 ────────────────────────────────────────────────
setup_firewall() {
    log_step "配置防火墙端口 $RELAY_DEDICATED_PORT..."

    # 清除旧规则
    iptables -D INPUT -p tcp --dport "$RELAY_DEDICATED_PORT" -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport "$RELAY_DEDICATED_PORT" -j DROP   2>/dev/null || true
    [[ -n "$RELAY_IP_RESTRICTION" ]] && \
        iptables -D INPUT -p tcp -s "$RELAY_IP_RESTRICTION" \
            --dport "$RELAY_DEDICATED_PORT" -j ACCEPT 2>/dev/null || true

    if [[ -n "$RELAY_IP_RESTRICTION" ]]; then
        iptables -I INPUT 1 -p tcp -s "$RELAY_IP_RESTRICTION" \
            --dport "$RELAY_DEDICATED_PORT" -j ACCEPT
        # 其他来源 DROP（插到全局 DROP 之前或 APPEND）
        local drop_line
        drop_line=$(iptables -L INPUT --line-numbers -n 2>/dev/null \
            | awk '/^[0-9]+.*DROP/{print $1; exit}')
        if [[ -n "$drop_line" ]]; then
            iptables -I INPUT "$drop_line" -p tcp \
                --dport "$RELAY_DEDICATED_PORT" -j DROP
        else
            iptables -A INPUT -p tcp --dport "$RELAY_DEDICATED_PORT" -j DROP
        fi
        log_info "防火墙：仅 $RELAY_IP_RESTRICTION 可访问端口 $RELAY_DEDICATED_PORT"
    else
        iptables -I INPUT 1 -p tcp --dport "$RELAY_DEDICATED_PORT" -j ACCEPT
        log_warn "防火墙：端口 $RELAY_DEDICATED_PORT 开放所有来源"
    fi

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
}

# ── 验证+重启 Xray ────────────────────────────────────────
restart_xray() {
    log_step "验证配置..."
    if ! "$XRAY_BIN" -test -confdir "$CONF_DIR" >/dev/null 2>&1; then
        "$XRAY_BIN" -test -confdir "$CONF_DIR" 2>&1 | tail -10
        log_error "配置验证失败，已写入文件: $RELAY_INBOUND_FILE"
    fi
    log_info "配置验证通过"
    systemctl restart xray && log_info "Xray 重启成功" || \
        log_error "Xray 重启失败：journalctl -u xray -n 20"
}

# ── 保存信息 ──────────────────────────────────────────────
save_info() {
    local direct_link="vless://${UUID}@${PUBLIC_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#LuoDi-Direct-${PUBLIC_IP}"
    cat > "$INFO_FILE" << EOF
============================================================
  落地机信息  $(date '+%Y-%m-%d %H:%M:%S')
============================================================
LUODI_IP=${PUBLIC_IP}
LUODI_RELAY_PORT=${RELAY_DEDICATED_PORT}
LUODI_UUID=${UUID}
LUODI_PUBKEY=${PUBLIC_KEY}
LUODI_PRIVKEY=${PRIVATE_KEY}
LUODI_SHORT_ID=${SHORT_ID}
LUODI_SNI=${SNI}
LUODI_DEST=${DEST}
LUODI_RELAY_IP_RESTRICTION=${RELAY_IP_RESTRICTION}

── 直连测试链接（验证落地机是否正常，不经过中转）────────
DIRECT_LINK=${direct_link}
============================================================
EOF
    log_info "信息已保存: $INFO_FILE"
}

# ── 打印结果 ──────────────────────────────────────────────
print_result() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  ${GREEN}${BOLD}✓ 落地机配置完成${NC}                                     ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}落地机 IP      :${NC} $PUBLIC_IP"
    echo -e "  ${BOLD}中转专用端口   :${NC} $RELAY_DEDICATED_PORT"
    echo -e "  ${BOLD}UUID           :${NC} $UUID"
    echo -e "  ${BOLD}公钥           :${NC} $PUBLIC_KEY"
    echo -e "  ${BOLD}SNI            :${NC} $SNI"
    echo -e "  ${BOLD}来源IP限制     :${NC} ${RELAY_IP_RESTRICTION:-未限制}"
    echo ""
    echo -e "${YELLOW}下一步：${NC}"
    echo -e "  1. 在中转机上运行 zhongzhuan.sh（如尚未初始化）"
    echo -e "  2. 回到本落地机，运行 duijie.sh 完成对接"
    echo -e "  3. 再次查看信息：${CYAN}cat $INFO_FILE${NC}"
    echo ""
}

main() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         落地机配置脚本  luodi.sh  v5.0              ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    read_reality_config
    derive_pubkey
    get_public_ip
    setup_relay_inbound
    setup_firewall
    restart_xray
    save_info
    print_result
}

main "$@"
