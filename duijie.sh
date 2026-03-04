#!/bin/bash
# ============================================================
# duijie.sh — 落地机与中转机对接脚本 v2.1
# 功能：在落地机上运行，SSH 到中转机自动添加入站+出站配置
# 支持：密码认证 / 密钥文件路径 / 粘贴私钥内容（甲骨文云等）
# 使用：bash <(curl -s https://your-host/duijie.sh)
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

LUODI_INFO_FILE="/root/xray_luodi_info.txt"
XRAY_BIN="/usr/local/bin/xray"
TEMP_KEY=""

# ── 退出时清理临时密钥文件 ────────────────────────────────
cleanup() {
    [[ -n "$TEMP_KEY" && -f "$TEMP_KEY" ]] && rm -f "$TEMP_KEY"
}
trap cleanup EXIT

[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

# ── 安装依赖 ───────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in ssh jq curl openssl python3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "安装缺失依赖: ${missing[*]}"
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq openssh-client jq curl openssl python3 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum install -y -q openssh-clients jq curl openssl python3 2>/dev/null || true
        fi
    fi
}

# ── 读取落地机信息 ─────────────────────────────────────────
read_luodi_info() {
    info "读取落地机配置信息..."
    [[ ! -f "$LUODI_INFO_FILE" ]] && \
        error "未找到 $LUODI_INFO_FILE，请先在落地机上运行 luodi.sh"

    LUODI_IP=$(grep      "^LUODI_IP="      "$LUODI_INFO_FILE" | cut -d= -f2)
    LUODI_PORT=$(grep    "^LUODI_PORT="    "$LUODI_INFO_FILE" | cut -d= -f2)
    LUODI_UUID=$(grep    "^LUODI_UUID="    "$LUODI_INFO_FILE" | cut -d= -f2)
    LUODI_PUBKEY=$(grep  "^LUODI_PUBKEY="  "$LUODI_INFO_FILE" | cut -d= -f2)
    LUODI_SHORTID=$(grep "^LUODI_SHORTID=" "$LUODI_INFO_FILE" | cut -d= -f2)
    LUODI_SNI=$(grep     "^LUODI_SNI="     "$LUODI_INFO_FILE" | cut -d= -f2)

    [[ -z "$LUODI_IP" || -z "$LUODI_PORT" || -z "$LUODI_UUID" ]] && \
        error "落地机信息不完整，请重新运行 luodi.sh"

    success "落地机信息读取成功"
    printf "  %-8s: ${CYAN}%s${NC}\n" "IP"   "$LUODI_IP"
    printf "  %-8s: ${CYAN}%s${NC}\n" "端口" "$LUODI_PORT"
    printf "  %-8s: ${CYAN}%s${NC}\n" "UUID" "$LUODI_UUID"
}

# ── 扫描本机已有 SSH 私钥 ──────────────────────────────────
scan_ssh_keys() {
    local keys=()
    for f in ~/.ssh/id_rsa ~/.ssh/id_ed25519 ~/.ssh/id_ecdsa \
              ~/.ssh/oracle_key ~/.ssh/oci_key /root/.ssh/id_rsa \
              /root/.ssh/id_ed25519; do
        f_real=$(eval echo "$f")
        [[ -f "$f_real" ]] && keys+=("$f_real")
    done
    # 还搜索 /root 下 .pem 文件
    while IFS= read -r pem; do
        keys+=("$pem")
    done < <(find /root -maxdepth 2 -name "*.pem" 2>/dev/null)
    echo "${keys[@]}"
}

