#!/bin/bash
# ============================================================
# luodi.sh v5.2 — 落地机配置脚本
# 支持后端：mack-a Xray / mack-a Sing-box / 独立 Sing-box / 手动输入
# 修复：防火墙 -A → -I 正确插入顺序 / 复制粘贴 Bug / Sing-box 支持
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

INFO_FILE="/root/xray_luodi_info.txt"

# ── 全局变量 ──────────────────────────────────────────────
BACKEND=""          # xray_mack_a | singbox_mack_a | singbox_standalone | manual
XRAY_CONF_DIR=""    # Xray 配置目录（mack-a）
SINGBOX_CONF=""     # Sing-box 配置文件路径
XRAY_BIN=""         # Xray 二进制路径（可选，用于推导公钥）
SINGBOX_BIN=""      # Sing-box 二进制路径
RELAY_INBOUND_FILE="" # 写入的专用入站配置文件路径
SERVICE_NAME=""     # systemd 服务名

PUBLIC_IP="" VLESS_PORT="" UUID="" PRIVATE_KEY=""
PUBLIC_KEY="" SHORT_ID="" SNI="" DEST=""
RELAY_DEDICATED_PORT="" RELAY_IP_RESTRICTION=""
IS_ORACLE=false

# ════════════════════════════════════════════════════════════
# 工具函数
# ════════════════════════════════════════════════════════════

detect_oracle() {
    if systemctl list-unit-files 2>/dev/null | grep -q "oracle-cloud-agent" || \
       [[ -f /etc/oracle-cloud-agent/agent.yml ]] || \
       curl -s --connect-timeout 2 http://169.254.169.254/opc/v1/instance/ \
           2>/dev/null | grep -q "compartmentId"; then
        IS_ORACLE=true
        log_warn "检测到甲骨文云环境"
    fi
}

find_xray_bin() {
    for p in /etc/v2ray-agent/xray/xray /usr/local/bin/xray \
              /usr/bin/xray /opt/xray/xray; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    local w; w=$(command -v xray 2>/dev/null || true)
    [[ -n "$w" ]] && { echo "$w"; return 0; }
    local s; s=$(systemctl show xray --property=ExecStart 2>/dev/null \
        | grep -o 'path=[^;]*' | head -1 | sed 's/path=//' | tr -d ' ')
    [[ -n "$s" && -x "$s" ]] && { echo "$s"; return 0; }
    return 1
}

find_singbox_bin() {
    for p in /etc/v2ray-agent/sing-box/sing-box \
              /usr/local/bin/sing-box /usr/bin/sing-box \
              /opt/sing-box/sing-box; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    local w; w=$(command -v sing-box 2>/dev/null || true)
    [[ -n "$w" ]] && { echo "$w"; return 0; }
    return 1
}

