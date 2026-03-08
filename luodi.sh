#!/bin/bash
# ============================================================
# luodi.sh — 落地机信息读取脚本 v5.4
# 支持：mack-a Xray / mack-a Sing-box / 独立Sing-box
#        (fscarmen / 233boy / yonggekkk) / x-ui / 3x-ui
# 使用：bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/luodi.sh)
#
# v5.4 新增：
#   - 所有 parse 函数输出传输协议细节（network/path/host/mode）
#   - 生成 /tmp/luodi_export.json（供 duijie.sh Level-1 嗅探使用）
#   - save_info() 写入 LUODI_NETWORK / LUODI_TYPE 及各协议参数
#   - confirm_params() 增加传输协议确认
#   - manual_input() 支持传输协议手动输入
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
EXPORT_JSON="/tmp/luodi_export.json"   # ← duijie.sh Level-1 嗅探源

[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         落地机配置脚本  luodi.sh  v5.4              ║"
    echo "║  支持：mack-a Xray / mack-a Sing-box / 独立Singbox ║"
    echo "║         x-ui / 3x-ui / 手动输入                    ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ============================================================
# 全局变量（含 v5.4 新增传输协议字段）
# ============================================================
PORT="" UUID="" ALL_UUIDS="" PRIVATE_KEY=""
SHORT_ID="" SNI="" DEST="" SOURCE_FILE=""
PUBLIC_IP="" PUBLIC_KEY=""
ORACLE_CLOUD=false
BACKEND_TYPE="" BACKEND_CONF=""

# ── 传输协议（v5.4 新增）────────────────────────────────────
NETWORK="tcp"             # tcp / xhttp / ws / grpc / h2
LUODI_TYPE="xray"         # xray / singbox
XHTTP_PATH="/"   XHTTP_HOST=""   XHTTP_MODE="auto"
WS_PATH="/"      WS_HOST=""
GRPC_SERVICE=""
H2_PATH="/"      H2_HOST=""

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
# ============================================================
derive_public_key() {
    local privkey="$1"
    local result=""

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

    if [[ -z "$result" ]]; then
        result=$(python3 - "$privkey" << 'PYEOF' 2>/dev/null || true
import sys, base64
privkey = sys.argv[1].strip()
pad = 4 - len(privkey) % 4
if pad != 4:
    privkey += '=' * pad
try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    raw = base64.urlsafe_b64decode(privkey)
    if len(raw) != 32:
        raw = base64.b64decode(privkey + '==')
    priv_obj = X25519PrivateKey.from_private_bytes(raw[:32])
    pub_raw = priv_obj.public_key().public_bytes_raw()
    print(base64.b64encode(pub_raw).decode())
except Exception:
    pass
PYEOF
        )
    fi

    if [[ -z "$result" ]]; then
        warn "无法自动推导公钥（需要 xray 或 python3-cryptography）"
        warn "请手动获取公钥（在有 xray 的机器上运行: xray x25519 -i <私钥>）"
        read -rp "公钥 (pubkey): " result
    fi

    echo "$result"
}

# ============================================================
# 检测后端类型
# ============================================================
detect_backend() {
    step "检测落地机后端类型..."

    BACKEND_TYPE=""
    BACKEND_CONF=""

    if [[ -d /etc/v2ray-agent/xray/conf ]]; then
        BACKEND_TYPE="macka_xray"
        BACKEND_CONF="/etc/v2ray-agent/xray/conf"
        log "检测到：mack-a Xray（${BACKEND_CONF}）"
        return
    fi

    if [[ -d /etc/v2ray-agent/sing-box/conf ]]; then
        BACKEND_TYPE="macka_singbox"
        BACKEND_CONF="/etc/v2ray-agent/sing-box/conf"
        log "检测到：mack-a Sing-box（${BACKEND_CONF}）"
        return
    fi

    for db in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db \
              /etc/3x-ui/db/x-ui.db /usr/local/3x-ui/x-ui.db \
              /root/3x-ui/x-ui.db; do
        if [[ -f "$db" ]]; then
            BACKEND_TYPE="xui"
            BACKEND_CONF="$db"
            log "检测到：x-ui / 3x-ui（${BACKEND_CONF}）"
            return
        fi
    done

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

    warn "未自动检测到已知代理后端"
    BACKEND_TYPE="manual"
    BACKEND_CONF=""
}

# ============================================================
# Xray 配置解析（mack-a Xray）
# v5.4：新增输出传输协议字段
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
        uuids = []
        for c in clients:
            uid = c.get("id", "").strip()
            if uid and uid not in uuids:
                uuids.append(uid)

        short_ids    = rc.get("shortIds", [""])
        short_id     = short_ids[0] if short_ids else ""
        server_names = rc.get("serverNames", [])
        sni          = server_names[0] if server_names else ""
        dest_raw     = rc.get("dest", "")
        dest         = dest_raw if dest_raw else f"{sni}:443"

        # ── 传输协议细节（v5.4 新增）──────────────────────
        net = stream.get("network", "tcp")
        if net in ("h2", "http"):
            net = "h2"

        transport = {"network": net, "luodi_type": "xray"}

        if net == "xhttp":
            xs = stream.get("xhttpSettings", {})
            transport["xhttp_path"] = xs.get("path", "/")
            transport["xhttp_host"] = xs.get("host", "")
            transport["xhttp_mode"] = xs.get("mode", "auto")
        elif net == "ws":
            ws = stream.get("wsSettings", {})
            transport["ws_path"] = ws.get("path", "/")
            transport["ws_host"] = ws.get("headers", {}).get("Host", "")
        elif net == "grpc":
            transport["grpc_service"] = stream.get("grpcSettings", {}).get("serviceName", "")
        elif net == "h2":
            h2    = stream.get("httpSettings", {})
            hosts = h2.get("host", [])
            transport["h2_path"] = h2.get("path", "/")
            transport["h2_host"] = hosts[0] if hosts else ""

        results.append({
            "port": port, "uuids": uuids,
            "private_key": rc.get("privateKey", ""),
            "short_id": short_id, "sni": sni, "dest": dest,
            "file": fpath,
            **transport,
        })

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
    print(f"NETWORK={r.get('network','tcp')}")
    print(f"LUODI_TYPE={r.get('luodi_type','xray')}")
    print(f"XHTTP_PATH={r.get('xhttp_path','/')}")
    print(f"XHTTP_HOST={r.get('xhttp_host','')}")
    print(f"XHTTP_MODE={r.get('xhttp_mode','auto')}")
    print(f"WS_PATH={r.get('ws_path','/')}")
    print(f"WS_HOST={r.get('ws_host','')}")
    print(f"GRPC_SERVICE={r.get('grpc_service','')}")
    print(f"H2_PATH={r.get('h2_path','/')}")
    print(f"H2_HOST={r.get('h2_host','')}")
else:
    print("NOT_FOUND")
PYEOF
    )

    [[ "$found" == "NOT_FOUND" || -z "$found" ]] && \
        error "未在 ${BACKEND_CONF} 中找到 VLESS Reality 入站配置"

    _parse_keyval "$found"
    log "端口: $PORT | SNI: $SNI | 传输: $NETWORK"
}

