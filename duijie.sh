#!/bin/bash
# ============================================================
# duijie.sh v6.0 — 落地机对接中转机脚本
# 功能：在落地机上运行，SSH 到中转机，自动写入
#       relay 入站 + 出站 + 路由规则，生成用户节点链接
# 用法：bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/duijie.sh)
# 前置：落地机已运行 luodi.sh，中转机已运行 zhongzhuan.sh
#
# v6.0 修复/新增：
#   - 修复 json.dumps 生成 false/true/null 导致远程 Python 报错
#   - 修复 LUODI_PORT / LUODI_RELAY_PORT / LUODI_SHORTID 字段名不一致
#   - 自动检测落地机传输协议（tcp / xhttp / ws / grpc / h2）
#   - xhttp 模式自动携带 path / host / mode，并去掉出站 flow
#   - ws / grpc / h2 模式自动携带对应 streamSettings
#   - 自动在中转机上查找 xray 可执行文件路径
#   - 修复 nodes.json 不存在时报错
#   - manual 模式支持手动输入传输协议参数
#   - 新增连通性验证提示
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
log_step()  { echo -e "${CYAN}[→]${NC} $1"; }

[[ $EUID -ne 0 ]] && log_error "请使用 root 权限运行"

LOCAL_INFO="/root/xray_luodi_info.txt"

# ── 落地机变量 ────────────────────────────────────────────
LUODI_IP=""
LUODI_PORT=""
LUODI_UUID=""
LUODI_PUBKEY=""
LUODI_PRIVKEY=""
LUODI_SHORT_ID=""
LUODI_SNI=""
LUODI_DEST=""
LUODI_NETWORK="tcp"
LUODI_XHTTP_PATH=""
LUODI_XHTTP_HOST=""
LUODI_XHTTP_MODE="auto"
LUODI_WS_PATH=""
LUODI_WS_HOST=""
LUODI_GRPC_SERVICE=""
LUODI_H2_PATH=""
LUODI_H2_HOST=""

# ── 中转机变量 ────────────────────────────────────────────
RELAY_IP=""
RELAY_SSH_PORT="22"
RELAY_SSH_USER="root"
RELAY_SSH_PASS=""
RELAY_KEY_FILE=""
SSH_OPTS=""
RELAY_PRIVKEY=""
RELAY_PUBKEY=""
RELAY_SHORT_ID=""
RELAY_SNI=""
RELAY_DEST=""
RELAY_START_PORT=""
RELAY_CONFIG=""
RELAY_NODES=""
RELAY_XRAY_BIN=""
AUTH_TYPE=""

# ── 结果变量 ──────────────────────────────────────────────
RELAY_ASSIGNED_PORT=""
NEW_UUID=""
NODE_LINK=""
NODE_LABEL=""

# ── SSH 执行工具 ──────────────────────────────────────────
run_relay() {
    local cmd="$1"
    case "$AUTH_TYPE" in
        key)      ssh -q $SSH_OPTS "${RELAY_SSH_USER}@${RELAY_IP}" "$cmd" ;;
        password) sshpass -p "$RELAY_SSH_PASS" \
                    ssh -q $SSH_OPTS "${RELAY_SSH_USER}@${RELAY_IP}" "$cmd" ;;
        keyfile)  ssh -q $SSH_OPTS -i "$RELAY_KEY_FILE" \
                    "${RELAY_SSH_USER}@${RELAY_IP}" "$cmd" ;;
        manual)   log_error "manual 模式不支持 run_relay" ;;
    esac
}

pipe_python_relay() {
    case "$AUTH_TYPE" in
        key)      ssh -q $SSH_OPTS "${RELAY_SSH_USER}@${RELAY_IP}" "python3" ;;
        password) sshpass -p "$RELAY_SSH_PASS" \
                    ssh -q $SSH_OPTS "${RELAY_SSH_USER}@${RELAY_IP}" "python3" ;;
        keyfile)  ssh -q $SSH_OPTS -i "$RELAY_KEY_FILE" \
                    "${RELAY_SSH_USER}@${RELAY_IP}" "python3" ;;
        manual)   log_error "manual 模式不支持 pipe_python_relay" ;;
    esac
}