# ════════════════════════════════════════════════════════════
# 后端自动检测
# ════════════════════════════════════════════════════════════
detect_backend() {
    log_step "检测落地机后端类型..."

    # 1. mack-a Xray
    if [[ -d "/etc/v2ray-agent/xray/conf" ]]; then
        BACKEND="xray_mack_a"
        XRAY_CONF_DIR="/etc/v2ray-agent/xray/conf"
        RELAY_INBOUND_FILE="$XRAY_CONF_DIR/relay_dedicated_inbound.json"
        SERVICE_NAME="xray"
        XRAY_BIN=$(find_xray_bin || true)
        log_info "检测到：mack-a Xray（$XRAY_CONF_DIR）"
        return
    fi

    # 2. mack-a Sing-box
    if [[ -d "/etc/v2ray-agent/sing-box" ]]; then
        BACKEND="singbox_mack_a"
        SERVICE_NAME="sing-box"
        SINGBOX_BIN=$(find_singbox_bin || true)
        XRAY_BIN=$(find_xray_bin || true)
        # mack-a sing-box 配置可能是目录或单文件
        if [[ -d "/etc/v2ray-agent/sing-box/conf" ]]; then
            SINGBOX_CONF="/etc/v2ray-agent/sing-box/conf"
        else
            SINGBOX_CONF="/etc/v2ray-agent/sing-box/config.json"
        fi
        RELAY_INBOUND_FILE="/etc/v2ray-agent/sing-box/conf/relay_dedicated_inbound.json"
        log_info "检测到：mack-a Sing-box（$SINGBOX_CONF）"
        return
    fi

    # 3. 独立 Sing-box（fscarmen 等）
    for p in /etc/sing-box/config.json \
              /usr/local/etc/sing-box/config.json \
              /root/sing-box/config.json; do
        if [[ -f "$p" ]]; then
            BACKEND="singbox_standalone"
            SINGBOX_CONF="$p"
            SINGBOX_BIN=$(find_singbox_bin || true)
            XRAY_BIN=$(find_xray_bin || true)
            SERVICE_NAME="sing-box"
            RELAY_INBOUND_FILE=""  # singbox 独立版：修改主配置，运行时由 setup_relay_inbound_singbox 赋值
            log_info "检测到：独立 Sing-box（$SINGBOX_CONF）"
            return
        fi
    done

    # 4. 未检测到，询问用户
    echo ""
    echo -e "${YELLOW}未自动检测到支持的后端，请手动选择：${NC}"
    echo -e "  ${CYAN}[1]${NC} mack-a Xray（/etc/v2ray-agent/xray）"
    echo -e "  ${CYAN}[2]${NC} mack-a Sing-box（/etc/v2ray-agent/sing-box）"
    echo -e "  ${CYAN}[3]${NC} 独立 Sing-box（手动指定配置路径）"
    echo -e "  ${CYAN}[4]${NC} 手动输入所有参数"
    read -rp "选择 [4]: " choice; choice="${choice:-4}"

    case "$choice" in
        1)
            BACKEND="xray_mack_a"
            XRAY_CONF_DIR="/etc/v2ray-agent/xray/conf"
            RELAY_INBOUND_FILE="$XRAY_CONF_DIR/relay_dedicated_inbound.json"
            SERVICE_NAME="xray"
            XRAY_BIN=$(find_xray_bin || true)
            ;;
        2)
            BACKEND="singbox_mack_a"
            SERVICE_NAME="sing-box"
            SINGBOX_BIN=$(find_singbox_bin || true)
            XRAY_BIN=$(find_xray_bin || true)
            SINGBOX_CONF="/etc/v2ray-agent/sing-box/config.json"
            RELAY_INBOUND_FILE="/etc/v2ray-agent/sing-box/conf/relay_dedicated_inbound.json"
            ;;
        3)
            BACKEND="singbox_standalone"
            read -rp "Sing-box 配置文件路径: " SINGBOX_CONF
            [[ -f "$SINGBOX_CONF" ]] || log_error "文件不存在: $SINGBOX_CONF"
            SINGBOX_BIN=$(find_singbox_bin || true)
            XRAY_BIN=$(find_xray_bin || true)
            SERVICE_NAME="sing-box"
            ;;
        *)
            BACKEND="manual"
            SERVICE_NAME=""
            ;;
    esac
    log_info "后端: $BACKEND"
}

# ════════════════════════════════════════════════════════════
# 读取配置：Xray
# ════════════════════════════════════════════════════════════
read_config_xray() {
    log_step "读取 Xray VLESS Reality 配置..."
    local conf_dir="$1"

    local result
    result=$(python3 - "$conf_dir" << 'PYEOF'
import json, glob, sys, os
conf_dir = sys.argv[1]
for fpath in sorted(glob.glob(os.path.join(conf_dir, "*.json"))):
    try: d = json.load(open(fpath))
    except: continue
    for ib in d.get("inbounds", []):
        if "relay-dedicated" in ib.get("tag", ""): continue
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
        log_error "未在 $conf_dir 找到 VLESS Reality 配置"

    while IFS='=' read -r key val; do
        case "$key" in
            PORT) VLESS_PORT="$val" ;; UUID) UUID="$val" ;;
            PRIVATE_KEY) PRIVATE_KEY="$val" ;; SNI) SNI="$val" ;;
            SHORT_ID) SHORT_ID="$val" ;; DEST) DEST="$val" ;;
        esac
    done <<< "$result"
    log_info "端口: $VLESS_PORT | SNI: $SNI"
}

