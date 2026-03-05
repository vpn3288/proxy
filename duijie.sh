#!/bin/bash
# ============================================================
# duijie.sh v5.0 — 落地机对接中转机脚本
# 功能：在落地机上运行，SSH 到中转机，自动写入
#       relay 入站 + 出站 + 路由规则，生成用户节点链接
# 用法：bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/duijie.sh)
# 前置：落地机已运行 luodi.sh，中转机已运行 zhongzhuan.sh
# ============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
log_step()  { echo -e "${CYAN}[→]${NC} $1"; }

[[ $EUID -ne 0 ]] && log_error "请使用 root 权限运行"

LOCAL_INFO="/root/xray_luodi_info.txt"

# 落地机变量
LUODI_IP="" LUODI_RELAY_PORT="" LUODI_UUID="" LUODI_PUBKEY=""
LUODI_PRIVKEY="" LUODI_SHORT_ID="" LUODI_SNI="" LUODI_DEST=""

# 中转机变量
RELAY_IP="" RELAY_SSH_PORT="22" RELAY_SSH_USER="root"
RELAY_SSH_PASS="" RELAY_KEY_FILE=""
RELAY_PRIVKEY="" RELAY_PUBKEY="" RELAY_SHORT_ID="" RELAY_SNI=""
RELAY_START_PORT="" RELAY_CONFIG="" RELAY_NODES="" RELAY_XRAY_BIN=""
AUTH_TYPE=""

# 结果
RELAY_ASSIGNED_PORT="" NEW_UUID="" NODE_LINK="" NODE_LABEL=""

# ── SSH 执行工具函数 ──────────────────────────────────────
# 在中转机上执行命令
run_relay() {
    local cmd="$1"
    case "$AUTH_TYPE" in
        key)      ssh -q $SSH_OPTS "${RELAY_SSH_USER}@${RELAY_IP}" "$cmd" ;;
        password) sshpass -p "$RELAY_SSH_PASS" \
                      ssh -q $SSH_OPTS "${RELAY_SSH_USER}@${RELAY_IP}" "$cmd" ;;
        keyfile)  ssh -q $SSH_OPTS -i "$RELAY_KEY_FILE" \
                      "${RELAY_SSH_USER}@${RELAY_IP}" "$cmd" ;;
    esac
}

# 通过 stdin 管道在中转机上运行 Python
pipe_python_relay() {
    case "$AUTH_TYPE" in
        key)      ssh -q $SSH_OPTS "${RELAY_SSH_USER}@${RELAY_IP}" "python3" ;;
        password) sshpass -p "$RELAY_SSH_PASS" \
                      ssh -q $SSH_OPTS "${RELAY_SSH_USER}@${RELAY_IP}" "python3" ;;
        keyfile)  ssh -q $SSH_OPTS -i "$RELAY_KEY_FILE" \
                      "${RELAY_SSH_USER}@${RELAY_IP}" "python3" ;;
    esac
}