# ── 自动检测落地机传输协议 ────────────────────────────────
detect_luodi_transport() {
    log_step "自动检测落地机传输协议..."

    local conf_dirs=(
        "/etc/v2ray-agent/xray/conf"
        "/usr/local/etc/xray/conf"
        "/usr/local/etc/xray"
        "/etc/xray"
    )

    local found_file=""
    for dir in "${conf_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            local f
            f=$(grep -rl "\"port\".*:.*${LUODI_PORT}\b" "$dir" 2>/dev/null | head -1 || true)
            if [[ -n "$f" ]]; then
                found_file="$f"
                break
            fi
        fi
    done

    if [[ -z "$found_file" ]]; then
        log_warn "未找到端口 ${LUODI_PORT} 对应的配置文件，默认 tcp"
        LUODI_NETWORK="tcp"
        return
    fi

    log_info "检测配置文件: $found_file"

    local transport_json
    # 写入临时 Python 脚本文件，避免 heredoc+命令替换+|| 的 shell 解析冲突
    local _py_tmp="/tmp/_detect_transport_$$.py"
    cat > "$_py_tmp" << 'PYEOF'
import json, sys
fpath = sys.argv[1]
port  = int(sys.argv[2])
try:
    with open(fpath) as f:
        cfg = json.load(f)
except Exception:
    print('{"network":"tcp"}'); sys.exit(0)
target = next((ib for ib in cfg.get("inbounds",[]) if ib.get("port")==port), None)
if not target:
    print('{"network":"tcp"}'); sys.exit(0)
ss      = target.get("streamSettings", {})
network = ss.get("network", "tcp")
result  = {"network": network}
if network == "xhttp":
    xs = ss.get("xhttpSettings", {})
    result["xhttp_path"] = xs.get("path", "/")
    result["xhttp_host"] = xs.get("host", "")
    result["xhttp_mode"] = xs.get("mode", "auto")
elif network == "ws":
    ws = ss.get("wsSettings", {})
    result["ws_path"] = ws.get("path", "/")
    result["ws_host"] = ws.get("headers", {}).get("Host", "")
elif network == "grpc":
    grpc = ss.get("grpcSettings", {})
    result["grpc_service"] = grpc.get("serviceName", "")
elif network in ("h2", "http"):
    h2    = ss.get("httpSettings", {})
    hosts = h2.get("host", [])
    result["network"] = "h2"
    result["h2_path"] = h2.get("path", "/")
    result["h2_host"] = hosts[0] if hosts else ""
print(json.dumps(result))
PYEOF
    transport_json=$(python3 "$_py_tmp" "$found_file" "${LUODI_PORT}" 2>/dev/null) || transport_json='{"network":"tcp"}'
    rm -f "$_py_tmp"
    [[ -z "$transport_json" ]] && transport_json='{"network":"tcp"}'

    LUODI_NETWORK=$(echo "$transport_json" | python3 -c \
        "import json,sys; print(json.load(sys.stdin).get('network','tcp'))" 2>/dev/null || echo "tcp")

    _get() { echo "$transport_json" | python3 -c \
        "import json,sys; print(json.load(sys.stdin).get('$1','$2'))" 2>/dev/null || echo "$2"; }

    case "$LUODI_NETWORK" in
        xhttp)
            LUODI_XHTTP_PATH=$(_get xhttp_path "/")
            LUODI_XHTTP_HOST=$(_get xhttp_host "")
            LUODI_XHTTP_MODE=$(_get xhttp_mode "auto")
            log_info "传输协议: xhttp | path=${LUODI_XHTTP_PATH} | host=${LUODI_XHTTP_HOST} | mode=${LUODI_XHTTP_MODE}"
            ;;
        ws)
            LUODI_WS_PATH=$(_get ws_path "/")
            LUODI_WS_HOST=$(_get ws_host "")
            log_info "传输协议: ws | path=${LUODI_WS_PATH} | host=${LUODI_WS_HOST}"
            ;;
        grpc)
            LUODI_GRPC_SERVICE=$(_get grpc_service "")
            log_info "传输协议: grpc | serviceName=${LUODI_GRPC_SERVICE}"
            ;;
        h2)
            LUODI_H2_PATH=$(_get h2_path "/")
            LUODI_H2_HOST=$(_get h2_host "")
            log_info "传输协议: h2 | path=${LUODI_H2_PATH} | host=${LUODI_H2_HOST}"
            ;;
        tcp)
            log_info "传输协议: tcp"
            ;;
        *)
            log_warn "未知传输协议 ${LUODI_NETWORK}，回退 tcp"
            LUODI_NETWORK="tcp"
            ;;
    esac
}