# ════════════════════════════════════════════════════════════
# 读取配置：Sing-box
# ════════════════════════════════════════════════════════════
read_config_singbox() {
    log_step "读取 Sing-box VLESS Reality 配置..."

    # sing-box 支持单文件或目录
    local conf_paths=()
    if [[ -d "$SINGBOX_CONF" ]]; then
        while IFS= read -r -d '' f; do
            conf_paths+=("$f")
        done < <(find "$SINGBOX_CONF" -name "*.json" -print0 | sort -z)
    else
        conf_paths=("$SINGBOX_CONF")
    fi

    local result
    result=$(python3 - "${conf_paths[@]}" << 'PYEOF'
import json, sys

for fpath in sys.argv[1:]:
    try: d = json.load(open(fpath))
    except: continue
    for ib in d.get("inbounds", []):
        # Bug-2 修复：跳过已存在的中转专用入站，避免第二次运行读到自己写入的
        if "relay-dedicated" in ib.get("tag", ""): continue
        # Sing-box VLESS Reality 格式
        if ib.get("type") != "vless": continue
        tls = ib.get("tls", {})
        reality = tls.get("reality", {})
        if not reality.get("enabled"): continue
        private_key = reality.get("private_key", "")
        if not private_key: continue
        users = ib.get("users", [])
        uuid = users[0].get("uuid", "") if users else ""
        # SNI：从 handshake.server 或 tls.server_name 读取
        handshake = reality.get("handshake", {})
        sni = handshake.get("server", "") or tls.get("server_name", "")
        dest_port = handshake.get("server_port", 443)
        dest = f"{sni}:{dest_port}" if sni else ""
        short_ids = reality.get("short_id", [""])
        short_id = short_ids[0] if short_ids else ""
        port = ib.get("listen_port", "")
        print(f"PORT={port}")
        print(f"UUID={uuid}")
        print(f"PRIVATE_KEY={private_key}")
        print(f"SNI={sni}")
        print(f"SHORT_ID={short_id}")
        print(f"DEST={dest}")
        sys.exit(0)
print("NOT_FOUND")
PYEOF
)
    [[ "$result" == "NOT_FOUND" || -z "$result" ]] && \
        log_error "未在 $SINGBOX_CONF 找到 Sing-box VLESS Reality 配置"

    while IFS='=' read -r key val; do
        case "$key" in
            PORT) VLESS_PORT="$val" ;; UUID) UUID="$val" ;;
            PRIVATE_KEY) PRIVATE_KEY="$val" ;; SNI) SNI="$val" ;;
            SHORT_ID) SHORT_ID="$val" ;; DEST) DEST="$val" ;;
        esac
    done <<< "$result"
    log_info "端口: $VLESS_PORT | SNI: $SNI"
}

# ════════════════════════════════════════════════════════════
# 手动输入
# ════════════════════════════════════════════════════════════
read_config_manual() {
    echo ""
    echo -e "${YELLOW}── 手动输入落地机 VLESS Reality 参数 ──${NC}"
    read -rp "对外 VLESS 端口: "  VLESS_PORT
    read -rp "UUID: "            UUID
    read -rp "私钥 (privateKey): " PRIVATE_KEY
    read -rp "SNI: "             SNI
    read -rp "Short ID [空]: "   SHORT_ID
    read -rp "Dest [SNI:443]: "  DEST
    DEST="${DEST:-${SNI}:443}"
}

# ════════════════════════════════════════════════════════════
# 统一读取入口
# ════════════════════════════════════════════════════════════
read_reality_config() {
    case "$BACKEND" in
        xray_mack_a)
            read_config_xray "$XRAY_CONF_DIR"
            ;;
        singbox_mack_a | singbox_standalone)
            read_config_singbox
            ;;
        manual)
            read_config_manual
            ;;
    esac

    # 参数确认（统一入口）
    echo ""
    echo -e "${YELLOW}── 确认参数（回车保留自动读取值）──${NC}"
    read -rp "VLESS 端口  [${VLESS_PORT}]: "     i; [[ -n "$i" ]] && VLESS_PORT="$i"
    read -rp "UUID        [${UUID}]: "           i; [[ -n "$i" ]] && UUID="$i"
    read -rp "SNI         [${SNI}]: "            i; [[ -n "$i" ]] && SNI="$i"
    read -rp "Short ID    [${SHORT_ID:-空}]: "   i; [[ -n "$i" ]] && SHORT_ID="$i"

    [[ -z "$VLESS_PORT" || -z "$UUID" || -z "$SNI" || -z "$PRIVATE_KEY" ]] && \
        log_error "关键参数不完整，请检查落地机配置"
}

