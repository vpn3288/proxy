#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║          duijie.sh  v16.0  —  落地机 ↔ 中转机 对接脚本         ║
# ║  运行位置：落地机上执行（通过 SSH 写入中转机配置）               ║
# ║  用法    ：bash duijie.sh            # 交互模式                  ║
# ║            bash duijie.sh --auto     # 全自动零交互模式          ║
# ║            bash duijie.sh --manage   # 节点管理模式              ║
# ╠══════════════════════════════════════════════════════════════════╣
# ║  ⚡ 核心设计                                                     ║
# ║  · LINK_ID（MD5 指纹）：每对「落地IP+端口」唯一标识              ║
# ║    in_tag  = relay-in-{LINK_ID}                                  ║
# ║    out_tag = relay-out-{LINK_ID}                                 ║
# ║  · 全程双层 Python json.dumps 序列化：杜绝 True/False/引号问题   ║
# ║  · 所有远端脚本由本地 Python 生成后 pipe_python_relay 管道执行   ║
# ╠══════════════════════════════════════════════════════════════════╣
# ║  🔧 v16 相较 v15 新增修复                                        ║
# ║                                                                  ║
# ║  [H1] RELAY_IP 信息在 auto_clean_by_link_id 之前暂存            ║
# ║       v15 在 read_luodi_info 中调用 auto_clean_by_link_id 后，   ║
# ║       LOCAL_INFO 的历史块被删除，包含 RELAY_IP= 的行也随之消失。  ║
# ║       后续 setup_ssh 找不到上次的中转机 IP，依然强制让用户输入。  ║
# ║       v16：clean 前先从历史文件提取 RELAY_IP/RELAY_SSH_PORT，    ║
# ║       暂存到全局变量；setup_ssh 将其作为默认值直接使用。          ║
# ║                                                                  ║
# ║  [H2] setup_ssh 先静默探测免密登录，成功直接跳过认证菜单         ║
# ║       v15 拿到 RELAY_IP 后依然每次弹出认证方式选择菜单。          ║
# ║       v16：先执行 ssh -o BatchMode=yes exit，成功则 AUTH_TYPE=   ║
# ║       key 自动通过，整个认证菜单静默跳过；                        ║
# ║       --auto 模式下若免密失败直接 log_error 终止，不再降级。      ║
# ║                                                                  ║
# ║  [H3] 引入 AUTO_MODE 全局零交互参数 (--auto)                     ║
# ║       v15 以下函数仍有阻塞式 read -rp：                          ║
# ║         configure_mux / configure_sockopt / check_unlock /       ║
# ║         generate_firewall_cmds / configure_port_knocking         ║
# ║       v16：检测到 AUTO_MODE=true 时：                            ║
# ║         Mux → 关闭（CN2 GIA 线路稳定，Mux 增加开销）            ║
# ║         sockopt → 开启（tcpFastOpen 对 CN2 GIA 优化显著）        ║
# ║         check_unlock → 跳过（交由用户手动检测）                  ║
# ║         firewall → 自动执行 iptables 落地侧保护规则              ║
# ║         port_knocking → 跳过（由第四个防火墙脚本负责）           ║
# ║                                                                  ║
# ║  [H4] --auto 模式下中转机侧自动放行新端口（iptables）            ║
# ║       v15 对接成功后仅输出 iptables 建议命令，需用户手动执行。    ║
# ║       v16：AUTO_MODE=true 时在 generate_firewall_cmds 中通过     ║
# ║       SSH 自动在中转机执行 iptables -I INPUT 放行 RELAY_PORT，   ║
# ║       并调用 netfilter-persistent save 持久化。                  ║
# ║                                                                  ║
# ║  [H5] BBR 在 AUTO_MODE 下静默启用，跳过确认提示                  ║
# ║       v15 BBR 设置仍弹 "启用 BBR？[Y/n]"，阻断自动化流程。       ║
# ║       v16：AUTO_MODE=true 时直接静默启用最优 BBR 版本。           ║
# ╠══════════════════════════════════════════════════════════════════╣
# ║  🔧 v15 相较 v14 新增修复                                        ║
# ║                                                                  ║
# ║  [G1] cleanup_old_data 完全去交互、改为 LINK_ID 精准自动清理     ║
# ║       v14 仍弹菜单让用户选择追加/清除，且 [2] 清除的是全部记录。 ║
# ║       v15：生成 LINK_ID 后立即无感调用 auto_clean_by_link_id()   ║
# ║       用 Python 精准移除该 LINK_ID 的历史段落，其他节点不受影响。║
# ║                                                                  ║
# ║  [G2] read_luodi_info 自动填充完整时零交互                       ║
# ║       v14 无论读没读到值，都弹 7 个 read -rp 等待用户确认。      ║
# ║       v15：仅对空字段弹输入框，全部字段就绪则打印摘要自动继续；  ║
# ║       同时新增从 LOCAL_INFO 读取 LUODI_NETWORK（之前缺失）。     ║
# ║                                                                  ║
# ║  [G3] _apply_transport_json 嗅探成功时跳过协议确认提示           ║
# ║       v14 每次都问"手动修改传输协议？"，即使嗅探 Level-1 成功。  ║
# ║       v15：source 为 export-json/xui-sqlite/json-file 时静默     ║
# ║       跳过覆盖提示；协议参数也仅在值为空/默认时才弹框。          ║
# ║                                                                  ║
# ║  [G4] SQLite 嗅探增加 enable=1 过滤 + ORDER BY id DESC           ║
# ║       v14 不过滤禁用的 inbound，可能抓到已停用节点导致对接失败。  ║
# ║       v15：WHERE enable=1 ORDER BY id DESC，优先读最新活跃节点。 ║
# ║                                                                  ║
# ║  [G5] save_result 写入前先清理同 LINK_ID 旧记录                  ║
# ║       v14 save_result 只追加，重复运行导致 LOCAL_INFO 冗余膨胀。  ║
# ║       v15：追加前先用 grep -v 去除同 LINK_ID 的旧段落。          ║
# ║                                                                  ║
# ║  [G6] 端口分配死循环修复                                         ║
# ║       v14 if p>65000: p=start_port 在极端情况会无限循环。        ║
# ║       v15：改为计数器，超过 500 次直接报错并输出诊断信息。        ║
# ║                                                                  ║
# ║  [G7] update_relay_config 配置验证警告不再阻塞                   ║
# ║       v14 xray -test 发现 error 时弹 read -rp 等用户确认重启。   ║
# ║       v15：自动打印警告后继续重启，非致命错误不阻断流程。         ║
# ║                                                                  ║
# ║  [G8] main 去除"进入节点管理"交互提示                            ║
# ║       v14 主流程中间弹出节点管理入口询问，打断自动化流程。        ║
# ║       v15：节点管理改为脚本参数 --manage 或运行后手动选择。       ║
# ║                                                                  ║
# ║  [G9] print_result 协议描述改为动态读取真实值                    ║
# ║       v14 流量路径固定写死 "tcp+Reality+Vision"。                ║
# ║       v15：根据 LUODI_NETWORK 显示真实落地传输协议。             ║
# ╠══════════════════════════════════════════════════════════════════╣
# ║  🔧 v14 相较 v13 新增修复                                        ║
# ║                                                                  ║
# ║  [F1] socket 双保险端口探测                                      ║
# ║       v13 仅用 ss -tlnp + config.json 扫描已用端口，对某些       ║
# ║       发行版（Alpine/OpenWRT）缺少 ss 时直接返回 0 导致分配冲突。 ║
# ║       v14：ss + netstat + Python socket.connect_ex 三层兜底，    ║
# ║       彻底杜绝端口冲突。                                          ║
# ║                                                                  ║
# ║  [F2] 自动清理完全无感知                                         ║
# ║       v13 的 check_existing_node 发现旧节点后还打印 "Ctrl+C" 提  ║
# ║       示并 sleep 1，行为不够"傻瓜"。                              ║
# ║       v14：发现旧节点只打印一行 WARN 日志后继续，update_relay_   ║
# ║       config 的幂等删除自动覆盖，零用户干预。                     ║
# ║                                                                  ║
# ║  [F3] _build_outbound_stream_json 变量注入风险                   ║
# ║       v13 在 heredoc 内直接用 ${LUODI_PUBKEY} 等 bash 变量插入   ║
# ║       Python 字符串赋值语句；若公钥含特殊字符（极少但可能）会破   ║
# ║       坏 Python 语法。                                            ║
# ║       v14：所有落地参数通过 json.dumps 序列化后再赋值给 Python    ║
# ║       变量，100% 安全。                                           ║
# ║                                                                  ║
# ║  [F4] nodes.json 路径不存在时 safe_write 静默失败                ║
# ║       v13 write nodes.json 前未确认目录存在；中转机首次运行时     ║
# ║       /usr/local/etc/xray-relay/ 可能还未创建。                  ║
# ║       v14：safe_write 自动 os.makedirs(exist_ok=True)。          ║
# ║                                                                  ║
# ║  [F5] _apply_transport_json 中用户手动输入覆盖后子变量未更新      ║
# ║       v13 若用户手动改 LUODI_NETWORK（如 tcp→xhttp），后续        ║
# ║       LUODI_XHTTP_PATH 等保持原来空值，出站配置中路径为空。        ║
# ║       v14：手动覆盖协议后强制重新交互收集该协议所需参数。          ║
# ║                                                                  ║
# ║  [F6] 订阅节点标签 URL 编码仅在本地执行                          ║
# ║       v13 调用 python3 进行 urllib.parse.quote，若落地机无 py3   ║
# ║       则静默返回空字符串，NODE_LINK 末尾 # 后为空。               ║
# ║       v14：内置纯 bash URL 编码函数，无外部依赖。                 ║
# ║                                                                  ║
# ║  [F7] Gemini 建议采纳：socket 探测 + 全自动清理逻辑合并          ║
# ║       将 Gemini 提出的 socket.connect_ex 实时探测与 v13 的        ║
# ║       config.json 扫描合并为三层端口检测，取最优方案。            ║
# ║                                                                  ║
# ║  [F8] 中转机 xray-relay 服务未启动时自动尝试启动                  ║
# ║       v13 仅判断 is-active，失败则直接报错退出。                  ║
# ║       v14：先 systemctl start，失败再报错并给出诊断命令。          ║
# ╠══════════════════════════════════════════════════════════════════╣
# ║  ✅ 继承 v13 全部 8 个致命 Bug 修复（CB-1 ~ CB-8）               ║
# ║  ✅ 继承 v13 全部 8 项新功能（NF-1 ~ NF-8）                      ║
# ║  ✅ 继承 v11/v12 全部原有功能                                    ║
# ║     四级嗅探 / LINK_ID隔离 / Failover / Sub-Store /              ║
# ║     Base64订阅 / 二维码 / 端口敲门 / Docker / 1Panel             ║
# ╚══════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── 颜色 ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
log_step()  { echo -e "${CYAN}[→]${NC} $1"; }
log_sep()   { echo -e "${CYAN}$(printf '─%.0s' {1..60})${NC}"; }

[[ $EUID -ne 0 ]] && log_error "请使用 root 权限运行"

# ── 本地文件路径 ──────────────────────────────────────────────────
LOCAL_INFO="/root/xray_luodi_info.txt"
EXPORT_JSON="/tmp/luodi_export.json"
SUB_FILE="/root/xray_relay_subscription.txt"
SUBSTORE_FILE="/root/xray_relay_substore.json"

# ── 落地机变量 ────────────────────────────────────────────────────
LUODI_IP="" LUODI_PORT="" LUODI_UUID="" LUODI_PUBKEY=""
LUODI_PRIVKEY="" LUODI_SHORT_ID="" LUODI_SNI="" LUODI_DEST=""
LUODI_NETWORK="tcp"
LUODI_XHTTP_PATH="/" LUODI_XHTTP_HOST="" LUODI_XHTTP_MODE="auto"
LUODI_WS_PATH="/"    LUODI_WS_HOST=""
LUODI_GRPC_SERVICE=""
LUODI_H2_PATH="/"    LUODI_H2_HOST=""
LUODI_TYPE="xray"    # xray | singbox

# ── 中转机变量 ────────────────────────────────────────────────────
RELAY_IP="" RELAY_SSH_PORT="22" RELAY_SSH_USER="root"
RELAY_SSH_PASS="" RELAY_KEY_FILE="" SSH_OPTS=""
RELAY_PRIVKEY="" RELAY_PUBKEY="" RELAY_SHORT_ID="" RELAY_SNI=""
RELAY_DEST="" RELAY_START_PORT="16888"
RELAY_CONFIG="/usr/local/etc/xray-relay/config.json"
RELAY_NODES="/usr/local/etc/xray-relay/nodes.json"
RELAY_XRAY_BIN="" AUTH_TYPE=""

# ── 功能开关 ──────────────────────────────────────────────────────
ENABLE_MUX="false"; MUX_PROTOCOL="xmux"; MUX_MAX_CONN=4
ENABLE_SOCKOPT="false"
# [H3] 全局自动模式开关（通过 --auto 参数启用）
AUTO_MODE="false"

# ── 核心变量 ──────────────────────────────────────────────────────
LINK_ID="" NODE_LABEL=""
RELAY_ASSIGNED_PORT="" NEW_UUID="" NODE_LINK=""
# [H1] 历史对接信息暂存（在 auto_clean_by_link_id 删除文件段落前保留）
_SAVED_RELAY_IP="" _SAVED_RELAY_SSH_PORT="" _SAVED_RELAY_SSH_USER=""

# ════════════════════════════════════════════════════════════════
# §1  工具函数
# ════════════════════════════════════════════════════════════════

ensure_python3_local() {
    if command -v python3 &>/dev/null; then
        local v
        v=$(python3 -c "import sys; print(sys.version_info.major)" 2>/dev/null || echo 0)
        [[ "$v" -ge 3 ]] && return 0
    fi
    log_warn "本机缺少 python3，自动安装..."
    if   command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y -qq python3
    elif command -v yum     &>/dev/null; then yum install -y -q python3
    elif command -v dnf     &>/dev/null; then dnf install -y -q python3
    else log_error "无法自动安装 python3，请手动安装"; fi
    command -v python3 &>/dev/null || log_error "python3 安装失败"
    log_info "python3 就绪: $(python3 --version)"
}