# ── 配置 SSH 连接 ──────────────────────────────────────────
get_zhongzhuan_ssh() {
    echo ""
    echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  配置中转机 SSH 连接${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"
    echo ""

    echo "请选择对接方式："
    echo "  1) SSH 自动对接（推荐）"
    echo "  2) 手动模式（脚本输出配置片段，手动粘贴到中转机）"
    read -rp "选择 [1/2，默认1]: " MODE
    MODE=${MODE:-1}
    if [[ "$MODE" == "2" ]]; then
        MANUAL_MODE=true
        return
    fi
    MANUAL_MODE=false

    # 中转机地址
    read -rp "中转机 IP 或域名: " ZZ_HOST
    [[ -z "$ZZ_HOST" ]] && error "中转机地址不能为空"

    read -rp "SSH 端口 [默认 22]: " ZZ_SSH_PORT
    ZZ_SSH_PORT=${ZZ_SSH_PORT:-22}

    # SSH 用户名
    echo ""
    echo "中转机 SSH 用户名："
    echo "  1) root    （大多数 VPS 默认）"
    echo "  2) ubuntu  （甲骨文 Ubuntu 镜像）"
    echo "  3) opc     （甲骨文 Oracle Linux 镜像）"
    echo "  4) 手动输入"
    read -rp "选择 [1/2/3/4，默认1]: " USER_OPT
    case "${USER_OPT:-1}" in
        2) ZZ_USER="ubuntu" ;;
        3) ZZ_USER="opc" ;;
        4) read -rp "用户名: " ZZ_USER ;;
        *) ZZ_USER="root" ;;
    esac
    info "SSH 用户名: $ZZ_USER"

    # 认证方式
    echo ""
    echo "SSH 认证方式："
    echo "  1) 密码"
    echo "  2) 密钥文件（本地有 .pem / id_rsa 等文件）"
    echo "  3) 粘贴私钥内容  ← 甲骨文云下载的 .pem 内容，从电脑复制过来"
    read -rp "选择 [1/2/3，默认2]: " AUTH_OPT
    AUTH_OPT=${AUTH_OPT:-2}

    case "$AUTH_OPT" in
        1) _setup_password ;;
        3) _setup_paste_key ;;
        *) _setup_keyfile ;;
    esac

    _test_ssh
}

# ── 认证1：密码 ────────────────────────────────────────────
_setup_password() {
    AUTH_TYPE="password"
    read -rsp "SSH 密码: " ZZ_PASS
    echo ""
    if ! command -v sshpass &>/dev/null; then
        info "安装 sshpass..."
        apt-get install -y -qq sshpass 2>/dev/null || \
        yum install -y -q sshpass 2>/dev/null || \
        error "sshpass 安装失败，建议改用密钥认证"
    fi
    SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
}