# ════════════════════════════════════════════════════════════
# 推导公钥（三级兜底）
# ════════════════════════════════════════════════════════════
derive_pubkey() {
    log_step "推导公钥..."

    # 方法一：xray x25519 -i（最可靠）
    if [[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]]; then
        local out; out=$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY" 2>&1) || true
        PUBLIC_KEY=$(echo "$out" | grep -iE "^(Public key|Password):" \
            | awk '{print $NF}' | tr -d '[:space:]' | head -1)
        [[ -z "$PUBLIC_KEY" ]] && \
            PUBLIC_KEY=$(echo "$out" | awk 'NR==2{print $NF}' | tr -d '[:space:]')
        if [[ -n "$PUBLIC_KEY" ]]; then
            log_info "公钥（via xray）: $PUBLIC_KEY"; return 0
        fi
        log_warn "xray 推导失败，尝试备用方法..."
    fi

    # 方法二：Python cryptography 库（支持 sing-box 环境无 xray 的情况）
    PUBLIC_KEY=$(python3 << PYEOF 2>/dev/null || true
import base64, sys
try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    pk = "$PRIVATE_KEY"
    # 补足 base64 padding
    pk += "=" * (4 - len(pk) % 4)
    raw = base64.urlsafe_b64decode(pk)
    priv = X25519PrivateKey.from_private_bytes(raw)
    pub_raw = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    print(base64.urlsafe_b64encode(pub_raw).decode().rstrip("="))
except ImportError:
    pass
PYEOF
)
    if [[ -n "$PUBLIC_KEY" ]]; then
        log_info "公钥（via Python cryptography）: $PUBLIC_KEY"; return 0
    fi

    # 方法三：尝试安装 cryptography 后重试
    log_warn "Python cryptography 库未安装，尝试安装..."
    pip3 install cryptography -q 2>/dev/null || \
        pip install cryptography -q 2>/dev/null || true

    PUBLIC_KEY=$(python3 << PYEOF 2>/dev/null || true
import base64
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
pk = "$PRIVATE_KEY"
pk += "=" * (4 - len(pk) % 4)
raw = base64.urlsafe_b64decode(pk)
priv = X25519PrivateKey.from_private_bytes(raw)
pub_raw = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
print(base64.urlsafe_b64encode(pub_raw).decode().rstrip("="))
PYEOF
)
    if [[ -n "$PUBLIC_KEY" ]]; then
        log_info "公钥（via Python cryptography，安装后）: $PUBLIC_KEY"; return 0
    fi

    # 三级全部失败，要求手动输入
    log_warn "无法自动推导公钥"
    read -rp "请手动输入公钥 (publicKey): " PUBLIC_KEY
    [[ -z "$PUBLIC_KEY" ]] && log_error "公钥不能为空"
    log_info "公钥（手动）: $PUBLIC_KEY"
}

# ════════════════════════════════════════════════════════════
# 获取公网 IP
# ════════════════════════════════════════════════════════════
get_public_ip() {
    log_step "获取公网 IP..."
    PUBLIC_IP=$(
        curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null ||
        curl -s4 --connect-timeout 5 https://ifconfig.me   2>/dev/null ||
        curl -s4 --connect-timeout 5 https://icanhazip.com 2>/dev/null ||
        echo ""
    )
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '[:space:]')

    # Bug-3 修复：curl 全部超时（大陆/特殊环境常见）时 PUBLIC_IP 为空
    # 此时必须手动输入，不能用 "unknown" 继续（否则后续 Python/节点链接报错）
    if [[ -z "$PUBLIC_IP" ]]; then
        log_warn "自动获取公网 IP 失败（网络不通或被限制）"
        while true; do
            read -rp "请手动输入落地机公网 IP: " PUBLIC_IP
            # 简单校验 IPv4 格式
            if [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                break
            fi
            log_warn "IP 格式不正确，请重新输入（示例：1.2.3.4）"
        done
    else
        read -rp "落地机公网 IP [回车使用 $PUBLIC_IP]: " i
        [[ -n "$i" ]] && PUBLIC_IP="$i"
    fi
    log_info "IP: $PUBLIC_IP"
}

