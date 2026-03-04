# Xray VLESS Reality 中转代理部署指南

基于 **Xray + VLESS Reality** 的中转转发架构，无需域名和证书，三条命令完成部署。

---

## 架构说明

```
你的设备（手机 / 电脑）
        │
        │  VLESS Reality
        ▼
   中转机  ←  用户实际连接（香港 / 日本 / 新加坡等低延迟 VPS）
        │
        │  VLESS Reality（服务器间直连）
        ▼
   落地机  ←  流量最终出口（甲骨文 / 搬瓦工等纯净 IP）
        │
        ▼
      互联网
```

| 角色 | 作用 | 推荐选择 |
|------|------|----------|
| **中转机** | 用户连接的入口，负责转发流量 | 香港 / 日本低延迟 VPS |
| **落地机** | 流量实际出口，IP 纯净度决定可用性 | 甲骨文、搬瓦工、RackNerd |

> 中转机只需运行一次，可对接多台落地机，每台落地机对应一个独立端口。

---

## 快速部署

### 第一步：落地机

登录落地机，执行以下命令（全自动安装，无需任何输入）：

```bash
bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/luodi.sh)
```

脚本自动完成：安装 Xray → 生成 UUID / Reality 密钥对 / Short ID → 写入配置 → 启动服务

完成后输出节点信息，**请截图或记录**，对接时需要用到：

```
============================================================
  落地机节点信息
============================================================
公网 IP     : 152.xx.xx.xx
VLESS 端口  : 443
UUID        : a1b2c3d4-xxxx-xxxx-xxxx-xxxxxxxxxxxx
公钥(pubkey): AbCdEfGhIjKl...
私钥(prikey): XxYyZz...（自己保管，勿泄露）
Short ID    : a1b2c3d4
伪装域名    : www.microsoft.com
```

> 信息同时保存在落地机的 `/root/xray_luodi_info.txt`，随时可查。

---

### 第二步：中转机

登录中转机，执行：

```bash
bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/zhongzhuan.sh)
```

脚本会询问三个问题：

**① 中转机公网 IP**
```
中转机公网 IP [回车使用自动检测 43.xx.xx.xx]:
```
直接回车即可，自动检测。

**② 对接落地机数量**
```
需要对接几台落地机 (1-20): 3
```
填计划对接的落地机数量，多填没关系，后续按需使用。

**③ 入站端口起始值**
```
入站端口起始值 [回车默认 10001]:
```
直接回车使用默认值，端口分配规则如下：

| 落地机 | 对应中转机端口 |
|--------|--------------|
| 第 1 台 | 10001 |
| 第 2 台 | 10002 |
| 第 3 台 | 10003 |

完成后输出：
```
中转机 IP         : 43.xx.xx.xx
可用入站端口      : 10001 ~ 10003
已对接落地机数    : 0 / 3
```

---

### 第三步：对接（在落地机上运行）

> ⚠️ **注意：对接脚本在落地机上运行**，它会 SSH 远程连接到中转机，自动写入配置。

登录落地机，执行：

```bash
bash <(curl -s https://raw.githubusercontent.com/vpn3288/proxy/refs/heads/main/duijie.sh)
```

#### 交互流程

**① 选择对接方式**
```
1) SSH 自动对接（推荐）
2) 手动模式（输出配置片段，手动粘贴到中转机）
```
选 `1`，全自动完成。

**② 输入中转机地址**
```
中转机 IP 或域名: 43.xx.xx.xx
SSH 端口 [默认 22]:
```

**③ SSH 用户名**
```
1) root    （大多数 VPS 默认）
2) ubuntu  （甲骨文 Ubuntu 镜像）
3) opc     （甲骨文 Oracle Linux 镜像）
4) 手动输入
```

**④ SSH 认证方式**
```
1) 密码
2) 密钥文件（本地有 .pem / id_rsa 文件）
3) 粘贴私钥内容  ← 甲骨文云推荐
```

- **普通 VPS（有密码）** → 选 `1`，输入密码
- **中转机是甲骨文云，已上传 .pem 文件** → 选 `2`，脚本自动扫描本机密钥文件列表
- **中转机是甲骨文云，无 .pem 文件** → 选 `3`，粘贴私钥内容：

```
请粘贴私钥内容（以 -----BEGIN ... PRIVATE KEY----- 开头）
粘贴完成后，新起一行输入 END 并回车：

-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA2a8s...
-----END RSA PRIVATE KEY-----
END
```

> 用文本编辑器打开 `.pem` 文件，全选复制，粘贴到终端，最后输 `END` 回车。

**⑤ 确认端口**
```
建议端口: 10001
确认 [回车=10001，或输入其他端口]:
```
直接回车即可，第二台落地机会自动建议 `10002`。

#### 脚本自动完成的工作

1. SSH 登录中转机
2. 添加入站配置（端口 10001，等待用户连接）
3. 添加出站配置（指向这台落地机）
4. 添加路由规则（入站绑定出站）
5. 重启中转机 Xray

#### 最终输出客户端节点链接

```
══════════════════════════════════════════════════════
  对接完成！客户端节点链接
══════════════════════════════════════════════════════

vless://a1b2c3d4-xxxx@43.xx.xx.xx:10001?encryption=none
  &flow=xtls-rprx-vision&security=reality
  &sni=www.microsoft.com&fp=chrome
  &pbk=AbCdEf...&sid=a1b2c3d4&type=tcp
  #中转43.xx:10001→落地152.xx

流量路径：用户 → 43.xx.xx.xx:10001（中转）→ 152.xx.xx.xx:443（落地）→ 互联网
```

复制链接导入到 v2rayN / v2rayNG / Shadowrocket / Sing-box 等客户端即可使用。

---

## 多台落地机

有几台落地机，重复执行**第一步 + 第三步**即可，中转机只需配置一次：

| 操作 | 落地机 A | 落地机 B | 落地机 C |
|------|:--------:|:--------:|:--------:|
| 运行 `luodi.sh` | ✅ | ✅ | ✅ |
| 运行 `duijie.sh` | ✅ | ✅ | ✅ |
| 分配中转端口 | 10001 | 10002 | 10003 |

---

## 查看节点信息

```bash
relay-info
```

---

## 管理命令

### 中转机

```bash
# 查看服务状态
systemctl status xray

# 重启服务
systemctl restart xray

# 查看已对接落地机列表
cat /usr/local/etc/xray/nodes.json | jq .

# 实时日志
journalctl -u xray -f
```

### 落地机

```bash
# 查看服务状态
systemctl status xray

# 重启服务
systemctl restart xray

# 查看本机节点信息
cat /root/xray_luodi_info.txt

# 查看所有对接记录和节点链接
cat /root/duijie_records.txt
```

---

## 常见问题

**Q：对接失败，SSH 连接超时？**
- 检查中转机安全组 / 防火墙是否放行了 22 端口
- 甲骨文云需在控制台的安全列表（Security List）放行 SSH

**Q：节点可以连接但无法上网？**
- 检查落地机防火墙，确保代理端口已放行
- 运行 `systemctl status xray` 检查 Xray 是否正常运行

**Q：中转机端口已满怎么办？**
- 重新运行 `zhongzhuan.sh`，增大落地机数量上限

**Q：想更换落地机 IP？**
- 在原落地机重新运行 `luodi.sh`，再运行 `duijie.sh` 重新对接即可
