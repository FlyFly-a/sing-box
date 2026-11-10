# sing-box 一键部署管理脚本

自动识别系统架构与 IPv4/IPv6 环境，安装依赖和 sing-box 核心，并通过交互式菜单管理多协议节点、出站和出口路由。

## 特性

- **一键部署**：自动识别架构、安装依赖、下载核心并注册系统服务
- **静态核心**：优先使用官方 musl 静态构建，兼容 Alpine 和旧 glibc 系统
- **多系统支持**：systemd 与 OpenRC 双服务后端
- **IPv4/IPv6 自适应**：根据环境选择 `0.0.0.0` / `::`；双栈环境每个节点输出 IPv4、IPv6 两套分享链接
- **11 种常用协议**：VLESS、Hysteria2、TUIC、Trojan、AnyTLS、Shadowsocks、VMess、Snell、SOCKS5
- **极简创建**：只需名称、端口、SNI；UUID、密码、PSK、路径、密钥全部自动生成
- **批量创建**：一次多选协议，按国家码 + 协议自动命名
- **链式落地**：粘贴分享链接即可把另一台服务器设为出口
- **多落地分流**：节点可单选或多选绑定不同出口，也可单选或多选恢复直连
- **原子配置**：节点单文件保存，`config.json` 同目录临时文件原子替换
- **自动分享链接**：节点创建完成后直接输出，主菜单可一次查看全部

## 系统与架构

| 系统 | 包管理 | 服务管理 |
|---|---|---|
| Ubuntu / Debian | apt | systemd |
| CentOS / RHEL / Rocky / AlmaLinux / Fedora | yum / dnf | systemd |
| Alpine Linux | apk | OpenRC |
| openSUSE | zypper | systemd |
| Arch Linux | pacman | systemd |

支持 x86_64、aarch64、armv7、armv6、i386、riscv64、s390x、ppc64le、loong64 等架构，并会识别 32 位用户态环境。

> musl 静态版覆盖 amd64、arm64、386、armv7、riscv64、loong64；其他架构会回退通用版，Alpine 等 musl 系统可能无法运行。

## 快速开始

以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/FlyFly-a/sing-box/main/dist/sing-box-oneclick.sh \
  -o /usr/local/bin/sb
chmod +x /usr/local/bin/sb
sb
```

首次运行会自动安装核心，之后随时执行 `sb` 打开管理菜单。

### 从源码运行

```bash
git clone https://github.com/FlyFly-a/sing-box.git
cd sing-box
bash sing-box.sh
```

也可以直接运行已构建的单文件版：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/FlyFly-a/sing-box/main/dist/sing-box-oneclick.sh)
```

### 命令行参数

```bash
bash sing-box.sh install   # 安装/更新核心并注册系统服务
bash sing-box.sh status    # 查看运行状态
bash sing-box.sh help      # 查看用法
```

## 主菜单

```text
1) 节点管理
2) 出站管理
3) 出口路由
4) 运行管理
5) 核心管理
6) 分享链接
7) 使用帮助
0) 退出
```

菜单顶部会显示核心版本、运行状态、节点数量、出站数量。

---

## 1) 节点管理

```text
1) 新增节点
2) 查看节点 / 分享链接
3) 编辑节点
4) 删除节点
0) 返回
```

### 新增节点

输入协议编号，可单个创建，也可用空格或逗号多选批量创建，例如：

```text
1 3 10
```

创建单个节点时，按协议询问：

```text
节点名称 [JP-VLESS-Reality-Vision]:   ← 回车接受默认名称
监听端口（回车随机）:                  ← 回车自动分配空闲端口
SNI域名:                               ← TLS / REALITY 协议
回源端口 [443]:                        ← 仅 VLESS-Reality-Vision
```

批量创建时：

- 只输入一次共享 SNI 域名
- 只输入一次 REALITY 回源端口（如果选中 REALITY）
- 每个协议分别输入监听端口
- 节点名称自动生成，重名时追加 `-2`、`-3`

默认名称格式为“国家码-协议”，例如 `JP-VLESS-WS`。国家码由公网 IP 自动查询，失败时为 `XX`，可在“使用帮助”中刷新缓存。

### 编辑节点

- 不重新询问名称
- 端口、SNI、REALITY 回源端口直接回车保留原值
- 只有 VLESS-Reality-Vision 会额外询问是否重新生成 REALITY 密钥对
- 修改端口时会重新检查占用；保留原端口则跳过检查
- 所有 TLS 协议共用一套自签证书，修改 SNI 不会重新签发证书

### 删除节点

删除节点配置，同时清除该节点的出口绑定，并重新生成运行配置。

### 分享链接