# ════════════════════════════════════════════════════════════
# 配置中转专用入站：Xray 格式
# ════════════════════════════════════════════════════════════
setup_relay_inbound_xray() {
    RELAY_INBOUND_FILE="$XRAY_CONF_DIR/relay_dedicated_inbound.json"

    python3 << PYEOF
import json, sys

port        = int("${RELAY_DEDICATED_PORT}")
uuid        = """${UUID}"""
private_key = """${PRIVATE_KEY}"""
sni         = """${SNI}"""
short_id    = """${SHORT_ID}"""
dest        = """${DEST}""" or f"{sni}:443"
out_file    = """${RELAY_INBOUND_FILE}"""

for name, val in [("UUID", uuid), ("privateKey", private_key), ("SNI", sni)]:
    if not val.strip():
        print(f"[✗] {name} 为空", file=sys.stderr); sys.exit(1)

config = {"inbounds": [{
    "tag": f"relay-dedicated-in-{port}",
    "port": port,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
        "clients": [{"id": uuid.strip(), "flow": "xtls-rprx-vision"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "show": False,
            "dest": dest.strip(),
            "xver": 0,
            "serverNames": [sni.strip()],
            "privateKey": private_key.strip(),
            "shortIds": [short_id.strip()]
        }
    }
}]}

with open(out_file, "w") as f:
    json.dump(config, f, indent=2)
print(f"[✓] Xray 专用入站已写入: {out_file}")
PYEOF
}

# ════════════════════════════════════════════════════════════
# 配置中转专用入站：Sing-box 格式
# ════════════════════════════════════════════════════════════
setup_relay_inbound_singbox() {
    # Sing-box 没有目录加载机制，需要修改主配置文件（原子操作）
    local conf_file
    if [[ -d "$SINGBOX_CONF" ]]; then
        # mack-a 目录模式：找主配置或 config.json
        conf_file=$(find "$SINGBOX_CONF" -maxdepth 1 -name "config.json" | head -1)
        [[ -z "$conf_file" ]] && \
            conf_file=$(find "$SINGBOX_CONF" -maxdepth 1 -name "*.json" | sort | head -1)
    else
        conf_file="$SINGBOX_CONF"
    fi
    [[ -z "$conf_file" || ! -f "$conf_file" ]] && \
        log_error "找不到 Sing-box 配置文件"

    RELAY_INBOUND_FILE="$conf_file"  # 记录修改的文件
    log_info "修改 Sing-box 配置: $conf_file"

    python3 << PYEOF
import json, sys, shutil
from datetime import datetime

port        = int("${RELAY_DEDICATED_PORT}")
uuid        = """${UUID}""".strip()
private_key = """${PRIVATE_KEY}""".strip()
sni         = """${SNI}""".strip()
short_id    = """${SHORT_ID}""".strip()
dest        = """${DEST}""".strip() or f"{sni}:443"
dest_host   = dest.split(":")[0]
dest_port   = int(dest.split(":")[-1]) if ":" in dest else 443
conf_file   = """${conf_file}"""
tag         = f"relay-dedicated-in-{port}"

# 备份原配置
bak = conf_file + f".bak.{datetime.now().strftime('%Y%m%d%H%M%S')}"
shutil.copy2(conf_file, bak)

try:
    with open(conf_file) as f:
        config = json.load(f)
except Exception as e:
    print(f"[✗] 读取配置失败: {e}", file=sys.stderr); sys.exit(1)

# 删除已有的同标签入站
config["inbounds"] = [ib for ib in config.get("inbounds", [])
                      if ib.get("tag") != tag]

# 新入站（Sing-box VLESS Reality 格式）
new_inbound = {
    "type": "vless",
    "tag": tag,
    "listen": "::",
    "listen_port": port,
    "users": [{"uuid": uuid, "flow": "xtls-rprx-vision"}],
    "tls": {
        "enabled": True,
        "server_name": sni,
        "reality": {
            "enabled": True,
            "handshake": {"server": dest_host, "server_port": dest_port},
            "private_key": private_key,
            "short_id": [short_id]
        }
    }
}
config["inbounds"].append(new_inbound)

with open(conf_file, "w") as f:
    json.dump(config, f, indent=2)
print(f"[✓] Sing-box 专用入站已写入（端口 {port}）")
print(f"[✓] 原配置已备份: {bak}")
PYEOF
}

