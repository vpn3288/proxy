#!/bin/bash
# ============================================================
# luodi.sh — 落地机信息读取脚本 v5.3
# 支持：mack-a Xray / mack-a Sing-box / 独立Sing-box
#        (fscarmen / 233boy / yonggekkk) / x-ui / 3x-ui
# 使用：bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/luodi.sh)
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()    { echo -e "${CYAN}[→]${NC} $1"; }
info()    { echo -e "    $1"; }

INFO_FILE="/root/xray_luodi_info.txt"

[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         落地机配置脚本  luodi.sh  v5.3              ║"
    echo "║  支持：mack-a Xray / mack-a Sing-box / 独立Singbox ║"
    echo "║         x-ui / 3x-ui / 手动输入                    ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ============================================================
# 甲骨文云检测
# ============================================================
detect_oracle() {
    if [[ -f /etc/oracle-cloud-agent/agent.conf ]] || \
       curl -s --max-time 2 -H "Authorization: Bearer Oracle" \
           http://169.254.169.254/opc/v2/instance/ &>/dev/null; then
        warn "检测到甲骨文云环境"
        ORACLE_CLOUD=true
    else
        ORACLE_CLOUD=false
    fi
}

# ============================================================
# 查找 Xray/Sing-box 二进制（用于推导公钥）
# ============================================================
find_xray_bin() {
    for p in /etc/v2ray-agent/xray/xray /usr/local/bin/xray /usr/bin/xray \
              /usr/local/share/xray/xray /opt/xray/xray; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    local w; w=$(command -v xray 2>/dev/null || true)
    [[ -n "$w" && -x "$w" ]] && { echo "$w"; return 0; }
    local sb; sb=$(command -v sing-box 2>/dev/null || true)
    [[ -n "$sb" && -x "$sb" ]] && { echo "$sb:singbox"; return 0; }
    return 1
}

find_singbox_bin() {
    for p in /usr/bin/sing-box /usr/local/bin/sing-box /opt/sing-box/sing-box; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    local w; w=$(command -v sing-box 2>/dev/null || true)
    [[ -n "$w" ]] && { echo "$w"; return 0; }
    return 1
}

# ============================================================
# 从私钥推导公钥
# 支持：xray x25519 / python3 cryptography / 手动输入
# ============================================================
derive_public_key() {
    local privkey="$1"
    local result=""

    # 方法1：xray x25519 -i
    local xray_bin
    if xray_bin=$(find_xray_bin 2>/dev/null) && [[ "$xray_bin" != *":singbox" ]]; then
        local out
        out=$("$xray_bin" x25519 -i "$privkey" 2>/dev/null || true)
        result=$(echo "$out" | grep -i "^Password:"   | awk '{print $NF}' | tr -d '[:space:]')
        [[ -z "$result" ]] && \
        result=$(echo "$out" | grep -i "^Public key:" | awk '{print $NF}' | tr -d '[:space:]')
        [[ -z "$result" ]] && \
        result=$(echo "$out" | sed -n '2p' | tr -d '[:space:]')
    fi

    # 方法2：Python3 cryptography（不依赖 xray）
    if [[ -z "$result" ]]; then
        result=$(python3 - "$privkey" << 'PYEOF' 2>/dev/null || true
import sys, base64
privkey = sys.argv[1].strip()
# 补 padding
pad = 4 - len(privkey) % 4
if pad != 4:
    privkey += '=' * pad
try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    raw = base64.urlsafe_b64decode(privkey)
    # 兼容标准base64和urlsafe
    if len(raw) != 32:
        raw = base64.b64decode(privkey + '==')
    priv_obj = X25519PrivateKey.from_private_bytes(raw[:32])
    pub_raw = priv_obj.public_key().public_bytes_raw()
    print(base64.b64encode(pub_raw).decode())
except Exception as e:
    pass
PYEOF
        )
    fi

    # 方法3：手动输入
    if [[ -z "$result" ]]; then
        warn "无法自动推导公钥（需要 xray 或 python3-cryptography）"
        warn "请手动获取公钥（在有 xray 的机器上运行: xray x25519 -i <私钥>）"
        read -rp "请输入公钥 (pubkey): " result
    fi

    echo "$result"
}

# ============================================================
# 检测后端类型（优先级从高到低）
# ============================================================
detect_backend() {
    step "检测落地机后端类型..."

    BACKEND_TYPE=""
    BACKEND_CONF=""

    # 1. mack-a Xray
    if [[ -d /etc/v2ray-agent/xray/conf ]]; then
        BACKEND_TYPE="macka_xray"
        BACKEND_CONF="/etc/v2ray-agent/xray/conf"
        log "检测到：mack-a Xray（${BACKEND_CONF}）"
        return
    fi

    # 2. mack-a Sing-box
    if [[ -d /etc/v2ray-agent/sing-box/conf ]]; then
        BACKEND_TYPE="macka_singbox"
        BACKEND_CONF="/etc/v2ray-agent/sing-box/conf"
        log "检测到：mack-a Sing-box（${BACKEND_CONF}）"
        return
    fi

    # 3. x-ui / 3x-ui（优先于独立 sing-box，因为可能共存）
    for db in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db; do
        if [[ -f "$db" ]]; then
            BACKEND_TYPE="xui"
            BACKEND_CONF="$db"
            log "检测到：x-ui / 3x-ui（${BACKEND_CONF}）"
            return
        fi
    done

    # 4. 独立 Sing-box（fscarmen / 233boy / yonggekkk 等）
    for cfg in /etc/sing-box/config.json \
               /usr/local/etc/sing-box/config.json \
               /root/sbconfig.json \
               /usr/local/sing-box/config.json \
               /opt/sing-box/config.json; do
        if [[ -f "$cfg" ]]; then
            BACKEND_TYPE="singbox_standalone"
            BACKEND_CONF="$cfg"
            log "检测到：独立 Sing-box（${BACKEND_CONF}）"
            return
        fi
    done

    # 5. 未检测到，提示手动输入
    warn "未自动检测到已知代理后端"
    BACKEND_TYPE="manual"
    BACKEND_CONF=""
}

# ============================================================
# Xray 配置解析（mack-a Xray）
# ============================================================
parse_macka_xray() {
    step "读取 mack-a Xray VLESS Reality 配置..."

    local found
    found=$(python3 - "$BACKEND_CONF" << 'PYEOF'
import json, os, sys, glob

conf_dir = sys.argv[1]
results = []

for fpath in sorted(glob.glob(os.path.join(conf_dir, "*.json"))):
    try:
        with open(fpath) as f:
            data = json.load(f)
    except Exception:
        continue
    for ib in data.get("inbounds", []):
        if not isinstance(ib, dict): continue
        if ib.get("protocol", "").lower() != "vless": continue
        stream = ib.get("streamSettings", {})
        if stream.get("security") != "reality": continue
        rc = stream.get("realitySettings", {})
        if not rc.get("privateKey"): continue

        port = ib.get("port", "")
        clients = ib.get("settings", {}).get("clients", [])

        # 所有 UUID（去重，保留有 flow 的优先）
        uuids = []
        for c in clients:
            uid = c.get("id","").strip()
            if uid and uid not in uuids:
                uuids.append(uid)

        short_ids = rc.get("shortIds", [""])
        short_id  = short_ids[0] if short_ids else ""

        server_names = rc.get("serverNames", [])
        sni = server_names[0] if server_names else ""

        dest_raw = rc.get("dest", "")
        # dest 可能是 "host:port" 字符串，直接使用
        dest = dest_raw if dest_raw else f"{sni}:443"

        results.append({
            "port": port,
            "uuids": uuids,
            "private_key": rc.get("privateKey",""),
            "short_id": short_id,
            "sni": sni,
            "dest": dest,
            "file": fpath,
        })

# 输出最佳匹配（有多个时按端口排序取第一）
if results:
    r = sorted(results, key=lambda x: x["port"])[0]
    print(f"PORT={r['port']}")
    print(f"UUID={r['uuids'][0] if r['uuids'] else ''}")
    print(f"ALL_UUIDS={'|'.join(r['uuids'])}")
    print(f"PRIVATE_KEY={r['private_key']}")
    print(f"SHORT_ID={r['short_id']}")
    print(f"SNI={r['sni']}")
    print(f"DEST={r['dest']}")
    print(f"SOURCE_FILE={r['file']}")
else:
    print("NOT_FOUND")
PYEOF
    )

    [[ "$found" == "NOT_FOUND" || -z "$found" ]] && \
        error "未在 ${BACKEND_CONF} 中找到 VLESS Reality 入站配置"

    _parse_keyval "$found"
    log "端口: $PORT | SNI: $SNI"
}

# ============================================================
# Sing-box 配置解析（通用，支持 mack-a 多文件 和 standalone 单文件）
# ============================================================
parse_singbox() {
    local is_dir=false
    [[ -d "$BACKEND_CONF" ]] && is_dir=true

    step "读取 Sing-box VLESS Reality 配置..."

    local found
    found=$(python3 - "$BACKEND_CONF" "$is_dir" << 'PYEOF'
import json, os, sys, glob

conf_path = sys.argv[1]
is_dir    = sys.argv[2] == "true"

def get_short_id(val):
    """sing-box short_id 可能是字符串或数组，统一返回字符串"""
    if isinstance(val, str):
        return val
    if isinstance(val, list):
        # 取第一个非空值
        for v in val:
            if v: return str(v)
    return ""

def parse_config(data):
    results = []
    for ib in data.get("inbounds", []):
        if not isinstance(ib, dict): continue
        ib_type = ib.get("type","").lower()
        if ib_type not in ("vless", "trojan"): continue

        tls = ib.get("tls", {})
        reality = tls.get("reality", {})
        if not reality.get("enabled", False): continue
        priv = reality.get("private_key","")
        if not priv: continue

        port = ib.get("listen_port", ib.get("port",""))

        # UUID / 密码
        uuids = []
        for u in ib.get("users", []):
            uid = u.get("uuid","") or u.get("password","")
            if uid and uid not in uuids:
                uuids.append(uid)

        # SNI：优先 tls.server_name，其次 handshake.server
        handshake = reality.get("handshake", {})
        sni = tls.get("server_name","") or handshake.get("server","")

        # dest：直接读 handshake.server + port
        h_server = handshake.get("server","") or sni
        h_port   = handshake.get("server_port", 443)
        dest = f"{h_server}:{h_port}" if h_server else ""

        # short_id
        raw_sid = reality.get("short_id", reality.get("short_ids",""))
        short_id = get_short_id(raw_sid)

        results.append({
            "port": port,
            "uuids": uuids,
            "private_key": priv,
            "short_id": short_id,
            "sni": sni,
            "dest": dest,
        })
    return results

results = []
if is_dir:
    for fpath in sorted(glob.glob(os.path.join(conf_path, "*.json"))):
        try:
            with open(fpath) as f:
                data = json.load(f)
            for r in parse_config(data):
                r["file"] = fpath
                results.append(r)
        except Exception:
            continue
else:
    try:
        with open(conf_path) as f:
            data = json.load(f)
        for r in parse_config(data):
            r["file"] = conf_path
            results.append(r)
    except Exception as e:
        print(f"PARSE_ERROR={e}")

if results:
    r = results[0]  # 取第一个有效结果
    print(f"PORT={r['port']}")
    print(f"UUID={r['uuids'][0] if r['uuids'] else ''}")
    print(f"ALL_UUIDS={'|'.join(r['uuids'])}")
    print(f"PRIVATE_KEY={r['private_key']}")
    print(f"SHORT_ID={r['short_id']}")
    print(f"SNI={r['sni']}")
    print(f"DEST={r['dest']}")
    print(f"SOURCE_FILE={r.get('file', conf_path)}")
else:
    print("NOT_FOUND")
PYEOF
    )

    if [[ "$found" == NOT_FOUND || -z "$found" ]]; then
        warn "在 ${BACKEND_CONF} 中未找到 VLESS Reality 入站"
        BACKEND_TYPE="manual"
        return
    fi
    if echo "$found" | grep -q "^PARSE_ERROR="; then
        warn "配置文件解析失败: $(echo "$found" | grep PARSE_ERROR | cut -d= -f2-)"
        BACKEND_TYPE="manual"
        return
    fi

    _parse_keyval "$found"
    log "端口: $PORT | SNI: $SNI"
}

# ============================================================
# x-ui / 3x-ui（SQLite 数据库）
# ============================================================
parse_xui() {
    step "读取 x-ui / 3x-ui 数据库..."

    if ! command -v python3 &>/dev/null; then
        warn "需要 python3 才能读取 x-ui 数据库"
        BACKEND_TYPE="manual"; return
    fi

    local found
    found=$(python3 - "$BACKEND_CONF" << 'PYEOF'
import sys, json

db_path = sys.argv[1]

try:
    import sqlite3
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    # 尝试 x-ui / 3x-ui 表结构（两者略有差异）
    tables = [r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]

    inbounds = []
    if "inbounds" in tables:
        rows = cur.execute("SELECT remark, port, protocol, settings, stream_settings, enable FROM inbounds WHERE enable=1").fetchall()
        for remark, port, proto, settings_raw, stream_raw, enable in rows:
            inbounds.append((remark, port, proto, settings_raw, stream_raw))
    conn.close()

    results = []
    for remark, port, proto, settings_raw, stream_raw in inbounds:
        if proto.lower() not in ("vless", "trojan"): continue
        try:
            stream = json.loads(stream_raw or "{}")
            settings = json.loads(settings_raw or "{}")
        except Exception:
            continue
        if stream.get("security") != "reality": continue
        rc = stream.get("realitySettings", {})
        priv = rc.get("privateKey","")
        if not priv: continue

        clients = settings.get("clients", [])
        uuids = [c.get("id","") or c.get("password","") for c in clients if c.get("id") or c.get("password")]
        uuids = list(dict.fromkeys(uuids))  # 去重保序

        sni = rc.get("serverNames",[""])[0]
        dest_raw = rc.get("dest","")
        dest = dest_raw if dest_raw else f"{sni}:443"
        sids = rc.get("shortIds",[""])
        short_id = sids[0] if sids else ""

        results.append({
            "port": port, "uuids": uuids,
            "private_key": priv, "short_id": short_id,
            "sni": sni, "dest": dest,
            "remark": remark,
        })

    if results:
        r = results[0]
        print(f"PORT={r['port']}")
        print(f"UUID={r['uuids'][0] if r['uuids'] else ''}")
        print(f"ALL_UUIDS={'|'.join(r['uuids'])}")
        print(f"PRIVATE_KEY={r['private_key']}")
        print(f"SHORT_ID={r['short_id']}")
        print(f"SNI={r['sni']}")
        print(f"DEST={r['dest']}")
        print(f"SOURCE_FILE=x-ui:{r['remark']}")
    else:
        print("NOT_FOUND")

except Exception as e:
    print(f"XUI_ERROR={e}")
PYEOF
    )

    if echo "$found" | grep -q "^XUI_ERROR="; then
        warn "x-ui 数据库读取失败: $(echo "$found" | grep XUI_ERROR | cut -d= -f2-)"
        BACKEND_TYPE="manual"; return
    fi
    [[ "$found" == "NOT_FOUND" || -z "$found" ]] && \
        { warn "x-ui 中未找到启用的 VLESS Reality 入站"; BACKEND_TYPE="manual"; return; }

    _parse_keyval "$found"
    log "端口: $PORT | SNI: $SNI"
}

# ============================================================
# 手动输入（兜底）
# ============================================================
manual_input() {
    echo ""
    warn "进入手动输入模式"
    echo -e "    请从代理面板或配置文件中手动获取以下参数"
    echo ""
    read -rp "VLESS 端口: " PORT
    read -rp "UUID:       " UUID
    read -rp "SNI（伪装域名）: " SNI
    read -rp "Short ID（无则回车）: " SHORT_ID
    SHORT_ID="${SHORT_ID:-}"
    read -rp "私钥 (private key，无则回车): " PRIVATE_KEY
    PRIVATE_KEY="${PRIVATE_KEY:-}"
    DEST="${SNI}:443"
    ALL_UUIDS="$UUID"
    SOURCE_FILE="manual"
}

# ============================================================
# 解析 key=val 输出（避免 eval 安全风险）
# ============================================================
_parse_keyval() {
    local raw="$1"
    PORT=""; UUID=""; ALL_UUIDS=""; PRIVATE_KEY=""
    SHORT_ID=""; SNI=""; DEST=""; SOURCE_FILE=""

    # grep+cut 方式：安全可靠，val 可含 = 号（base64 私钥）
    PORT=$(echo "$raw"        | grep "^PORT="        | cut -d= -f2-)
    UUID=$(echo "$raw"        | grep "^UUID="        | cut -d= -f2-)
    ALL_UUIDS=$(echo "$raw"   | grep "^ALL_UUIDS="   | cut -d= -f2-)
    PRIVATE_KEY=$(echo "$raw" | grep "^PRIVATE_KEY=" | cut -d= -f2-)
    SHORT_ID=$(echo "$raw"    | grep "^SHORT_ID="    | cut -d= -f2-)
    SNI=$(echo "$raw"         | grep "^SNI="         | cut -d= -f2-)
    DEST=$(echo "$raw"        | grep "^DEST="        | cut -d= -f2-)
    SOURCE_FILE=$(echo "$raw" | grep "^SOURCE_FILE=" | cut -d= -f2-)
}

# ============================================================
# 处理多 UUID（超过1个时询问用哪个）
# ============================================================
handle_multi_uuid() {
    [[ -z "$ALL_UUIDS" ]] && return

    local -a uuids
    IFS='|' read -ra uuids <<< "$ALL_UUIDS"
    local count=${#uuids[@]}

    if [[ $count -gt 1 ]]; then
        echo ""
        warn "检测到 ${count} 个 UUID，请选择用于中转对接的 UUID："
        for i in "${!uuids[@]}"; do
            echo "  $((i+1))) ${uuids[$i]}"
        done
        read -rp "选择 [默认1]: " sel
        sel="${sel:-1}"
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= count )); then
            UUID="${uuids[$((sel-1))]}"
        else
            UUID="${uuids[0]}"
        fi
        log "使用 UUID: $UUID"
    fi
}

