# 中转机 + 落地机 一键对接脚本

> **一个中转机对接多台落地机，流量经 CN2GIA 中转，从落地机优质 IP 出口**

---

## 架构

```
用户
 │  VLESS Reality（中转机公钥，隐蔽安全）
 ▼
中转机（CN2GIA）  xray-relay.service
 │  端口 30001 → 落地机1
 │  端口 30002 → 落地机2
 │  端口 30003 → 落地机N
 │  VLESS Reality（落地机公钥，服务器间直连）
 ▼
落地机（Oracle / 搬瓦工 / 其他）
 │  v2ray-agent xray.service（0.0.0.0:45001 专用入站）
 ▼
目标网站（使用落地机 IP）
```

**关键设计：**
- 中转机运行独立的 `xray-relay.service`，与 v2ray-agent 的 `xray.service` 互不干扰
- 落地机添加专用直连入站（端口 45001，监听 `0.0.0.0`），绕过 nginx，直接与中转机通信
- mack-a 任何操作不会影响中转机的 xray-relay 配置

---

## 前置要求

| 机器 | 要求 |
|------|------|
| 落地机 | Ubuntu 20.04/22.04/24.04，v2ray-agent 已安装且 VLESS Reality 可用 |
| 中转机 | Ubuntu 20.04/22.04/24.04，v2ray-agent 已安装（Xray 二进制需存在） |
| 网络   | 落地机的专用端口（默认 45001）可被中转机访问 |

---

## 部署顺序

### 第一步：中转机初始化（只需运行一次）

在**中转机**上运行：

```bash
bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/zhongzhuan.sh)
```

脚本将：
- 安装/复用 Xray 二进制
- 生成 Reality 密钥（用户连接中转机时使用）
- 创建 `xray-relay.service` 独立服务
- 预留端口范围（默认 30001 起）
- 保存信息到 `/root/xray_zhongzhuan_info.txt`

---

### 第二步：落地机配置（每台落地机各运行一次）

在**落地机**上运行：

```bash
bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/luodi.sh)
```

脚本将：
- 读取 v2ray-agent 的 VLESS Reality 配置（UUID、私钥、SNI 等）
- 添加中转机专用入站 `relay_dedicated_inbound.json`（0.0.0.0:45001）
- 配置防火墙（可选：限制仅中转机 IP 可访问）
- 保存信息到 `/root/xray_luodi_info.txt`

---

### 第三步：对接（在落地机上运行，SSH 自动写入中转机）

在**落地机**上运行：

```bash
bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/duijie.sh)
```

脚本将：
- 读取落地机信息（`/root/xray_luodi_info.txt`）
- SSH 到中转机，读取中转机密钥和端口分配
- 自动写入中转机的入站 + 出站 + 路由规则
- 重启 `xray-relay.service`
- 生成节点链接（使用中转机 IP）

---

## 新增第 N 台落地机

直接在新落地机上重复第二步 + 第三步，中转机会自动分配下一个端口（30002、30003...）。

---

## 节点链接格式

```
vless://UUID@中转机IP:30001?
  encryption=none
  &flow=xtls-rprx-vision
  &security=reality
  &sni=www.microsoft.com
  &fp=chrome
  &pbk=中转机公钥
  &sid=中转机ShortID
  &type=tcp
  #节点标签
```

用户连接中转机，流量经中转机转发至对应落地机出口。

---

## 常用管理命令

### 落地机

```bash
# 查看落地机信息和节点链接
cat /root/xray_luodi_info.txt

# 查看 Xray 状态
systemctl status xray

# 查看是否有中转机连入
grep relay /var/log/xray/access.log 2>/dev/null | tail -20
```

### 中转机

```bash
# 查看所有已对接落地机
python3 -m json.tool /usr/local/etc/xray-relay/nodes.json

# 查看中转配置
python3 -m json.tool /usr/local/etc/xray-relay/config.json

# 查看 xray-relay 状态
systemctl status xray-relay

# 查看实时日志
journalctl -u xray-relay -f --no-pager

# 重启 xray-relay
systemctl restart xray-relay

# 查看入站端口列表
python3 -c "
import json
c = json.load(open('/usr/local/etc/xray-relay/config.json'))
for i in c['inbounds']:
    print(f\"端口 {i['port']} → {i['tag']}\")
"
```

---

## 文件位置

| 文件 | 说明 |
|------|------|
| `/root/xray_luodi_info.txt` | 落地机信息 + 节点链接（落地机上） |
| `/root/xray_zhongzhuan_info.txt` | 中转机密钥和配置（中转机上） |
| `/usr/local/etc/xray-relay/config.json` | xray-relay 主配置（中转机） |
| `/usr/local/etc/xray-relay/nodes.json` | 已对接节点注册表（中转机） |
| `/etc/v2ray-agent/xray/conf/relay_dedicated_inbound.json` | 落地机中转专用入站（落地机） |
| `/var/log/xray-relay/` | xray-relay 日志目录（中转机） |

---

## 常见问题

**Q: 连接超时，节点不通**

1. 确认中转机 30001 端口已在安全组放行（TCP）
2. 确认落地机 45001 端口已在安全组放行（TCP）
3. 在中转机测试能否连通落地机：`nc -zv 落地机IP 45001`
4. 查看中转机日志：`journalctl -u xray-relay -n 50`

**Q: mack-a 更新配置后节点失效**

中转机的 `xray-relay.service` 完全独立，不受 mack-a 影响。若是落地机的 `relay_dedicated_inbound.json` 被删除，重新运行 `luodi.sh` 即可恢复。

**Q: 甲骨文云落地机无法连接**

甲骨文使用 NAT，落地机没有绑定公网 IP。`luodi.sh` 已配置 `0.0.0.0` 监听，中转机通过公网 IP 访问时会经过甲骨文的安全组过滤——需确保安全组放行了 45001/TCP。

**Q: 如何删除某台落地机的对接**

在中转机上运行：
```bash
python3 << 'EOF'
import json
config_path = '/usr/local/etc/xray-relay/config.json'
nodes_path  = '/usr/local/etc/xray-relay/nodes.json'

# 填入要删除的端口号
remove_port = 30001

c = json.load(open(config_path))
tag = next((i['tag'] for i in c['inbounds'] if i['port'] == remove_port), None)
if tag:
    c['inbounds']  = [i for i in c['inbounds']  if i.get('tag') != tag]
    c['outbounds'] = [o for o in c['outbounds'] if o.get('tag') != tag.replace('in', 'out')]
    c['routing']['rules'] = [r for r in c['routing']['rules']
                              if tag not in r.get('inboundTag', [])]
    json.dump(c, open(config_path,'w'), indent=2)
    print(f"已删除端口 {remove_port} 的配置")

n = json.load(open(nodes_path))
n['nodes'] = [nd for nd in n['nodes'] if nd.get('tag') != tag]
json.dump(n, open(nodes_path,'w'), indent=2)
EOF

systemctl restart xray-relay
```

---

## 支持的落地机软件

| 软件 | 支持状态 |
|------|---------|
| v2ray-agent (mack-a) + Xray | ✅ 完整支持 |
| v2ray-agent (mack-a) + Sing-box | 🚧 待支持（手动输入参数可用） |
| 233boy/Xray | 🚧 待支持（手动输入参数可用） |
| x-ui / 3x-ui 面板 | 🚧 待支持（手动输入参数可用） |
| 手动输入参数 | ✅ 任何情况兜底 |