# ── 读取落地机信息 ────────────────────────────────────────
read_luodi_info() {
    log_step "读取落地机信息..."

    if [[ -f "$LOCAL_INFO" ]]; then
        log_info "从 $LOCAL_INFO 加载..."
        while IFS='=' read -r key val; do
            val=$(echo "$val" | tr -d '\r' | xargs 2>/dev/null || echo "$val")
            case "$key" in
                LUODI_IP)                              LUODI_IP="$val"         ;;
                LUODI_PORT|LUODI_RELAY_PORT)           LUODI_PORT="$val"       ;;
                LUODI_UUID)                            LUODI_UUID="$val"       ;;
                LUODI_PUBKEY)                          LUODI_PUBKEY="$val"     ;;
                LUODI_PRIVKEY)                         LUODI_PRIVKEY="$val"    ;;
                LUODI_SHORT_ID|LUODI_SHORTID)          LUODI_SHORT_ID="$val"   ;;
                LUODI_SNI)                             LUODI_SNI="$val"        ;;
                LUODI_DEST)                            LUODI_DEST="$val"       ;;
                LUODI_NETWORK)                         LUODI_NETWORK="$val"    ;;
                LUODI_XHTTP_PATH)                      LUODI_XHTTP_PATH="$val" ;;
                LUODI_XHTTP_HOST)                      LUODI_XHTTP_HOST="$val" ;;
                LUODI_XHTTP_MODE)                      LUODI_XHTTP_MODE="$val" ;;
                LUODI_WS_PATH)                         LUODI_WS_PATH="$val"    ;;
                LUODI_WS_HOST)                         LUODI_WS_HOST="$val"    ;;
                LUODI_GRPC_SERVICE)                    LUODI_GRPC_SERVICE="$val";;
            esac
        done < "$LOCAL_INFO"

        # 兼容 luodi.sh 写入的中文标签格式（带空格）
        if [[ -z "$LUODI_IP" ]]; then
            LUODI_IP=$(grep -m1 "公网 IP" "$LOCAL_INFO" | grep -oP '[\d.]+$' || true)
        fi
        if [[ -z "$LUODI_PORT" ]]; then
            LUODI_PORT=$(grep -m1 "VLESS 端口\|LUODI_PORT\|LUODI_RELAY_PORT" "$LOCAL_INFO" \
                | grep -oP '\d+$' || true)
        fi
        if [[ -z "$LUODI_UUID" ]]; then
            LUODI_UUID=$(grep -m1 "^UUID\s*=" "$LOCAL_INFO" | cut -d= -f2 | tr -d ' \r' || true)
        fi
        if [[ -z "$LUODI_PUBKEY" ]]; then
            LUODI_PUBKEY=$(grep -m1 "公钥(pubkey)" "$LOCAL_INFO" | cut -d: -f2 | tr -d ' \r' || true)
        fi
        if [[ -z "$LUODI_SNI" ]]; then
            LUODI_SNI=$(grep -m1 "伪装域名\|LUODI_SNI" "$LOCAL_INFO" | cut -d= -f2 | tr -d ' \r' || true)
        fi
    fi

    echo ""
    echo -e "${YELLOW}── 确认落地机信息（回车保留自动读取值）──${NC}"
    local i
    read -rp "落地机 IP            [${LUODI_IP:-待输入}]: "    i; [[ -n "$i" ]] && LUODI_IP="$i"
    read -rp "落地机监听端口       [${LUODI_PORT:-待输入}]: "  i; [[ -n "$i" ]] && LUODI_PORT="$i"
    read -rp "UUID                 [${LUODI_UUID:-待输入}]: "   i; [[ -n "$i" ]] && LUODI_UUID="$i"
    read -rp "公钥 (pubkey)        [${LUODI_PUBKEY:-待输入}]: " i; [[ -n "$i" ]] && LUODI_PUBKEY="$i"
    read -rp "SNI                  [${LUODI_SNI:-待输入}]: "    i; [[ -n "$i" ]] && LUODI_SNI="$i"
    read -rp "Short ID             [${LUODI_SHORT_ID:-空}]: "   i; [[ -n "$i" ]] && LUODI_SHORT_ID="$i"
    read -rp "节点标签             [LuoDi-${LUODI_IP}]: "       i
    NODE_LABEL="${i:-LuoDi-${LUODI_IP}}"

    [[ -z "$LUODI_IP" || -z "$LUODI_PORT" || \
       -z "$LUODI_UUID" || -z "$LUODI_PUBKEY" ]] && \
        log_error "落地机信息不完整，请先运行 luodi.sh"

    log_info "落地机: $LUODI_IP:$LUODI_PORT"

    # 自动检测传输协议
    detect_luodi_transport

    # 协议参数确认（xhttp / ws / grpc）
    if [[ "$LUODI_NETWORK" == "xhttp" ]]; then
        echo ""
        echo -e "${YELLOW}── 确认 xhttp 传输参数 ──${NC}"
        read -rp "path [${LUODI_XHTTP_PATH:-/}]: "             i; [[ -n "$i" ]] && LUODI_XHTTP_PATH="$i"
        read -rp "host [${LUODI_XHTTP_HOST:-$LUODI_SNI}]: "    i; [[ -n "$i" ]] && LUODI_XHTTP_HOST="$i"
        read -rp "mode [${LUODI_XHTTP_MODE:-auto}]: "          i; [[ -n "$i" ]] && LUODI_XHTTP_MODE="$i"
        LUODI_XHTTP_PATH="${LUODI_XHTTP_PATH:-/}"
        LUODI_XHTTP_HOST="${LUODI_XHTTP_HOST:-$LUODI_SNI}"
        LUODI_XHTTP_MODE="${LUODI_XHTTP_MODE:-auto}"
    elif [[ "$LUODI_NETWORK" == "ws" ]]; then
        echo ""
        echo -e "${YELLOW}── 确认 WebSocket 传输参数 ──${NC}"
        read -rp "path [${LUODI_WS_PATH:-/}]: "                i; [[ -n "$i" ]] && LUODI_WS_PATH="$i"
        read -rp "host [${LUODI_WS_HOST:-$LUODI_SNI}]: "       i; [[ -n "$i" ]] && LUODI_WS_HOST="$i"
        LUODI_WS_PATH="${LUODI_WS_PATH:-/}"
        LUODI_WS_HOST="${LUODI_WS_HOST:-$LUODI_SNI}"
    elif [[ "$LUODI_NETWORK" == "grpc" ]]; then
        echo ""
        echo -e "${YELLOW}── 确认 gRPC 传输参数 ──${NC}"
        read -rp "serviceName [${LUODI_GRPC_SERVICE:-}]: "     i; [[ -n "$i" ]] && LUODI_GRPC_SERVICE="$i"
    fi

    # 允许手动覆盖检测结果
    echo ""
    echo -e "  检测到传输协议: ${CYAN}${LUODI_NETWORK}${NC}"
    read -rp "手动修改传输协议(tcp/xhttp/ws/grpc/h2)，回车跳过: " i
    [[ -n "$i" ]] && LUODI_NETWORK="$i" && log_warn "传输协议已手动设为: $LUODI_NETWORK"
}