# ============================================================
# 用户确认/修改参数
# ============================================================
confirm_params() {
    echo ""
    echo -e "${YELLOW}── 确认参数（回车保留自动读取值）──${NC}"

    read -rp "VLESS 端口  [${PORT}]: "   _in; [[ -n "$_in" ]] && PORT="$_in"
    read -rp "UUID        [${UUID}]: "   _in; [[ -n "$_in" ]] && UUID="$_in"
    read -rp "SNI         [${SNI}]: "    _in; [[ -n "$_in" ]] && SNI="$_in"
    read -rp "Short ID    [${SHORT_ID:-空}]: " _in; [[ -n "$_in" ]] && SHORT_ID="$_in"

    echo ""
    log "最终参数 → 端口: $PORT | UUID: ${UUID:0:8}... | SNI: $SNI | ShortID: ${SHORT_ID:-（空）}"
}

# ============================================================
# 获取公网 IP
# ============================================================
get_public_ip() {
    step "获取本机公网 IP..."
    PUBLIC_IP=$(
        curl -s4 --connect-timeout 5 https://api.ipify.org    2>/dev/null || \
        curl -s4 --connect-timeout 5 https://ifconfig.me      2>/dev/null || \
        curl -s4 --connect-timeout 5 https://icanhazip.com    2>/dev/null || \
        curl -s4 --connect-timeout 5 https://ipecho.net/plain 2>/dev/null || \
        echo "unknown"
    )
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '[:space:]')
    log "公网 IP: $PUBLIC_IP"
}