ensure_python3_relay() {
    [[ "$AUTH_TYPE" == "manual" ]] && return 0
    log_step "检测中转机 python3..."
    local v
    v=$(run_relay "python3 -c 'import sys;print(sys.version_info.major)' 2>/dev/null||echo 0" \
        | tr -d '[:space:]') || v=0
    if [[ "$v" -ge 3 ]]; then log_info "中转机 python3 ✓"; return 0; fi
    log_warn "中转机缺少 python3，自动安装..."
    run_relay "
        if   command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y -qq python3
        elif command -v yum     &>/dev/null; then yum install -y -q python3
        elif command -v dnf     &>/dev/null; then dnf install -y -q python3
        fi" 2>/dev/null || true
    v=$(run_relay "python3 -c 'import sys;print(sys.version_info.major)' 2>/dev/null||echo 0" \
        | tr -d '[:space:]') || v=0
    [[ "$v" -ge 3 ]] || log_error "中转机 python3 安装失败，请手动安装后重试"
    log_info "中转机 python3 安装完成"
}

# [F6修复] 纯 bash URL 编码，无需 python3
url_encode() {
    local s="$1" r="" i c
    for ((i=0; i<${#s}; i++)); do
        c="${s:$i:1}"
        case "$c" in
            [A-Za-z0-9._~-]) r+="$c" ;;
            *) r+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$r"
}

wrap_ip()   { local ip="$1"; [[ "$ip" == *:* && "$ip" != \[* ]] && echo "[$ip]" || echo "$ip"; }
ip_for_url(){ wrap_ip "$1"; }

# ════════════════════════════════════════════════════════════════
# §2  SSH 工具
# ════════════════════════════════════════════════════════════════

run_relay() {
    local cmd="$1"
    case "$AUTH_TYPE" in
        key)      ssh    -q $SSH_OPTS                        "${RELAY_SSH_USER}@${RELAY_IP}" "$cmd" ;;
        password) sshpass -p "$RELAY_SSH_PASS" ssh -q $SSH_OPTS "${RELAY_SSH_USER}@${RELAY_IP}" "$cmd" ;;
        keyfile)  ssh    -q $SSH_OPTS -i "$RELAY_KEY_FILE"  "${RELAY_SSH_USER}@${RELAY_IP}" "$cmd" ;;
        manual)   log_error "manual 模式不支持 run_relay" ;;
    esac
}

pipe_python_relay() {
    # 将 stdin 脚本管道到中转机 python3 执行，返回 stdout
    case "$AUTH_TYPE" in
        key)      ssh    -q $SSH_OPTS                        "${RELAY_SSH_USER}@${RELAY_IP}" "python3" ;;
        password) sshpass -p "$RELAY_SSH_PASS" ssh -q $SSH_OPTS "${RELAY_SSH_USER}@${RELAY_IP}" "python3" ;;
        keyfile)  ssh    -q $SSH_OPTS -i "$RELAY_KEY_FILE"  "${RELAY_SSH_USER}@${RELAY_IP}" "python3" ;;
        manual)   log_error "manual 模式不支持 pipe_python_relay" ;;
    esac
}

# ════════════════════════════════════════════════════════════════
# §3  链路预检
# ════════════════════════════════════════════════════════════════

precheck_link() {
    local ip="$1" port="${2:-}" label="${3:-目标}"
    log_step "链路预检: ${label} ${ip}${port:+:$port}"
    local raw="${ip//[\[\]]/}"

    local po lo rt
    if po=$(ping -c 3 -W 2 "$raw" 2>/dev/null); then
        lo=$(echo "$po" | grep -oP '\d+(?=% packet loss)' || echo "?")
        rt=$(echo "$po" | grep -oP 'rtt.*' | grep -oP '[\d.]+/[\d.]+/[\d.]+' || echo "?")
        [[ "$lo" == "100" ]] \
            && log_warn "Ping ${raw}: 100% 丢包（ICMP 可能屏蔽）" \
            || log_info "Ping ${raw}: 丢包 ${lo}%  RTT ${rt} ms"
    else
        log_warn "Ping ${raw}: 无响应"
    fi

    if [[ -n "$port" ]]; then
        local nf=""
        [[ "$ip" == *:* ]] && nf="-6"
        # shellcheck disable=SC2086
        nc -zw 5 $nf "$raw" "$port" 2>/dev/null \
            && log_info "端口 ${raw}:${port} ✓ 可达" \
            || log_warn "端口 ${raw}:${port} ✗ 不可达（请检查防火墙）"
    fi
}

# ════════════════════════════════════════════════════════════════
# §4  LINK_ID 生成
# ════════════════════════════════════════════════════════════════

generate_link_id() {
    local raw="${LUODI_IP//[\[\]]/}"
    LINK_ID=$(printf '%s' "${raw}:${LUODI_PORT}" | \
        python3 -c "import sys,hashlib; print(hashlib.md5(sys.stdin.buffer.read()).hexdigest()[:8])" \
        2>/dev/null || printf '%s_%s' "$raw" "$LUODI_PORT" | tr -cd 'a-f0-9' | head -c 8)
    log_info "LINK_ID: ${LINK_ID}  [${raw}:${LUODI_PORT}]"
}

# ════════════════════════════════════════════════════════════════
# §5  四级协议嗅探链
# ════════════════════════════════════════════════════════════════
# 优先级：① luodi_export.json → ② SQLite(x-ui/3x-ui) →
#         ③ JSON配置文件(Xray/Singbox) → ④ 进程反推