# ── 配置 SSH 连接 ─────────────────────────────────────────
setup_ssh() {
    echo ""
    echo -e "${YELLOW}── 中转机 SSH 连接信息 ──${NC}"
    read -rp "中转机公网 IP: " RELAY_IP
    [[ -z "$RELAY_IP" ]] && log_error "中转机 IP 不能为空"
    local i
    read -rp "SSH 端口 [22]: "    i; RELAY_SSH_PORT="${i:-22}"
    read -rp "SSH 用户 [root]: "  i; RELAY_SSH_USER="${i:-root}"

    SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p $RELAY_SSH_PORT"

    echo ""
    echo -e "${YELLOW}选择 SSH 认证方式：${NC}"
    echo -e "  ${CYAN}[1]${NC} 密钥登录（默认，~/.ssh/id_rsa）"
    echo -e "  ${CYAN}[2]${NC} 指定密钥文件路径"
    echo -e "  ${CYAN}[3]${NC} 密码登录"
    echo -e "  ${CYAN}[4]${NC} 手动模式（无法 SSH 时）"
    read -rp "选择 [1]: " choice; choice="${choice:-1}"

    case "$choice" in
        1)
            AUTH_TYPE="key"
            local test_opts="$SSH_OPTS -o BatchMode=yes"
            if ssh -q $test_opts "${RELAY_SSH_USER}@${RELAY_IP}" "exit" 2>/dev/null; then
                log_info "密钥认证成功"
                SSH_OPTS="$test_opts"
            else
                log_warn "密钥认证失败"
                echo "  提示：在中转机执行 'cat ~/.ssh/authorized_keys' 确认公钥"
                read -rp "继续尝试？[y/N]: " yn
                [[ "${yn,,}" != "y" ]] && { AUTH_TYPE="manual"; return; }
                SSH_OPTS="$test_opts"
            fi
            ;;
        2)
            read -rp "密钥文件路径 [~/.ssh/id_rsa]: " RELAY_KEY_FILE
            RELAY_KEY_FILE="${RELAY_KEY_FILE:-~/.ssh/id_rsa}"
            RELAY_KEY_FILE="${RELAY_KEY_FILE/#\~/$HOME}"
            [[ ! -f "$RELAY_KEY_FILE" ]] && log_error "密钥文件不存在: $RELAY_KEY_FILE"
            AUTH_TYPE="keyfile"
            log_info "密钥文件: $RELAY_KEY_FILE"
            ;;
        3)
            if ! command -v sshpass &>/dev/null; then
                log_warn "安装 sshpass..."
                apt-get install -y -qq sshpass 2>/dev/null || true
            fi
            command -v sshpass &>/dev/null || log_error "sshpass 安装失败"
            read -rsp "SSH 密码: " RELAY_SSH_PASS; echo ""
            AUTH_TYPE="password"
            ;;
        *)
            AUTH_TYPE="manual"
            ;;
    esac
}