- 节点创建完成后直接输出
- 主菜单 `6) 分享链接` 可一次查看全部节点
- 双栈环境每个节点输出两套链接，分别标记 `# IPv4` 和 `# IPv6`
- 只有一种协议栈时只输出一套

---

## 2) 出站管理

```text
1) 新增出站
2) 查看出站
3) 编辑出站
4) 删除出站
0) 返回主菜单
```

出站管理只负责“定义落地”；让某个节点走这个落地，要到主菜单 `3) 出口路由` 绑定。

### 新增出站

#### 粘贴分享链接

适用于把另一台服务器作为落地。支持：

```text
vless / vmess / trojan / hysteria2 / hy2 / tuic / ss / anytls
```

不支持：

- `socks://`、Snell：请用“手动填写”
- 带 `plugin` 的 Shadowsocks：会明确报错
- `grpc`、`h2`、`httpupgrade` 等暂不支持的传输：会明确报错
- IPv6 地址需要写成 `[2001:db8::1]:端口`

出站名称规则：

- 只能包含字母、数字、点、下划线、短横线
- 不能以点开头，不能叫 `direct`
- 不能与现有节点、出站或内部入站 tag 重名

#### 手动填写

```text
1) SOCKS5
2) HTTP 代理
3) Snell-v6
```

需要填写：

- 名称
- 服务器地址（IPv6 建议填裸地址，不带方括号）
- 服务器端口（SOCKS5/HTTP 默认 1080，Snell 默认 6160）
- SOCKS5/HTTP 用户名和密码（用户名留空表示无认证）
- Snell PSK（默认自动生成，12-255 字节，不能包含空格或逗号；需要 sing-box 1.14+）

#### 导入自定义 JSON

准备一个 JSON 文件，必须是单个对象，包含字符串类型的 `type` 和 `tag`。脚本校验名称合法且不冲突后，保存为 `/etc/sing-box/outbounds/<tag>.json`。

> 新增出站只写入出站文件，不会立即重启核心；到“出口路由”绑定节点时会统一生成配置并校验。

### 查看出站

列出 `direct` 和所有自定义出站；选择后可查看完整 JSON。

### 编辑出站

调用 `nano` / `vim` / `vi` 或 `$EDITOR` 打开出站 JSON。保存后自动校验：

- 必须是 JSON 对象
- 必须包含 `type` 和 `tag`
- 不允许修改 `tag`
- 配置校验失败会自动恢复原文件
- 核心运行时会询问是否重启

### 删除出站

删除出站文件，并自动清除所有引用该出站的节点绑定；这些节点回到直连。

### 链式落地示例

```text
设备 -> 服务器A(节点) -> 服务器B(节点) -> 目标网站
```

1. 在服务器 B 上建好节点，复制分享链接
2. 在服务器 A：`出站管理 → 新增出站 → 粘贴分享链接`
3. 在服务器 A：`出口路由 → 为节点绑定 / 修改出口`
4. 撤销：`出口路由 → 为节点取消 / 恢复直连`

多个节点可以分别指向不同落地，互不影响。本机自身流量始终直连。

---

## 3) 出口路由

```text
1) 查看节点出口
2) 为节点绑定 / 修改出口
3) 为节点取消 / 恢复直连
0) 返回
```

第 2、3 项都支持单选和多选节点。

输入格式：

```text
2                单个节点
1 3 5            多个节点
1,3,5            逗号分隔
1，3，5          中文逗号分隔
0                全部节点
直接回车         取消
```

节点列表会显示序号、节点名称、协议、当前出口。

- **第 2 项**：只列出真实自定义出站，不包含 `direct`；选择后批量设置所选节点的出口。
- **第 3 项**：清除所选节点的出口绑定，恢复直连；如果所选节点都已是直连，会直接提示。

---

## 4) 运行管理

```text
1) 启动核心
2) 停止核心
3) 重启核心
4) 查看日志
5) 查看运行状态
0) 返回
```

查看日志：

```text
1) 最近 100 行日志
2) 实时跟踪日志
3) systemd 日志（仅 systemd）
0) 返回
```

查看运行状态会显示：

- 核心版本、运行状态
- 节点数量、出站数量
- 公网 IPv4、公网 IPv6
- 当前监听地址和 `bindv6only` 状态
- 配置文件、日志文件
- 实际监听端口

---

## 5) 核心管理

```text
1) 更新核心
2) 卸载核心
3) 查看核心版本
0) 返回
```

- **更新核心**：查询 GitHub 最新版本并安装；如核心正在运行，更新后会尝试重启
- **卸载核心**：停止服务并删除核心；可选是否保留节点、证书和配置
- **查看版本**：执行 `sing-box version`

---

## 6) 分享链接

一次显示所有节点的分享链接。