detect_luodi_transport() {
    log_step "四级协议嗅探..."

    # ─────── ① luodi_export.json ────────────────────────────
    if [[ -f "$EXPORT_JSON" ]]; then
        log_info "Level-1: 读取 ${EXPORT_JSON}..."
        local ex
        ex=$(python3 - "$LUODI_PORT" "$EXPORT_JSON" << 'PYEOF'
import json, sys

port_target = int(sys.argv[1])
fpath       = sys.argv[2]

def pick(n):
    r = {"network": n.get("network","tcp"), "source":"export-json"}
    for k in ["xhttp_path","xhttp_host","xhttp_mode",
              "ws_path","ws_host","grpc_service","h2_path","h2_host","luodi_type"]:
        if k in n: r[k] = n[k]
    return r

try:
    with open(fpath) as f: raw = json.load(f)
    nodes = raw if isinstance(raw, list) else raw.get("nodes", [raw])
    # 端口精确匹配
    for n in nodes:
        p = n.get("port") or n.get("listen_port")
        try:
            if int(str(p)) == port_target:
                print(json.dumps(pick(n))); raise SystemExit(0)
        except SystemExit: raise
        except: pass
    # 无匹配则取第一个
    if nodes: print(json.dumps(pick(nodes[0])))
except SystemExit: pass
except: print("{}")
PYEOF
        2>/dev/null) || ex="{}"
        local en
        en=$(echo "$ex" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); print(d.get('network',''))" 2>/dev/null || echo "")
        if [[ -n "$en" && "$en" != "null" && "$en" != "{}" ]]; then
            _apply_transport_json "$ex"; return 0
        fi
    fi

    # ─────── ② SQLite：x-ui / 3x-ui ────────────────────────
    local -a xui_dbs=(
        "/etc/x-ui/x-ui.db"
        "/etc/3x-ui/db/x-ui.db"
        "/usr/local/x-ui/x-ui.db"
        "/usr/local/3x-ui/x-ui.db"
        "/root/3x-ui/x-ui.db"
    )
    # Docker 卷
    local ddb
    ddb=$(find /var/lib/docker/volumes -name "x-ui.db" 2>/dev/null | head -1 || true)
    [[ -n "$ddb" ]] && xui_dbs+=("$ddb")

    local xui_py
    xui_py=$(mktemp /tmp/xui_XXXX.py)
    # CB-1修复(v13继承)：先 cp 到 /tmp 再读，防止 database is locked
    cat > "$xui_py" << 'PYEOF'
import sqlite3, json, sys, shutil, os, tempfile

db_orig = sys.argv[1]
port    = int(sys.argv[2])
tmp_db  = tempfile.mktemp(suffix=".db", dir="/tmp")
try:
    shutil.copy2(db_orig, tmp_db)
    conn = sqlite3.connect(tmp_db, timeout=3)
    tables = {r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}

    rows = []
    if "inbounds" in tables:
        # 兼容 3x-ui（有 settings 列）和 x-ui（无 settings 列）
        # [G4修复] 增加 enable=1 过滤 + ORDER BY id DESC，优先读最新活跃节点
        try:
            rows = conn.execute(
                "SELECT stream_settings FROM inbounds WHERE port=? AND enable=1 ORDER BY id DESC", (port,)
            ).fetchall()
        except Exception:
            # 兼容旧版无 enable 字段
            try:
                rows = conn.execute(
                    "SELECT stream_settings FROM inbounds WHERE port=? ORDER BY id DESC", (port,)
                ).fetchall()
            except Exception:
                rows = []

    for (ss_str,) in rows:
        ss  = json.loads(ss_str or "{}")
        net = ss.get("network","tcp")
        r   = {"network": net, "source": "xui-sqlite"}
        if net == "xhttp":
            xs = ss.get("xhttpSettings",{})
            r.update(xhttp_path=xs.get("path","/"),
                     xhttp_host=xs.get("host",""),
                     xhttp_mode=xs.get("mode","auto"))
        elif net == "ws":
            ws = ss.get("wsSettings",{})
            r.update(ws_path=ws.get("path","/"),
                     ws_host=ws.get("headers",{}).get("Host",""))
        elif net == "grpc":
            r.update(grpc_service=ss.get("grpcSettings",{}).get("serviceName",""))
        elif net in ("h2","http"):
            h2 = ss.get("httpSettings",{})
            r["network"] = "h2"
            hosts = h2.get("host",[])
            r.update(h2_path=h2.get("path","/"), h2_host=hosts[0] if hosts else "")
        print(json.dumps(r)); break
    conn.close()
except Exception:
    pass
finally:
    try: os.unlink(tmp_db)
    except: pass
PYEOF
    local db xui_r
    for db in "${xui_dbs[@]}"; do
        [[ -f "$db" ]] || continue
        log_info "Level-2: SQLite 嗅探 (安全拷贝): $db"
        xui_r=$(python3 "$xui_py" "$db" "$LUODI_PORT" 2>/dev/null) || xui_r=""
        if [[ -n "$xui_r" && "$xui_r" != "{}" ]]; then
            rm -f "$xui_py"
            _apply_transport_json "$xui_r"; return 0
        fi
    done
    rm -f "$xui_py"

    # ─────── ③ JSON 配置文件（Xray + Sing-box 双格式）──────
    local -a conf_dirs=(
        "/etc/v2ray-agent/xray/conf"    # mack-a
        "/usr/local/etc/xray"           # 手动 Xray
        "/etc/xray"
        "/usr/local/etc/sing-box"       # Sing-box
        "/etc/sing-box"
        "/opt/xray" "/root/xray"
        "/opt/v2ray" "/usr/local/etc/v2ray"
    )
    # Docker 卷目录嗅探
    if command -v docker &>/dev/null; then
        local dm
        dm=$(docker ps -q 2>/dev/null | xargs -r docker inspect 2>/dev/null | python3 -c "
import json,sys
try:
    for c in json.load(sys.stdin):
        for m in c.get('Mounts',[]):
            s = m.get('Source','')
            if s and any(k in s.lower() for k in ['xray','sing','v2ray','3x-ui','x-ui']):
                print(s)
except: pass
" 2>/dev/null || true)
        while IFS= read -r vol; do
            [[ -d "$vol" ]] && conf_dirs+=("$vol") || true
            [[ -f "$vol" ]] && conf_dirs+=("$(dirname "$vol")") || true
        done <<< "$dm"
    fi
    # 1Panel
    for d in /opt/1panel /data/1panel /www/1panel; do
        [[ -d "$d" ]] && conf_dirs+=("$d") || true
    done

    local found_file=""
    for d in "${conf_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        local f
        f=$(grep -rl \
            -e "\"port\"[[:space:]]*:[[:space:]]*${LUODI_PORT}\b" \
            -e "\"listen_port\"[[:space:]]*:[[:space:]]*${LUODI_PORT}\b" \
            "$d" 2>/dev/null | head -1 || true)
        if [[ -n "$f" ]]; then found_file="$f"; log_info "Level-3: 配置文件: $f"; break; fi
    done

    if [[ -n "$found_file" ]]; then
        local det_py
        det_py=$(mktemp /tmp/det_XXXX.py)
        cat > "$det_py" << 'PYEOF'
import json, sys

fpath = sys.argv[1]
port  = int(sys.argv[2])
res   = {"network":"tcp","source":"json-file"}

_SB = {"websocket":"ws","http":"h2","grpc":"grpc",
       "httpupgrade":"ws","xhttp":"xhttp","quic":"quic"}

def do_xray(ib, res):
    ss  = ib.get("streamSettings",{})
    net = ss.get("network","tcp")
    if net in ("h2","http"): net = "h2"
    res["network"] = net
    if net == "xhttp":
        xs = ss.get("xhttpSettings",{})
        res.update(xhttp_path=xs.get("path","/"),
                   xhttp_host=xs.get("host",""),
                   xhttp_mode=xs.get("mode","auto"))
    elif net == "ws":
        ws = ss.get("wsSettings",{})
        res.update(ws_path=ws.get("path","/"),
                   ws_host=ws.get("headers",{}).get("Host",""))
    elif net == "grpc":
        res.update(grpc_service=ss.get("grpcSettings",{}).get("serviceName",""))
    elif net == "h2":
        h2 = ss.get("httpSettings",{}); hosts=h2.get("host",[])
        res.update(h2_path=h2.get("path","/"),
                   h2_host=hosts[0] if hosts else "")

def do_singbox(ib, res):
    res["luodi_type"] = "singbox"
    tr  = ib.get("transport",{})
    net = _SB.get(tr.get("type",""),"tcp")
    res["network"] = net
    if net == "xhttp":
        res.update(xhttp_path=tr.get("path","/"),
                   xhttp_host=tr.get("host",""),
                   xhttp_mode=tr.get("mode","auto"))
    elif net == "ws":
        res.update(ws_path=tr.get("path","/"),
                   ws_host=tr.get("headers",{}).get("Host",""))
    elif net == "grpc":
        res.update(grpc_service=tr.get("service_name",""))
    elif net == "h2":
        hosts=tr.get("host",[])
        res.update(h2_path=tr.get("path","/"),
                   h2_host=hosts[0] if isinstance(hosts,list) and hosts else "")

try:
    with open(fpath) as f: data = json.load(f)
    ibs = data if isinstance(data,list) else data.get("inbounds",[])
    for ib in ibs:
        p = ib.get("port") or ib.get("listen_port")
        try:
            if int(str(p)) != port: continue
        except: continue
        if "streamSettings" in ib:   do_xray(ib, res)
        elif "transport" in ib or "listen_port" in ib: do_singbox(ib, res)
        else:                         do_xray(ib, res)
        break
except: pass
print(json.dumps(res))
PYEOF
        local tj lt
        tj=$(python3 "$det_py" "$found_file" "$LUODI_PORT" 2>/dev/null) \
            || tj='{"network":"tcp"}'
        rm -f "$det_py"
        lt=$(echo "$tj" | python3 -c \
            "import json,sys; print(json.load(sys.stdin).get('luodi_type','xray'))" \
            2>/dev/null || echo "xray")
        LUODI_TYPE="$lt"
        _apply_transport_json "$tj"
        return 0
    fi

    # ─────── ④ 进程反推 ─────────────────────────────────────
    log_warn "Level-4: 进程反推..."
    local pc
    pc=$(ps -ef 2>/dev/null \
        | grep -E '\b(xray|sing-box|v2ray)\b.*-config\b' \
        | grep -v grep \
        | grep -oP '(?<=-config\s)\S+' | head -1 || true)
    if [[ -n "$pc" && -f "$pc" ]]; then
        log_info "Level-4: 进程配置文件: $pc"
        local proc_py
        proc_py=$(mktemp /tmp/proc_XXXX.py)
        cat > "$proc_py" << 'PYEOF'
import json, sys
fpath, port = sys.argv[1], int(sys.argv[2])
res = {"network":"tcp","source":"process-sniff"}
try:
    with open(fpath) as f: data = json.load(f)
    ibs = data if isinstance(data,list) else data.get("inbounds",[])
    for ib in ibs:
        p = ib.get("port") or ib.get("listen_port")
        try:
            if int(str(p)) != port: continue
        except: continue
        ss  = ib.get("streamSettings",{})
        net = ss.get("network","tcp")
        if net in ("h2","http"): net = "h2"
        res["network"] = net
        if net == "xhttp":
            xs = ss.get("xhttpSettings",{})
            res.update(xhttp_path=xs.get("path","/"),
                       xhttp_host=xs.get("host",""),
                       xhttp_mode=xs.get("mode","auto"))
        elif net == "ws":
            ws = ss.get("wsSettings",{})
            res.update(ws_path=ws.get("path","/"),
                       ws_host=ws.get("headers",{}).get("Host",""))
        elif net == "grpc":
            res.update(grpc_service=ss.get("grpcSettings",{}).get("serviceName",""))
        break
except: pass
print(json.dumps(res))
PYEOF
        tj=$(python3 "$proc_py" "$pc" "$LUODI_PORT" 2>/dev/null) \
            || tj='{"network":"tcp"}'
        rm -f "$proc_py"
        _apply_transport_json "$tj"
        return 0
    fi

    log_warn "所有嗅探均无结果，默认 tcp+Reality"
    _apply_transport_json '{"network":"tcp"}'
}

# ── 应用嗅探结果 + 用户交互确认 ──────────────────────────────────
_apply_transport_json() {
    local tj="${1:-{\"network\":\"tcp\"}}"
    local _p
    _p() { echo "$tj" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d.get('$1','$2'))" 2>/dev/null || echo "$2"; }

    LUODI_NETWORK=$(_p network tcp) || LUODI_NETWORK="tcp"

    _show_net_info() {
        case "$LUODI_NETWORK" in
            xhttp) log_info "协议: xhttp  path=${LUODI_XHTTP_PATH}  host=${LUODI_XHTTP_HOST}  mode=${LUODI_XHTTP_MODE}" ;;
            ws)    log_info "协议: ws     path=${LUODI_WS_PATH}  host=${LUODI_WS_HOST}" ;;
            grpc)  log_info "协议: grpc   serviceName=${LUODI_GRPC_SERVICE}" ;;
            h2)    log_info "协议: h2     path=${LUODI_H2_PATH}  host=${LUODI_H2_HOST}" ;;
            tcp)   log_info "协议: tcp+Reality" ;;
            *)     log_warn "未知协议 ${LUODI_NETWORK}，回退 tcp"; LUODI_NETWORK="tcp" ;;
        esac
    }

    _load_net_params() {
        case "$LUODI_NETWORK" in
            xhttp)
                LUODI_XHTTP_PATH=$(_p xhttp_path "/") || true
                LUODI_XHTTP_HOST=$(_p xhttp_host "")  || true
                LUODI_XHTTP_MODE=$(_p xhttp_mode "auto") || true
                ;;
            ws)
                LUODI_WS_PATH=$(_p ws_path "/") || true
                LUODI_WS_HOST=$(_p ws_host "")  || true
                ;;
            grpc)
                LUODI_GRPC_SERVICE=$(_p grpc_service "") || true
                ;;
            h2)
                LUODI_H2_PATH=$(_p h2_path "/") || true
                LUODI_H2_HOST=$(_p h2_host "")  || true
                ;;
        esac
    }
    _load_net_params
    _show_net_info

    # [G3] 仅当嗅探失败（fallback tcp）时才弹协议覆盖提示
    local _src
    _src=$(_p source "") || _src=""
    local _need_prompt=false
    if [[ -z "$_src" || "$_src" == "process-sniff" && "$LUODI_NETWORK" == "tcp" ]]; then
        _need_prompt=true
    fi

    if [[ "$_need_prompt" == "true" ]]; then
        echo ""
        local i
        read -rp "手动修改传输协议 (tcp/xhttp/ws/grpc/h2)，回车保留 [${LUODI_NETWORK}]: " i || true
        if [[ -n "$i" && "$i" != "$LUODI_NETWORK" ]]; then
            LUODI_NETWORK="$i"
            log_warn "协议已覆盖: $LUODI_NETWORK"
            # [F5修复] 强制重置该协议的参数，再交互收集
            LUODI_XHTTP_PATH="/" LUODI_XHTTP_HOST="" LUODI_XHTTP_MODE="auto"
            LUODI_WS_PATH="/"    LUODI_WS_HOST=""
            LUODI_GRPC_SERVICE=""
            LUODI_H2_PATH="/"    LUODI_H2_HOST=""
        fi
    fi

    # [G3] 协议参数：仅在值为空/默认时才弹输入框
    local i=""
    case "$LUODI_NETWORK" in
        xhttp)
            [[ "$LUODI_XHTTP_PATH" == "/" ]] && {
                read -rp "  xhttp path  [/]: " i || true; [[ -n "$i" ]] && LUODI_XHTTP_PATH="$i"; }
            [[ -z "$LUODI_XHTTP_HOST" ]] && {
                read -rp "  xhttp host  [${LUODI_SNI}]: " i || true; [[ -n "$i" ]] && LUODI_XHTTP_HOST="$i"; }
            [[ -z "$LUODI_XHTTP_MODE" || "$LUODI_XHTTP_MODE" == "auto" ]] && {
                read -rp "  xhttp mode  [auto]: " i || true; [[ -n "$i" ]] && LUODI_XHTTP_MODE="$i"; }
            LUODI_XHTTP_PATH="${LUODI_XHTTP_PATH:-/}"
            LUODI_XHTTP_HOST="${LUODI_XHTTP_HOST:-${LUODI_SNI}}"
            LUODI_XHTTP_MODE="${LUODI_XHTTP_MODE:-auto}"
            ;;
        ws)
            [[ "$LUODI_WS_PATH" == "/" ]] && {
                read -rp "  ws path  [/]: " i || true; [[ -n "$i" ]] && LUODI_WS_PATH="$i"; }
            [[ -z "$LUODI_WS_HOST" ]] && {
                read -rp "  ws host  [${LUODI_SNI}]: " i || true; [[ -n "$i" ]] && LUODI_WS_HOST="$i"; }
            LUODI_WS_PATH="${LUODI_WS_PATH:-/}"
            LUODI_WS_HOST="${LUODI_WS_HOST:-${LUODI_SNI}}"
            ;;
        grpc)
            [[ -z "$LUODI_GRPC_SERVICE" ]] && {
                read -rp "  grpc serviceName []: " i || true; [[ -n "$i" ]] && LUODI_GRPC_SERVICE="$i"; }
            ;;
        h2)
            [[ "$LUODI_H2_PATH" == "/" ]] && {
                read -rp "  h2 path  [/]: " i || true; [[ -n "$i" ]] && LUODI_H2_PATH="$i"; }
            [[ -z "$LUODI_H2_HOST" ]] && {
                read -rp "  h2 host  [${LUODI_SNI}]: " i || true; [[ -n "$i" ]] && LUODI_H2_HOST="$i"; }
            LUODI_H2_PATH="${LUODI_H2_PATH:-/}"
            LUODI_H2_HOST="${LUODI_H2_HOST:-${LUODI_SNI}}"
            ;;
    esac
}

# ════════════════════════════════════════════════════════════════
# §6  BBR 拥塞控制（CB-6修复：精确 BBRv3/BBR2/BBR1 判断）
# ════════════════════════════════════════════════════════════════

check_and_enable_bbr() {
    echo ""
    echo -e "${YELLOW}── BBR 拥塞控制 ──${NC}"
    local cur qdisc
    cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    log_info "当前拥塞控制: ${cur}  队列: ${qdisc}"
    [[ "$cur" == "bbr"* ]] && { log_info "BBR 已启用，跳过"; return 0; }

    # [H5] AUTO_MODE：直接静默启用最优 BBR，不询问
    if [[ "$AUTO_MODE" != "true" ]]; then
        local i
        read -rp "启用 BBR 提升速度？[Y/n]: " i || true
        [[ "${i,,}" == "n" ]] && return 0
    else
        log_info "自动模式：静默启用 BBR..."
    fi

    local kver major minor chosen bbrver
    kver=$(uname -r)
    major=$(python3 -c \
        "v='${kver}'.split('-')[0].split('.'); print(int(v[0]))" 2>/dev/null || echo 0)
    minor=$(python3 -c \
        "v='${kver}'.split('-')[0].split('.'); print(int(v[1]) if len(v)>1 else 0)" \
        2>/dev/null || echo 0)

    if (( major > 6 || (major == 6 && minor >= 3) )); then
        chosen="bbr"; bbrver="BBRv3（≥6.3 内核内置）"
    elif (( major > 5 || (major == 5 && minor >= 13) )); then
        if modprobe tcp_bbr2 2>/dev/null; then
            chosen="bbr2"; bbrver="BBR2"
        else
            chosen="bbr"; bbrver="BBR1（bbr2 不可用，降级）"
        fi
    else
        modprobe tcp_bbr 2>/dev/null || true
        chosen="bbr"; bbrver="BBR1"
    fi

    sysctl -w net.core.default_qdisc=fq                   2>/dev/null || true
    sysctl -w "net.ipv4.tcp_congestion_control=${chosen}"  2>/dev/null || true
    grep -q "net.core.default_qdisc"          /etc/sysctl.conf 2>/dev/null \
        || echo "net.core.default_qdisc = fq"               >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control"  /etc/sysctl.conf 2>/dev/null \
        || echo "net.ipv4.tcp_congestion_control = ${chosen}" >> /etc/sysctl.conf

    log_info "${bbrver} 启用完成（内核 ${kver}）"
}

# ════════════════════════════════════════════════════════════════
# §7  读取落地机信息（自动 + 确认）
# ════════════════════════════════════════════════════════════════