# ════════════════════════════════════════════════════════════
# 统一入站配置入口
# ════════════════════════════════════════════════════════════
setup_relay_inbound() {
    log_step "配置中转专用直连入站..."

    # 推荐端口（python3 socket 检测，可靠）
    local existing_port=""
    # BUG-L1 修复：singbox 后端的 RELAY_INBOUND_FILE 初始值不可靠（指向不存在的文件）
    # 统一改为直接从实际配置文件里按 relay-dedicated tag 精准查找已有中转端口
    local _search_file=""
    case "$BACKEND" in
        xray_mack_a)
            # Xray：RELAY_INBOUND_FILE 是独立文件，可直接读
            _search_file="$RELAY_INBOUND_FILE"
            ;;
        singbox_mack_a | singbox_standalone)
            # Singbox：已有入站在主配置文件里，需找到实际 conf 文件
            if [[ -d "$SINGBOX_CONF" ]]; then
                _search_file=$(find "$SINGBOX_CONF" -maxdepth 1 \
                    -name "config.json" | head -1)
                [[ -z "$_search_file" ]] && \
                    _search_file=$(find "$SINGBOX_CONF" -maxdepth 1 \
                        -name "*.json" | sort | head -1)
            else
                _search_file="$SINGBOX_CONF"
            fi
            ;;
    esac

    if [[ -n "$_search_file" && -f "$_search_file" ]]; then
        existing_port=$(python3 -c "
import json
try:
    d = json.load(open('$_search_file'))
    for ib in d.get('inbounds', []):
        if 'relay-dedicated' in ib.get('tag', ''):
            print(ib.get('port') or ib.get('listen_port', ''))
            break
except: pass" 2>/dev/null || true)
        [[ -n "$existing_port" ]] && \
            log_warn "已存在中转专用入站（端口 $existing_port），将覆盖更新"
    fi

    local suggest=45001
    [[ -n "$existing_port" ]] && suggest="$existing_port"
    if [[ -z "$existing_port" ]]; then
        suggest=$(python3 -c "
import socket
p = 45001
while True:
    try:
        s = socket.socket(); s.settimeout(0.1)
        s.bind(('0.0.0.0', p)); s.close(); print(p); break
    except OSError: p += 1
" 2>/dev/null || echo 45001)
    fi

    read -rp "中转专用端口 [回车使用 $suggest]: " i
    RELAY_DEDICATED_PORT="${i:-$suggest}"
    [[ "$RELAY_DEDICATED_PORT" =~ ^[0-9]+$ ]] && \
        (( RELAY_DEDICATED_PORT >= 1024 && RELAY_DEDICATED_PORT <= 65535 )) || \
        log_error "端口 $RELAY_DEDICATED_PORT 不合法"

    echo ""
    echo -e "${YELLOW}安全建议：限制只允许中转机 IP 访问此端口${NC}"
    read -rp "中转机公网 IP（留空=不限制，依靠 Reality+UUID 保护）: " \
        RELAY_IP_RESTRICTION

    case "$BACKEND" in
        xray_mack_a)
            setup_relay_inbound_xray
            ;;
        singbox_mack_a | singbox_standalone)
            setup_relay_inbound_singbox
            ;;
        manual)
            log_warn "手动模式：跳过自动写入入站配置"
            log_warn "请手动在你的代理软件中添加监听 0.0.0.0:${RELAY_DEDICATED_PORT} 的 VLESS Reality 入站"
            ;;
    esac
    log_info "专用入站端口: $RELAY_DEDICATED_PORT"
}