- 普通协议输出标准分享链接
- Snell-v6 输出 Surge / Sub-Store 格式
- 双栈环境每个节点输出 IPv4、IPv6 两套
- 链接中的节点名称会加 `-v4` / `-v6` 后缀，避免两个链接重名

---

## 7) 使用帮助

```text
1) 查看使用帮助
2) 刷新公网 IP 与国家码缓存
0) 返回
```

刷新缓存会同时重新探测公网 IPv4、IPv6 和国家码。

---

## 协议支持

| 协议 | 传输 | 证书 | 用户输入 | 自动生成 |
|---|---|---|---|---|
| VLESS-Reality-Vision | TCP | 不需要（REALITY） | 名称、端口、SNI、回源端口 | UUID、short_id、REALITY 密钥对 |
| VLESS-WS | TCP | 需要 | 名称、端口、SNI | UUID、WS 路径 |
| Hysteria2 | UDP | 需要 | 名称、端口、SNI | 密码 |
| TUIC | UDP | 需要 | 名称、端口、SNI | UUID、密码 |
| Trojan | TCP | 需要 | 名称、端口、SNI | 密码 |
| Trojan-WS | TCP | 需要 | 名称、端口、SNI | 密码、WS 路径 |
| AnyTLS | TCP | 需要 | 名称、端口、SNI | 密码 |
| Shadowsocks-2022 | TCP+UDP | 不需要 | 名称、端口 | 32 字节 Base64 密钥 |
| VMess-WS | TCP | 需要 | 名称、端口、SNI | UUID、WS 路径 |
| Snell-v6 | TCP | 不需要 | 名称、端口 | PSK |
| SOCKS5 | TCP | 不需要 | 名称、端口 | 用户名 `user`、随机密码 |

协议版本要求：

- AnyTLS 需要 sing-box 1.12+
- Snell-v6 需要 sing-box 1.14+

> 显示名不带 `-TLS` 后缀，但 VLESS-WS、Trojan、Trojan-WS、VMess-WS、AnyTLS、Hysteria2、TUIC 实际都启用 TLS。去掉后缀是为了避免 Sub-Store 把 `TL` 识别成东帝汶国家码。

### 分享链接与出站导入

- 10 种协议生成标准分享链接；Snell-v6 输出 Surge 行
- 出站粘贴链接支持：`vless`、`vmess`、`trojan`、`hysteria2/hy2`、`tuic`、`ss`、`anytls`
- SOCKS5 与 Snell 不作为链接导入，使用“手动填写”
- 带 `plugin` 的 SS、未支持的传输类型会明确报错，不会生成错误配置

---

## IPv4 / IPv6 行为

启动时检测系统网络环境：

| 环境 | 节点监听 | 分享链接 |
|---|---|---|
| IPv6 被禁用 | `0.0.0.0` | 仅 IPv4 |
| 仅 IPv6 | `::` | 仅 IPv6 |
| 双栈，`bindv6only=0` | `::`（双栈） | IPv4 + IPv6 两套 |
| 双栈，`bindv6only=1` | `::` + 自动附加 `0.0.0.0` 入站 | IPv4 + IPv6 两套 |

说明：

- `bindv6only=1` 时，脚本为每个节点生成两个入站：主入站 `::`，附加 IPv4 入站 `<tag>-v4`，监听 `0.0.0.0`
- 路由规则会同时覆盖两个入站
- 公网 IPv4、IPv6 分别缓存到 `/etc/sing-box/server_ip4`、`server_ip6`
- 手动填写出站服务器时，IPv6 建议填裸地址，例如 `2001:db8::1`

---

## 数据目录

| 路径 | 说明 |
|---|---|
| `/etc/sing-box/config.json` | 合并后的运行配置 |
| `/etc/sing-box/nodes/` | 节点配置（含内部 `_meta`，生成运行配置时自动剥离） |
| `/etc/sing-box/outbounds/` | 自定义出站 |
| `/etc/sing-box/routes/` | 节点出口绑定 |
| `/etc/sing-box/cert/` | 自签证书与私钥 |
| `/etc/sing-box/log/` | 运行日志 |
| `/etc/sing-box/server_ip` | 主公网地址缓存 |
| `/etc/sing-box/server_ip4` | 公网 IPv4 缓存 |
| `/etc/sing-box/server_ip6` | 公网 IPv6 缓存 |
| `/etc/sing-box/server_country` | 国家码缓存 |
| `/etc/sing-box/sing-box.pid` | 无 systemd/OpenRC 时的后台进程 PID |
| `/usr/local/bin/sing-box` | 核心二进制 |
| `/etc/systemd/system/sing-box.service` | systemd 服务文件 |
| `/etc/init.d/sing-box` | OpenRC 服务文件 |

节点文件结构：