# ============================================================
# Sing-box 配置解析（通用，mack-a 多文件 + standalone 单文件）
# v5.4：新增输出传输协议字段
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

_SB_NET = {
    "websocket": "ws", "http": "h2", "grpc": "grpc",
    "httpupgrade": "ws", "xhttp": "xhttp",
}

def get_short_id(val):
    if isinstance(val, str): return val
    if isinstance(val, list):
        for v in val:
            if v: return str(v)
    return ""

def extract_transport(ib):
    """从 sing-box inbound 提取传输协议细节"""
    tr  = ib.get("transport", {})
    raw = tr.get("type", "")
    net = _SB_NET.get(raw, "tcp")

    t = {"network": net, "luodi_type": "singbox",
         "xhttp_path": "/", "xhttp_host": "", "xhttp_mode": "auto",
         "ws_path": "/", "ws_host": "",
         "grpc_service": "", "h2_path": "/", "h2_host": ""}

    if net == "xhttp":
        t["xhttp_path"] = tr.get("path", "/")
        t["xhttp_host"] = tr.get("host", "")
        t["xhttp_mode"] = tr.get("mode", "auto")
    elif net == "ws":
        t["ws_path"] = tr.get("path", "/")
        t["ws_host"] = tr.get("headers", {}).get("Host", "")
    elif net == "grpc":
        t["grpc_service"] = tr.get("service_name", "")
    elif net == "h2":
        hosts = tr.get("host", [])
        t["h2_path"] = tr.get("path", "/")
        t["h2_host"] = hosts[0] if isinstance(hosts, list) and hosts else ""
    return t