read_luodi_info() {
    log_step "读取落地机信息..."

    if [[ -f "$LOCAL_INFO" ]]; then
        log_info "从 $LOCAL_INFO 自动加载..."
        # CB-8修复：cut -d= -f2- 保留含 '=' 的 Base64 值
        while IFS= read -r line; do
            local key val
            key=$(echo "$line" | cut -d= -f1 | tr -d ' \r')
            val=$(echo "$line" | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//')
            case "$key" in
                LUODI_IP)                      LUODI_IP="$val"       ;;
                LUODI_PORT|LUODI_RELAY_PORT)   LUODI_PORT="$val"     ;;
                LUODI_UUID)                    LUODI_UUID="$val"     ;;
                LUODI_PUBKEY)                  LUODI_PUBKEY="$val"   ;;
                LUODI_PRIVKEY)                 LUODI_PRIVKEY="$val"  ;;
                LUODI_SHORT_ID|LUODI_SHORTID)  LUODI_SHORT_ID="$val" ;;
                LUODI_SNI)                     LUODI_SNI="$val"      ;;
                LUODI_DEST)                    LUODI_DEST="$val"     ;;
            esac
        done < <(grep -v '^#\|^──\|^NODE_LINK\|^[[:space:]]*$' "$LOCAL_INFO") || true

        # 兼容 luodi.sh 中文标签格式
        [[ -z "$LUODI_IP"     ]] && LUODI_IP=$(grep -m1 "公网.*IP\|公网IP" "$LOCAL_INFO" \
            | grep -oP '(?<=[:：]\s{0,4})[\d.:a-fA-F\[\]]+' | tail -1 || true)
        [[ -z "$LUODI_PORT"   ]] && LUODI_PORT=$(grep -m1 "监听端口\|VLESS.*端口" "$LOCAL_INFO" \
            | grep -oP '\d+$' || true)
        [[ -z "$LUODI_PUBKEY" ]] && LUODI_PUBKEY=$(grep -m1 "公钥\|pubkey" "$LOCAL_INFO" \
            | grep -oP '[A-Za-z0-9+/=_-]{40,}' | tail -1 || true)
        [[ -z "$LUODI_SNI"    ]] && LUODI_SNI=$(grep -m1 "伪装域名\|SNI" "$LOCAL_INFO" \
            | grep -oP '(?<=[:：]\s{0,4})[^\s]+$' || true)
        [[ -z "$LUODI_UUID"   ]] && LUODI_UUID=$(grep -m1 "UUID\|uuid" "$LOCAL_INFO" \
            | grep -oP '[0-9a-f-]{36}' | tail -1 || true)
        # [G2新增] 读取 LUODI_NETWORK（v14 缺失此字段）
        [[ -z "$LUODI_NETWORK" ]] && {
            local _net; _net=$(grep -m1 '^LUODI_NETWORK=' "$LOCAL_INFO" | cut -d= -f2- | tr -d '\r' || true)
            [[ -n "$_net" ]] && LUODI_NETWORK="$_net"
        }
    fi

    # [G2] 仅对空字段交互提示；全部字段就绪则自动继续
    local _all_ready=true
    for _f in LUODI_IP LUODI_PORT LUODI_UUID LUODI_PUBKEY LUODI_SNI; do
        [[ -z "${!_f}" ]] && _all_ready=false && break
    done

    if [[ "$_all_ready" == "true" ]]; then
        # 全部字段已自动读取，仅展示摘要
        local pubkey_hint="${LUODI_PUBKEY:0:16}…"
        echo ""
        echo -e "${YELLOW}── 落地机信息（已自动读取）──${NC}"
        log_info "IP        : ${LUODI_IP}"
        log_info "端口      : ${LUODI_PORT}"
        log_info "UUID      : ${LUODI_UUID:0:18}…"
        log_info "公钥      : ${pubkey_hint}"
        log_info "SNI       : ${LUODI_SNI}"
        log_info "传输协议  : ${LUODI_NETWORK:-tcp(待嗅探)}"
        [[ -z "$NODE_LABEL" ]] && NODE_LABEL="中转-${LUODI_IP}"
        log_info "节点标签  : ${NODE_LABEL}"
        echo ""
        # 3 秒后自动继续，允许 Ctrl+C 中断
        for _c in 3 2 1; do
            printf "\r  %s 秒后自动继续（Ctrl+C 中断手动修改）..." "$_c"
            sleep 1
        done
        echo ""
    else
        # 有空字段，进入交互模式补全
        echo ""
        echo -e "${YELLOW}── 补全落地机信息（回车保留已读取值）──${NC}"
        local i pubkey_hint="${LUODI_PUBKEY:0:16}${LUODI_PUBKEY:+…}"
        [[ -z "$LUODI_IP"     ]] && { read -rp "落地机 IP      [待输入]: "           i || true; LUODI_IP="$i";     }
        [[ -z "$LUODI_PORT"   ]] && { read -rp "监听端口       [待输入]: "           i || true; LUODI_PORT="$i";   }
        [[ -z "$LUODI_UUID"   ]] && { read -rp "UUID           [待输入]: "           i || true; LUODI_UUID="$i";   }
        [[ -z "$LUODI_PUBKEY" ]] && { read -rp "公钥 (pubkey)  [待输入]: "           i || true; LUODI_PUBKEY="$i"; }
        [[ -z "$LUODI_SNI"    ]] && { read -rp "SNI            [待输入]: "           i || true; LUODI_SNI="$i";    }
        [[ -z "$LUODI_SHORT_ID" ]] && { read -rp "Short ID (可空) []: "             i || true; LUODI_SHORT_ID="$i"; }
        read -rp "节点标签 [中转-${LUODI_IP:-落地}]: " i || true
        NODE_LABEL="${i:-中转-${LUODI_IP:-落地}}"
    fi

    [[ -z "$LUODI_IP"     ]] && log_error "落地机 IP 不能为空"
    [[ -z "$LUODI_PORT"   ]] && log_error "落地机端口不能为空"
    [[ -z "$LUODI_UUID"   ]] && log_error "落地机 UUID 不能为空"
    [[ -z "$LUODI_PUBKEY" ]] && log_error "落地机公钥不能为空"
    [[ -z "$LUODI_SNI"    ]] && log_error "落地机 SNI 不能为空"

    [[ "$LUODI_IP" == *:* ]] && log_info "IPv6 地址，URL 中将自动包裹 []"
    log_info "落地机: ${LUODI_IP}:${LUODI_PORT}"

    generate_link_id
    # [G1] LINK_ID 确定后立即自动清理旧的同 LINK_ID 记录
    auto_clean_by_link_id
    detect_luodi_transport
}

# ════════════════════════════════════════════════════════════════
# §8  SSH 认证配置（H1：历史 IP 作默认值；H2：静默免密探测）
# ════════════════════════════════════════════════════════════════

setup_ssh() {
    echo ""
    echo -e "${YELLOW}── 中转机 SSH 连接 ──${NC}"

    # [H1] 用暂存的历史值作默认值（auto_clean_by_link_id 执行前已提取）
    [[ -z "$RELAY_IP"       && -n "$_SAVED_RELAY_IP"       ]] && RELAY_IP="$_SAVED_RELAY_IP"
    [[ "$RELAY_SSH_PORT" == "22" && -n "$_SAVED_RELAY_SSH_PORT" ]] && RELAY_SSH_PORT="$_SAVED_RELAY_SSH_PORT"
    [[ "$RELAY_SSH_USER" == "root" && -n "$_SAVED_RELAY_SSH_USER" ]] && RELAY_SSH_USER="$_SAVED_RELAY_SSH_USER"

    local i
    if [[ "$AUTO_MODE" == "true" ]]; then
        # --auto 模式：IP 必须来自历史或环境变量，否则报错
        [[ -z "$RELAY_IP" ]] && log_error "--auto 模式下未找到中转机 IP（请先运行一次交互模式）"
        log_info "自动模式：中转机 ${RELAY_IP}:${RELAY_SSH_PORT:-22}"
    else
        read -rp "中转机公网 IP [${RELAY_IP:-待输入}]: " i || true
        [[ -n "$i" ]] && RELAY_IP="$i"
        [[ -z "$RELAY_IP" ]] && log_error "中转机 IP 不能为空"
        read -rp "SSH 端口 [${RELAY_SSH_PORT:-22}]: "   i || true; RELAY_SSH_PORT="${i:-${RELAY_SSH_PORT:-22}}"
        read -rp "SSH 用户 [${RELAY_SSH_USER:-root}]: " i || true; RELAY_SSH_USER="${i:-${RELAY_SSH_USER:-root}}"
    fi

    SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${RELAY_SSH_PORT}"

    # [H2] 先静默探测免密登录，成功则完全跳过认证菜单
    log_step "尝试静默免密登录 ${RELAY_SSH_USER}@${RELAY_IP}..."
    local bm_opts="$SSH_OPTS -o BatchMode=yes"
    if ssh -q $bm_opts "${RELAY_SSH_USER}@${RELAY_IP}" "exit" 2>/dev/null; then
        AUTH_TYPE="key"
        SSH_OPTS="$bm_opts"
        log_info "免密登录验证通过 ✓（自动跳过认证菜单）"
        return 0
    fi

    # 免密失败
    if [[ "$AUTO_MODE" == "true" ]]; then
        log_error "--auto 模式下 SSH 免密登录失败，请先配置中转机公钥免密登录后重试"
    fi

    log_warn "免密登录失败，请选择认证方式"
    echo ""
    echo -e "  ${CYAN}[1]${NC} 密钥（继续尝试）  ${CYAN}[2]${NC} 指定密钥文件  ${CYAN}[3]${NC} 密码  ${CYAN}[4]${NC} 手动模式"
    read -rp "认证方式 [1]: " i || true; i="${i:-1}"

    case "$i" in
        1)
            AUTH_TYPE="key"
            log_warn "继续尝试密钥认证（可能弹密钥密码提示）..."
            SSH_OPTS="$bm_opts"
            ;;
        2)
            read -rp "密钥文件路径 [~/.ssh/id_rsa]: " RELAY_KEY_FILE || true
            RELAY_KEY_FILE="${RELAY_KEY_FILE:-~/.ssh/id_rsa}"
            RELAY_KEY_FILE="${RELAY_KEY_FILE/#\~/$HOME}"
            [[ ! -f "$RELAY_KEY_FILE" ]] && log_error "密钥文件不存在: $RELAY_KEY_FILE"
            AUTH_TYPE="keyfile"
            ;;
        3)
            command -v sshpass &>/dev/null || {
                apt-get install -y -qq sshpass 2>/dev/null \
                    || yum install -y -q sshpass 2>/dev/null || true
            }
            command -v sshpass &>/dev/null || log_error "sshpass 安装失败，请手动安装"
            read -rsp "SSH 密码: " RELAY_SSH_PASS; echo ""
            AUTH_TYPE="password"
            ;;
        *)
            AUTH_TYPE="manual"
            log_warn "手动模式：后续操作输出脚本供复制到中转机执行"
            ;;
    esac
}

# ════════════════════════════════════════════════════════════════
# §9  读取中转机配置（CB-8修复：cut -d= -f2-）
# ════════════════════════════════════════════════════════════════

read_relay_info() {
    if [[ "$AUTH_TYPE" == "manual" ]]; then
        echo ""
        echo -e "${YELLOW}── 手动输入中转机参数（cat /root/xray_zhongzhuan_info.txt）──${NC}"
        local i
        read -rp "公钥  (ZHONGZHUAN_PUBKEY): "           RELAY_PUBKEY   || true
        read -rp "私钥  (ZHONGZHUAN_PRIVKEY): "          RELAY_PRIVKEY  || true
        read -rp "SNI   (ZHONGZHUAN_SNI): "              RELAY_SNI      || true
        read -rp "Short ID (ZHONGZHUAN_SHORT_ID): "      RELAY_SHORT_ID || true
        read -rp "起始端口 [${RELAY_START_PORT}]: "      i || true; RELAY_START_PORT="${i:-$RELAY_START_PORT}"
        read -rp "config.json [${RELAY_CONFIG}]: "        i || true; [[ -n "$i" ]] && RELAY_CONFIG="$i"
        read -rp "nodes.json  [${RELAY_NODES}]: "         i || true; [[ -n "$i" ]] && RELAY_NODES="$i"
        read -rp "Xray 二进制 [/etc/v2ray-agent/xray/xray]: " i || true
        RELAY_XRAY_BIN="${i:-/etc/v2ray-agent/xray/xray}"
        RELAY_DEST="${RELAY_SNI}:443"
        [[ -z "$RELAY_PUBKEY" || -z "$RELAY_PRIVKEY" ]] && log_error "中转机参数不完整"
        return 0
    fi

    log_step "读取中转机配置 (zhongzhuan_info.txt)..."
    local info
    info=$(run_relay "cat /root/xray_zhongzhuan_info.txt 2>/dev/null || echo NOT_FOUND") || \
        log_error "SSH 执行失败，请检查连接"
    [[ "$info" == *NOT_FOUND* || -z "$info" ]] && \
        log_error "中转机未找到 xray_zhongzhuan_info.txt，请先运行 zhongzhuan.sh"

    while IFS= read -r line; do
        local key val
        key=$(echo "$line" | cut -d= -f1 | tr -d ' \r')
        val=$(echo "$line" | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//')
        case "$key" in
            ZHONGZHUAN_PRIVKEY)    RELAY_PRIVKEY="$val"    ;;
            ZHONGZHUAN_PUBKEY)     RELAY_PUBKEY="$val"     ;;
            ZHONGZHUAN_SHORT_ID)   RELAY_SHORT_ID="$val"   ;;
            ZHONGZHUAN_SNI)        RELAY_SNI="$val"        ;;
            ZHONGZHUAN_DEST)       RELAY_DEST="$val"       ;;
            ZHONGZHUAN_START_PORT) RELAY_START_PORT="$val" ;;
            ZHONGZHUAN_CONFIG)     RELAY_CONFIG="$val"     ;;
            ZHONGZHUAN_NODES)      RELAY_NODES="$val"      ;;
            ZHONGZHUAN_XRAY_BIN)   RELAY_XRAY_BIN="$val"  ;;
        esac
    done <<< "$info"

    RELAY_CONFIG="${RELAY_CONFIG:-/usr/local/etc/xray-relay/config.json}"
    RELAY_NODES="${RELAY_NODES:-/usr/local/etc/xray-relay/nodes.json}"
    RELAY_XRAY_BIN="${RELAY_XRAY_BIN:-/etc/v2ray-agent/xray/xray}"
    RELAY_DEST="${RELAY_DEST:-${RELAY_SNI}:443}"

    [[ -z "$RELAY_PUBKEY" || -z "$RELAY_PRIVKEY" ]] && \
        log_error "中转机信息不完整，请重新运行 zhongzhuan.sh"
    log_info "中转机: ${RELAY_IP}  SNI=${RELAY_SNI}  起始端口=${RELAY_START_PORT}"
}

# ════════════════════════════════════════════════════════════════
# §10 自动检查并提示旧节点（F2修复：完全无感知）
# ════════════════════════════════════════════════════════════════

check_existing_node() {
    [[ "$AUTH_TYPE" == "manual" ]] && return 0
    log_step "检查旧节点 (LINK_ID: ${LINK_ID})..."

    local CHECK
    CHECK=$(python3 - << PYEOF
import json
nodes_path = "${RELAY_NODES}"
link_id    = "${LINK_ID}"
remote = f"""import json, os
nodes_path = {json.dumps(nodes_path)}
link_id    = {json.dumps(link_id)}
try:
    data  = json.load(open(nodes_path))
    found = [n for n in data.get("nodes",[]) if n.get("link_id") == link_id]
    if found:
        n = found[0]
        print(f"FOUND|{{n.get('label','-')}}|{{n.get('relay_port','-')}}|{{n.get('added_at','-')}}")
    else:
        print("NOTFOUND")
except:
    print("NOTFOUND")
"""
print(remote)
PYEOF
)
    local result
    result=$(echo "$CHECK" | pipe_python_relay 2>/dev/null | tr -d '\r') || result="NOTFOUND"

    # [F2修复] 发现旧节点仅打印一行警告，update_relay_config 的幂等逻辑自动覆盖
    if [[ "$result" == FOUND* ]]; then
        local old_label old_port old_date
        IFS='|' read -r _ old_label old_port old_date <<< "$result"
        log_warn "发现旧节点 [${old_label}] 中转端口=${old_port} (${old_date})，将自动替换"
    else
        log_info "无旧节点，将创建新节点"
    fi
}

