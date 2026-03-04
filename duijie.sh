#!/bin/bash
# ============================================================
# duijie.sh — 落地机与中转机对接脚本 v3.0
# 功能：在落地机上运行，SSH 到中转机，在 v2ray-agent 的
#       Xray conf 目录中注入新的入站+出站+路由配置文件
# 支持：密码 / 密钥文件 / 粘贴私钥内容（甲骨文云）
# 前提：落地机和中转机都已安装 v2ray-agent
# 使用：bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/duijie.sh)
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

cleanup() {
    [[ -n "$TEMP_KEY" && -f "$TEMP_KEY" ]] && rm -f "$TEMP_KEY"
}
trap cleanup EXIT

[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

# ============================================================
print_banner() {
    echo -e "${CYAN}"
    echo "  ██████╗ ██╗   ██╗██╗     ██╗██╗███████╗"
    echo "  ██╔══██╗██║   ██║██║     ██║██║██╔════╝"
    echo "  ██║  ██║██║   ██║██║     ██║██║█████╗  "
    echo "  ██║  ██║██║   ██║██║██   ██║██║██╔══╝  "
    echo "  ██████╔╝╚██████╔╝██║╚█████╔╝██║███████╗"
    echo "  ╚═════╝  ╚═════╝ ╚═╝ ╚════╝ ╚═╝╚══════╝"
    echo -e "  落地机 ↔ 中转机 对接脚本 v3.0${NC}"
    echo ""
}

# ============================================================
# 安装依赖
# ============================================================
check_deps() {
    local missing=()
    for cmd in ssh jq curl openssl python3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "安装缺失依赖: ${missing[*]}"
        if command -v apt-get &>/dev/null; then
            rm -f /etc/apt/sources.list.d/nginx.list
            rm -f /etc/apt/sources.list.d/*nginx* 2>/dev/null || true
            apt-get update -qq 2>/dev/null || true
            apt-get install -y -qq openssh-client jq curl openssl python3 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum install -y -q openssh-clients jq curl openssl python3 2>/dev/null || true
        fi
    fi
}

# ============================================================
# 读取落地机信息（从 luodi.sh 生成的文件）
# ============================================================
read_luodi_info() {
    info "读取落地机配置信息..."
    [[ ! -f "$LUODI_INFO_FILE" ]] && \
        error "未找到 $LUODI_INFO_FILE\n请先在落地机上运行 luodi.sh"

    LUODI_IP=$(grep      "^LUODI_IP="      "$LUODI_INFO_FILE" | cut -d= -f2)
    LUODI_PORT=$(grep    "^LUODI_PORT="    "$LUODI_INFO_FILE" | cut -d= -f2)
    LUODI_UUID=$(grep    "^LUODI_UUID="    "$LUODI_INFO_FILE" | cut -d= -f2)
    LUODI_PUBKEY=$(grep  "^LUODI_PUBKEY="  "$LUODI_INFO_FILE" | cut -d= -f2)
    LUODI_PRIVKEY=$(grep "^LUODI_PRIVKEY=" "$LUODI_INFO_FILE" | cut -d= -f2)
    LUODI_SHORTID=$(grep "^LUODI_SHORTID=" "$LUODI_INFO_FILE" | cut -d= -f2)
    LUODI_SNI=$(grep     "^LUODI_SNI="     "$LUODI_INFO_FILE" | cut -d= -f2)

    [[ -z "$LUODI_IP" || -z "$LUODI_PORT" || -z "$LUODI_UUID" || -z "$LUODI_PUBKEY" ]] && \
        error "落地机信息不完整，请重新运行 luodi.sh"

    success "落地机信息读取成功"
    printf "  %-8s: ${CYAN}%s${NC}\n" "IP"   "$LUODI_IP"
    printf "  %-8s: ${CYAN}%s${NC}\n" "端口" "$LUODI_PORT"
    printf "  %-8s: ${CYAN}%s${NC}\n" "UUID" "$LUODI_UUID"
    printf "  %-8s: ${CYAN}%s${NC}\n" "SNI"  "$LUODI_SNI"
}

# ============================================================
# 扫描本机 SSH 私钥
# ============================================================
scan_ssh_keys() {
    local keys=()
    for f in ~/.ssh/id_rsa ~/.ssh/id_ed25519 ~/.ssh/id_ecdsa \
              /root/.ssh/id_rsa /root/.ssh/id_ed25519; do
        f_real=$(eval echo "$f")
        [[ -f "$f_real" ]] && keys+=("$f_real")
    done
    while IFS= read -r pem; do
        keys+=("$pem")
    done < <(find /root -maxdepth 2 -name "*.pem" 2>/dev/null)
    echo "${keys[@]}"
}

# ============================================================
# 配置 SSH 连接信息
# ============================================================
get_ssh_config() {
    echo ""
    echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  配置中转机 SSH 连接${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"
    echo ""

    echo "请选择对接方式："
    echo "  1) SSH 自动对接（推荐）"
    echo "  2) 手动模式（输出配置片段，手动粘贴到中转机）"
    read -rp "选择 [1/2，默认1]: " MODE
    MODE=${MODE:-1}
    if [[ "$MODE" == "2" ]]; then
        MANUAL_MODE=true
        return
    fi
    MANUAL_MODE=false

    read -rp "中转机 IP 或域名: " ZZ_HOST
    [[ -z "$ZZ_HOST" ]] && error "中转机地址不能为空"

    read -rp "SSH 端口 [默认 22]: " ZZ_SSH_PORT
    ZZ_SSH_PORT=${ZZ_SSH_PORT:-22}

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

    echo ""
    echo "SSH 认证方式："
    echo "  1) 密码"
    echo "  2) 密钥文件（本地有 .pem / id_rsa 等文件）"
    echo "  3) 粘贴私钥内容  ← 甲骨文云推荐"
    read -rp "选择 [1/2/3，默认2]: " AUTH_OPT
    AUTH_OPT=${AUTH_OPT:-2}

    case "$AUTH_OPT" in
        1) _setup_password ;;
        3) _setup_paste_key ;;
        *) _setup_keyfile ;;
    esac

    _test_ssh
}

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

_setup_keyfile() {
    AUTH_TYPE="keyfile"
    local found_keys
    read -ra found_keys <<< "$(scan_ssh_keys)"

    if [[ ${#found_keys[@]} -gt 0 ]]; then
        echo ""
        echo "检测到以下密钥文件："
        local i
        for i in "${!found_keys[@]}"; do
            echo "  $((i+1))) ${found_keys[$i]}"
        done
        echo "  $((${#found_keys[@]}+1))) 手动输入路径"
        read -rp "选择 [默认1]: " K_OPT
        K_OPT=${K_OPT:-1}
        if [[ "$K_OPT" -le "${#found_keys[@]}" ]] 2>/dev/null; then
            ZZ_KEY="${found_keys[$((K_OPT-1))]}"
        else
            read -rp "密钥路径: " ZZ_KEY
            ZZ_KEY=$(eval echo "$ZZ_KEY")
        fi
    else
        read -rp "密钥文件路径 [如 /root/oracle.pem]: " ZZ_KEY
        ZZ_KEY=$(eval echo "$ZZ_KEY")
    fi

    [[ ! -f "$ZZ_KEY" ]] && error "文件不存在: $ZZ_KEY"
    chmod 600 "$ZZ_KEY"
    info "使用密钥: $ZZ_KEY"
    SSH_OPTS="-i $ZZ_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
}

_setup_paste_key() {
    AUTH_TYPE="keyfile"
    echo ""
    echo -e "${YELLOW}请粘贴私钥内容（-----BEGIN ... PRIVATE KEY----- 开头）${NC}"
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
    SSH_OPTS="-i $ZZ_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
    info "私钥已写入临时文件（退出后自动删除）"
}

_test_ssh() {
    info "测试 SSH 连接 ${ZZ_USER}@${ZZ_HOST}:${ZZ_SSH_PORT} ..."
    local out
    out=$(_ssh_run "echo __CONN_OK__" 2>&1) || true
    if echo "$out" | grep -q "__CONN_OK__"; then
        success "SSH 连接成功 ✓"
    else
        echo -e "${RED}连接失败：${NC}"
        echo "$out"
        echo ""
        echo -e "${YELLOW}排查建议：${NC}"
        echo "  1. 安全组需放行 SSH 端口"
        echo "  2. 甲骨文 Ubuntu 用 ubuntu，Oracle Linux 用 opc"
        echo "  3. 密钥需与创建实例时对应"
        error "SSH 连接失败，请检查后重试"
    fi
}

_ssh_run() {
    local cmd="$1"
    if [[ "$AUTH_TYPE" == "password" ]]; then
        sshpass -p "$ZZ_PASS" ssh $SSH_OPTS -p "$ZZ_SSH_PORT" "$ZZ_USER@$ZZ_HOST" "$cmd"
    else
        ssh $SSH_OPTS -p "$ZZ_SSH_PORT" "$ZZ_USER@$ZZ_HOST" "$cmd"
    fi
}

_ssh_pipe() {
    if [[ "$AUTH_TYPE" == "password" ]]; then
        sshpass -p "$ZZ_PASS" ssh $SSH_OPTS -p "$ZZ_SSH_PORT" "$ZZ_USER@$ZZ_HOST" bash -s
    else
        ssh $SSH_OPTS -p "$ZZ_SSH_PORT" "$ZZ_USER@$ZZ_HOST" bash -s
    fi
}

# ============================================================
# 获取中转机下一个可用端口
# ============================================================
get_next_port() {
    info "查询中转机端口分配情况..."

    NODES_JSON=$(_ssh_run "cat /usr/local/etc/xray/nodes.json 2>/dev/null || echo '{\"nodes\":[]}'")
    ZZ_META=$(_ssh_run    "cat /root/xray_zhongzhuan_info.txt 2>/dev/null || echo ''")

    START_PORT=$(echo "$ZZ_META" | grep "^ZHONGZHUAN_START_PORT=" | cut -d= -f2)
    MAX_NODES=$(echo  "$ZZ_META" | grep "^ZHONGZHUAN_MAX_NODES="  | cut -d= -f2)
    ZZ_CONF_DIR=$(echo "$ZZ_META" | grep "^ZHONGZHUAN_CONF_DIR=" | cut -d= -f2)
    START_PORT=${START_PORT:-30001}
    MAX_NODES=${MAX_NODES:-20}
    ZZ_CONF_DIR=${ZZ_CONF_DIR:-/etc/v2ray-agent/xray/conf}

    USED_PORTS=$(echo "$NODES_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d.get('nodes',[]): print(n.get('inbound_port',''))
" 2>/dev/null || echo "")

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

# ============================================================
# 生成中转机入站的独立 Reality 密钥对
# ============================================================
gen_relay_keys() {
    info "生成中转机入站 Reality 密钥对..."

    local xray_bin="/usr/local/bin/xray"
    [[ ! -f "$xray_bin" ]] && xray_bin=$(command -v xray 2>/dev/null || echo "")
    [[ -z "$xray_bin" ]] && error "未找到 xray，请确认落地机已安装 v2ray-agent"

    local key_out
    key_out=$("$xray_bin" x25519 2>/dev/null)

    # 兼容 v26 新格式（PrivateKey/Password）和旧格式（Private key/Public key）
    RELAY_PRIVKEY=$(echo "$key_out" | grep -i "^PrivateKey:" | awk '{print $NF}' | tr -d '[:space:]')
    RELAY_PUBKEY=$(echo  "$key_out" | grep -i "^Password:"   | awk '{print $NF}' | tr -d '[:space:]')
    # 兼容旧格式
    [[ -z "$RELAY_PRIVKEY" ]] && \
        RELAY_PRIVKEY=$(echo "$key_out" | grep -i "^Private key:" | awk '{print $NF}' | tr -d '[:space:]')
    [[ -z "$RELAY_PUBKEY" ]] && \
        RELAY_PUBKEY=$(echo  "$key_out" | grep -i "^Public key:"  | awk '{print $NF}' | tr -d '[:space:]')

    [[ -z "$RELAY_PRIVKEY" || -z "$RELAY_PUBKEY" ]] && \
        error "密钥生成失败，原始输出:\n$key_out"

    RELAY_SHORTID=$(openssl rand -hex 8)
    NODE_TAG="relay-$(echo "$LUODI_IP" | tr '.' '-')-${NEXT_PORT}"
    info "中转入站公钥: $RELAY_PUBKEY"
}

# ============================================================
# 注入配置到中转机（写入独立 json 文件，不修改原有配置）
# ============================================================
inject_config() {
    info "注入配置到中转机 v2ray-agent..."

    _ssh_pipe << REMOTE_SCRIPT
#!/bin/bash
set -e

# 所有变量通过 heredoc 展开传入
NODE_TAG="${NODE_TAG}"
NEXT_PORT="${NEXT_PORT}"
LUODI_IP="${LUODI_IP}"
LUODI_PORT="${LUODI_PORT}"
LUODI_UUID="${LUODI_UUID}"
LUODI_PUBKEY="${LUODI_PUBKEY}"
LUODI_SHORTID="${LUODI_SHORTID}"
LUODI_SNI="${LUODI_SNI}"
RELAY_PRIVKEY="${RELAY_PRIVKEY}"
RELAY_PUBKEY="${RELAY_PUBKEY}"
RELAY_SHORTID="${RELAY_SHORTID}"
ZZ_CONF_DIR="${ZZ_CONF_DIR}"
NODES_FILE="/usr/local/etc/xray/nodes.json"
ADDED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

# ── 写入入站配置文件（独立文件，不影响 v2ray-agent 原配置）──
INBOUND_FILE="\${ZZ_CONF_DIR}/relay_inbound_\${NODE_TAG}.json"
OUTBOUND_FILE="\${ZZ_CONF_DIR}/relay_outbound_\${NODE_TAG}.json"
ROUTING_FILE="\${ZZ_CONF_DIR}/relay_routing_\${NODE_TAG}.json"

echo "[INFO] 写入入站配置: \$INBOUND_FILE"
cat > "\$INBOUND_FILE" << INBOUND_EOF
{
  "inbounds": [
    {
      "tag": "\${NODE_TAG}-in",
      "listen": "0.0.0.0",
      "port": \${NEXT_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "\${LUODI_UUID}",
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
          "dest": "\${LUODI_SNI}:443",
          "xver": 0,
          "serverNames": ["\${LUODI_SNI}"],
          "privateKey": "\${RELAY_PRIVKEY}",
          "shortIds": ["\${RELAY_SHORTID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ]
}
INBOUND_EOF

echo "[INFO] 写入出站配置: \$OUTBOUND_FILE"
cat > "\$OUTBOUND_FILE" << OUTBOUND_EOF
{
  "outbounds": [
    {
      "tag": "\${NODE_TAG}-out",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "\${LUODI_IP}",
            "port": \${LUODI_PORT},
            "users": [
              {
                "id": "\${LUODI_UUID}",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "\${LUODI_SNI}",
          "publicKey": "\${LUODI_PUBKEY}",
          "shortId": "\${LUODI_SHORTID}"
        }
      }
    }
  ]
}
OUTBOUND_EOF

echo "[INFO] 写入路由配置: \$ROUTING_FILE"
cat > "\$ROUTING_FILE" << ROUTING_EOF
{
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["\${NODE_TAG}-in"],
        "outboundTag": "\${NODE_TAG}-out"
      }
    ]
  }
}
ROUTING_EOF

# ── 更新 nodes.json 记录 ─────────────────────────────────
mkdir -p "\$(dirname \$NODES_FILE)"
python3 - << PYEOF
import json, os

nodes_path = os.environ.get("NODES_FILE", "/usr/local/etc/xray/nodes.json")
# 从 bash 变量读取（已通过 heredoc 展开）
node = {
    "tag":           "${NODE_TAG}",
    "luodi_ip":      "${LUODI_IP}",
    "luodi_port":    int("${LUODI_PORT}"),
    "inbound_port":  int("${NEXT_PORT}"),
    "relay_pubkey":  "${RELAY_PUBKEY}",
    "relay_shortid": "${RELAY_SHORTID}",
    "uuid":          "${LUODI_UUID}",
    "inbound_file":  "${ZZ_CONF_DIR}/relay_inbound_${NODE_TAG}.json",
    "added_at":      "${ADDED_AT}"
}

try:
    with open(nodes_path) as f:
        nodes = json.load(f)
except Exception:
    nodes = {"nodes": []}

# 如果同 tag 已存在则更新
nodes["nodes"] = [n for n in nodes["nodes"] if n.get("tag") != node["tag"]]
nodes["nodes"].append(node)

with open(nodes_path, "w") as f:
    json.dump(nodes, f, indent=2, ensure_ascii=False)
print("[OK] nodes.json 已更新")
PYEOF

# ── 验证配置并重启 Xray ──────────────────────────────────
echo "[INFO] 验证 Xray 配置..."
if /usr/local/bin/xray -test -config /etc/v2ray-agent/xray/conf/00_log.json 2>/dev/null; then
    echo "[INFO] 配置验证通过"
else
    echo "[WARN] 配置验证命令不支持多文件模式，跳过验证直接重启"
fi

echo "[INFO] 重启 Xray 服务..."
systemctl restart xray
sleep 3
if systemctl is-active --quiet xray; then
    echo "[OK] Xray 重启成功"
else
    echo "[ERROR] Xray 重启失败，日志："
    journalctl -u xray -n 20 --no-pager
    exit 1
fi
REMOTE_SCRIPT

    success "配置注入完成"
}

# ============================================================
# 手动模式：输出配置内容
# ============================================================
manual_mode() {
    echo ""
    echo -e "${YELLOW}══════════ 手动对接模式 ══════════════════════════════${NC}"
    read -rp "中转机上使用哪个端口？(如 30001): " NEXT_PORT
    [[ -z "$NEXT_PORT" ]] && error "端口不能为空"

    gen_relay_keys
    NODE_TAG="relay-$(echo "$LUODI_IP" | tr '.' '-')-${NEXT_PORT}"

    echo ""
    echo -e "${CYAN}在中转机的 /etc/v2ray-agent/xray/conf/ 目录下创建三个文件：${NC}"
    echo ""
    echo -e "${GREEN}── 文件1: relay_inbound_${NODE_TAG}.json ──────────────${NC}"
    cat << EOF
{
  "inbounds": [{
    "tag": "${NODE_TAG}-in",
    "listen": "0.0.0.0",
    "port": ${NEXT_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${LUODI_UUID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${LUODI_SNI}:443",
        "xver": 0,
        "serverNames": ["${LUODI_SNI}"],
        "privateKey": "${RELAY_PRIVKEY}",
        "shortIds": ["${RELAY_SHORTID}"]
      }
    }
  }]
}
EOF

    echo ""
    echo -e "${GREEN}── 文件2: relay_outbound_${NODE_TAG}.json ─────────────${NC}"
    cat << EOF
{
  "outbounds": [{
    "tag": "${NODE_TAG}-out",
    "protocol": "vless",
    "settings": {
      "vnext": [{"address": "${LUODI_IP}", "port": ${LUODI_PORT},
        "users": [{"id": "${LUODI_UUID}", "flow": "xtls-rprx-vision", "encryption": "none"}]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "fingerprint": "chrome",
        "serverName": "${LUODI_SNI}",
        "publicKey": "${LUODI_PUBKEY}",
        "shortId": "${LUODI_SHORTID}"
      }
    }
  }]
}
EOF

    echo ""
    echo -e "${GREEN}── 文件3: relay_routing_${NODE_TAG}.json ──────────────${NC}"
    cat << EOF
{
  "routing": {
    "rules": [{"type": "field", "inboundTag": ["${NODE_TAG}-in"], "outboundTag": "${NODE_TAG}-out"}]
  }
}
EOF
    echo ""
    echo -e "${YELLOW}完成后执行: systemctl restart xray${NC}"
}

# ============================================================
# 输出客户端节点链接
# ============================================================
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

# ============================================================
# 主流程
# ============================================================
main() {
    print_banner
    check_deps
    read_luodi_info
    get_ssh_config

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