# ── 认证2：密钥文件路径 ────────────────────────────────────
_setup_keyfile() {
    AUTH_TYPE="keyfile"
    local found_keys
    read -ra found_keys <<< "$(scan_ssh_keys)"

    if [[ ${#found_keys[@]} -gt 0 ]]; then
        echo ""
        echo "检测到以下密钥文件，选择或手动输入路径："
        local i
        for i in "${!found_keys[@]}"; do
            echo "  $((i+1))) ${found_keys[$i]}"
        done
        echo "  $((${#found_keys[@]}+1))) 手动输入"
        read -rp "选择 [默认1]: " K_OPT
        K_OPT=${K_OPT:-1}
        if [[ "$K_OPT" -le "${#found_keys[@]}" ]] 2>/dev/null; then
            ZZ_KEY="${found_keys[$((K_OPT-1))]}"
        else
            read -rp "密钥路径 (支持 ~ 展开): " ZZ_KEY
            ZZ_KEY=$(eval echo "$ZZ_KEY")
        fi
    else
        read -rp "密钥文件路径 [如 /root/oracle.pem 或 ~/.ssh/id_rsa]: " ZZ_KEY
        ZZ_KEY=$(eval echo "$ZZ_KEY")
    fi

    [[ ! -f "$ZZ_KEY" ]] && error "文件不存在: $ZZ_KEY"
    chmod 600 "$ZZ_KEY"
    info "使用密钥: $ZZ_KEY"
    SSH_OPTS="-i $ZZ_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
}

# ── 认证3：粘贴私钥内容 ────────────────────────────────────
_setup_paste_key() {
    AUTH_TYPE="keyfile"
    echo ""
    echo -e "${YELLOW}请粘贴私钥内容（以 -----BEGIN ... PRIVATE KEY----- 开头）${NC}"
    echo -e "${YELLOW}粘贴完成后，新起一行输入 END 并回车：${NC}"
    echo ""

    local key_lines=""
    local line
    while IFS= read -r line; do
        [[ "$line" == "END" ]] && break
        key_lines+="${line}"$'\n'
    done

    echo "$key_lines" | grep -q "PRIVATE KEY" || \
        error "内容不包含 PRIVATE KEY，请确认粘贴了完整私钥"

    TEMP_KEY=$(mktemp /tmp/.ssh_key_XXXXXX)
    chmod 600 "$TEMP_KEY"
    printf '%s' "$key_lines" > "$TEMP_KEY"
    ZZ_KEY="$TEMP_KEY"
    info "私钥已写入临时文件（脚本结束后自动删除）"
    SSH_OPTS="-i $ZZ_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
}

# ── 测试 SSH 连通性 ────────────────────────────────────────
_test_ssh() {
    info "测试 SSH 连接 ${ZZ_USER}@${ZZ_HOST}:${ZZ_SSH_PORT} ..."
    local out
    out=$(_ssh_run "echo __CONN_OK__" 2>&1) || true
    if echo "$out" | grep -q "__CONN_OK__"; then
        success "SSH 连接成功 ✓"
    else
        echo -e "${RED}连接失败，原始错误：${NC}"
        echo "$out"
        echo ""
        echo -e "${YELLOW}甲骨文云常见问题排查：${NC}"
        echo "  1. 安全组/NSG 需放行 SSH 端口（默认22）"
        echo "  2. Ubuntu 镜像用 ubuntu，Oracle Linux 镜像用 opc"
        echo "  3. 密钥需与创建实例时上传的公钥对应"
        echo "  4. 如果用密码方式，甲骨文默认禁用密码登录，需改用密钥"
        echo "  5. .pem 文件需 chmod 600"
        error "请检查后重试"
    fi
}

# ── 统一执行远端命令 ───────────────────────────────────────
_ssh_run() {
    local cmd="$1"
    if [[ "$AUTH_TYPE" == "password" ]]; then
        sshpass -p "$ZZ_PASS" ssh $SSH_OPTS -p "$ZZ_SSH_PORT" "$ZZ_USER@$ZZ_HOST" "$cmd"
    else
        ssh $SSH_OPTS -p "$ZZ_SSH_PORT" "$ZZ_USER@$ZZ_HOST" "$cmd"
    fi
}

# ── 统一向远端传入脚本（stdin） ────────────────────────────
_ssh_pipe() {
    if [[ "$AUTH_TYPE" == "password" ]]; then
        sshpass -p "$ZZ_PASS" ssh $SSH_OPTS -p "$ZZ_SSH_PORT" "$ZZ_USER@$ZZ_HOST" bash -s
    else
        ssh $SSH_OPTS -p "$ZZ_SSH_PORT" "$ZZ_USER@$ZZ_HOST" bash -s
    fi
}

# ── 获取下一个可用端口 ─────────────────────────────────────
get_next_port() {
    info "查询中转机端口分配情况..."

    NODES_JSON=$(_ssh_run "cat /usr/local/etc/xray/nodes.json 2>/dev/null || echo '{\"nodes\":[]}'")
    ZZ_META=$(_ssh_run    "cat /root/xray_zhongzhuan_info.txt 2>/dev/null || echo ''")

    START_PORT=$(echo "$ZZ_META" | grep "^ZHONGZHUAN_START_PORT=" | cut -d= -f2)
    MAX_NODES=$(echo  "$ZZ_META" | grep "^ZHONGZHUAN_MAX_NODES="  | cut -d= -f2)
    START_PORT=${START_PORT:-10001}
    MAX_NODES=${MAX_NODES:-20}

    USED_PORTS=$(echo "$NODES_JSON" | jq -r '.nodes[].inbound_port' 2>/dev/null || echo "")

    NEXT_PORT=""
    for ((p=START_PORT; p<START_PORT+MAX_NODES; p++)); do
        echo "$USED_PORTS" | grep -qx "$p" || { NEXT_PORT=$p; break; }
    done

    [[ -z "$NEXT_PORT" ]] && error "所有 $MAX_NODES 个端口已用满，请扩容中转机"

    echo ""
    [[ -n "$USED_PORTS" ]] && echo -e "  已用端口: ${YELLOW}$(echo $USED_PORTS | tr '\n' ' ')${NC}"
    echo -e "  建议端口: ${CYAN}${NEXT_PORT}${NC}"
    read -rp "确认 [回车=$NEXT_PORT，或输入其他端口]: " TMP
    [[ -n "$TMP" ]] && NEXT_PORT="$TMP"
    info "本次使用端口: $NEXT_PORT"
}

# ── 生成中转机入站 Reality 密钥对 ─────────────────────────
gen_relay_keys() {
    info "生成中转机入站 Reality 密钥对..."
    if [[ -f "$XRAY_BIN" ]]; then
        local kout
        kout=$("$XRAY_BIN" x25519 2>/dev/null)
        RELAY_PRIVKEY=$(echo "$kout" | grep "Private key:" | awk '{print $3}')
        RELAY_PUBKEY=$(echo  "$kout" | grep "Public key:"  | awk '{print $3}')
    else
        warn "本机无 xray，使用 fallback 密钥（建议先运行 luodi.sh）"
        RELAY_PRIVKEY="$LUODI_PUBKEY"
        RELAY_PUBKEY="$LUODI_PUBKEY"
    fi
    RELAY_SHORTID=$(openssl rand -hex 8)
    NODE_TAG="node-$(echo "$LUODI_IP" | tr '.' '-')-${NEXT_PORT}"
}

# ── 注入配置到中转机 ───────────────────────────────────────
inject_config() {
    info "将配置注入到中转机..."

    # 通过管道传入 bash 脚本，脚本内用 python3 操作 JSON
    # 所有变量通过 export 传递给远端 python3
    _ssh_pipe <<REMOTE_SCRIPT
export NODE_TAG="${NODE_TAG}"
export NEXT_PORT="${NEXT_PORT}"
export LUODI_IP="${LUODI_IP}"
export LUODI_PORT="${LUODI_PORT}"
export LUODI_UUID="${LUODI_UUID}"
export LUODI_PUBKEY="${LUODI_PUBKEY}"
export LUODI_SHORTID="${LUODI_SHORTID}"
export LUODI_SNI="${LUODI_SNI}"
export RELAY_PRIVKEY="${RELAY_PRIVKEY}"
export RELAY_PUBKEY="${RELAY_PUBKEY}"
export RELAY_SHORTID="${RELAY_SHORTID}"
export ADDED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

set -e
CFG="/usr/local/etc/xray/config.json"
NDS="/usr/local/etc/xray/nodes.json"

[[ ! -f "\$CFG" ]] && echo "[ERROR] 中转机配置文件不存在: \$CFG" && exit 1

# 备份
cp "\$CFG" "\${CFG}.bak.\$(date +%s)"

python3 - <<'PYEOF'
import json, os, sys

cfg_path   = "/usr/local/etc/xray/config.json"
nodes_path = "/usr/local/etc/xray/nodes.json"
e = os.environ

try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except Exception as ex:
    print(f"[ERROR] 无法解析配置文件: {ex}")
    sys.exit(1)

tag          = e["NODE_TAG"]
in_port      = int(e["NEXT_PORT"])
luodi_ip     = e["LUODI_IP"]
luodi_port   = int(e["LUODI_PORT"])
uuid         = e["LUODI_UUID"]
luodi_pubkey = e["LUODI_PUBKEY"]
luodi_sid    = e["LUODI_SHORTID"]
sni          = e["LUODI_SNI"]
r_privkey    = e["RELAY_PRIVKEY"]
r_pubkey     = e["RELAY_PUBKEY"]
r_sid        = e["RELAY_SHORTID"]
added_at     = e["ADDED_AT"]

# 检查端口是否已存在
for ib in cfg.get("inbounds", []):
    if ib.get("port") == in_port:
        print(f"[ERROR] 端口 {in_port} 已被占用，请换一个端口")
        sys.exit(1)

# 入站：用户 → 中转机（Reality 在中转机终结）
new_in = {
    "tag": f"{tag}-in",
    "listen": "0.0.0.0",
    "port": in_port,
    "protocol": "vless",
    "settings": {
        "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "show": False,
            "dest": f"{sni}:443",
            "xver": 0,
            "serverNames": [sni],
            "privateKey": r_privkey,
            "shortIds": [r_sid]
        }
    },
    "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}
}

# 出站：中转机 → 落地机（Reality 连落地机）
new_out = {
    "tag": f"{tag}-out",
    "protocol": "vless",
    "settings": {
        "vnext": [{
            "address": luodi_ip,
            "port": luodi_port,
            "users": [{"id": uuid, "flow": "xtls-rprx-vision", "encryption": "none"}]
        }]
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "fingerprint": "chrome",
            "serverName": sni,
            "publicKey": luodi_pubkey,
            "shortId": luodi_sid
        }
    }
}

# 路由：该入站 → 该出站（插最前确保优先命中）
new_rule = {
    "type": "field",
    "inboundTag": [f"{tag}-in"],
    "outboundTag": f"{tag}-out"
}

cfg.setdefault("inbounds",  []).append(new_in)
cfg.setdefault("outbounds", []).append(new_out)
cfg.setdefault("routing", {}).setdefault("rules", []).insert(0, new_rule)

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

# 更新节点记录
try:
    with open(nodes_path) as f:
        nodes = json.load(f)
except Exception:
    nodes = {"nodes": []}

nodes["nodes"].append({
    "tag":           tag,
    "luodi_ip":      luodi_ip,
    "luodi_port":    luodi_port,
    "inbound_port":  in_port,
    "relay_pubkey":  r_pubkey,
    "relay_shortid": r_sid,
    "uuid":          uuid,
    "added_at":      added_at
})

with open(nodes_path, "w") as f:
    json.dump(nodes, f, indent=2, ensure_ascii=False)

print("[OK] 配置注入成功")
PYEOF
REMOTE_SCRIPT

    success "配置注入完成"

    # 重启中转机 Xray
    info "重启中转机 Xray 服务..."
    local st
    st=$(_ssh_run "systemctl restart xray 2>&1; sleep 2; systemctl is-active xray 2>&1" || echo "unknown")
    if echo "$st" | grep -q "^active"; then
        success "中转机 Xray 重启成功 ✓"
    else
        warn "Xray 状态异常，请登录中转机检查："
        warn "  journalctl -u xray -n 30 --no-pager"
        warn "  xray -test -c /usr/local/etc/xray/config.json"
    fi
}

# ── 手动模式 ───────────────────────────────────────────────
manual_mode() {
    echo ""
    echo -e "${YELLOW}══════════ 手动对接模式 ══════════════════════════════${NC}"
    read -rp "中转机上使用哪个端口？(例如 10001): " NEXT_PORT
    [[ -z "$NEXT_PORT" ]] && error "端口不能为空"

    # 手动模式下在本机生成密钥
    gen_relay_keys

    echo ""
    echo -e "${CYAN}══ 1. 追加到中转机 inbounds 数组 ══════════════════════${NC}"
    python3 - <<PYEOF
import json
d = {
    "tag": "${NODE_TAG}-in",
    "listen": "0.0.0.0",
    "port": int("${NEXT_PORT}"),
    "protocol": "vless",
    "settings": {"clients":[{"id":"${LUODI_UUID}","flow":"xtls-rprx-vision"}],"decryption":"none"},
    "streamSettings": {
        "network":"tcp","security":"reality",
        "realitySettings":{
            "show":False,"dest":"${LUODI_SNI}:443","xver":0,
            "serverNames":["${LUODI_SNI}"],
            "privateKey":"${RELAY_PRIVKEY}",
            "shortIds":["${RELAY_SHORTID}"]
        }
    },
    "sniffing":{"enabled":True,"destOverride":["http","tls","quic"]}
}
print(json.dumps(d,indent=2,ensure_ascii=False))
PYEOF

    echo ""
    echo -e "${CYAN}══ 2. 追加到中转机 outbounds 数组 ═════════════════════${NC}"
    python3 - <<PYEOF
import json
d = {
    "tag": "${NODE_TAG}-out",
    "protocol":"vless",
    "settings":{"vnext":[{"address":"${LUODI_IP}","port":int("${LUODI_PORT}"),
        "users":[{"id":"${LUODI_UUID}","flow":"xtls-rprx-vision","encryption":"none"}]}]},
    "streamSettings":{
        "network":"tcp","security":"reality",
        "realitySettings":{"fingerprint":"chrome","serverName":"${LUODI_SNI}",
            "publicKey":"${LUODI_PUBKEY}","shortId":"${LUODI_SHORTID}"}
    }
}
print(json.dumps(d,indent=2,ensure_ascii=False))
PYEOF

    echo ""
    echo -e "${CYAN}══ 3. 插入到 routing.rules 数组最前面 ══════════════════${NC}"
    echo "{\"type\":\"field\",\"inboundTag\":[\"${NODE_TAG}-in\"],\"outboundTag\":\"${NODE_TAG}-out\"}"

    echo ""
    echo -e "${YELLOW}4. 中转机执行: systemctl restart xray${NC}"
    echo ""
    echo -e "${YELLOW}客户端参数（连中转机）：${NC}"
    echo "  地址   : <中转机IP>"
    echo "  端口   : $NEXT_PORT"
    echo "  UUID   : $LUODI_UUID"
    echo "  Flow   : xtls-rprx-vision"
    echo "  pbk    : $RELAY_PUBKEY   ← 中转机入站公钥"
    echo "  sid    : $RELAY_SHORTID"
    echo "  sni    : $LUODI_SNI"
    echo "  fp     : chrome"
}

# ── 输出客户端节点链接 ─────────────────────────────────────
gen_client_link() {
    local zz="${ZZ_HOST:-<中转机IP>}"
    local link="vless://${LUODI_UUID}@${zz}:${NEXT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${LUODI_SNI}&fp=chrome&pbk=${RELAY_PUBKEY}&sid=${RELAY_SHORTID}&type=tcp&headerType=none#中转${zz}:${NEXT_PORT}→落地${LUODI_IP}"

    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  对接完成！客户端节点链接${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "$link"
    echo ""
    echo -e "${YELLOW}流量路径：用户 → ${zz}:${NEXT_PORT}（中转）→ ${LUODI_IP}:${LUODI_PORT}（落地）→ 互联网${NC}"
    echo ""

    {
        echo "================================================================"
        echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "中转: ${zz}:${NEXT_PORT}   落地: ${LUODI_IP}:${LUODI_PORT}"
        echo "链接: $link"
    } >> /root/duijie_records.txt

    success "记录已追加到 /root/duijie_records.txt"
}

# ── 主流程 ─────────────────────────────────────────────────
main() {
    echo -e "${CYAN}"
    echo "  ██████╗ ██╗   ██╗██╗     ██╗██╗███████╗"
    echo "  ██╔══██╗██║   ██║██║     ██║██║██╔════╝"
    echo "  ██║  ██║██║   ██║██║     ██║██║█████╗  "
    echo "  ██║  ██║██║   ██║██║██   ██║██║██╔══╝  "
    echo "  ██████╔╝╚██████╔╝██║╚█████╔╝██║███████╗"
    echo "  ╚═════╝  ╚═════╝ ╚═╝ ╚════╝ ╚═╝╚══════╝"
    echo -e "  落地机 ↔ 中转机 对接脚本 v2.1${NC}"
    echo ""

    check_deps
    read_luodi_info
    get_zhongzhuan_ssh

    if [[ "$MANUAL_MODE" == "true" ]]; then
        manual_mode
    else
        get_next_port
        gen_relay_keys
        inject_config
        gen_client_link
    fi
}

main "$@"