# ── 自动查找中转机 xray 路径 ──────────────────────────────
find_relay_xray_bin() {
    [[ "$AUTH_TYPE" == "manual" ]] && return
    log_step "查找中转机 xray 路径..."
    local found
    found=$(run_relay \
        "find /usr/local/bin /usr/bin /opt -maxdepth 3 -name 'xray' -type f 2>/dev/null | head -1 || true" \
        | tr -d '[:space:]') || true
    if [[ -n "$found" ]]; then
        RELAY_XRAY_BIN="$found"
        log_info "中转机 xray: $RELAY_XRAY_BIN"
    else
        log_warn "未找到 xray，跳过配置验证"
        RELAY_XRAY_BIN=""
    fi
}

# ── 读取中转机信息 ────────────────────────────────────────
read_relay_info() {
    if [[ "$AUTH_TYPE" == "manual" ]]; then
        echo ""
        echo -e "${YELLOW}── 手动输入中转机参数（cat /root/xray_zhongzhuan_info.txt）──${NC}"
        local i
        read -rp "中转机公钥 (ZHONGZHUAN_PUBKEY): "               RELAY_PUBKEY
        read -rp "中转机 SNI (ZHONGZHUAN_SNI): "                  RELAY_SNI
        read -rp "中转机 Short ID (ZHONGZHUAN_SHORT_ID): "        RELAY_SHORT_ID
        read -rp "中转机私钥 (ZHONGZHUAN_PRIVKEY): "              RELAY_PRIVKEY
        read -rp "起始端口 [30001]: "                             i; RELAY_START_PORT="${i:-30001}"
        read -rp "config.json 路径 [/usr/local/etc/xray-relay/config.json]: " i
        RELAY_CONFIG="${i:-/usr/local/etc/xray-relay/config.json}"
        read -rp "nodes.json 路径  [/usr/local/etc/xray-relay/nodes.json]: "  i
        RELAY_NODES="${i:-/usr/local/etc/xray-relay/nodes.json}"
        read -rp "xray 路径 [留空跳过验证]: "                     i; RELAY_XRAY_BIN="${i:-}"
        RELAY_DEST="${RELAY_SNI}:443"
        [[ -z "$RELAY_PUBKEY" || -z "$RELAY_SNI" || -z "$RELAY_PRIVKEY" ]] && \
            log_error "中转机参数不完整"
        log_info "中转机参数已手动录入"
        return
    fi

    log_step "读取中转机配置..."
    local info
    info=$(run_relay "cat /root/xray_zhongzhuan_info.txt 2>/dev/null || echo NOT_FOUND") || \
        log_error "SSH 执行失败，请检查连接"

    [[ "$info" == "NOT_FOUND" || -z "$info" ]] && \
        log_error "中转机未找到 xray_zhongzhuan_info.txt，请先运行 zhongzhuan.sh"

    local info_ip
    info_ip=$(echo "$info" | grep "^ZHONGZHUAN_IP=" | cut -d= -f2 | tr -d '\r')
    if [[ -n "$info_ip" && "$info_ip" != "$RELAY_IP" ]]; then
        log_warn "中转机信息 IP ($info_ip) 与输入 ($RELAY_IP) 不同（多 IP 或未更新，不影响连接）"
    fi

    while IFS='=' read -r key val; do
        val=$(echo "$val" | tr -d '\r')
        case "$key" in
            ZHONGZHUAN_PRIVKEY)     RELAY_PRIVKEY="$val"    ;;
            ZHONGZHUAN_PUBKEY)      RELAY_PUBKEY="$val"     ;;
            ZHONGZHUAN_SHORT_ID)    RELAY_SHORT_ID="$val"   ;;
            ZHONGZHUAN_SNI)         RELAY_SNI="$val"        ;;
            ZHONGZHUAN_DEST)        RELAY_DEST="$val"       ;;
            ZHONGZHUAN_START_PORT)  RELAY_START_PORT="$val" ;;
            ZHONGZHUAN_CONFIG)      RELAY_CONFIG="$val"     ;;
            ZHONGZHUAN_NODES)       RELAY_NODES="$val"      ;;
            ZHONGZHUAN_XRAY_BIN)    RELAY_XRAY_BIN="$val"   ;;
        esac
    done <<< "$info"

    RELAY_CONFIG="${RELAY_CONFIG:-/usr/local/etc/xray-relay/config.json}"
    RELAY_NODES="${RELAY_NODES:-/usr/local/etc/xray-relay/nodes.json}"
    RELAY_START_PORT="${RELAY_START_PORT:-30001}"

    [[ -z "$RELAY_PUBKEY" || -z "$RELAY_PRIVKEY" ]] && \
        log_error "中转机信息不完整，请重新运行 zhongzhuan.sh"

    log_info "中转机公钥: $RELAY_PUBKEY"
    log_info "中转机 SNI: $RELAY_SNI | 起始端口: $RELAY_START_PORT"

    find_relay_xray_bin
}