def parse_config(data, filepath):
    results = []
    for ib in data.get("inbounds", []):
        if not isinstance(ib, dict): continue
        if ib.get("type", "").lower() not in ("vless", "trojan"): continue

        tls     = ib.get("tls", {})
        reality = tls.get("reality", {})
        if not reality.get("enabled", False): continue
        priv = reality.get("private_key", "")
        if not priv: continue

        port = ib.get("listen_port", ib.get("port", ""))
        uuids = []
        for u in ib.get("users", []):
            uid = u.get("uuid", "") or u.get("password", "")
            if uid and uid not in uuids:
                uuids.append(uid)

        handshake = reality.get("handshake", {})
        sni  = tls.get("server_name", "") or handshake.get("server", "")
        h_s  = handshake.get("server", "") or sni
        h_p  = handshake.get("server_port", 443)
        dest = f"{h_s}:{h_p}" if h_s else ""

        raw_sid  = reality.get("short_id", reality.get("short_ids", ""))
        short_id = get_short_id(raw_sid)

        t = extract_transport(ib)
        results.append({
            "port": port, "uuids": uuids,
            "private_key": priv, "short_id": short_id,
            "sni": sni, "dest": dest, "file": filepath,
            **t,
        })
    return results

results = []
if is_dir:
    for fpath in sorted(glob.glob(os.path.join(conf_path, "*.json"))):
        try:
            with open(fpath) as f:
                data = json.load(f)
            results.extend(parse_config(data, fpath))
        except Exception:
            continue
else:
    try:
        with open(conf_path) as f:
            data = json.load(f)
        results.extend(parse_config(data, conf_path))
    except Exception as e:
        print(f"PARSE_ERROR={e}")

if results:
    r = results[0]
    print(f"PORT={r['port']}")
    print(f"UUID={r['uuids'][0] if r['uuids'] else ''}")
    print(f"ALL_UUIDS={'|'.join(r['uuids'])}")
    print(f"PRIVATE_KEY={r['private_key']}")
    print(f"SHORT_ID={r['short_id']}")
    print(f"SNI={r['sni']}")
    print(f"DEST={r['dest']}")
    print(f"SOURCE_FILE={r.get('file', conf_path)}")
    print(f"NETWORK={r.get('network','tcp')}")
    print(f"LUODI_TYPE={r.get('luodi_type','singbox')}")
    print(f"XHTTP_PATH={r.get('xhttp_path','/')}")
    print(f"XHTTP_HOST={r.get('xhttp_host','')}")
    print(f"XHTTP_MODE={r.get('xhttp_mode','auto')}")
    print(f"WS_PATH={r.get('ws_path','/')}")
    print(f"WS_HOST={r.get('ws_host','')}")
    print(f"GRPC_SERVICE={r.get('grpc_service','')}")
    print(f"H2_PATH={r.get('h2_path','/')}")
    print(f"H2_HOST={r.get('h2_host','')}")
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
    log "端口: $PORT | SNI: $SNI | 传输: $NETWORK"
}