# ════════════════════════════════════════════════════════════
# 防火墙（BUG 修复：正确使用 -I 插入顺序）
# ════════════════════════════════════════════════════════════
ensure_iptables_persistent() {
    if ! dpkg -l iptables-persistent &>/dev/null 2>&1; then
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | \
            debconf-set-selections 2>/dev/null || true
        echo iptables-persistent iptables-persistent/autosave_v6 boolean false | \
            debconf-set-selections 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            iptables-persistent netfilter-persistent 2>/dev/null || \
            log_warn "iptables-persistent 安装失败，规则可能重启后丢失"
    fi
}

save_iptables() {
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    command -v netfilter-persistent &>/dev/null && \
        netfilter-persistent save >/dev/null 2>&1 || true
}

setup_firewall() {
    log_step "配置防火墙端口 $RELAY_DEDICATED_PORT..."
    ensure_iptables_persistent

    # ── 清除本端口所有旧规则 ─────────────────────────────
    for _ in $(seq 1 10); do
        iptables -D INPUT -p tcp --dport "$RELAY_DEDICATED_PORT" \
            -j ACCEPT 2>/dev/null || break
    done
    for _ in $(seq 1 10); do
        iptables -D INPUT -p tcp --dport "$RELAY_DEDICATED_PORT" \
            -j DROP 2>/dev/null || break
    done
    if [[ -n "$RELAY_IP_RESTRICTION" ]]; then
        for _ in $(seq 1 10); do
            iptables -D INPUT -p tcp -s "$RELAY_IP_RESTRICTION" \
                --dport "$RELAY_DEDICATED_PORT" -j ACCEPT 2>/dev/null || break
        done
    fi

    if [[ -n "$RELAY_IP_RESTRICTION" ]]; then
        # ── 白名单模式 ─────────────────────────────────────
        # 正确插入顺序（原 BUG 修复）：
        # 先插 DROP 到位置1，再插 ACCEPT 到位置1（将 DROP 推到位置2）
        # 最终链顺序：ACCEPT(来源限制) → DROP(其他) → 原有规则...
        # 全平台统一使用 -I，不再区分 Oracle（-A 在 Oracle 上对 REJECT 前规则无效）
        iptables -I INPUT 1 -p tcp --dport "$RELAY_DEDICATED_PORT" -j DROP
        iptables -I INPUT 1 -p tcp -s "$RELAY_IP_RESTRICTION" \
            --dport "$RELAY_DEDICATED_PORT" -j ACCEPT
        log_info "防火墙：仅 $RELAY_IP_RESTRICTION 可访问端口 $RELAY_DEDICATED_PORT"
    else
        # ── 开放模式 ──────────────────────────────────────
        iptables -I INPUT 1 -p tcp --dport "$RELAY_DEDICATED_PORT" -j ACCEPT
        log_warn "防火墙：端口 $RELAY_DEDICATED_PORT 对所有来源开放（Reality+UUID 保护）"
    fi

    save_iptables

    if $IS_ORACLE; then
        # Oracle 额外强制持久化（oci 规则链可能干扰 iptables-save 时序）
        netfilter-persistent save >/dev/null 2>&1 || true
        echo ""
        echo -e "${YELLOW}⚠ 甲骨文云提示：${NC}"
        echo -e "  iptables 已设置，但还需在 OCI 控制台放行："
        echo -e "  路径：VCN → 子网 → 安全列表 → 入站规则 → 添加 TCP ${RELAY_DEDICATED_PORT}"
        echo ""
    fi
}