# ── 分配端口 + 生成 UUID ──────────────────────────────────
allocate_port_and_uuid() {
    log_step "分配中转机端口..."

    if [[ "$AUTH_TYPE" == "manual" ]]; then
        local i
        read -rp "中转机入站端口 [$RELAY_START_PORT]: " i
        RELAY_ASSIGNED_PORT="${i:-$RELAY_START_PORT}"
    else
        RELAY_ASSIGNED_PORT=$(echo "
import json, sys
try:
    cfg = json.load(open('${RELAY_CONFIG}'))
    used = {ib.get('port') for ib in cfg.get('inbounds', [])}
    p = int('${RELAY_START_PORT:-30001}')
    while p in used:
        p += 1
    print(p)
except Exception:
    print('${RELAY_START_PORT:-30001}')
" | pipe_python_relay | tr -d '[:space:]')
    fi

    [[ "$RELAY_ASSIGNED_PORT" =~ ^[0-9]+$ ]] || \
        log_error "获取端口失败，返回值: $RELAY_ASSIGNED_PORT"

    NEW_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
    log_info "分配端口: $RELAY_ASSIGNED_PORT | 新 UUID: $NEW_UUID"
}

# ── 更新中转机配置 ────────────────────────────────────────
update_relay_config() {
    log_step "更新中转机 xray-relay 配置..."

    # 出站是否需要 flow（xhttp / grpc / h2 不需要）
    local outbound_flow="xtls-rprx-vision"
    if [[ "$LUODI_NETWORK" =~ ^(xhttp|grpc|h2|http)$ ]]; then
        outbound_flow=""
    fi

    # 本地 Python 生成远程脚本，所有值通过 json.dumps → json.loads 传递
    # 彻底避免 false/true/null 及特殊字符问题
    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(python3 - << PYEOF
import json

network        = "${LUODI_NETWORK}"
outbound_flow  = "${outbound_flow}"
inbound_tag    = "relay-in-${RELAY_ASSIGNED_PORT}"
outbound_tag   = "relay-out-${RELAY_ASSIGNED_PORT}"

# ── 入站：用户→中转机，固定 tcp + Reality + vision ──
inbound = {
    "tag": inbound_tag,
    "port": int("${RELAY_ASSIGNED_PORT}"),
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
        "clients": [{"id": "${NEW_UUID}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "show": False,
            "dest": "${RELAY_DEST:-${RELAY_SNI}:443}",
            "xver": 0,
            "serverNames": ["${RELAY_SNI}"],
            "privateKey": "${RELAY_PRIVKEY}",
            "shortIds": ["${RELAY_SHORT_ID}"]
        }
    }
}

# ── 出站：中转机→落地机，使用落地机实际传输协议 ──
reality_out = {
    "fingerprint": "chrome",
    "serverName": "${LUODI_SNI}",
    "publicKey": "${LUODI_PUBKEY}",
    "shortId": "${LUODI_SHORT_ID}",
    "spiderX": "/"
}

stream_out = {
    "network": network,
    "security": "reality",
    "realitySettings": reality_out
}

# 按传输协议附加对应 settings
if network == "xhttp":
    stream_out["xhttpSettings"] = {
        "host": "${LUODI_XHTTP_HOST}" or "${LUODI_SNI}",
        "path": "${LUODI_XHTTP_PATH}" or "/",
        "mode": "${LUODI_XHTTP_MODE}" or "auto"
    }
elif network == "ws":
    headers = {}
    if "${LUODI_WS_HOST}":
        headers["Host"] = "${LUODI_WS_HOST}"
    stream_out["wsSettings"] = {
        "path": "${LUODI_WS_PATH}" or "/",
        "headers": headers
    }
elif network == "grpc":
    stream_out["grpcSettings"] = {
        "serviceName": "${LUODI_GRPC_SERVICE}"
    }
elif network in ("h2", "http"):
    stream_out["network"] = "h2"
    h2_host = "${LUODI_H2_HOST}"
    stream_out["httpSettings"] = {
        "path": "${LUODI_H2_PATH}" or "/",
        "host": [h2_host] if h2_host else []
    }

user_out = {"id": "${LUODI_UUID}", "encryption": "none"}
if outbound_flow:
    user_out["flow"] = outbound_flow

outbound = {
    "tag": outbound_tag,
    "protocol": "vless",
    "settings": {
        "vnext": [{
            "address": "${LUODI_IP}",
            "port": int("${LUODI_PORT}"),
            "users": [user_out]
        }]
    },
    "streamSettings": stream_out
}

rule = {
    "type": "field",
    "inboundTag": [inbound_tag],
    "outboundTag": outbound_tag
}

node_info = {
    "tag": inbound_tag,
    "relay_port": int("${RELAY_ASSIGNED_PORT}"),
    "relay_uuid": "${NEW_UUID}",
    "landing_ip": "${LUODI_IP}",
    "landing_port": int("${LUODI_PORT}"),
    "landing_network": network,
    "label": "${NODE_LABEL}",
    "added_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}

# 生成远程脚本：用 json.loads() 解析序列化后的字符串，避免 false/true/null 问题
remote = f"""import json, sys, os

config_path = {json.dumps("${RELAY_CONFIG}")}
nodes_path  = {json.dumps("${RELAY_NODES}")}
inbound     = json.loads({json.dumps(json.dumps(inbound))})
outbound    = json.loads({json.dumps(json.dumps(outbound))})
rule        = json.loads({json.dumps(json.dumps(rule))})
node_info   = json.loads({json.dumps(json.dumps(node_info))})

# 读取配置
try:
    with open(config_path) as f:
        config = json.load(f)
except Exception as e:
    print(f"ERROR: 读取配置失败 {{e}}", file=sys.stderr)
    sys.exit(1)

# 幂等：先删除同标签旧规则
config["inbounds"] = [i for i in config.get("inbounds", [])
                      if i.get("tag") != inbound["tag"]]
config["outbounds"] = [o for o in config.get("outbounds", [])
                       if o.get("tag") not in (outbound["tag"], "direct")]
config.setdefault("routing", {{}}).setdefault("rules", [])
config["routing"]["rules"] = [r for r in config["routing"]["rules"]
                               if inbound["tag"] not in r.get("inboundTag", [])]

# 写入新规则，路由置顶
config["inbounds"].append(inbound)
config["outbounds"].insert(0, outbound)
config["outbounds"].append({{"tag": "direct", "protocol": "freedom"}})
config["routing"]["rules"].insert(0, rule)

with open(config_path, "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print(f"[OK] 入站/出站/路由已写入（端口 {{inbound['port']}}，传输: {json.dumps(network)}）")

# 更新节点注册表，nodes.json 不存在时自动创建
os.makedirs(os.path.dirname(nodes_path), exist_ok=True)
try:
    with open(nodes_path) as f:
        nodes = json.load(f)
except Exception:
    nodes = {{"nodes": []}}
nodes["nodes"] = [n for n in nodes.get("nodes", [])
                  if n.get("tag") != node_info["tag"]]
nodes["nodes"].append(node_info)
with open(nodes_path, "w") as f:
    json.dump(nodes, f, indent=2, ensure_ascii=False)
print(f"[OK] 节点注册表已更新（共 {{len(nodes['nodes'])}} 个节点）")
"""
print(remote)
PYEOF
)

    if [[ "$AUTH_TYPE" == "manual" ]]; then
        echo ""
        echo -e "${YELLOW}══ 在中转机上执行以下 Python 脚本 ══${NC}"
        echo ""
        echo "保存为 /tmp/relay_update.py 后运行 python3 /tmp/relay_update.py："
        echo "────────────────────────────────────────────────────────"
        echo "$REMOTE_SCRIPT"
        echo "────────────────────────────────────────────────────────"
        echo ""
        log_warn "执行完毕后在中转机运行: systemctl restart xray-relay"
        echo ""
        read -rp "已在中转机执行完毕？按回车继续..." _
        return
    fi

    # 发送到中转机执行
    local result
    result=$(echo "$REMOTE_SCRIPT" | pipe_python_relay) || \
        log_error "远程配置写入失败，请检查中转机"
    echo "$result" | while read -r line; do log_info "中转机: $line"; done

    # 验证配置
    if [[ -n "$RELAY_XRAY_BIN" ]]; then
        log_step "验证 xray-relay 配置..."
        local verify_ok
        verify_ok=$(run_relay \
            "${RELAY_XRAY_BIN} -test -config ${RELAY_CONFIG} >/dev/null 2>&1 \
             && echo OK || echo FAIL" | tr -d '[:space:]') || verify_ok="FAIL"
        if [[ "$verify_ok" == "OK" ]]; then
            log_info "配置验证通过"
        else
            log_warn "配置验证失败，错误详情："
            run_relay "${RELAY_XRAY_BIN} -test -config ${RELAY_CONFIG} 2>&1 | tail -10" || true
            log_error "xray-relay 配置有误，请检查"
        fi
    else
        log_warn "跳过配置验证（未找到 xray 路径）"
    fi

    # 重启并确认
    run_relay "systemctl restart xray-relay"
    sleep 2
    local status
    status=$(run_relay \
        "systemctl is-active xray-relay 2>/dev/null || echo inactive" \
        | tr -d '[:space:]') || status="unknown"

    if [[ "$status" == "active" ]]; then
        log_info "xray-relay 重启成功，运行正常"
    else
        log_warn "xray-relay 状态异常，最近日志："
        run_relay "journalctl -u xray-relay -n 10 --no-pager 2>/dev/null || true" | \
            while read -r line; do echo -e "  ${YELLOW}${line}${NC}"; done
        log_error "xray-relay 未能正常启动，请 SSH 到中转机排查"
    fi
}

# ── 生成节点链接 ──────────────────────────────────────────
generate_node_link() {
    log_step "生成节点链接..."

    [[ -z "$RELAY_PUBKEY" ]] && log_error "中转机公钥为空"
    [[ -z "$RELAY_SNI" ]]    && log_error "中转机 SNI 为空"

    # 节点链接：用户→中转机，固定 tcp + Reality + vision flow
    local label_encoded
    label_encoded=$(python3 -c \
        "import urllib.parse; print(urllib.parse.quote('${NODE_LABEL}'))" 2>/dev/null \
        || echo "${NODE_LABEL}")

    NODE_LINK="vless://${NEW_UUID}@${RELAY_IP}:${RELAY_ASSIGNED_PORT}"
    NODE_LINK+="?encryption=none&flow=xtls-rprx-vision"
    NODE_LINK+="&security=reality&sni=${RELAY_SNI}"
    NODE_LINK+="&fp=chrome&pbk=${RELAY_PUBKEY}"
    NODE_LINK+="&sid=${RELAY_SHORT_ID}"
    NODE_LINK+="&type=tcp&headerType=none"
    NODE_LINK+="#${label_encoded}"

    log_info "节点链接已生成"
}

# ── 保存结果 ──────────────────────────────────────────────
save_result() {
    {
        echo ""
        echo "── 对接节点链接（$(date '+%Y-%m-%d %H:%M:%S')）──────────────────────"
        echo "RELAY_IP=${RELAY_IP}"
        echo "RELAY_PORT=${RELAY_ASSIGNED_PORT}"
        echo "RELAY_UUID=${NEW_UUID}"
        echo "LANDING_IP=${LUODI_IP}"
        echo "LANDING_PORT=${LUODI_PORT}"
        echo "LANDING_NETWORK=${LUODI_NETWORK}"
        echo "NODE_LABEL=${NODE_LABEL}"
        echo "NODE_LINK=${NODE_LINK}"
        echo "────────────────────────────────────────────────────────────"
    } >> "$LOCAL_INFO"
    log_info "节点链接已追加到: $LOCAL_INFO"
}

# ── 打印结果 ──────────────────────────────────────────────
print_result() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  ${GREEN}${BOLD}✓ 对接完成  duijie.sh v6.0${NC}                          ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}流量路径：${NC}"
    echo -e "  用户 ──tcp/Reality──▶ ${CYAN}${RELAY_IP}:${RELAY_ASSIGNED_PORT}${NC}"
    echo -e "       ──${LUODI_NETWORK}/Reality──▶ ${LUODI_IP}:${LUODI_PORT} ──▶ 互联网"
    echo ""
    echo -e "  ${BOLD}节点链接：${NC}"
    echo -e "  ${GREEN}${NODE_LINK}${NC}"
    echo ""
    echo -e "  ${BOLD}中转机 IP      :${NC} $RELAY_IP"
    echo -e "  ${BOLD}入站端口       :${NC} $RELAY_ASSIGNED_PORT"
    echo -e "  ${BOLD}出口 IP        :${NC} $LUODI_IP:$LUODI_PORT"
    echo -e "  ${BOLD}中转→落地协议  :${NC} $LUODI_NETWORK"
    echo -e "  ${BOLD}节点标签       :${NC} $NODE_LABEL"
    echo ""
    echo -e "${YELLOW}连通性验证（在中转机执行）：${NC}"
    if [[ "$LUODI_NETWORK" == "xhttp" ]]; then
        echo -e "  curl -sv --max-time 5 http://${LUODI_IP}:${LUODI_PORT}${LUODI_XHTTP_PATH}"
    else
        echo -e "  nc -zv ${LUODI_IP} ${LUODI_PORT} -w 5"
    fi
    echo ""
    echo -e "${YELLOW}常用命令：${NC}"
    echo -e "  落地机信息      : cat $LOCAL_INFO"
    echo -e "  中转机节点列表  : (SSH到中转机) python3 -m json.tool $RELAY_NODES"
    echo -e "  中转机实时日志  : (SSH到中转机) journalctl -u xray-relay -f"
    echo -e "  中转机配置      : (SSH到中转机) cat $RELAY_CONFIG"
    echo ""
}

main() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       落地机对接脚本  duijie.sh  v6.0               ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    read_luodi_info
    setup_ssh
    read_relay_info
    allocate_port_and_uuid
    update_relay_config
    generate_node_link
    save_result
    print_result
}

main "$@"