# ============================================================
# x-ui / 3x-ui（SQLite 数据库）
# v5.4：新增输出传输协议字段
# ============================================================
parse_xui() {
    step "读取 x-ui / 3x-ui 数据库..."

    if ! command -v python3 &>/dev/null; then
        warn "需要 python3 才能读取 x-ui 数据库"
        BACKEND_TYPE="manual"; return
    fi

    local found
    found=$(python3 - "$BACKEND_CONF" << 'PYEOF'
import sys, json, sqlite3, shutil, os, tempfile

db_orig  = sys.argv[1]
tmp_db   = tempfile.mktemp(suffix=".db", dir="/tmp")

try:
    shutil.copy2(db_orig, tmp_db)
    conn = sqlite3.connect(tmp_db, timeout=5)
    cur  = conn.cursor()

    tables = {r[0] for r in cur.execute(
        "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}

    inbounds = []
    if "inbounds" in tables:
        try:
            rows = cur.execute(
                "SELECT remark, port, protocol, settings, stream_settings "
                "FROM inbounds WHERE enable=1 ORDER BY id DESC"
            ).fetchall()
        except Exception:
            rows = cur.execute(
                "SELECT remark, port, protocol, settings, stream_settings "
                "FROM inbounds ORDER BY id DESC"
            ).fetchall()
        inbounds = rows
    conn.close()

    results = []
    for remark, port, proto, settings_raw, stream_raw in inbounds:
        if proto.lower() not in ("vless", "trojan"): continue
        try:
            stream   = json.loads(stream_raw or "{}")
            settings = json.loads(settings_raw or "{}")
        except Exception:
            continue
        if stream.get("security") != "reality": continue
        rc   = stream.get("realitySettings", {})
        priv = rc.get("privateKey", "")
        if not priv: continue

        clients = settings.get("clients", [])
        uuids   = [c.get("id", "") or c.get("password", "") for c in clients
                   if c.get("id") or c.get("password")]
        uuids   = list(dict.fromkeys(uuids))

        sni      = rc.get("serverNames", [""])[0]
        dest_raw = rc.get("dest", "")
        dest     = dest_raw if dest_raw else f"{sni}:443"
        sids     = rc.get("shortIds", [""])
        short_id = sids[0] if sids else ""

        # ── 传输协议细节（v5.4 新增）──────────────────
        net = stream.get("network", "tcp")
        if net in ("h2", "http"):
            net = "h2"

        t = {"network": net, "luodi_type": "xray",
             "xhttp_path": "/", "xhttp_host": "", "xhttp_mode": "auto",
             "ws_path": "/", "ws_host": "",
             "grpc_service": "", "h2_path": "/", "h2_host": ""}

        if net == "xhttp":
            xs = stream.get("xhttpSettings", {})
            t["xhttp_path"] = xs.get("path", "/")
            t["xhttp_host"] = xs.get("host", "")
            t["xhttp_mode"] = xs.get("mode", "auto")
        elif net == "ws":
            ws = stream.get("wsSettings", {})
            t["ws_path"] = ws.get("path", "/")
            t["ws_host"] = ws.get("headers", {}).get("Host", "")
        elif net == "grpc":
            t["grpc_service"] = stream.get("grpcSettings", {}).get("serviceName", "")
        elif net == "h2":
            h2    = stream.get("httpSettings", {})
            hosts = h2.get("host", [])
            t["h2_path"] = h2.get("path", "/")
            t["h2_host"] = hosts[0] if hosts else ""

        results.append({"port": port, "uuids": uuids,
                        "private_key": priv, "short_id": short_id,
                        "sni": sni, "dest": dest, "remark": remark, **t})

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
        print(f"NETWORK={r.get('network','tcp')}")
        print(f"LUODI_TYPE={r.get('luodi_type','xray')}")
        print(f"XHTTP_PATH={r.get('xhttp_path','/')}")
        print(f"XHTTP_HOST={r.get('xhttp_host','')}")
        print(f"XHTTP_MODE={r.get('xhttp_mode','auto')}")
        print(f"WS_PATH={r.get('ws_path','/')}")
        print(f"WS_HOST={r.get('ws_host','')}")
        print(f"GRPC_SERVICE={r.get('grpc_service','')}")
        print(f"H2_PATH={r.get('h2_path','/')}")
        print(f"H2_HOST={r.get('h2_host','')}")
    else:
        print("NOT_FOUND")

except Exception as e:
    print(f"XUI_ERROR={e}")
finally:
    try: os.unlink(tmp_db)
    except: pass
PYEOF
    )

    if echo "$found" | grep -q "^XUI_ERROR="; then
        warn "x-ui 数据库读取失败: $(echo "$found" | grep XUI_ERROR | cut -d= -f2-)"
        BACKEND_TYPE="manual"; return
    fi
    [[ "$found" == "NOT_FOUND" || -z "$found" ]] && \
        { warn "x-ui 中未找到启用的 VLESS Reality 入站"; BACKEND_TYPE="manual"; return; }

    _parse_keyval "$found"
    log "端口: $PORT | SNI: $SNI | 传输: $NETWORK"
}

# ============================================================
# 手动输入（兜底）
# v5.4：支持传输协议输入
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

    # ── 传输协议（v5.4 新增）──────────────────────────
    echo ""
    echo -e "${YELLOW}── 传输协议配置 ──${NC}"
    echo "  支持：tcp / xhttp / ws / grpc / h2  （默认 tcp）"
    local i
    read -rp "传输协议 [tcp]: " i
    NETWORK="${i:-tcp}"
    LUODI_TYPE="xray"

    case "$NETWORK" in
        xhttp)
            read -rp "  xhttp path  [/]: "    i; XHTTP_PATH="${i:-/}"
            read -rp "  xhttp host  [${SNI}]: " i; XHTTP_HOST="${i:-${SNI}}"
            read -rp "  xhttp mode  [auto]: " i; XHTTP_MODE="${i:-auto}"
            ;;
        ws)
            read -rp "  ws path  [/]: "       i; WS_PATH="${i:-/}"
            read -rp "  ws host  [${SNI}]: "  i; WS_HOST="${i:-${SNI}}"
            ;;
        grpc)
            read -rp "  grpc serviceName []: " i; GRPC_SERVICE="${i:-}"
            ;;
        h2)
            read -rp "  h2 path  [/]: "       i; H2_PATH="${i:-/}"
            read -rp "  h2 host  [${SNI}]: "  i; H2_HOST="${i:-${SNI}}"
            ;;
        tcp|*)
            NETWORK="tcp"
            ;;
    esac
    log "传输协议: ${NETWORK}"
}

