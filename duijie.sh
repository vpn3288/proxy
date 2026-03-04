#!/bin/bash
# ============================================================
# duijie.sh — 落地机与中转机对接脚本 v3.1
# 功能：在落地机上运行，SSH 到中转机，在 v2ray-agent 的
#       Xray conf 目录中注入新的入站+出站+路由配置文件
# 支持：密码 / 密钥文件 / 粘贴私钥内容（甲骨文云）
# 修复：heredoc 变量作用域、Python 变量传递、Xray 动态路径、
#       配置验证、nodes.json 路径修复、路由合并优化
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
    echo -e "  落地机 ↔ 中转机 对接脚本 v3.1${NC}"
    echo ""
}

# ============================================================
# 动态查找 Xray 二进制（本机落地机用）
# ============================================================
find_xray_bin() {
    # 方法1: 常见固定路径
    local candidates=(
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
    # 方法3: 从 systemd 服务文件提取实际路径
    local svc_bin
    svc_bin=$(systemctl show xray --property=ExecStart 2>/dev/null         | grep -oP 'path=\K[^;]+' | head -1 | tr -d '[:space:]')
    [[ -n "$svc_bin" && -x "$svc_bin" ]] && { echo "$svc_bin"; return 0; }
    # 方法4: 从运行中的进程提取
    local proc_bin
    proc_bin=$(ps -eo cmd --no-headers 2>/dev/null         | grep -v grep | grep -i 'xray' | awk '{print $1}' | head -1)
    [[ -n "$proc_bin" && -x "$proc_bin" ]] && { echo "$proc_bin"; return 0; }
    # 方法5: 全盘搜索（兜底）
    local found
    found=$(find /usr /opt /root -maxdepth 5 -name 'xray' -type f         -perm /111 2>/dev/null | head -1)
    [[ -n "$found" ]] && { echo "$found"; return 0; }
    return 1
}

# ============================================================
# 安装依赖
# ============================================================
check_deps() {
    local missing=()
    for cmd in ssh curl openssl python3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "安装缺失依赖: ${missing[*]}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                openssh-client curl openssl python3 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum install -y -q openssh-clients curl openssl python3 2>/dev/null || true
        fi
    fi

    # jq 可选，不强依赖
    command -v jq &>/dev/null || warn "jq 未安装，使用 python3 替代（不影响功能）"
}

# ============================================================
# 读取落地机信息（从 luodi.sh 生成的文件）
# ============================================================
read_luodi_info() {
    info "读取落地机配置信息..."
    [[ ! -f "$LUODI_INFO_FILE" ]] && \
        error "未找到 $LUODI_INFO_FILE\n请先在落地机上运行 luodi.sh"

    LUODI_IP=$(grep      "^LUODI_IP="      "$LUODI_INFO_FILE" | cut -d= -f2 | tr -d '[:space:]')
    LUODI_PORT=$(grep    "^LUODI_PORT="    "$LUODI_INFO_FILE" | cut -d= -f2 | tr -d '[:space:]')
    LUODI_UUID=$(grep    "^LUODI_UUID="    "$LUODI_INFO_FILE" | cut -d= -f2 | tr -d '[:space:]')
    LUODI_PUBKEY=$(grep  "^LUODI_PUBKEY="  "$LUODI_INFO_FILE" | cut -d= -f2 | tr -d '[:space:]')
    LUODI_PRIVKEY=$(grep "^LUODI_PRIVKEY=" "$LUODI_INFO_FILE" | cut -d= -f2 | tr -d '[:space:]')
    LUODI_SHORTID=$(grep "^LUODI_SHORTID=" "$LUODI_INFO_FILE" | cut -d= -f2 | tr -d '[:space:]')
    LUODI_SNI=$(grep     "^LUODI_SNI="     "$LUODI_INFO_FILE" | cut -d= -f2 | tr -d '[:space:]')

    [[ -z "$LUODI_IP" ]]     && error "落地机信息缺少 LUODI_IP，请重新运行 luodi.sh"
    [[ -z "$LUODI_PORT" ]]   && error "落地机信息缺少 LUODI_PORT，请重新运行 luodi.sh"
    [[ -z "$LUODI_UUID" ]]   && error "落地机信息缺少 LUODI_UUID，请重新运行 luodi.sh"
    [[ -z "$LUODI_PUBKEY" ]] && error "落地机信息缺少 LUODI_PUBKEY，请重新运行 luodi.sh"

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
        local f_real
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
    SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=30"
}

_setup_keyfile() {
    AUTH_TYPE="keyfile"
    local found_keys=()
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
        if [[ "$K_OPT" =~ ^[0-9]+$ ]] && [[ "$K_OPT" -le "${#found_keys[@]}" ]]; then
            ZZ_KEY="${found_keys[$((K_OPT-1))]}"
        else
            read -rp "密钥路径: " ZZ_KEY
            ZZ_KEY=$(eval echo "$ZZ_KEY")
        fi
    else
        while true; do
            read -rp "密钥文件路径 [如 /root/oracle.pem]: " ZZ_KEY
            ZZ_KEY=$(eval echo "$ZZ_KEY")
            [[ -z "$ZZ_KEY" ]] && { warn "路径不能为空，请重新输入"; continue; }
            [[ -f "$ZZ_KEY" ]] && break
            warn "文件不存在: $ZZ_KEY，请重新输入"
        done
    fi

    [[ ! -f "$ZZ_KEY" ]] && error "文件不存在: $ZZ_KEY"
    chmod 600 "$ZZ_KEY"
    info "使用密钥: $ZZ_KEY"
    SSH_OPTS="-i $ZZ_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
              -o BatchMode=yes -o ServerAliveInterval=30"
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
    SSH_OPTS="-i $ZZ_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
              -o BatchMode=yes -o ServerAliveInterval=30"
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
        echo "  1. 安全组需放行 SSH 端口 $ZZ_SSH_PORT"
        echo "  2. 甲骨文 Ubuntu 用 ubuntu，Oracle Linux 用 opc"
        echo "  3. 密钥需与创建实例时对应"
        echo "  4. 检查 sshd 是否允许密钥登录: grep PubkeyAuthentication /etc/ssh/sshd_config"
        error "SSH 连接失败，请检查后重试"
    fi
}

_ssh_run() {
    local cmd="$1"
    if [[ "$AUTH_TYPE" == "password" ]]; then
        sshpass -p "$ZZ_PASS" ssh $SSH_OPTS -p "$ZZ_SSH_PORT" "${ZZ_USER}@${ZZ_HOST}" "$cmd"
    else
        ssh $SSH_OPTS -p "$ZZ_SSH_PORT" "${ZZ_USER}@${ZZ_HOST}" "$cmd"
    fi
}

_ssh_pipe() {
    if [[ "$AUTH_TYPE" == "password" ]]; then
        sshpass -p "$ZZ_PASS" ssh $SSH_OPTS -p "$ZZ_SSH_PORT" "${ZZ_USER}@${ZZ_HOST}" bash -s
    else
        ssh $SSH_OPTS -p "$ZZ_SSH_PORT" "${ZZ_USER}@${ZZ_HOST}" bash -s
    fi
}

# ============================================================
# 获取中转机下一个可用端口
# ============================================================
get_next_port() {
    info "查询中转机端口分配情况..."

    local nodes_raw zz_meta
    nodes_raw=$(_ssh_run "cat /usr/local/etc/xray/nodes.json 2>/dev/null || echo '{\"nodes\":[]}'")
    zz_meta=$(_ssh_run   "cat /root/xray_zhongzhuan_info.txt 2>/dev/null || echo ''")

    START_PORT=$(echo "$zz_meta"  | grep "^ZHONGZHUAN_START_PORT=" | cut -d= -f2 | tr -d '[:space:]')
    MAX_NODES=$(echo  "$zz_meta"  | grep "^ZHONGZHUAN_MAX_NODES="  | cut -d= -f2 | tr -d '[:space:]')
    ZZ_CONF_DIR=$(echo "$zz_meta" | grep "^ZHONGZHUAN_CONF_DIR="   | cut -d= -f2 | tr -d '[:space:]')
    START_PORT=${START_PORT:-30001}
    MAX_NODES=${MAX_NODES:-20}
    ZZ_CONF_DIR=${ZZ_CONF_DIR:-/etc/v2ray-agent/xray/conf}

    local used_ports
    used_ports=$(echo "$nodes_raw" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for n in d.get('nodes', []):
        p = n.get('inbound_port', '')
        if p:
            print(p)
except Exception:
    pass
" 2>/dev/null || echo "")

    NEXT_PORT=""
    local p
    for (( p=START_PORT; p<START_PORT+MAX_NODES; p++ )); do
        echo "$used_ports" | grep -qx "$p" || { NEXT_PORT=$p; break; }
    done

    [[ -z "$NEXT_PORT" ]] && error "所有 $MAX_NODES 个端口已用满（${START_PORT}~$((START_PORT+MAX_NODES-1))），请在中转机重新运行 zhongzhuan.sh 扩容"

    echo ""
    if [[ -n "$used_ports" ]]; then
        echo -e "  已用端口: ${YELLOW}$(echo "$used_ports" | tr '\n' ' ')${NC}"
    fi
    echo -e "  建议端口: ${CYAN}${NEXT_PORT}${NC}"
    read -rp "确认 [回车=$NEXT_PORT，或输入其他端口]: " TMP
    [[ -n "$TMP" ]] && NEXT_PORT="$TMP"
    info "本次使用端口: $NEXT_PORT"
}

# ============================================================
# 生成中转机入站独立 Reality 密钥对（在本地落地机上生成）
# ============================================================
gen_relay_keys() {
    info "生成中转机入站 Reality 密钥对..."

    local xray_bin
    xray_bin=$(find_xray_bin) || {
        echo -e "${RED}[ERROR]${NC} 未找到本地 Xray 二进制，无法生成密钥"
        echo "  全盘搜索: $(find /usr /opt /root -name 'xray' -type f 2>/dev/null | head -5 || echo '无')"
        echo "  systemd : $(systemctl show xray --property=ExecStart 2>/dev/null | head -1 || echo '无')"
        echo "  进程    : $(ps -eo cmd --no-headers 2>/dev/null | grep -v grep | grep -i xray | head -2 || echo '无')"
        echo ""
        echo "  请确认落地机 v2ray-agent 已正确安装，或手动运行: vasma"
        exit 1
    }

    local key_out
    key_out=$("$xray_bin" x25519 2>/dev/null) || \
        error "xray x25519 密钥生成失败"

    # 兼容 v26 新格式（PrivateKey/Password）和旧格式（Private key/Public key）
    RELAY_PRIVKEY=$(echo "$key_out" | grep -i "^PrivateKey:" | awk '{print $NF}' | tr -d '[:space:]')
    RELAY_PUBKEY=$(echo  "$key_out" | grep -i "^Password:"  | awk '{print $NF}' | tr -d '[:space:]')
    [[ -z "$RELAY_PRIVKEY" ]] && \
        RELAY_PRIVKEY=$(echo "$key_out" | grep -i "^Private key:" | awk '{print $NF}' | tr -d '[:space:]')
    [[ -z "$RELAY_PUBKEY" ]] && \
        RELAY_PUBKEY=$(echo  "$key_out" | grep -i "^Public key:"  | awk '{print $NF}' | tr -d '[:space:]')

    # 兼容直接两行输出格式
    if [[ -z "$RELAY_PRIVKEY" ]]; then
        RELAY_PRIVKEY=$(echo "$key_out" | sed -n '1p' | tr -d '[:space:]')
        RELAY_PUBKEY=$(echo  "$key_out" | sed -n '2p' | tr -d '[:space:]')
    fi

    [[ -z "$RELAY_PRIVKEY" || -z "$RELAY_PUBKEY" ]] && \
        error "密钥生成失败\nXray 版本: $($xray_bin version 2>/dev/null | head -1)\n原始输出:\n$key_out"

    RELAY_SHORTID=$(openssl rand -hex 8)
    NODE_TAG="relay-$(echo "$LUODI_IP" | tr '.' '-')-${NEXT_PORT}"

    info "中转入站私钥: $RELAY_PRIVKEY"
    info "中转入站公钥: $RELAY_PUBKEY"
    info "中转 Short ID: $RELAY_SHORTID"
}

# ============================================================
# 注入配置到中转机
# 关键修复：
#   1. 所有变量先赋值为本地 shell 变量，再通过参数方式传给远端
#   2. 远端 heredoc 使用引号 'XXEOF' 避免二次展开
#   3. Python 不依赖 os.environ，直接用已展开的字符串字面量
#   4. 配置验证改为真正有效的方式
# ============================================================
inject_config() {
    info "注入配置到中转机 v2ray-agent..."

    # ── 把所有需要传到远端的值固化为本地变量 ──────────────
    local v_node_tag="$NODE_TAG"
    local v_next_port="$NEXT_PORT"
    local v_luodi_ip="$LUODI_IP"
    local v_luodi_port="$LUODI_PORT"
    local v_luodi_uuid="$LUODI_UUID"
    local v_luodi_pubkey="$LUODI_PUBKEY"
    local v_luodi_shortid="$LUODI_SHORTID"
    local v_luodi_sni="$LUODI_SNI"
    local v_relay_privkey="$RELAY_PRIVKEY"
    local v_relay_pubkey="$RELAY_PUBKEY"
    local v_relay_shortid="$RELAY_SHORTID"
    local v_zz_conf_dir="$ZZ_CONF_DIR"
    local v_nodes_file="/usr/local/etc/xray/nodes.json"
    local v_added_at
    v_added_at=$(date '+%Y-%m-%d %H:%M:%S')

    # ── 拼接远端脚本（外层 heredoc 不加引号 → 本地展开所有 ${v_*}）──
    # ── 内层 heredoc 加引号 'EOF' → 防止远端 bash 再次展开 ──────────
    _ssh_pipe << REMOTE_SCRIPT
#!/bin/bash
set -e

INBOUND_FILE="${v_zz_conf_dir}/relay_inbound_${v_node_tag}.json"
OUTBOUND_FILE="${v_zz_conf_dir}/relay_outbound_${v_node_tag}.json"
ROUTING_FILE="${v_zz_conf_dir}/relay_routing_${v_node_tag}.json"
NODES_FILE="${v_nodes_file}"
# 方法1: 常见固定路径
for _p in /usr/local/bin/xray /usr/bin/xray /usr/local/share/xray/xray /opt/xray/xray; do
    [[ -x "\$_p" ]] && { XRAY_BIN="\$_p"; break; }
done
# 方法2: PATH 查找
[[ -z "\$XRAY_BIN" ]] && XRAY_BIN=\$(command -v xray 2>/dev/null || echo "")
# 方法3: 从 systemd 服务文件提取实际路径
if [[ -z "\$XRAY_BIN" ]]; then
    _svc_bin=\$(systemctl show xray --property=ExecStart 2>/dev/null \
        | grep -oP 'path=\K[^;]+' | head -1 | tr -d '[:space:]')
    [[ -n "\$_svc_bin" && -x "\$_svc_bin" ]] && XRAY_BIN="\$_svc_bin"
fi
# 方法4: 从运行中的进程提取
if [[ -z "\$XRAY_BIN" ]]; then
    _proc_bin=\$(ps -eo cmd --no-headers 2>/dev/null \
        | grep -v grep | grep -i 'xray' | awk '{print \$1}' | head -1)
    [[ -n "\$_proc_bin" && -x "\$_proc_bin" ]] && XRAY_BIN="\$_proc_bin"
fi
# 方法5: 全盘搜索（最慢，兜底）
if [[ -z "\$XRAY_BIN" ]]; then
    XRAY_BIN=\$(find /usr /opt /root -maxdepth 5 -name 'xray' -type f \
        -perm /111 2>/dev/null | head -1)
fi
if [[ -z "\$XRAY_BIN" ]]; then
    echo "[ERROR] 中转机未找到 Xray 二进制，搜索结果："
    find /usr /opt -name 'xray' 2>/dev/null || echo "  (无)"
    exit 1
fi
echo "[INFO] 中转机 Xray 路径: \$XRAY_BIN"

echo "[INFO] 写入入站配置: \$INBOUND_FILE"
cat > "\$INBOUND_FILE" << 'INBOUND_EOF'
{
  "inbounds": [
    {
      "tag": "${v_node_tag}-in",
      "listen": "0.0.0.0",
      "port": ${v_next_port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${v_luodi_uuid}",
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
          "dest": "${v_luodi_sni}:443",
          "xver": 0,
          "serverNames": ["${v_luodi_sni}"],
          "privateKey": "${v_relay_privkey}",
          "shortIds": ["${v_relay_shortid}"]
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
cat > "\$OUTBOUND_FILE" << 'OUTBOUND_EOF'
{
  "outbounds": [
    {
      "tag": "${v_node_tag}-out",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${v_luodi_ip}",
            "port": ${v_luodi_port},
            "users": [
              {
                "id": "${v_luodi_uuid}",
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
          "serverName": "${v_luodi_sni}",
          "publicKey": "${v_luodi_pubkey}",
          "shortId": "${v_luodi_shortid}"
        }
      }
    }
  ]
}
OUTBOUND_EOF

echo "[INFO] 写入路由配置: \$ROUTING_FILE"
cat > "\$ROUTING_FILE" << 'ROUTING_EOF'
{
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["${v_node_tag}-in"],
        "outboundTag": "${v_node_tag}-out"
      }
    ]
  }
}
ROUTING_EOF

# ── 更新 nodes.json（全部用字符串字面量，不依赖环境变量）────
mkdir -p "\$(dirname \$NODES_FILE)"
python3 << 'PYEOF'
import json, os

nodes_path = "${v_nodes_file}"
node = {
    "tag":           "${v_node_tag}",
    "luodi_ip":      "${v_luodi_ip}",
    "luodi_port":    int("${v_luodi_port}"),
    "inbound_port":  int("${v_next_port}"),
    "relay_pubkey":  "${v_relay_pubkey}",
    "relay_shortid": "${v_relay_shortid}",
    "uuid":          "${v_luodi_uuid}",
    "inbound_file":  "${v_zz_conf_dir}/relay_inbound_${v_node_tag}.json",
    "outbound_file": "${v_zz_conf_dir}/relay_outbound_${v_node_tag}.json",
    "routing_file":  "${v_zz_conf_dir}/relay_routing_${v_node_tag}.json",
    "added_at":      "${v_added_at}"
}

try:
    with open(nodes_path) as f:
        nodes = json.load(f)
except Exception:
    nodes = {"nodes": []}

# 同 tag 已存在则更新
nodes["nodes"] = [n for n in nodes["nodes"] if n.get("tag") != node["tag"]]
nodes["nodes"].append(node)

with open(nodes_path, "w") as f:
    json.dump(nodes, f, indent=2, ensure_ascii=False)
print("[OK] nodes.json 已更新，共 " + str(len(nodes["nodes"])) + " 条记录")
PYEOF

# ── 验证配置合法性（用 xray run 短暂启动验证）────────────────
echo "[INFO] 验证 Xray 配置目录合法性..."
CONF_DIR=\$(dirname "\$INBOUND_FILE")

# 方法：启动 xray 加载配置目录，3秒内无报错即视为通过
timeout 5 "\$XRAY_BIN" run -confdir "\$CONF_DIR" >/tmp/xray_test.log 2>&1 &
XRAY_TEST_PID=\$!
sleep 3
if kill -0 \$XRAY_TEST_PID 2>/dev/null; then
    kill \$XRAY_TEST_PID 2>/dev/null
    wait \$XRAY_TEST_PID 2>/dev/null || true
    echo "[OK] 配置验证通过（Xray 正常加载）"
else
    # 进程已退出，说明启动失败
    echo "[ERROR] 配置加载失败，错误日志："
    cat /tmp/xray_test.log
    echo "[INFO] 回滚本次写入的配置文件..."
    rm -f "\$INBOUND_FILE" "\$OUTBOUND_FILE" "\$ROUTING_FILE"
    exit 1
fi
rm -f /tmp/xray_test.log

# ── 重启 Xray 服务 ───────────────────────────────────────────
echo "[INFO] 重启 Xray 服务..."
systemctl restart xray
sleep 3
if systemctl is-active --quiet xray; then
    echo "[OK] Xray 重启成功 ✓"
else
    echo "[ERROR] Xray 重启失败，最近日志："
    journalctl -u xray -n 30 --no-pager
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
    read -rp "中转机上使用哪个端口（如 30001）: " NEXT_PORT
    [[ -z "$NEXT_PORT" ]] && error "端口不能为空"

    gen_relay_keys
    NODE_TAG="relay-$(echo "$LUODI_IP" | tr '.' '-')-${NEXT_PORT}"
    ZZ_CONF_DIR="/etc/v2ray-agent/xray/conf"

    echo ""
    echo -e "${CYAN}在中转机的 ${ZZ_CONF_DIR}/ 目录下创建三个文件：${NC}"
    echo ""

    echo -e "${GREEN}── 文件1: relay_inbound_${NODE_TAG}.json ──${NC}"
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
    },
    "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
  }]
}
EOF

    echo ""
    echo -e "${GREEN}── 文件2: relay_outbound_${NODE_TAG}.json ──${NC}"
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
    echo -e "${GREEN}── 文件3: relay_routing_${NODE_TAG}.json ──${NC}"
    cat << EOF
{
  "routing": {
    "rules": [{"type": "field", "inboundTag": ["${NODE_TAG}-in"], "outboundTag": "${NODE_TAG}-out"}]
  }
}
EOF

    echo ""
    echo -e "${YELLOW}完成后在中转机执行: systemctl restart xray${NC}"

    # 手动模式下也生成客户端链接
    ZZ_HOST="<中转机IP>"
    gen_client_link
}