# ════════════════════════════════════════════════════════════
# 验证并重启服务
# ════════════════════════════════════════════════════════════
restart_service() {
    log_step "验证配置并重启服务..."

    case "$BACKEND" in
        xray_mack_a)
            if [[ -n "$XRAY_BIN" ]] && \
               ! "$XRAY_BIN" -test -confdir "$XRAY_CONF_DIR" >/dev/null 2>&1; then
                echo -e "${RED}配置验证失败：${NC}"
                "$XRAY_BIN" -test -confdir "$XRAY_CONF_DIR" 2>&1 | tail -10
                log_error "请检查 $RELAY_INBOUND_FILE"
            fi
            systemctl restart "$SERVICE_NAME" && \
                log_info "Xray 重启成功" || \
                log_error "Xray 重启失败：journalctl -u $SERVICE_NAME -n 20"
            ;;
        singbox_mack_a | singbox_standalone)
            if [[ -n "$SINGBOX_BIN" ]]; then
                # 用数组存参数，避免路径含空格时 word-split 问题
                local -a conf_arg
                if [[ -d "$SINGBOX_CONF" ]]; then
                    conf_arg=(-D "$SINGBOX_CONF")
                else
                    conf_arg=(-c "$SINGBOX_CONF")
                fi
                if ! "$SINGBOX_BIN" check "${conf_arg[@]}" >/dev/null 2>&1; then
                    echo -e "${RED}Sing-box 配置验证失败：${NC}"
                    "$SINGBOX_BIN" check "${conf_arg[@]}" 2>&1 | tail -10
                    log_error "请检查 $RELAY_INBOUND_FILE"
                fi
            fi
            systemctl restart "$SERVICE_NAME" && \
                log_info "Sing-box 重启成功" || \
                log_error "Sing-box 重启失败：journalctl -u $SERVICE_NAME -n 20"
            ;;
        manual)
            log_warn "手动模式：请自行重启你的代理服务"
            ;;
    esac
}

# ════════════════════════════════════════════════════════════
# 保存信息
# ════════════════════════════════════════════════════════════
save_info() {
    local direct_link
    direct_link="vless://${UUID}@${PUBLIC_IP}:${VLESS_PORT}"
    direct_link+="?encryption=none&flow=xtls-rprx-vision"
    direct_link+="&security=reality&sni=${SNI}&fp=chrome"
    direct_link+="&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}"
    direct_link+="&type=tcp&headerType=none"
    direct_link+="#LuoDi-Direct-${PUBLIC_IP}"

    cat > "$INFO_FILE" << EOF
============================================================
  落地机信息  $(date '+%Y-%m-%d %H:%M:%S')
  后端：${BACKEND}
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
LUODI_BACKEND=${BACKEND}

── 直连测试链接（不经过中转，验证落地机是否正常）────────
DIRECT_LINK=${direct_link}
============================================================
EOF
    log_info "信息已保存: $INFO_FILE"
}

# ════════════════════════════════════════════════════════════
# 打印结果
# ════════════════════════════════════════════════════════════
print_result() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  ${GREEN}${BOLD}✓ 落地机配置完成  luodi.sh v5.2${NC}                     ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}后端类型       :${NC} $BACKEND"
    echo -e "  ${BOLD}落地机 IP      :${NC} $PUBLIC_IP"
    echo -e "  ${BOLD}中转专用端口   :${NC} $RELAY_DEDICATED_PORT"
    echo -e "  ${BOLD}UUID           :${NC} $UUID"
    echo -e "  ${BOLD}公钥           :${NC} $PUBLIC_KEY"
    echo -e "  ${BOLD}SNI            :${NC} $SNI"
    echo -e "  ${BOLD}来源IP限制     :${NC} ${RELAY_IP_RESTRICTION:-未限制}"
    echo ""
    echo -e "${YELLOW}下一步：${NC}"
    echo -e "  1. 在中转机上运行 ${CYAN}zhongzhuan.sh${NC}（如尚未初始化）"
    echo -e "  2. 回到本落地机，运行 ${CYAN}duijie.sh${NC} 完成对接"
    echo -e "  3. 再次查看信息：${CYAN}cat $INFO_FILE${NC}"
    echo ""
}

# ════════════════════════════════════════════════════════════
# 主函数
# ════════════════════════════════════════════════════════════
main() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         落地机配置脚本  luodi.sh  v5.2              ║${NC}"
    echo -e "${CYAN}║  支持：mack-a Xray / mack-a Sing-box / 独立Singbox ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    detect_oracle
    detect_backend
    read_reality_config
    derive_pubkey
    get_public_ip
    setup_relay_inbound
    setup_firewall
    restart_service
    save_info
    print_result
}

main "$@"