```json
{
  "type": "vless",
  "tag": "JP-VLESS-WS",
  "listen": "::",
  "listen_port": 443,
  "...": "其余 sing-box inbound 字段",
  "_meta": {
    "proto": "vless-ws",
    "pbk": "",
    "insecure": 1,
    "extra_inbounds": []
  }
}
```

生成 `config.json` 时会删除 `_meta`。

---

## 目录结构

```text
sing-box.sh                  模块化入口
build.sh                     单文件构建脚本
README.md                    项目说明
lib/
  modules.list               模块加载顺序
  base.sh                    常量、协议注册表、运行状态、交互输入
  protocols.sh               协议注册表访问层
  system.sh                  依赖安装、架构识别、核心下载、systemd/OpenRC
  config.sh                  原子配置合并与校验
  utils.sh                   随机值、公网 IP、国家码、编码工具
  runtime.sh                 启动/停止/重启、状态、日志
  node-common.sh             节点公共逻辑、端口、校验、证书、保存
  node-vless.sh              VLESS 系列
  node-quic.sh               Hysteria2、TUIC
  node-ss.sh                 Shadowsocks-2022
  node-trojan-vmess.sh       Trojan、VMess
  node-anytls-socks5.sh      AnyTLS、SOCKS5
  node-snell.sh              Snell-v6
  node-links.sh              节点详情与分享链接
  node-menu.sh               节点管理菜单
  outbound-common.sh         出站公共逻辑
  outbound-link.sh           分享链接解析（IPv4/IPv6、外部客户端变体）
  outbound-create.sh         出站手动创建
  outbound-menu.sh           出站管理菜单与出口路由
  core.sh                    核心更新/卸载/版本
  help.sh                    使用帮助
  menu.sh                    主菜单
  main.sh                    命令行参数与首次安装
dist/
  sing-box-oneclick.sh       构建产物（单文件版）
tests/
  run.sh                     离线测试套件入口
  common.sh                  测试框架（断言、沙箱、交互桩函数）
```

---

## 构建

修改 `lib/` 中的模块后执行：

```bash
bash build.sh
```

会重新生成 `dist/sing-box-oneclick.sh` 并自动执行语法校验。请保持 `lib/` 与 `dist/` 的同步提交。

不要直接编辑 `dist/sing-box-oneclick.sh`。

---

## 测试

```bash
bash tests/run.sh
```

全部用例在临时目录中运行，不会读写真实的 `/etc/sing-box`，也不需要 root。

覆盖范围：

| 分组 | 内容 |
|---|---|
| A | 协议注册表一致性（编号、显示名、传输类型、能力矩阵） |
| B | 端口、UUID、SNI、PSK、名称、国家码等校验 |
| C | URL 编解码与查询串解析 |
| D | 11 种协议的节点创建与 JSON 结构 |
| E | 分享链接生成 → 再解析的往返一致性 |
| F | 出站创建（SOCKS5 / HTTP / Snell / 自定义 JSON） |
| G | 配置合并（inbounds / outbounds / 路由规则） |
| H | 路由绑定、单选/多选改直连、删除出站后的清理 |
| I | 错误处理与回归用例 |
| J | 单节点/批量创建、传输矩阵、外部链接变体、原子配置 |
| K | IPv4/IPv6 环境自适应（监听地址、附加 IPv4 入站、双栈链接） |

当前共 289 条断言。依赖 `jq >= 1.6`、`openssl`、`base64`。修改 `lib/` 后建议先跑测试再构建。

---

## 注意事项

- 需要 root 权限运行，bash 4.0 及以上
- 当前节点数据格式与旧版 `.meta` 格式不兼容；升级后需要重新创建节点
- 所有需要证书的节点共用同一套自签证书，客户端需开启「允许不安全连接 / allowInsecure」
- Hysteria2、TUIC 只使用 UDP；Shadowsocks-2022 同时监听 TCP 和 UDP，请在安全组和防火墙中同时放行
- 双栈环境会同时输出 IPv4/IPv6 两套链接；`bindv6only=1` 会增加一个 IPv4 入站
- 批量创建会查询公网 IP 国家码；如国家码不准，可在「使用帮助」中刷新缓存
- 新增出站只有绑定到节点后才会影响流量
- 本机自身流量不受出口路由影响，始终直连
- AnyTLS 需要 sing-box 1.12+；Snell-v6 需要 sing-box 1.14+
- Snell-v6 无需证书，分享页输出 Surge 格式：
  `节点名 = snell, 服务器, 端口, psk=密钥, version=6, mode=default, reuse=false`
- Sub-Store 不支持 `snell://` 作为输入；输出 sing-box 时使用
  `target=sing-box&includeUnsupportedProxy=true`
- Shadowsocks-2022 使用 32 字节 Base64 密钥
- 出站 TLS 客户端默认 `insecure=true`，用于兼容对端常见的自签证书