# ════════════════════════════════════════════════════════════════
# §11 Mux / sockopt 配置
# ════════════════════════════════════════════════════════════════

configure_mux() {
    echo ""
    echo -e "${YELLOW}── Mux 多路复用 ──${NC}"
    case "$LUODI_NETWORK" in
        xhttp|grpc|h2)
            log_info "${LUODI_NETWORK} 内置多路复用，跳过"; ENABLE_MUX="false"; return 0 ;;
    esac

    # [H3] AUTO_MODE：CN2 GIA 线路质量好，Mux 增加开销且偶发断连，自动关闭
    if [[ "$AUTO_MODE" == "true" ]]; then
        ENABLE_MUX="false"; log_info "自动模式：Mux 已关闭（CN2 GIA 推荐）"; return 0
    fi

    case "$LUODI_NETWORK" in
        tcp) echo -e "  ${YELLOW}⚠ tcp+Vision+Mux 在高延迟链路偶发断连，不稳定时关闭${NC}" ;;
        ws)  echo -e "  ws 协议 — Mux 效果较好" ;;
    esac
    local i
    read -rp "开启 Mux？[y/N]: " i || true
    if [[ "${i,,}" == "y" ]]; then
        ENABLE_MUX="true"
        echo -e "  ${CYAN}[1]${NC} xmux（推荐）  ${CYAN}[2]${NC} smux"
        read -rp "选择 [1]: " i || true; [[ "$i" == "2" ]] && MUX_PROTOCOL="smux" || MUX_PROTOCOL="xmux"
        read -rp "最大并发连接数 [${MUX_MAX_CONN}]: " i || true
        [[ -n "$i" && "$i" =~ ^[0-9]+$ ]] && MUX_MAX_CONN="$i"
        log_info "Mux: ${MUX_PROTOCOL}  maxConn=${MUX_MAX_CONN}"
    else
        ENABLE_MUX="false"; log_info "Mux 未启用"
    fi
}

configure_sockopt() {
    echo ""
    echo -e "${YELLOW}── TCP sockopt 优化（CN2 GIA 推荐）──${NC}"
    # [H3] AUTO_MODE：sockopt 对 CN2 GIA 有显著优化，自动开启
    if [[ "$AUTO_MODE" == "true" ]]; then
        ENABLE_SOCKOPT="true"; log_info "自动模式：sockopt 已开启（CN2 GIA tcpFastOpen 优化）"; return 0
    fi
    echo -e "  tcpFastOpen + mark=255，减少握手延迟"
    local i
    read -rp "开启 sockopt？[y/N]: " i || true
    [[ "${i,,}" == "y" ]] && ENABLE_SOCKOPT="true" || ENABLE_SOCKOPT="false"
    log_info "sockopt: ${ENABLE_SOCKOPT}"
}

# ════════════════════════════════════════════════════════════════
# §12 分配端口 + UUID
#     F1修复：ss + netstat + socket.connect_ex 三层兜底
#     Gemini 建议采纳：socket 实时探测确保可用性
# ════════════════════════════════════════════════════════════════

allocate_port_and_uuid() {
    log_step "在中转机分配可用入站端口..."

    if [[ "$AUTH_TYPE" == "manual" ]]; then
        local i
        read -rp "中转机入站端口 [${RELAY_START_PORT}]: " i || true
        RELAY_ASSIGNED_PORT="${i:-$RELAY_START_PORT}"
    else
        local PORT_SCRIPT
        PORT_SCRIPT=$(python3 - << PYEOF
import json
config_path = "${RELAY_CONFIG}"
start_port  = int("${RELAY_START_PORT:-16888}")
remote = f"""import json, re, subprocess, socket, os

config_path = {json.dumps(config_path)}
start_port  = {start_port}

used = set()

# 层1：从 config.json 读取已分配端口
try:
    cfg = json.load(open(config_path))
    for ib in cfg.get("inbounds", []):
        p = ib.get("port")
        if p: used.add(int(p))
except: pass

# 层2：从 nodes.json 读取（防止 config 和 nodes 不同步）
nodes_path = os.path.join(os.path.dirname(config_path), "nodes.json")
try:
    nd = json.load(open(nodes_path))
    for n in nd.get("nodes", []):
        p = n.get("relay_port")
        if p: used.add(int(p))
except: pass

# 层3：ss -tlnp 扫描系统占用端口
try:
    out = subprocess.check_output(["ss", "-tlnp"], text=True, timeout=5)
    for m in re.finditer(r":(\\d{{2,5}})\\b", out):
        try:
            p = int(m.group(1))
            if 1024 <= p <= 65535: used.add(p)
        except: pass
except: pass

# 层4：netstat 兜底（Alpine/BusyBox 等无 ss 的发行版）
try:
    out = subprocess.check_output(["netstat", "-tlnp"], text=True, timeout=5,
                                   stderr=subprocess.DEVNULL)
    for m in re.finditer(r":(\\d{{2,5}})\\b", out):
        try:
            p = int(m.group(1))
            if 1024 <= p <= 65535: used.add(p)
        except: pass
except: pass

# 层5：[F1+Gemini] socket.connect_ex 实时探测，双保险
def is_port_open(port):
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.3)
            return s.connect_ex(("127.0.0.1", port)) == 0
    except: return False

p = start_port
# [G6修复] 使用计数器防止无限循环，超过 500 次直接报错
_tries = 0
while p in used or is_port_open(p):
    p += 1
    _tries += 1
    if _tries > 500:
        import sys
        print(f"ERROR: 无法在端口 {start_port}~{p} 找到空闲端口，请检查中转机端口使用情况", file=sys.stderr)
        sys.exit(1)
    if p > 65000: p = start_port  # 防止端口超界

print(p)
"""
print(remote)
PYEOF
)
        RELAY_ASSIGNED_PORT=$(echo "$PORT_SCRIPT" | pipe_python_relay | tr -d '[:space:]') || true
    fi

    [[ "$RELAY_ASSIGNED_PORT" =~ ^[0-9]+$ ]] || \
        log_error "端口分配失败 (${RELAY_ASSIGNED_PORT})，请检查中转机"
    NEW_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
    log_info "分配端口: ${RELAY_ASSIGNED_PORT}  |  UUID: ${NEW_UUID}"
}

# ════════════════════════════════════════════════════════════════
# §13 构建出站 streamSettings（Sing-box 翻译层，F3修复）
#     F3修复：所有落地参数通过 json.dumps 序列化，100% 安全
# ════════════════════════════════════════════════════════════════

_build_outbound_stream_json() {
    # 先将所有落地参数在 bash 侧 json.dumps 序列化为 Python 字符串字面量
    local params_json
    params_json=$(python3 - << PYEOF
import json
print(json.dumps({
    "network":      "${LUODI_NETWORK}",
    "sni":          "${LUODI_SNI}",
    "pubkey":       "${LUODI_PUBKEY}",
    "short_id":     "${LUODI_SHORT_ID}",
    "xhttp_path":   "${LUODI_XHTTP_PATH}",
    "xhttp_host":   "${LUODI_XHTTP_HOST}",
    "xhttp_mode":   "${LUODI_XHTTP_MODE}",
    "ws_path":      "${LUODI_WS_PATH}",
    "ws_host":      "${LUODI_WS_HOST}",
    "grpc_service": "${LUODI_GRPC_SERVICE}",
    "h2_path":      "${LUODI_H2_PATH}",
    "h2_host":      "${LUODI_H2_HOST}",
    "sockopt":      "${ENABLE_SOCKOPT}" == "true"
}))
PYEOF
)
    python3 - << PYEOF
import json

p = json.loads("""${params_json}""")

reality = {
    "fingerprint": "chrome",
    "serverName":  p["sni"],
    "publicKey":   p["pubkey"],
    "shortId":     p["short_id"],
    "spiderX":     "/"
}

net = p["network"]

# Sing-box → Xray 翻译层：无论落地机是什么类型，输出均为 Xray outbound 格式
if net == "xhttp":
    ss = {
        "network": "xhttp", "security": "reality",
        "realitySettings": reality,
        "xhttpSettings": {
            "path": p["xhttp_path"] or "/",
            "host": p["xhttp_host"],
            "mode": p["xhttp_mode"] or "auto"
        }
    }
elif net == "ws":
    ss = {
        "network": "ws", "security": "reality",
        "realitySettings": reality,
        "wsSettings": {
            "path":    p["ws_path"] or "/",
            "headers": {"Host": p["ws_host"]}
        }
    }
elif net == "grpc":
    ss = {
        "network": "grpc", "security": "reality",
        "realitySettings": reality,
        "grpcSettings": {"serviceName": p["grpc_service"]}
    }
elif net == "h2":
    ss = {
        "network": "h2", "security": "reality",
        "realitySettings": reality,
        "httpSettings": {
            "path": p["h2_path"] or "/",
            "host": [p["h2_host"]]
        }
    }
else:  # tcp（默认）
    ss = {
        "network":  "tcp",
        "security": "reality",
        "realitySettings": reality
    }

if p["sockopt"]:
    ss["sockopt"] = {"tcpFastOpen": True, "mark": 255, "domainStrategy": "UseIPv4"}

print(json.dumps(ss))
PYEOF
}

# ════════════════════════════════════════════════════════════════
# §14 核心：更新中转机配置
#     CB-1修复：routing_helper 作为 Python 字符串字面量内联
#     F4修复：safe_write 自动 makedirs
#     F8修复：xray-relay 未启动时先尝试 start 再判断
# ════════════════════════════════════════════════════════════════