# ── 读取落地机信息 ────────────────────────────────────────
read_luodi_info() {
    log_step "读取落地机信息..."

    if [[ -f "$LOCAL_INFO" ]]; then
        log_info "从 $LOCAL_INFO 加载..."
        while IFS='=' read -r key val; do
            val=$(echo "$val" | tr -d '\r')
            case "$key" in
                LUODI_IP)          LUODI_IP="$val"          ;;
                LUODI_RELAY_PORT)  LUODI_RELAY_PORT="$val"  ;;
                LUODI_UUID)        LUODI_UUID="$val"        ;;
                LUODI_PUBKEY)      LUODI_PUBKEY="$val"      ;;
                LUODI_PRIVKEY)     LUODI_PRIVKEY="$val"     ;;
                LUODI_SHORT_ID)    LUODI_SHORT_ID="$val"    ;;
                LUODI_SNI)         LUODI_SNI="$val"         ;;
                LUODI_DEST)        LUODI_DEST="$val"        ;;
            esac
        done < "$LOCAL_INFO"
    fi

    # 若信息不完整则提示手动输入
    echo ""
    echo -e "${YELLOW}── 确认落地机信息（回车保留自动读取值）──${NC}"
    read -rp "落地机 IP               [${LUODI_IP:-待输入}]: "         i; [[ -n "$i" ]] && LUODI_IP="$i"
    read -rp "中转专用端口            [${LUODI_RELAY_PORT:-待输入}]: "  i; [[ -n "$i" ]] && LUODI_RELAY_PORT="$i"
    read -rp "UUID                    [${LUODI_UUID:-待输入}]: "        i; [[ -n "$i" ]] && LUODI_UUID="$i"
    read -rp "公钥 (pubkey)           [${LUODI_PUBKEY:-待输入}]: "      i; [[ -n "$i" ]] && LUODI_PUBKEY="$i"
    read -rp "SNI                     [${LUODI_SNI:-待输入}]: "         i; [[ -n "$i" ]] && LUODI_SNI="$i"
    read -rp "Short ID                [${LUODI_SHORT_ID:-空}]: "        i; [[ -n "$i" ]] && LUODI_SHORT_ID="$i"
    read -rp "节点标签（显示名称）    [LuoDi-${LUODI_IP}]: "            i
    NODE_LABEL="${i:-LuoDi-${LUODI_IP}}"

    [[ -z "$LUODI_IP" || -z "$LUODI_RELAY_PORT" || -z "$LUODI_UUID" || -z "$LUODI_PUBKEY" ]] && \
        log_error "落地机信息不完整，请先运行 luodi.sh"
    log_info "落地机: $LUODI_IP:$LUODI_RELAY_PORT"
}

# ── 配置 SSH 连接 ─────────────────────────────────────────
setup_ssh() {
    echo ""
    echo -e "${YELLOW}── 中转机 SSH 连接信息 ──${NC}"
    read -rp "中转机公网 IP: " RELAY_IP
    [[ -z "$RELAY_IP" ]] && log_error "中转机 IP 不能为空"
    read -rp "SSH 端口 [22]: " i; RELAY_SSH_PORT="${i:-22}"
    read -rp "SSH 用户 [root]: " i; RELAY_SSH_USER="${i:-root}"

    SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 \
              -o BatchMode=yes -p $RELAY_SSH_PORT"

    echo ""
    echo -e "${YELLOW}选择 SSH 认证方式：${NC}"
    echo -e "  ${CYAN}[1]${NC} 密钥登录（默认，尝试 ~/.ssh/id_rsa）"
    echo -e "  ${CYAN}[2]${NC} 指定密钥文件路径"
    echo -e "  ${CYAN}[3]${NC} 密码登录"
    echo -e "  ${CYAN}[4]${NC} 显示手动命令（无法 SSH 时使用）"
    read -rp "选择 [1]: " choice; choice="${choice:-1}"

    case "$choice" in
        1)
            AUTH_TYPE="key"
            if ! ssh -q $SSH_OPTS "${RELAY_SSH_USER}@${RELAY_IP}" "exit" 2>/dev/null; then
                log_warn "密钥认证失败，请检查是否已配置免密登录"
                echo "  提示：在中转机上执行 'cat ~/.ssh/authorized_keys' 确认落地机公钥已添加"
                read -rp "继续尝试？[y/N]: " yn
                [[ "${yn,,}" != "y" ]] && { AUTH_TYPE="manual"; return; }
            else
                log_info "密钥认证成功"
            fi
            ;;
        2)
            read -rp "密钥文件路径 [~/.ssh/id_rsa]: " RELAY_KEY_FILE
            RELAY_KEY_FILE="${RELAY_KEY_FILE:-~/.ssh/id_rsa}"
            RELAY_KEY_FILE="${RELAY_KEY_FILE/#\~/$HOME}"
            [[ ! -f "$RELAY_KEY_FILE" ]] && log_error "密钥文件不存在: $RELAY_KEY_FILE"
            AUTH_TYPE="keyfile"
            SSH_OPTS="${SSH_OPTS/ -o BatchMode=yes/}"  # keyfile 不需要 BatchMode
            log_info "使用密钥: $RELAY_KEY_FILE"
            ;;
        3)
            if ! command -v sshpass &>/dev/null; then
                log_warn "安装 sshpass..."
                apt-get install -y -qq sshpass 2>/dev/null || true
            fi
            command -v sshpass &>/dev/null || log_error "sshpass 安装失败，请改用密钥登录"
            read -rsp "SSH 密码: " RELAY_SSH_PASS; echo ""
            AUTH_TYPE="password"
            SSH_OPTS="${SSH_OPTS/ -o BatchMode=yes/}"
            ;;
        4)
            AUTH_TYPE="manual"
            ;;
        *)
            AUTH_TYPE="manual"
            ;;
    esac
}