# ============================================================
# 解析 key=val 输出
# v5.4：新增传输协议字段解析
# ============================================================
_parse_keyval() {
    local raw="$1"
    PORT="" UUID="" ALL_UUIDS="" PRIVATE_KEY=""
    SHORT_ID="" SNI="" DEST="" SOURCE_FILE=""
    NETWORK="tcp" LUODI_TYPE="xray"
    XHTTP_PATH="/"  XHTTP_HOST=""  XHTTP_MODE="auto"
    WS_PATH="/"     WS_HOST=""
    GRPC_SERVICE=""
    H2_PATH="/"     H2_HOST=""

    PORT=$(echo         "$raw" | grep "^PORT="         | cut -d= -f2-)
    UUID=$(echo         "$raw" | grep "^UUID="         | cut -d= -f2-)
    ALL_UUIDS=$(echo    "$raw" | grep "^ALL_UUIDS="    | cut -d= -f2-)
    PRIVATE_KEY=$(echo  "$raw" | grep "^PRIVATE_KEY="  | cut -d= -f2-)
    SHORT_ID=$(echo     "$raw" | grep "^SHORT_ID="     | cut -d= -f2-)
    SNI=$(echo          "$raw" | grep "^SNI="          | cut -d= -f2-)
    DEST=$(echo         "$raw" | grep "^DEST="         | cut -d= -f2-)
    SOURCE_FILE=$(echo  "$raw" | grep "^SOURCE_FILE="  | cut -d= -f2-)
    # ── 传输协议（v5.4）─────────────────────────────────
    local _n; _n=$(echo "$raw" | grep "^NETWORK=" | cut -d= -f2-)
    [[ -n "$_n" ]] && NETWORK="$_n"
    local _lt; _lt=$(echo "$raw" | grep "^LUODI_TYPE=" | cut -d= -f2-)
    [[ -n "$_lt" ]] && LUODI_TYPE="$_lt"
    local _v
    _v=$(echo "$raw" | grep "^XHTTP_PATH="    | cut -d= -f2-); [[ -n "$_v" ]] && XHTTP_PATH="$_v"
    _v=$(echo "$raw" | grep "^XHTTP_HOST="    | cut -d= -f2-); [[ -n "$_v" ]] && XHTTP_HOST="$_v"
    _v=$(echo "$raw" | grep "^XHTTP_MODE="    | cut -d= -f2-); [[ -n "$_v" ]] && XHTTP_MODE="$_v"
    _v=$(echo "$raw" | grep "^WS_PATH="       | cut -d= -f2-); [[ -n "$_v" ]] && WS_PATH="$_v"
    _v=$(echo "$raw" | grep "^WS_HOST="       | cut -d= -f2-); [[ -n "$_v" ]] && WS_HOST="$_v"
    _v=$(echo "$raw" | grep "^GRPC_SERVICE="  | cut -d= -f2-); [[ -n "$_v" ]] && GRPC_SERVICE="$_v"
    _v=$(echo "$raw" | grep "^H2_PATH="       | cut -d= -f2-); [[ -n "$_v" ]] && H2_PATH="$_v"
    _v=$(echo "$raw" | grep "^H2_HOST="       | cut -d= -f2-); [[ -n "$_v" ]] && H2_HOST="$_v"
}