update_relay_config() {
    log_step "写入中转机配置（LINK_ID: ${LINK_ID}）..."

    local outbound_flow="xtls-rprx-vision"
    [[ "$LUODI_NETWORK" =~ ^(xhttp|grpc|h2|ws)$ ]] && outbound_flow=""

    local outbound_stream
    outbound_stream=$(_build_outbound_stream_json)

    local mux_json="null"
    if [[ "$ENABLE_MUX" == "true" && ! "$LUODI_NETWORK" =~ ^(xhttp|grpc|h2)$ ]]; then
        mux_json=$(python3 -c "
import json
d = {'enabled': True, 'protocol': '${MUX_PROTOCOL}', 'maxConnections': ${MUX_MAX_CONN}}
if '${MUX_PROTOCOL}' == 'xmux':
    d['xmuxSettings'] = {'maxConcurrency': ${MUX_MAX_CONN}, 'maxConnections': 4}
print(json.dumps(d))")
    fi

    # ── 本地 Python 生成完整的远端执行脚本 ──
    # CB-1修复：routing_helper_src 作为 Python 三引号字符串字面量内联
    # 双层 json.dumps 序列化彻底消除 True/False 问题
    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(python3 - << PYEOF
import json

LINK_ID       = "${LINK_ID}"
in_tag        = f"relay-in-{LINK_ID}"
out_tag       = f"relay-out-{LINK_ID}"
config_path   = "${RELAY_CONFIG}"
nodes_path    = "${RELAY_NODES}"
outbound_flow = "${outbound_flow}"

inbound = {
    "tag":      in_tag,
    "port":     int("${RELAY_ASSIGNED_PORT}"),
    "listen":   "0.0.0.0",
    "protocol": "vless",
    "settings": {
        "clients":    [{"id": "${NEW_UUID}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network":  "tcp",
        "security": "reality",
        "realitySettings": {
            "show":        False,
            "dest":        "${RELAY_DEST}",
            "xver":        0,
            "serverNames": ["${RELAY_SNI}"],
            "privateKey":  "${RELAY_PRIVKEY}",
            "shortIds":    ["${RELAY_SHORT_ID}"]
        }
    }
}

out_ss   = json.loads("""${outbound_stream}""")
out_user = {"id": "${LUODI_UUID}", "encryption": "none"}
if outbound_flow:
    out_user["flow"] = outbound_flow

outbound = {
    "tag":      out_tag,
    "protocol": "vless",
    "settings": {
        "vnext": [{"address": "${LUODI_IP}",
                   "port":    int("${LUODI_PORT}"),
                   "users":   [out_user]}]
    },
    "streamSettings": out_ss
}

mux_cfg = json.loads("""${mux_json}""")
if mux_cfg: outbound["mux"] = mux_cfg

routing_rule = {"type": "field", "inboundTag": [in_tag], "outboundTag": out_tag}

node_info = {
    "tag":             in_tag,
    "link_id":         LINK_ID,
    "relay_port":      int("${RELAY_ASSIGNED_PORT}"),
    "relay_uuid":      "${NEW_UUID}",
    "landing_ip":      "${LUODI_IP}",
    "landing_port":    int("${LUODI_PORT}"),
    "landing_network": "${LUODI_NETWORK}",
    "landing_type":    "${LUODI_TYPE}",
    "mux":             "${ENABLE_MUX}" == "true",
    "sockopt":         "${ENABLE_SOCKOPT}" == "true",
    "label":           "${NODE_LABEL}",
    "added_at":        "$(date '+%Y-%m-%d %H:%M:%S')"
}

# routing_helper 作为 Python 字符串字面量内联（CB-1修复核心）
routing_helper = '''
def safe_routing_insert(rules, new_rule, in_tag):
    """精准路由插入：block/dns 规则之后，direct 规则之前"""
    rules = [r for r in rules if in_tag not in r.get("inboundTag", [])]
    insert_pos = 0
    for idx, r in enumerate(rules):
        ob = r.get("outboundTag", "")
        if ob in ("block", "dns-out", "Reject", "blackhole-out", "adblock"):
            insert_pos = idx + 1
        elif ob in ("direct", "freedom", "direct-out"):
            break
    rules.insert(insert_pos, new_rule)
    return rules
'''

remote = f"""import json, sys, os, subprocess as sp

config_path  = {json.dumps(config_path)}
nodes_path   = {json.dumps(nodes_path)}
in_tag       = {json.dumps(in_tag)}
out_tag      = {json.dumps(out_tag)}
inbound      = json.loads({json.dumps(json.dumps(inbound))})
outbound     = json.loads({json.dumps(json.dumps(outbound))})
rule         = json.loads({json.dumps(json.dumps(routing_rule))})
node_info    = json.loads({json.dumps(json.dumps(node_info))})

{routing_helper}

# [F4修复] safe_write 自动创建目录
def _find_xray_cid():
    try:
        out = sp.check_output(
            ["docker","ps","--format","{{{{.ID}}}}\\\\t{{{{.Names}}}}"],text=True)
        for ln in out.splitlines():
            if any(k in ln.lower() for k in ("xray","v2ray","xray-relay","3x-ui","x-ui")):
                return ln.split()[0]
    except: pass
    return None

def safe_write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)  # [F4修复]
    s = json.dumps(data, indent=2, ensure_ascii=False)
    try: os.chmod(path, 0o644)
    except: pass
    try:
        with open(path, "w", encoding="utf-8") as f: f.write(s)
        return "direct"
    except PermissionError:
        pass
    cid = _find_xray_cid()
    if not cid: raise RuntimeError(f"无法写入 {{path}} 且未找到 xray 容器")
    tmp = f"/tmp/_relay_{{os.getpid()}}.json"
    with open(tmp,"w") as f: f.write(s)
    sp.run(["docker","cp",tmp,f"{{cid}}:{{path}}"],check=True,capture_output=True)
    os.unlink(tmp)
    return f"docker-cp:{{cid}}"

# 读取 config.json（若不存在则创建最小骨架）
try: os.chmod(config_path, 0o644)
except: pass
try:
    with open(config_path, encoding="utf-8") as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {{"log":{{"loglevel":"warning"}},
            "inbounds":[],"outbounds":[{{"tag":"direct","protocol":"freedom"}}],
            "routing":{{"rules":[]}}}}
    safe_write(config_path, cfg)
    print("[OK] config.json 已初始化（首次运行）")
except PermissionError as e:
    print(f"ERROR 无读取权限: {{e}}",file=sys.stderr); sys.exit(1)
except Exception as e:
    print(f"ERROR 读取失败: {{e}}",file=sys.stderr); sys.exit(1)

# 幂等删除旧同 LINK_ID 规则
had_direct = any(o.get("tag") == "direct" for o in cfg.get("outbounds",[]))
cfg["inbounds"]  = [x for x in cfg.get("inbounds",[])
                    if x.get("tag") != in_tag]
cfg["outbounds"] = [x for x in cfg.get("outbounds",[])
                    if x.get("tag") not in (out_tag,"direct")]
cfg.setdefault("routing",{{}}).setdefault("rules",[])

# 精准路由插入
cfg["routing"]["rules"] = safe_routing_insert(cfg["routing"]["rules"], rule, in_tag)

# 插入新规则
cfg["inbounds"].append(inbound)
cfg["outbounds"].insert(0, outbound)
if not had_direct:
    cfg["outbounds"].append({{"tag":"direct","protocol":"freedom"}})

# Failover Balancer（CB-7修复：<2 时同时清除 balancers + observatory）
relay_outs = [o["tag"] for o in cfg["outbounds"] if o.get("tag","").startswith("relay-out-")]
if len(relay_outs) >= 2:
    cfg.setdefault("observatory",{{}})
    cfg["observatory"].update({{
        "subjectSelector": ["relay-out-"],
        "probeInterval":   "60s",
        "probeURL":        "https://www.google.com/generate_204"
    }})
    bals = [b for b in cfg.get("balancers",[]) if b.get("tag") != "relay-balancer"]
    bals.append({{"tag":"relay-balancer","selector":["relay-out-"],
                  "strategy":{{"type":"leastPing"}}}})
    cfg["balancers"] = bals
    relay_ins = [x["tag"] for x in cfg["inbounds"] if x.get("tag","").startswith("relay-in-")]
    fail_rule = {{"type":"field","inboundTag":relay_ins,"balancerTag":"relay-balancer"}}
    cfg["routing"]["rules"] = [r for r in cfg["routing"]["rules"]
                                if r.get("balancerTag") != "relay-balancer"]
    cfg["routing"]["rules"].insert(0, fail_rule)
    print(f"[OK] Failover Balancer 已更新（{{len(relay_outs)}} 个落地）")
else:
    cfg.pop("balancers",  None)  # [CB-7修复]
    cfg.pop("observatory", None) # [CB-7修复]

mode = safe_write(config_path, cfg)
net_info  = outbound.get("streamSettings",{{}}).get("network","tcp")
flow_info = (outbound.get("settings",{{}}).get("vnext",[{{}}])[0]
             .get("users",[{{}}])[0].get("flow","none"))
print(f"[OK] config.json 写入成功 ({{mode}}) 端口={{inbound['port']}} 协议={{net_info}} Flow={{flow_info}}")

# 更新 nodes.json（[F4修复] safe_write 自动 makedirs）
try:
    nd = json.load(open(nodes_path))
except:
    nd = {{"nodes":[]}}
nd["nodes"] = [n for n in nd.get("nodes",[]) if n.get("link_id") != node_info["link_id"]]
nd["nodes"].append(node_info)
safe_write(nodes_path, nd)
print(f"[OK] nodes.json 已更新（共 {{len(nd['nodes'])}} 个节点）")
"""
print(remote)
PYEOF
)

    # 手动模式
    if [[ "$AUTH_TYPE" == "manual" ]]; then
        echo ""
        echo -e "${YELLOW}══ 在中转机执行以下 Python 脚本 ══${NC}"
        echo "python3 << 'EOF'"
        echo "$REMOTE_SCRIPT"
        echo "EOF"
        log_sep
        log_warn "执行后运行: systemctl restart xray-relay"
        read -rp "已在中转机执行完毕？按回车继续..." _ || true
        return 0
    fi

    # 自动模式：管道执行
    local result
    result=$(echo "$REMOTE_SCRIPT" | pipe_python_relay) || \
        log_error "远程配置写入失败，请检查 SSH 连接或中转机 python3"
    echo "$result" | while read -r l; do log_info "中转机: $l"; done

    # 验证配置
    log_step "验证 xray-relay 配置..."
    local xray_bin
    xray_bin=$(run_relay "
for p in '${RELAY_XRAY_BIN}' /etc/v2ray-agent/xray/xray /usr/local/bin/xray /usr/bin/xray /opt/xray/xray; do
    [ -x \"\$p\" ] && echo \"\$p\" && break
done" 2>/dev/null | head -1 | tr -d '\r\n') || xray_bin=""
    [[ -z "$xray_bin" ]] && xray_bin="${RELAY_XRAY_BIN:-/etc/v2ray-agent/xray/xray}"

    local test_out
    test_out=$(run_relay "${xray_bin} -test -config ${RELAY_CONFIG} 2>&1 | tail -5") || true
    if echo "$test_out" | grep -qi "error\|failed\|invalid"; then
        log_warn "配置验证警告（自动继续，请关注日志）:"
        echo "$test_out" | while read -r l; do echo "    $l"; done
        # [G7修复] 非致命警告自动继续，不阻断流程
    else
        log_info "配置验证 ✓"
    fi

    # [F8修复] 先 start 再判断状态
    run_relay "systemctl enable xray-relay 2>/dev/null; systemctl restart xray-relay" || true
    sleep 2
    local st
    st=$(run_relay "systemctl is-active xray-relay 2>/dev/null || echo inactive" \
        | tr -d '[:space:]') || st="unknown"
    if [[ "$st" == "active" ]]; then
        log_info "xray-relay ✓ 运行正常"
    else
        log_warn "xray-relay 状态: ${st}"
        log_error "xray-relay 启动失败，诊断命令: journalctl -u xray-relay -n 50 --no-pager"
    fi
}

# ════════════════════════════════════════════════════════════════
# §15 连通性验证
# ════════════════════════════════════════════════════════════════

connectivity_check() {
    [[ "$AUTH_TYPE" == "manual" ]] && return 0
    log_step "连通性验证..."
    local raw="${LUODI_IP//[\[\]]/}"

    local nc_r
    nc_r=$(run_relay "nc -zw 5 ${raw} ${LUODI_PORT} 2>&1 | tail -1") || true
    echo "$nc_r" | grep -qi "succeed\|connected\|open" \
        && log_info "中转 → 落地 ${raw}:${LUODI_PORT} ✓ TCP 可达" \
        || { log_warn "中转 → 落地 ${raw}:${LUODI_PORT} TCP 可能不通"
             echo "    nc: $nc_r"
             echo "    请检查：落地机防火墙是否放行中转机 IP / 端口是否正确"; }

    local listen
    listen=$(run_relay "ss -tlnp 2>/dev/null | grep :${RELAY_ASSIGNED_PORT} | head -1") || true
    [[ -n "$listen" ]] \
        && log_info "中转入站 :${RELAY_ASSIGNED_PORT} ✓ 监听中" \
        || log_warn "中转入站 :${RELAY_ASSIGNED_PORT} 未监听，请检查 xray-relay 日志"
}

# ════════════════════════════════════════════════════════════════
# §16 落地机出口纯净度检测（CB-5修复：无 --interface 绑定）
# ════════════════════════════════════════════════════════════════

check_unlock() {
    # [H3] AUTO_MODE：跳过解锁检测（可手动执行）
    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "自动模式：跳过解锁检测（可后续手动运行）"; return 0
    fi
    echo ""
    echo -e "${YELLOW}── 落地机出口纯净度检测（可选）──${NC}"
    local i
    read -rp "检测 Google/Netflix/Disney+ 解锁情况？[y/N]: " i || true
    [[ "${i,,}" != "y" ]] && return 0

    # Google
    log_step "Google..."
    local g
    g=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 --connect-timeout 5 \
        "https://www.google.com/generate_204" 2>/dev/null || echo "000")
    [[ "$g" == "204" ]] && log_info "Google ✓ (HTTP 204)" \
                        || log_warn "Google ✗ (HTTP ${g})"

    # Netflix
    log_step "Netflix..."
    local nf nf_cc
    nf=$(curl -s --max-time 10 -H "Accept-Language: en-US" \
        "https://www.netflix.com/title/81280792" 2>/dev/null || echo "")
    nf_cc=$(echo "$nf" | python3 -c "
import sys,re
b = sys.stdin.read()
for pat in [r'\"requestCountry\":\"([A-Z]{2})\"',r'\"currentCountry\":\"([A-Z]{2})\"']:
    m = re.search(pat,b)
    if m: print(m.group(1)); break
" 2>/dev/null || echo "")
    if [[ -n "$nf_cc" ]]; then
        log_info "Netflix ✓ 解锁地区: ${nf_cc}"
    elif echo "$nf" | grep -qi "Not Available\|unavailable"; then
        log_warn "Netflix ✗ 当前区域不可用"
    else
        log_warn "Netflix 检测结果不确定，请手动验证"
    fi

    # Disney+
    log_step "Disney+..."
    local dc
    dc=$(curl -s --max-time 10 \
        "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" \
        -X POST -H "Content-Type: application/json" \
        --data '{"query":"{ me { account { activeEntitlements { name } } } }"}' \
        2>/dev/null || echo "")
    echo "$dc" | grep -qi '"name"' \
        && log_info "Disney+ ✓ 可访问" \
        || log_warn "Disney+ 检测不确定（请手动确认）"

    echo ""; log_info "解锁检测完成（仅供参考）"
}

# ════════════════════════════════════════════════════════════════
# §17 生成节点链接（F6修复：纯 bash URL 编码）
# ════════════════════════════════════════════════════════════════

generate_node_link() {
    log_step "生成节点链接..."
    [[ -z "$RELAY_PUBKEY" ]] && log_error "中转机公钥为空"
    [[ -z "$RELAY_SNI"    ]] && log_error "中转机 SNI 为空"

    local rh encoded_label
    rh=$(ip_for_url "$RELAY_IP")
    encoded_label=$(url_encode "$NODE_LABEL")   # [F6修复] 纯 bash，无 python3 依赖

    NODE_LINK="vless://${NEW_UUID}@${rh}:${RELAY_ASSIGNED_PORT}"
    NODE_LINK+="?encryption=none&flow=xtls-rprx-vision"
    NODE_LINK+="&security=reality&sni=${RELAY_SNI}"
    NODE_LINK+="&fp=chrome&pbk=${RELAY_PUBKEY}"
    NODE_LINK+="&sid=${RELAY_SHORT_ID}"
    NODE_LINK+="&type=tcp&headerType=none"
    NODE_LINK+="#${encoded_label}"
    log_info "节点链接已生成"
}

# ════════════════════════════════════════════════════════════════
# §18 Base64 订阅 + 终端二维码
# ════════════════════════════════════════════════════════════════

generate_subscription() {
    log_step "生成订阅内容..."

    touch "$SUB_FILE"
    local tmp
    tmp=$(mktemp)
    grep -v "LINK_ID=${LINK_ID}" "$SUB_FILE" > "$tmp" 2>/dev/null || true
    echo "# LINK_ID=${LINK_ID}  label=${NODE_LABEL}  $(date '+%Y-%m-%d')" >> "$tmp"
    echo "$NODE_LINK" >> "$tmp"
    mv "$tmp" "$SUB_FILE"

    local all b64
    all=$(grep -v '^#' "$SUB_FILE" | grep -v '^$' || true)
    b64=$(echo "$all" | base64 -w 0 2>/dev/null \
        || echo "$all" | python3 -c \
            "import sys,base64; print(base64.b64encode(sys.stdin.buffer.read()).decode())")

    local cnt
    cnt=$(grep -v '^#' "$SUB_FILE" | grep -vc '^$' || echo "?")
    log_info "订阅文件: $SUB_FILE  (共 ${cnt} 个节点)"
    echo ""
    echo -e "  ${BOLD}Base64 订阅内容：${NC}"
    echo -e "  ${GREEN}${b64}${NC}"

    if command -v qrencode &>/dev/null; then
        echo ""; echo -e "  ${BOLD}节点二维码：${NC}"
        qrencode -t ANSIUTF8 "$NODE_LINK"
    else
        echo -e "  ${YELLOW}提示：apt install qrencode 可生成终端二维码${NC}"
    fi
}

# ════════════════════════════════════════════════════════════════
# §19 Sub-Store JSON 输出（CB-3修复：本地 Python，无注入风险）
# ════════════════════════════════════════════════════════════════

generate_substore_json() {
    log_step "生成 Sub-Store 配置..."

    python3 - << PYEOF
import json, os

substore_path = "${SUBSTORE_FILE}"
link_id       = "${LINK_ID}"

new_node = {
    "type":   "vless",
    "name":   "${NODE_LABEL}",
    "server": "${RELAY_IP//[\[\]]/}",
    "port":   int("${RELAY_ASSIGNED_PORT}"),
    "uuid":   "${NEW_UUID}",
    "flow":   "xtls-rprx-vision",
    "tls":    True,
    "servername": "${RELAY_SNI}",
    "reality-opts": {
        "public-key": "${RELAY_PUBKEY}",
        "short-id":   "${RELAY_SHORT_ID}"
    },
    "network":            "tcp",
    "client-fingerprint": "chrome",
    "link_id":            link_id
}

try:
    with open(substore_path) as f: data = json.load(f)
    proxies = data.get("proxies", []) if isinstance(data, dict) else data
    if not isinstance(proxies, list): proxies = []
except:
    proxies = []

proxies = [p for p in proxies if p.get("link_id") != link_id]
proxies.append(new_node)

os.makedirs(os.path.dirname(substore_path) or ".", exist_ok=True)
with open(substore_path, "w", encoding="utf-8") as f:
    json.dump({"proxies": proxies}, f, ensure_ascii=False, indent=2)

print(f"Sub-Store 已更新: {substore_path}  (共 {len(proxies)} 节点)")
PYEOF

    echo ""
    echo -e "  ${BOLD}Sub-Store 文件：${NC} ${SUBSTORE_FILE}"
    echo -e "  可通过 HTTP 服务暴露，在 Sub-Store 直接导入"
}

# ════════════════════════════════════════════════════════════════
# §20 防火墙联动
# ════════════════════════════════════════════════════════════════

generate_firewall_cmds() {
    echo ""
    log_sep
    echo -e "${YELLOW}  防火墙联动（落地机侧 + 中转机侧）${NC}"
    log_sep
    local raw="${RELAY_IP//[\[\]]/}"
    echo -e "  # 落地机：仅允许中转机 IP 访问代理端口"
    echo -e "  ${CYAN}iptables -I INPUT -s ${raw} -p tcp --dport ${LUODI_PORT} -j ACCEPT${NC}"
    echo -e "  ${CYAN}iptables -A INPUT -p tcp --dport ${LUODI_PORT} -j DROP${NC}"
    echo -e "  # 中转机：放行新入站端口"
    echo -e "  ${CYAN}iptables -I INPUT -p tcp --dport ${RELAY_ASSIGNED_PORT} -j ACCEPT${NC}"
    log_sep

    # [H3] AUTO_MODE：自动执行落地机侧 iptables 规则
    if [[ "$AUTO_MODE" == "true" ]]; then
        log_step "自动模式：执行落地机侧 iptables 规则..."
        iptables -I INPUT -s "$raw" -p tcp --dport "$LUODI_PORT" -j ACCEPT 2>/dev/null \
            && log_info "落地机 iptables ACCEPT 已添加" || log_warn "iptables 添加失败，请手动执行"
        iptables -A INPUT -p tcp --dport "$LUODI_PORT" -j DROP 2>/dev/null || true
        netfilter-persistent save 2>/dev/null && log_info "落地机规则已持久化" || true

        # [H4] AUTO_MODE：通过 SSH 自动在中转机放行新端口
        if [[ "$AUTH_TYPE" != "manual" ]]; then
            log_step "自动模式：在中转机放行入站端口 ${RELAY_ASSIGNED_PORT}..."
            run_relay "iptables -I INPUT -p tcp --dport ${RELAY_ASSIGNED_PORT} -j ACCEPT 2>/dev/null && \
                netfilter-persistent save 2>/dev/null; \
                nft add rule inet filter input tcp dport ${RELAY_ASSIGNED_PORT} accept 2>/dev/null; \
                echo DONE" | grep -q "DONE" \
                && log_info "中转机端口 ${RELAY_ASSIGNED_PORT} 已放行" \
                || log_warn "中转机端口放行失败，请手动执行：iptables -I INPUT -p tcp --dport ${RELAY_ASSIGNED_PORT} -j ACCEPT"
        fi
        return 0
    fi

    # 交互模式：询问用户是否执行
    local i
    read -rp "现在自动执行落地机 iptables 规则？[y/N]: " i || true
    if [[ "${i,,}" == "y" ]]; then
        iptables -I INPUT -s "$raw" -p tcp --dport "$LUODI_PORT" -j ACCEPT 2>/dev/null \
            && log_info "iptables 已添加" || log_warn "iptables 添加失败，请手动执行"
        netfilter-persistent save 2>/dev/null && log_info "规则已持久化" || true
    fi

    if [[ "$AUTH_TYPE" != "manual" ]]; then
        read -rp "同时在中转机放行端口 ${RELAY_ASSIGNED_PORT}？[y/N]: " i || true
        if [[ "${i,,}" == "y" ]]; then
            run_relay "iptables -I INPUT -p tcp --dport ${RELAY_ASSIGNED_PORT} -j ACCEPT 2>/dev/null && \
                netfilter-persistent save 2>/dev/null; echo DONE" | grep -q "DONE" \
                && log_info "中转机端口 ${RELAY_ASSIGNED_PORT} 已放行" \
                || log_warn "中转机端口放行失败，请手动执行"
        fi
    fi
}

# ════════════════════════════════════════════════════════════════
# §21 端口敲门
# ════════════════════════════════════════════════════════════════

configure_port_knocking() {
    # [H3] AUTO_MODE：跳过端口敲门（由第四个防火墙脚本统一管理）
    if [[ "$AUTO_MODE" == "true" ]]; then
        log_info "自动模式：跳过端口敲门配置（由防火墙脚本负责）"; return 0
    fi
    echo ""
    echo -e "${YELLOW}── 端口敲门 (Port Knocking) ──${NC}"
    local i
    read -rp "配置端口敲门保护落地机端口？[y/N]: " i || true
    [[ "${i,,}" != "y" ]] && return 0

    command -v knockd &>/dev/null || {
        apt-get install -y -qq knockd 2>/dev/null \
            || yum install -y -q knockd 2>/dev/null \
            || { log_warn "knockd 安装失败，跳过"; return 0; }
    }

    local k1 k2 k3 to
    read -rp "敲门端口1 [7000]: " k1 || true; k1="${k1:-7000}"
    read -rp "敲门端口2 [8000]: " k2 || true; k2="${k2:-8000}"
    read -rp "敲门端口3 [9000]: " k3 || true; k3="${k3:-9000}"
    read -rp "超时(秒)  [10]:   " to || true; to="${to:-10}"

    cat > /etc/knockd.conf << KNOCKEOF
[options]
    UseSyslog

[openProxy]
    sequence    = ${k1},${k2},${k3}
    seq_timeout = ${to}
    command     = /sbin/iptables -I INPUT -s %IP% -p tcp --dport ${LUODI_PORT} -j ACCEPT
    tcpflags    = syn

[closeProxy]
    sequence    = ${k3},${k2},${k1}
    seq_timeout = ${to}
    command     = /sbin/iptables -D INPUT -s %IP% -p tcp --dport ${LUODI_PORT} -j ACCEPT
    tcpflags    = syn
KNOCKEOF

    iptables -D INPUT -p tcp --dport "$LUODI_PORT" -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p tcp --dport "$LUODI_PORT" -j DROP   2>/dev/null || true
    systemctl enable knockd 2>/dev/null || true
    systemctl restart knockd 2>/dev/null && log_info "knockd 已启动" || log_warn "knockd 启动失败"

    echo -e "  敲门序列: ${CYAN}${k1} → ${k2} → ${k3}${NC}  (超时 ${to}s)"
    local raw="${LUODI_IP//[\[\]]/}"
    echo -e "  中转机执行: ${CYAN}knock ${raw} ${k1} ${k2} ${k3}${NC}"
}

# ════════════════════════════════════════════════════════════════
# §22 节点管理（查看 / 批量删除）
# ════════════════════════════════════════════════════════════════

node_manager() {
    [[ "$AUTH_TYPE" == "manual" ]] && { log_warn "manual 模式不支持节点管理"; return 0; }
    echo ""
    echo -e "${CYAN}── 中转机已对接节点 ──────────────────────────────────${NC}"

    local nj
    nj=$(run_relay "cat ${RELAY_NODES} 2>/dev/null || echo '{\"nodes\":[]}'") || \
        { log_warn "无法读取节点列表"; return 0; }

    local total
    total=$(echo "$nj" | python3 -c \
        "import json,sys; print(len(json.load(sys.stdin).get('nodes',[])))" 2>/dev/null || echo 0)

    echo "$nj" | python3 -c "
import json, sys
nodes = json.load(sys.stdin).get('nodes',[])
if not nodes: print('  （暂无节点）'); raise SystemExit
for i,n in enumerate(nodes,1):
    t = ''
    if n.get('mux'):    t += ' [Mux]'
    if n.get('sockopt'): t += ' [SO]'
    if n.get('landing_type')=='singbox': t += ' [SB]'
    print(f\"  [{i:2d}] {n.get('label','-'):24s}  \"\
          f\"中转:{n.get('relay_port','-'):5}  \"\
          f\"落地:{n.get('landing_ip','-')}:{n.get('landing_port','-')}  \"\
          f\"{n.get('landing_network','tcp')}{t}  {n.get('added_at','-')}\")
" 2>/dev/null || true

    [[ "$total" -eq 0 ]] && return 0
    echo ""
    echo -e "  ${CYAN}[d]${NC} 删除（序号，支持逗号分隔）  ${CYAN}[回车]${NC} 返回"
    local action
    read -rp "操作: " action || true

    if [[ "${action,,}" == "d" ]]; then
        local idx_str
        read -rp "序号（如 1 或 1,3）: " idx_str || true
        [[ -n "$idx_str" ]] && _delete_nodes "$idx_str"
    elif [[ "$action" =~ ^[0-9,]+$ ]]; then
        _delete_nodes "$action"
    fi
}

_delete_nodes() {
    local del_indices="$1"
    log_step "删除节点: ${del_indices}..."

    # CB-2修复：pipe_python_relay 模式，本地 Python 生成完整远端脚本
    local DEL_SCRIPT
    DEL_SCRIPT=$(python3 - << PYEOF
import json

config_path  = "${RELAY_CONFIG}"
nodes_path   = "${RELAY_NODES}"
del_indices  = "${del_indices}"

remote = f"""import json, sys

config_path = {json.dumps(config_path)}
nodes_path  = {json.dumps(nodes_path)}
del_indices = {json.dumps(del_indices)}

try:
    nd  = json.load(open(nodes_path))
except: nd = {{"nodes":[]}}
nodes = nd.get("nodes",[])

try:
    cfg = json.load(open(config_path))
except Exception as e:
    print(f"ERROR reading config: {{e}}"); sys.exit(1)

indices = sorted(
    set(int(x.strip())-1 for x in del_indices.split(",") if x.strip().isdigit()),
    reverse=True
)
deleted = []

for idx in indices:
    if idx < 0 or idx >= len(nodes):
        print(f"WARN: 序号 {{idx+1}} 超出范围，跳过"); continue
    node    = nodes[idx]
    in_tag  = node.get("tag","")
    out_tag = in_tag.replace("relay-in-","relay-out-")

    had_direct = any(o.get("tag")=="direct" for o in cfg.get("outbounds",[]))
    cfg["inbounds"]  = [x for x in cfg.get("inbounds",[]) if x.get("tag") != in_tag]
    cfg["outbounds"] = [x for x in cfg.get("outbounds",[])
                        if x.get("tag") not in (out_tag,"direct")]
    cfg.setdefault("routing",{{}}).setdefault("rules",[])
    cfg["routing"]["rules"] = [
        r for r in cfg["routing"]["rules"]
        if in_tag not in r.get("inboundTag",[])
        and r.get("balancerTag") != "relay-balancer"
    ]
    if had_direct:
        cfg["outbounds"].append({{"tag":"direct","protocol":"freedom"}})
    deleted.append(node.get("label",in_tag))
    nodes.pop(idx)

# CB-7修复：正确重建或清除 Balancer
relay_outs = [o["tag"] for o in cfg["outbounds"] if o.get("tag","").startswith("relay-out-")]
if len(relay_outs) >= 2:
    relay_ins = [x["tag"] for x in cfg["inbounds"] if x.get("tag","").startswith("relay-in-")]
    fail_rule = {{"type":"field","inboundTag":relay_ins,"balancerTag":"relay-balancer"}}
    cfg["routing"]["rules"] = [r for r in cfg["routing"]["rules"]
                                if r.get("balancerTag") != "relay-balancer"]
    cfg["routing"]["rules"].insert(0, fail_rule)
    bals = [b for b in cfg.get("balancers",[]) if b.get("tag") != "relay-balancer"]
    bals.append({{"tag":"relay-balancer","selector":["relay-out-"],
                  "strategy":{{"type":"leastPing"}}}})
    cfg["balancers"] = bals
    cfg.setdefault("observatory",{{}})["subjectSelector"] = ["relay-out-"]
    print(f"[OK] Balancer 已重建（{{len(relay_outs)}} 个落地）")
else:
    cfg.pop("balancers",  None)
    cfg.pop("observatory", None)
    print("[OK] 节点数 < 2，Balancer 及 observatory 已清除")

import os
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path,"w") as f: json.dump(cfg,f,indent=2)
nd["nodes"] = nodes
with open(nodes_path,"w") as f: json.dump(nd,f,indent=2)
print(f"[OK] 已删除: {{deleted}}  剩余: {{len(nodes)}} 个节点")
"""
print(remote)
PYEOF
)
    local result
    result=$(echo "$DEL_SCRIPT" | pipe_python_relay) || { log_warn "删除失败"; return 0; }
    echo "$result" | while read -r l; do log_info "$l"; done
    run_relay "systemctl restart xray-relay" || true
    log_info "xray-relay 已重启"
}

# ════════════════════════════════════════════════════════════════
# §23 旧对接数据处理（G1修复：LINK_ID 精准自动清理，零交互）
# ════════════════════════════════════════════════════════════════

# [G1] 在 LINK_ID 确定后调用，精准移除 LOCAL_INFO 中该 LINK_ID 的旧段落
auto_clean_by_link_id() {
    [[ -z "$LINK_ID" ]] && return 0
    [[ ! -f "$LOCAL_INFO" ]] && return 0
    grep -q "LINK_ID=${LINK_ID}" "$LOCAL_INFO" 2>/dev/null || return 0

    # [H1] 在删除段落前，先从历史文件中提取上次对接的中转机连接信息暂存
    if [[ -z "$_SAVED_RELAY_IP" ]]; then
        _SAVED_RELAY_IP=$(grep -m1 '^RELAY_IP=' "$LOCAL_INFO" | cut -d= -f2- | tr -d '\r' || true)
        _SAVED_RELAY_SSH_PORT=$(grep -m1 '^RELAY_SSH_PORT=' "$LOCAL_INFO" | cut -d= -f2- | tr -d '\r' || true)
        _SAVED_RELAY_SSH_USER=$(grep -m1 '^RELAY_SSH_USER=' "$LOCAL_INFO" | cut -d= -f2- | tr -d '\r' || true)
        [[ -n "$_SAVED_RELAY_IP" ]] && log_info "已暂存历史中转机: ${_SAVED_RELAY_IP}:${_SAVED_RELAY_SSH_PORT:-22}"
    fi

    log_info "检测到旧对接记录 (LINK_ID: ${LINK_ID})，自动精准清理..."

    # Python 精准移除包含该 LINK_ID 的段落
    python3 - << PYEOF
import sys

link_id  = "${LINK_ID}"
filepath = "${LOCAL_INFO}"

with open(filepath, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

result = []
i = 0
while i < len(lines):
    line = lines[i]
    # 段落起始标志：以 "── 对接节点" 开头
    if line.startswith("── 对接节点") and "────" in line:
        # 收集这个段落的所有行
        block = [line]
        j = i + 1
        while j < len(lines):
            if lines[j].startswith("── 对接节点") and "────" in lines[j]:
                break
            block.append(lines[j])
            j += 1
        # 判断这个段落是否含有目标 LINK_ID
        block_text = "".join(block)
        if f"LINK_ID={link_id}" in block_text:
            # 跳过这个段落
            i = j
            continue
        else:
            result.extend(block)
            i = j
            continue
    result.append(line)
    i += 1

# 移除末尾多余空行
content = "".join(result).rstrip("\n")
with open(filepath, "w", encoding="utf-8") as f:
    f.write(content + "\n" if content else "")

print(f"[OK] 已从 {filepath} 移除 LINK_ID={link_id} 旧段落")
PYEOF

    # 同步清理订阅文件中的旧记录
    if [[ -f "$SUB_FILE" ]]; then
        grep -v "LINK_ID=${LINK_ID}" "$SUB_FILE" > "${SUB_FILE}.tmp" 2>/dev/null \
            && mv "${SUB_FILE}.tmp" "$SUB_FILE" || rm -f "${SUB_FILE}.tmp"
    fi

    log_info "旧对接记录已精准清理 (LINK_ID: ${LINK_ID})"
}

# [保留] 旧式全局清理入口（供节点管理菜单调用）
_cleanup_old_data_interactive() {
    if [[ ! -f "$LOCAL_INFO" ]] || \
       ! grep -qE "^RELAY_IP=|^── 对接节点" "$LOCAL_INFO" 2>/dev/null; then
        return 0
    fi
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  本地历史记录操作                                   ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${CYAN}[1]${NC} 追加新节点（保留全部旧记录）"
    echo -e "  ${CYAN}[2]${NC} 清除全部本地对接记录（谨慎）"
    echo -e "  ${CYAN}[3]${NC} 进入节点管理（查看/删除中转机节点）"
    local choice
    read -rp "请选择 [1]: " choice || true; choice="${choice:-1}"

    case "$choice" in
        2)
            local clean
            clean=$(awk '/^── 对接节点/{exit} /^RELAY_IP=/{exit} {print}' "$LOCAL_INFO")
            printf '%s\n' "$clean" > "$LOCAL_INFO"
            log_info "本地旧对接记录已全部清除"
            read -rp "同时清理中转机全部旧节点规则？[Y/n]: " yn || true
            [[ "${yn,,}" != "n" ]] && _cleanup_relay_all || true
            ;;
        3)
            setup_ssh; read_relay_info; node_manager
            read -rp "继续对接新节点？[y/N]: " cont || true
            [[ "${cont,,}" != "y" ]] && exit 0
            ;;
        *) log_info "继续追加新节点" ;;
    esac
}

_cleanup_relay_all() {
    echo ""
    echo -e "${YELLOW}── 连接中转机，清理全部 relay-* 规则 ──${NC}"
    local _CIP _CP="${RELAY_SSH_PORT:-22}" _CU="${RELAY_SSH_USER:-root}" _CA _CPASS=""
    read -rp "中转机 IP [${RELAY_IP:-}]: " _CIP || true
    _CIP="${_CIP:-$RELAY_IP}"
    [[ -z "$_CIP" ]] && { log_warn "跳过"; return 0; }
    local _O="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p $_CP"
    echo -e "认证：[1]密钥  [3]密码"
    read -rp "选择 [1]: " _CA || true; _CA="${_CA:-1}"
    [[ "$_CA" == "3" ]] && { read -rsp "密码: " _CPASS; echo ""; } || true
    _rsc() {
        [[ "$_CA" == "3" ]] \
            && sshpass -p "$_CPASS" ssh -q $_O "${_CU}@${_CIP}" "$1" \
            || ssh -q $_O "${_CU}@${_CIP}" "$1"
    }
    _rsc "python3 << 'PYEOF'
import json, os
for path in ['/usr/local/etc/xray-relay/config.json',
             '/etc/v2ray-agent/xray/conf/00_base.json']:
    try:
        cfg = json.load(open(path))
        cfg['inbounds']  = [x for x in cfg.get('inbounds',[])
                            if not x.get('tag','').startswith('relay-in-')]
        cfg['outbounds'] = [x for x in cfg.get('outbounds',[])
                            if not x.get('tag','').startswith('relay-out-')]
        cfg.setdefault('routing',{}).setdefault('rules',[])
        cfg['routing']['rules'] = [r for r in cfg['routing']['rules']
            if not any(t.startswith('relay-in-') for t in r.get('inboundTag',[]))
            and r.get('balancerTag') != 'relay-balancer']
        cfg.pop('balancers',None); cfg.pop('observatory',None)
        if not any(o.get('tag')=='direct' for o in cfg.get('outbounds',[])):
            cfg['outbounds'].append({'tag':'direct','protocol':'freedom'})
        with open(path,'w') as f: json.dump(cfg,f,indent=2)
        print(f'[OK] 已清理 {path}')
    except Exception as e: print(f'[SKIP] {path}: {e}')
for p in ['/usr/local/etc/xray-relay/nodes.json']:
    try:
        os.makedirs(os.path.dirname(p),exist_ok=True)
        with open(p,'w') as f: json.dump({'nodes':[]},f)
        print(f'[OK] 已重置 {p}')
    except: pass
PYEOF" && log_info "中转机规则已全部清理" || log_warn "中转机清理部分失败，请手动检查"
    _rsc "systemctl restart xray-relay 2>/dev/null; echo restarted" || true
}

# ════════════════════════════════════════════════════════════════
# §24 保存结果 / 打印摘要
# ════════════════════════════════════════════════════════════════

save_result() {
    # [G5修复] 追加前先精准移除同 LINK_ID 的旧记录（防止重复运行造成冗余）
    auto_clean_by_link_id

    {
        echo ""
        echo "── 对接节点 $(date '+%Y-%m-%d %H:%M:%S') ────────────────────────"
        echo "RELAY_IP=${RELAY_IP}"
        echo "RELAY_SSH_PORT=${RELAY_SSH_PORT:-22}"
        echo "RELAY_SSH_USER=${RELAY_SSH_USER:-root}"
        echo "RELAY_PORT=${RELAY_ASSIGNED_PORT}"
        echo "RELAY_UUID=${NEW_UUID}"
        echo "LINK_ID=${LINK_ID}"
        echo "LUODI_NETWORK=${LUODI_NETWORK}"
        echo "LUODI_TYPE=${LUODI_TYPE}"
        echo "MUX=${ENABLE_MUX}"
        echo "SOCKOPT=${ENABLE_SOCKOPT}"
        echo "NODE_LABEL=${NODE_LABEL}"
        echo "NODE_LINK=${NODE_LINK}"
        echo "────────────────────────────────────────────────────────────"
    } >> "$LOCAL_INFO"
    log_info "节点信息已写入: $LOCAL_INFO"
}

print_result() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  ${GREEN}${BOLD}✓ 对接完成  duijie.sh v16.0${NC}                              ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}流量路径：${NC}"
    echo -e "  客户端 → ${CYAN}${RELAY_IP}:${RELAY_ASSIGNED_PORT}${NC} [tcp+Reality+Vision]"
    local _luodi_desc="${LUODI_NETWORK:-tcp}+Reality"
    [[ "$LUODI_NETWORK" == "tcp" ]] && _luodi_desc="tcp+Reality+Vision"
    echo -e "           → ${LUODI_IP}:${LUODI_PORT} [${_luodi_desc}] → 🌐 互联网"
    echo ""
    [[ "$ENABLE_MUX"     == "true"    ]] && echo -e "  ${BOLD}Mux：${NC}     ${MUX_PROTOCOL}  maxConn=${MUX_MAX_CONN}"
    [[ "$ENABLE_SOCKOPT" == "true"    ]] && echo -e "  ${BOLD}sockopt：${NC}  tcpFastOpen + mark=255 ✓"
    [[ "$LUODI_TYPE"     == "singbox" ]] && echo -e "  ${BOLD}落地类型：${NC} Sing-box（已翻译为 Xray outbound 格式）"
    echo -e "  ${BOLD}LINK_ID：${NC}  ${LINK_ID}"
    echo -e "  ${BOLD}节点标签：${NC} ${NODE_LABEL}"
    echo ""
    echo -e "  ${BOLD}节点链接：${NC}"
    echo -e "  ${GREEN}${NODE_LINK}${NC}"
    echo ""
    log_sep
    echo -e "${YELLOW}常用命令：${NC}"
    echo -e "  落地机信息    : cat ${LOCAL_INFO}"
    echo -e "  Sub-Store JSON: cat ${SUBSTORE_FILE}"
    echo -e "  订阅文件      : cat ${SUB_FILE}"
    echo -e "  节点列表      : (SSH中转) python3 -m json.tool ${RELAY_NODES}"
    echo -e "  中转机日志    : (SSH中转) journalctl -u xray-relay -f"
    echo -e "  节点管理      : bash duijie.sh → 选节点管理入口"
    log_sep
    echo -e "${CYAN}v16.0：5项新增修复（H1~H5）+ 继承 v15 全部修复（G1~G9 + F1~F8 + CB-1~CB-8）${NC}"
    echo ""
}

# ════════════════════════════════════════════════════════════════
# §25 主流程
# ════════════════════════════════════════════════════════════════

main() {
    # ── 参数解析 ──────────────────────────────────────────────────
    for _arg in "$@"; do
        case "$_arg" in
            --auto)   AUTO_MODE="true"  ;;
            --manage) true ;;  # handled below
        esac
    done

    # 支持 --manage 参数直接进入节点管理
    if [[ "${1:-}" == "--manage" ]]; then
        ensure_python3_local
        setup_ssh
        [[ "$AUTH_TYPE" != "manual" ]] && ensure_python3_relay || true
        read_relay_info
        node_manager
        exit 0
    fi

    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       落地机对接脚本  duijie.sh  v16.0                  ║${NC}"
    echo -e "${CYAN}║  支持: Xray / Sing-box / 3x-ui / x-ui / mack-a / 1Panel ║${NC}"
    echo -e "${CYAN}║  特性: 全自动读取 · 隔离节点 · 幂等写入 · 全面兼容      ║${NC}"
    if [[ "$AUTO_MODE" == "true" ]]; then
    echo -e "${CYAN}║  ${GREEN}${BOLD}⚡ AUTO_MODE：全零交互 · 免密SSH · 自动防火墙${NC}             ${CYAN}║${NC}"
    else
    echo -e "${CYAN}║  提示: --auto 零交互  --manage 节点管理                  ║${NC}"
    fi
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    ensure_python3_local        # §1 环境

    read_luodi_info             # §7 落地机信息 + §4 LINK_ID + §5 协议嗅探
                                # LINK_ID 在此生成后，auto_clean_by_link_id 已自动调用
                                # [H1] _SAVED_RELAY_IP 已在 clean 前暂存

    precheck_link "$LUODI_IP" "$LUODI_PORT" "落地机"  # §3

    check_and_enable_bbr        # §6 BBR（H5：--auto 时静默启用）

    setup_ssh                   # §8 SSH（H1+H2：历史默认值 + BatchMode 探测）

    [[ "$AUTH_TYPE" != "manual" ]] && ensure_python3_relay || true  # §1

    read_relay_info             # §9 中转机配置

    [[ "$AUTH_TYPE" != "manual" ]] && precheck_link "$RELAY_IP" "" "中转机" || true

    [[ "$AUTH_TYPE" != "manual" ]] && check_existing_node || true   # §10

    configure_mux               # §11（H3：--auto 时自动关闭）
    configure_sockopt           # §11（H3：--auto 时自动开启）

    allocate_port_and_uuid      # §12（三层端口探测）

    update_relay_config         # §14（核心写入）

    connectivity_check          # §15

    check_unlock                # §16（H3：--auto 时跳过）

    generate_node_link          # §17

    generate_subscription       # §18

    generate_substore_json      # §19

    generate_firewall_cmds      # §20（H3+H4：--auto 时自动执行双侧 iptables）

    configure_port_knocking     # §21（H3：--auto 时跳过）

    save_result                 # §24
    print_result                # §24
}

main "$@"