# ============================================================
# 输出客户端节点链接
# ============================================================
gen_client_link() {
    local zz="${ZZ_HOST:-<中转机IP>}"
    local link="vless://${LUODI_UUID}@${zz}:${NEXT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${LUODI_SNI}&fp=chrome&pbk=${RELAY_PUBKEY}&sid=${RELAY_SHORTID}&type=tcp&headerType=none#中转${zz}:${NEXT_PORT}→落地${LUODI_IP}"

    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  对接完成！客户端节点链接如下${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "$link"
    echo ""
    echo -e "${YELLOW}流量路径：用户 → ${zz}:${NEXT_PORT}（中转）→ ${LUODI_IP}:${LUODI_PORT}（落地）→ 互联网${NC}"
    echo ""
    echo -e "${YELLOW}── 中转机入站参数（客户端配置用）──────────────────${NC}"
    printf "  %-10s: %s\n" "服务器"   "$zz"
    printf "  %-10s: %s\n" "端口"     "$NEXT_PORT"
    printf "  %-10s: %s\n" "UUID"     "$LUODI_UUID"
    printf "  %-10s: %s\n" "Flow"     "xtls-rprx-vision"
    printf "  %-10s: %s\n" "安全"     "reality"
    printf "  %-10s: %s\n" "SNI"      "$LUODI_SNI"
    printf "  %-10s: %s\n" "公钥"     "$RELAY_PUBKEY"
    printf "  %-10s: %s\n" "ShortID"  "$RELAY_SHORTID"
    printf "  %-10s: %s\n" "指纹"     "chrome"
    echo ""

    {
        echo "================================================================"
        echo "时间    : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "中转    : ${zz}:${NEXT_PORT}"
        echo "落地    : ${LUODI_IP}:${LUODI_PORT}"
        echo "链接    : $link"
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