# ============================================================
# 处理多 UUID（超过1个时询问）
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
# v5.4：增加传输协议确认
# ============================================================
confirm_params() {
    echo ""
    echo -e "${YELLOW}── 确认参数（回车保留自动读取值）──${NC}"

    read -rp "VLESS 端口  [${PORT}]: "           _in; [[ -n "$_in" ]] && PORT="$_in"
    read -rp "UUID        [${UUID}]: "           _in; [[ -n "$_in" ]] && UUID="$_in"
    read -rp "SNI         [${SNI}]: "            _in; [[ -n "$_in" ]] && SNI="$_in"
    read -rp "Short ID    [${SHORT_ID:-空}]: "   _in; [[ -n "$_in" ]] && SHORT_ID="$_in"

    # ── 传输协议确认（v5.4 新增）──────────────────────
    echo ""
    echo -e "${YELLOW}── 传输协议（自动检测: ${NETWORK}）──${NC}"
    case "$NETWORK" in
        xhttp) info "  path=${XHTTP_PATH}  host=${XHTTP_HOST}  mode=${XHTTP_MODE}" ;;
        ws)    info "  path=${WS_PATH}  host=${WS_HOST}" ;;
        grpc)  info "  serviceName=${GRPC_SERVICE}" ;;
        h2)    info "  path=${H2_PATH}  host=${H2_HOST}" ;;
        tcp)   info "  tcp + Reality（无额外参数）" ;;
    esac
    read -rp "修改传输协议？(tcp/xhttp/ws/grpc/h2，回车保留 ${NETWORK}): " _in
    if [[ -n "$_in" && "$_in" != "$NETWORK" ]]; then
        NETWORK="$_in"
        # 重置后重新输入
        XHTTP_PATH="/"  XHTTP_HOST=""  XHTTP_MODE="auto"
        WS_PATH="/"     WS_HOST=""
        GRPC_SERVICE="" H2_PATH="/"    H2_HOST=""
        _collect_transport_params
    elif [[ -n "$_in" && "$_in" == "$NETWORK" ]]; then
        # 协议不变，允许修改细节参数
        _collect_transport_params_if_needed
    fi

    echo ""
    log "最终参数 → 端口: $PORT | UUID: ${UUID:0:8}... | SNI: $SNI | ShortID: ${SHORT_ID:-（空）} | 传输: ${NETWORK}"
}

# 修改了协议，重新收集所有参数
_collect_transport_params() {
    local i
    case "$NETWORK" in
        xhttp)
            read -rp "  xhttp path  [/]: "    i; XHTTP_PATH="${i:-/}"
            read -rp "  xhttp host  [${SNI}]: " i; XHTTP_HOST="${i:-${SNI}}"
            read -rp "  xhttp mode  [auto]: " i; XHTTP_MODE="${i:-auto}"
            ;;
        ws)
            read -rp "  ws path  [/]: "       i; WS_PATH="${i:-/}"
            read -rp "  ws host  [${SNI}]: "  i; WS_HOST="${i:-${SNI}}"
            ;;
        grpc)
            read -rp "  grpc serviceName []: " i; GRPC_SERVICE="${i:-}"
            ;;
        h2)
            read -rp "  h2 path  [/]: "       i; H2_PATH="${i:-/}"
            read -rp "  h2 host  [${SNI}]: "  i; H2_HOST="${i:-${SNI}}"
            ;;
        tcp|*) NETWORK="tcp" ;;
    esac
}