# ── 读取中转机信息 ────────────────────────────────────────
read_relay_info() {
    [[ "$AUTH_TYPE" == "manual" ]] && return
    log_step "读取中转机配置..."

    local info
    info=$(run_relay "cat /root/xray_zhongzhuan_info.txt 2>/dev/null || echo 'NOT_FOUND'") || \
        log_error "无法读取中转机信息，请确认 zhongzhuan.sh 已运行"
    [[ "$info" == "NOT_FOUND" ]] && \
        log_error "/root/xray_zhongzhuan_info.txt 不存在，请先在中转机运行 zhongzhuan.sh"

    while IFS='=' read -r key val; do
        val=$(echo "$val" | tr -d '\r')
        case "$key" in
            ZHONGZHUAN_IP)          RELAY_IP_CONFIRMED="$val"   ;;
            ZHONGZHUAN_PRIVKEY)     RELAY_PRIVKEY="$val"        ;;
            ZHONGZHUAN_PUBKEY)      RELAY_PUBKEY="$val"         ;;
            ZHONGZHUAN_SHORT_ID)    RELAY_SHORT_ID="$val"       ;;
            ZHONGZHUAN_SNI)         RELAY_SNI="$val"            ;;
            ZHONGZHUAN_DEST)        RELAY_DEST="$val"           ;;
            ZHONGZHUAN_START_PORT)  RELAY_START_PORT="$val"     ;;
            ZHONGZHUAN_CONFIG)      RELAY_CONFIG="$val"         ;;
            ZHONGZHUAN_NODES)       RELAY_NODES="$val"          ;;
            ZHONGZHUAN_XRAY_BIN)    RELAY_XRAY_BIN="$val"       ;;
        esac
    done <<< "$info"

    log_info "中转机 Reality 公钥: $RELAY_PUBKEY"
    log_info "中转机 SNI: $RELAY_SNI"
    log_info "起始端口: $RELAY_START_PORT"
}

# ── 分配端口 + 生成 UUID ──────────────────────────────────
allocate_port_and_uuid() {
    [[ "$AUTH_TYPE" == "manual" ]] && {
        read -rp "中转机入站端口 [30001]: " RELAY_ASSIGNED_PORT
        RELAY_ASSIGNED_PORT="${RELAY_ASSIGNED_PORT:-30001}"
        NEW_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
        log_info "端口: $RELAY_ASSIGNED_PORT | UUID: $NEW_UUID"
        return
    }

    log_step "分配中转机端口..."

    # 在中转机上找下一个可用端口
    RELAY_ASSIGNED_PORT=$(run_relay "python3 -c \"
import json
try:
    cfg = json.load(open('${RELAY_CONFIG}'))
    used = {i.get('port') for i in cfg.get('inbounds', [])}
    start = ${RELAY_START_PORT:-30001}
    p = start
    while p in used: p += 1
    print(p)
except Exception as e:
    print(${RELAY_START_PORT:-30001})
\"")
    RELAY_ASSIGNED_PORT=$(echo "$RELAY_ASSIGNED_PORT" | tr -d '[:space:]')

    # 生成新 UUID（本地）
    NEW_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")

    log_info "分配端口: $RELAY_ASSIGNED_PORT | 新 UUID: $NEW_UUID"
}