# ============================================================
# 推导公钥
# ============================================================
do_derive_pubkey() {
    if [[ -z "$PRIVATE_KEY" ]]; then
        warn "无私钥，跳过推导公钥"
        warn "请手动输入公钥（在 https://v2.reality.tools/ 或 xray x25519 -i <私钥> 获取）"
        read -rp "公钥 (pubkey): " PUBLIC_KEY
        return
    fi

    step "推导公钥..."
    PUBLIC_KEY=$(derive_public_key "$PRIVATE_KEY")
    [[ -z "$PUBLIC_KEY" ]] && error "公钥推导失败，请手动输入"
    log "公钥: $PUBLIC_KEY"
}

# ============================================================
# 保存信息文件
# ============================================================
save_info() {
    local vless_link="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#LuoDi-${PUBLIC_IP}"

    cat > "$INFO_FILE" << EOF
============================================================
  落地机节点信息  $(date '+%Y-%m-%d %H:%M:%S')
  来源: ${BACKEND_TYPE}  ${SOURCE_FILE}
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
LUODI_DEST=${DEST}

── VLESS 直连测试链接 ────────────────────────────────────
${vless_link}
============================================================
EOF
    log "信息已保存: $INFO_FILE"
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
    echo -e "  在落地机上运行 ${CYAN}duijie.sh${NC} 完成与中转机的对接"
    echo -e "  再次查看信息：${CYAN}cat $INFO_FILE${NC}"
    echo ""
}

# ============================================================
# 主流程
# ============================================================
main() {
    print_banner
    detect_oracle

    detect_backend

    case "$BACKEND_TYPE" in
        macka_xray)        parse_macka_xray  ;;
        macka_singbox)     parse_singbox      ;;
        singbox_standalone) parse_singbox     ;;
        xui)               parse_xui          ;;
        manual)            manual_input       ;;
    esac

    # 如果解析后仍为manual（解析失败），走手动输入
    [[ "$BACKEND_TYPE" == "manual" && -z "$PORT" ]] && manual_input

    handle_multi_uuid
    confirm_params
    get_public_ip
    do_derive_pubkey
    save_info
    print_result
}

main "$@"