# 协议未变，仅补充空的细节参数
_collect_transport_params_if_needed() {
    local i
    case "$NETWORK" in
        xhttp)
            [[ "$XHTTP_PATH" == "/" ]] && { read -rp "  xhttp path  [/]: " i; [[ -n "$i" ]] && XHTTP_PATH="$i"; }
            [[ -z "$XHTTP_HOST" ]]    && { read -rp "  xhttp host  [${SNI}]: " i; XHTTP_HOST="${i:-${SNI}}"; }
            [[ -z "$XHTTP_MODE" || "$XHTTP_MODE" == "auto" ]] && \
                { read -rp "  xhttp mode  [auto]: " i; [[ -n "$i" ]] && XHTTP_MODE="$i"; }
            XHTTP_PATH="${XHTTP_PATH:-/}"
            XHTTP_HOST="${XHTTP_HOST:-${SNI}}"
            XHTTP_MODE="${XHTTP_MODE:-auto}"
            ;;
        ws)
            [[ "$WS_PATH" == "/" ]] && { read -rp "  ws path  [/]: " i; [[ -n "$i" ]] && WS_PATH="$i"; }
            [[ -z "$WS_HOST" ]]    && { read -rp "  ws host  [${SNI}]: " i; WS_HOST="${i:-${SNI}}"; }
            WS_PATH="${WS_PATH:-/}"
            WS_HOST="${WS_HOST:-${SNI}}"
            ;;
        grpc)
            [[ -z "$GRPC_SERVICE" ]] && { read -rp "  grpc serviceName []: " i; GRPC_SERVICE="${i:-}"; }
            ;;
        h2)
            [[ "$H2_PATH" == "/" ]] && { read -rp "  h2 path  [/]: " i; [[ -n "$i" ]] && H2_PATH="$i"; }
            [[ -z "$H2_HOST" ]]    && { read -rp "  h2 host  [${SNI}]: " i; H2_HOST="${i:-${SNI}}"; }
            H2_PATH="${H2_PATH:-/}"
            H2_HOST="${H2_HOST:-${SNI}}"
            ;;
    esac
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
        echo ""
    )
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '[:space:]')

    if [[ -z "$PUBLIC_IP" ]]; then
        warn "自动获取公网 IP 失败"
        while true; do
            read -rp "请手动输入本机公网 IP: " PUBLIC_IP
            [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
            log_warn "IP 格式不正确，请重新输入"
        done
    fi
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
# 生成 /tmp/luodi_export.json
# v5.4 新增：供 duijie.sh Level-1 嗅探使用（最高优先级）
# JSON 结构与 duijie.sh pick(n) 函数完全匹配
# ============================================================
save_export_json() {
    step "生成 ${EXPORT_JSON}（duijie.sh Level-1 嗅探源）..."

    python3 - << PYEOF
import json, os, sys

export_path = "${EXPORT_JSON}"
ip          = """${PUBLIC_IP}"""
port_str    = """${PORT}"""
uuid_val    = """${UUID}"""
pubkey      = """${PUBLIC_KEY}"""
privkey     = """${PRIVATE_KEY}"""
short_id    = """${SHORT_ID}"""
sni         = """${SNI}"""
dest        = """${DEST}"""
network     = """${NETWORK}"""
luodi_type  = """${LUODI_TYPE}"""
xhttp_path  = """${XHTTP_PATH}"""
xhttp_host  = """${XHTTP_HOST}"""
xhttp_mode  = """${XHTTP_MODE}"""
ws_path     = """${WS_PATH}"""
ws_host     = """${WS_HOST}"""
grpc_svc    = """${GRPC_SERVICE}"""
h2_path     = """${H2_PATH}"""
h2_host     = """${H2_HOST}"""

try:
    port = int(port_str)
except Exception:
    port = 0

node = {
    "port":       port,
    "listen_port": port,
    "ip":         ip,
    "uuid":       uuid_val,
    "pubkey":     pubkey,
    "privkey":    privkey,
    "short_id":   short_id,
    "sni":        sni,
    "dest":       dest,
    "network":    network,
    "luodi_type": luodi_type,
}

# 仅写入非空传输参数（减少冗余）
if network == "xhttp":
    node["xhttp_path"] = xhttp_path
    node["xhttp_host"] = xhttp_host
    node["xhttp_mode"] = xhttp_mode
elif network == "ws":
    node["ws_path"] = ws_path
    node["ws_host"] = ws_host
elif network == "grpc":
    node["grpc_service"] = grpc_svc
elif network == "h2":
    node["h2_path"] = h2_path
    node["h2_host"] = h2_host

# 读取已有文件，更新同端口节点（幂等）
existing = {"nodes": []}
if os.path.exists(export_path):
    try:
        with open(export_path) as f:
            existing = json.load(f)
        if not isinstance(existing, dict):
            existing = {"nodes": [existing] if isinstance(existing, list) else []}
    except Exception:
        existing = {"nodes": []}

nodes = [n for n in existing.get("nodes", [])
         if int(str(n.get("port") or n.get("listen_port") or 0)) != port]
nodes.append(node)
existing["nodes"] = nodes

with open(export_path, "w") as f:
    json.dump(existing, f, ensure_ascii=False, indent=2)

print(f"OK nodes={len(nodes)}")
PYEOF
    local rc=$?
    [[ $rc -eq 0 ]] && log "export.json 已写入: ${EXPORT_JSON}" \
                    || warn "export.json 写入失败（非致命）"
}

# ============================================================
# 保存信息文件
# v5.4：新增传输协议字段（LUODI_NETWORK, LUODI_TYPE 等）
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
传输协议    : ${NETWORK}

── 供 duijie.sh 对接使用 ─────────────────────────────────
LUODI_IP=${PUBLIC_IP}
LUODI_PORT=${PORT}
LUODI_UUID=${UUID}
LUODI_PUBKEY=${PUBLIC_KEY}
LUODI_PRIVKEY=${PRIVATE_KEY}
LUODI_SHORTID=${SHORT_ID}
LUODI_SNI=${SNI}
LUODI_DEST=${DEST}
LUODI_NETWORK=${NETWORK}
LUODI_TYPE=${LUODI_TYPE}
LUODI_XHTTP_PATH=${XHTTP_PATH}
LUODI_XHTTP_HOST=${XHTTP_HOST}
LUODI_XHTTP_MODE=${XHTTP_MODE}
LUODI_WS_PATH=${WS_PATH}
LUODI_WS_HOST=${WS_HOST}
LUODI_GRPC_SERVICE=${GRPC_SERVICE}
LUODI_H2_PATH=${H2_PATH}
LUODI_H2_HOST=${H2_HOST}

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
    echo -e "${GREEN}  落地机信息读取完成！luodi.sh v5.4${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo -e "  ${BOLD}公网 IP     :${NC} $PUBLIC_IP"
    echo -e "  ${BOLD}VLESS 端口  :${NC} $PORT"
    echo -e "  ${BOLD}UUID        :${NC} $UUID"
    echo -e "  ${BOLD}公钥        :${NC} ${PUBLIC_KEY:0:20}..."
    echo -e "  ${BOLD}Short ID    :${NC} ${SHORT_ID:-（空）}"
    echo -e "  ${BOLD}SNI         :${NC} $SNI"
    echo -e "  ${BOLD}传输协议    :${NC} ${NETWORK}"

    case "$NETWORK" in
        xhttp) echo -e "  ${BOLD}  path/host/mode :${NC} ${XHTTP_PATH}  /  ${XHTTP_HOST}  /  ${XHTTP_MODE}" ;;
        ws)    echo -e "  ${BOLD}  ws path/host   :${NC} ${WS_PATH}  /  ${WS_HOST}" ;;
        grpc)  echo -e "  ${BOLD}  serviceName    :${NC} ${GRPC_SERVICE:-（空）}" ;;
        h2)    echo -e "  ${BOLD}  h2 path/host   :${NC} ${H2_PATH}  /  ${H2_HOST}" ;;
    esac

    echo ""
    echo -e "${YELLOW}提示：${NC}"
    echo -e "  Level-1 嗅探源已生成  : ${CYAN}${EXPORT_JSON}${NC}"
    echo -e "  info 文件已保存        : ${CYAN}${INFO_FILE}${NC}"
    echo -e "  在落地机上运行 ${CYAN}duijie.sh${NC} 完成与中转机的对接"
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
        macka_xray)         parse_macka_xray ;;
        macka_singbox)      parse_singbox     ;;
        singbox_standalone) parse_singbox     ;;
        xui)                parse_xui         ;;
        manual)             manual_input      ;;
    esac

    [[ "$BACKEND_TYPE" == "manual" && -z "$PORT" ]] && manual_input

    handle_multi_uuid
    confirm_params
    get_public_ip
    do_derive_pubkey
    save_export_json   # ← v5.4 新增：生成 Level-1 嗅探源
    save_info
    print_result
}

main "$@"