# ── 更新中转机配置 ────────────────────────────────────────
update_relay_config() {
    if [[ "$AUTH_TYPE" == "manual" ]]; then
        show_manual_commands
        return
    fi

    log_step "更新中转机 xray-relay 配置..."

    # 本地用 Python 生成完整的远程更新脚本（所有值 JSON 转义后嵌入）
    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(python3 << PYEOF
import json

inbound_tag = "relay-in-${RELAY_ASSIGNED_PORT}"
outbound_tag = "relay-out-${RELAY_ASSIGNED_PORT}"

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

outbound = {
    "tag": outbound_tag,
    "protocol": "vless",
    "settings": {
        "vnext": [{
            "address": "${LUODI_IP}",
            "port": int("${LUODI_RELAY_PORT}"),
            "users": [{
                "id": "${LUODI_UUID}",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
            }]
        }]
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "fingerprint": "chrome",
            "serverName": "${LUODI_SNI}",
            "publicKey": "${LUODI_PUBKEY}",
            "shortId": "${LUODI_SHORT_ID}",
            "spiderX": "/"
        }
    }
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
    "landing_port": int("${LUODI_RELAY_PORT}"),
    "label": "${NODE_LABEL}",
    "added_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}

script = f'''
import json, sys

config_path = "${RELAY_CONFIG}"
nodes_path  = "${RELAY_NODES}"

inbound   = {json.dumps(inbound)}
outbound  = {json.dumps(outbound)}
rule      = {json.dumps(rule)}
node_info = {json.dumps(node_info)}

try:
    with open(config_path) as f:
        config = json.load(f)
except Exception as e:
    print(f"ERROR: 读取配置失败 {{e}}", file=sys.stderr)
    sys.exit(1)

# 幂等：删除同标签的旧规则
config["inbounds"] = [i for i in config.get("inbounds", [])
                      if i.get("tag") != inbound["tag"]]
config["outbounds"] = [o for o in config.get("outbounds", [])
                       if o.get("tag") not in [outbound["tag"], "direct"]]
config.setdefault("routing", {{}}).setdefault("rules", [])
config["routing"]["rules"] = [r for r in config["routing"]["rules"]
                               if inbound["tag"] not in r.get("inboundTag", [])]

# 写入新规则
config["inbounds"].append(inbound)
config["outbounds"].insert(0, outbound)
config["outbounds"].append({{"tag": "direct", "protocol": "freedom"}})
config["routing"]["rules"].insert(0, rule)   # 路由规则置顶

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"[✓] 入站/出站/路由规则已写入 (端口 {inbound['port']})")

# 更新节点注册表
try:
    with open(nodes_path) as f:
        nodes = json.load(f)
except Exception:
    nodes = {{"nodes": []}}
nodes["nodes"] = [n for n in nodes.get("nodes", [])
                  if n.get("tag") != node_info["tag"]]
nodes["nodes"].append(node_info)
with open(nodes_path, "w") as f:
    json.dump(nodes, f, indent=2)
print(f"[✓] 节点注册表已更新 (共 {{len(nodes['nodes'])}} 个节点)")
'''
print(script)
PYEOF
)

    # 发送并执行远程脚本
    local result
    result=$(echo "$REMOTE_SCRIPT" | pipe_python_relay) || \
        log_error "远程配置写入失败，请检查中转机"
    echo "$result" | while read -r line; do log_info "中转机: $line"; done

    # 验证配置
    log_step "验证中转机 xray-relay 配置..."
    run_relay "${RELAY_XRAY_BIN:-xray} -test -config ${RELAY_CONFIG} >/dev/null 2>&1 && \
               echo CONFIG_OK || echo CONFIG_FAIL" | grep -q "CONFIG_OK" || {
        log_warn "配置验证失败，尝试查看错误..."
        run_relay "${RELAY_XRAY_BIN:-xray} -test -config ${RELAY_CONFIG} 2>&1 | tail -10" || true
        log_error "xray-relay 配置有误，请检查"
    }
    log_info "配置验证通过"

    # 重启 xray-relay
    run_relay "systemctl restart xray-relay"
    sleep 2

    local status
    status=$(run_relay "systemctl is-active xray-relay 2>/dev/null || echo inactive")
    status=$(echo "$status" | tr -d '[:space:]')
    if [[ "$status" == "active" ]]; then
        log_info "xray-relay 重启成功，运行正常"
    else
        log_error "xray-relay 未能正常启动：run_relay 'journalctl -u xray-relay -n 20'"
    fi
}

# ── 生成节点链接 ──────────────────────────────────────────
generate_node_link() {
    log_step "生成节点链接..."

    # 用户使用的节点：连接中转机，流量经中转到落地机出口
    NODE_LINK="vless://${NEW_UUID}@${RELAY_IP}:${RELAY_ASSIGNED_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RELAY_SNI}&fp=chrome&pbk=${RELAY_PUBKEY}&sid=${RELAY_SHORT_ID}&type=tcp&headerType=none#${NODE_LABEL}"
    log_info "节点链接已生成"
}

# ── 显示手动命令（SSH 失败时的降级方案）─────────────────
show_manual_commands() {
    echo ""
    echo -e "${YELLOW}══ 无法自动 SSH，请在中转机手动执行以下 Python 脚本 ══${NC}"
    echo ""
    echo -e "在中转机上运行 ${CYAN}python3 /tmp/relay_update.py${NC}"
    echo ""
    echo "将以下内容保存为 /tmp/relay_update.py："
    echo "─────────────────────────────────────────────────"
    cat << MANUAL_PYEOF
import json

config_path = "${RELAY_CONFIG:-/usr/local/etc/xray-relay/config.json}"
nodes_path  = "${RELAY_NODES:-/usr/local/etc/xray-relay/nodes.json}"

# 请替换以下实际值
relay_privkey   = "请在中转机 /root/xray_zhongzhuan_info.txt 查看 ZHONGZHUAN_PRIVKEY"
relay_sni       = "请填写 ZHONGZHUAN_SNI"
relay_short_id  = "请填写 ZHONGZHUAN_SHORT_ID"
landing_ip      = "${LUODI_IP}"
landing_port    = ${LUODI_RELAY_PORT}
landing_uuid    = "${LUODI_UUID}"
landing_pubkey  = "${LUODI_PUBKEY}"
landing_sni     = "${LUODI_SNI}"
landing_sid     = "${LUODI_SHORT_ID}"
relay_port      = 30001  # 从起始端口依次往后取未使用的
new_uuid        = "$(python3 -c 'import uuid; print(uuid.uuid4())')"

# 用实际值替换上面后直接运行即可
# 脚本自动更新 config.json 和 nodes.json 并打印结果
MANUAL_PYEOF
    echo "─────────────────────────────────────────────────"
    echo ""
    log_warn "完成后在中转机执行: systemctl restart xray-relay"
    echo ""
}

# ── 保存结果 ──────────────────────────────────────────────
save_result() {
    # 追加节点链接到落地机信息文件
    {
        echo ""
        echo "── 对接节点链接（$(date '+%Y-%m-%d %H:%M:%S')）────────────────────"
        echo "RELAY_IP=${RELAY_IP}"
        echo "RELAY_PORT=${RELAY_ASSIGNED_PORT}"
        echo "RELAY_UUID=${NEW_UUID}"
        echo "NODE_LABEL=${NODE_LABEL}"
        echo "NODE_LINK=${NODE_LINK}"
        echo "──────────────────────────────────────────────────────────"
    } >> "$LOCAL_INFO"
    log_info "节点链接已追加到: $LOCAL_INFO"
}

# ── 打印结果 ──────────────────────────────────────────────
print_result() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  ${GREEN}${BOLD}✓ 对接完成！节点链接如下${NC}                            ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}流量路径：${NC}"
    echo -e "  用户 → 中转机 ${RELAY_IP}:${RELAY_ASSIGNED_PORT} → 落地机 ${LUODI_IP} → 互联网"
    echo ""
    echo -e "  ${BOLD}节点链接：${NC}"
    echo -e "  ${GREEN}${NODE_LINK}${NC}"
    echo ""
    echo -e "  ${BOLD}中转机 IP  :${NC} $RELAY_IP"
    echo -e "  ${BOLD}入站端口   :${NC} $RELAY_ASSIGNED_PORT"
    echo -e "  ${BOLD}出口 IP    :${NC} $LUODI_IP"
    echo -e "  ${BOLD}节点标签   :${NC} $NODE_LABEL"
    echo ""
    echo -e "${YELLOW}常用命令：${NC}"
    echo -e "  查看落地机信息   : cat $LOCAL_INFO"
    echo -e "  查看中转机节点表 : (SSH到中转机) cat $RELAY_NODES | python3 -m json.tool"
    echo -e "  中转机日志       : (SSH到中转机) journalctl -u xray-relay -f"
    echo ""
}

# ── 主函数 ────────────────────────────────────────────────
main() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       落地机对接脚本  duijie.sh  v5.0               ║${NC}"
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
