# sing-box 部署与节点管理

在 Linux 服务器上安装 sing-box，通过中文菜单创建节点、生成客户端配置、管理中转出口和运行服务。

支持 11 种节点预设。**VLESS-WS、Trojan-WS、VMess-WS 均可选择直连或 Cloudflare CDN**，向导分别设置连接地址、端口、证书和 WebSocket 路径。

已完成的检查和待验证的 Linux 服务、CDN 实机测试见 [验证记录](docs/VALIDATION.md)。

## 快速开始

以 root 身份在已具备 Bash 和 curl 的 Linux 服务器上执行。首次运行会检查依赖，按提示确认安装依赖和官方核心，然后引导创建节点并询问是否启动服务：

```bash
curl -fsSL https://raw.githubusercontent.com/FlyFly-a/sing-box/main2/dist/sing-box-oneclick.sh \
  -o /usr/local/bin/sb && chmod 700 /usr/local/bin/sb && sb
```

之后随时执行下面的命令打开管理菜单：

```bash
sb
```

也可以不保存文件，直接运行单文件版本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/FlyFly-a/sing-box/main2/dist/sing-box-oneclick.sh)
```

如果使用源码运行：

```bash
git clone https://github.com/FlyFly-a/sing-box.git
cd sing-box
bash sing-box.sh
```

## 功能一览

| 功能 | 可以做什么 |
|---|---|
| 核心安装与更新 | 识别架构，下载固定版本的官方核心，检查 SHA256，失败时保留或恢复旧核心 |
| 节点管理 | 创建、编辑、删除节点；自动生成 UUID、密码和密钥；支持多协议批量创建 |
| WS 直连 / CDN | 三种 WS 协议共用向导；CDN 使用业务域名、HTTPS 端口及对应源站证书 |
| 每节点证书 | 导入公开证书、Cloudflare Origin CA，或为直连生成自签证书；检查域名、有效期、私钥及信任链 |
| 客户端配置 | 导出分享链接、Snell Surge 配置行、完整 sing-box 客户端 JSON、公开证书 |
| 中转与出口 | 手工创建出站、导入链接或 JSON；多个节点绑定出口；配置出站之间的 detour 链路 |
| IPv4 / IPv6 | 自动选择监听方式；可指定双监听、回环监听和备用连接地址 |
| DDNS | 用域名替代直连节点的分享地址；DNS 更新由自己的 DDNS 服务负责 |
| 服务管理 | 启动、停止、重启、查看状态；支持 systemd、OpenRC 和后台进程模式 |
| 配置保存 | 整批校验后统一保存；运行中的服务自动应用修改，失败时尝试恢复上一版 |
| 排错与维护 | 核心检查、前台调试、管理日志、资源诊断、保留配置卸载或完整卸载 |

## 开始前准备

- 一台 Linux 服务器和 root 权限，知道它的公网 IP 或连接域名。
- 根据协议开放服务器防火墙和云平台安全组端口；NAT 环境还需设置公网到服务器的端口映射。
- 使用普通 TLS 协议时准备证书，或选择自签并在客户端导入信任。使用 CDN 时需要自己管理的域名。

依赖：Bash 4+、jq 1.6+、支持 `-addext` / `-checkhost` 的 OpenSSL（通常 1.1.1+），以及 curl、tar、gzip、mkfifo、tee、sha256sum。`deps` 会调用发行版包管理器安装依赖。

| 系统系列 | 依赖安装方式 |
|---|---|
| Debian / Ubuntu | apt |
| Alpine | apk |
| Fedora / RHEL 系列 | dnf / yum |
| openSUSE | zypper |
| Arch Linux | pacman |

核心按架构选择官方资产，包括 amd64、arm64、386、ARM 等；实际可用性取决于该版本是否提供对应资产。安装器不会自动换用第三方核心。

## 安装并创建第一个节点

### 1. 运行脚本

如果已经按上面的快速开始安装，可直接执行 `sb`。手动上传单文件时，以 root 执行：

```bash
cd /root
bash sing-box-oneclick.sh
```

脚本会检查依赖，缺少时询问是否安装；没有核心时引导安装官方核心；没有节点时进入创建向导，保存后询问是否启动服务。已有节点时直接进入管理菜单。创建过程中输入 `q` 可取消并回到菜单。

也可在源码目录中用 `bash sing-box.sh` 执行。单文件支持 `bash <(curl …)` 和 `curl … | bash`；交互菜单会从终端读取输入，无交互终端时请指定子命令。脚本会完整读取自身内容后再运行，安装后的管理入口不依赖下载流。

需要分步执行或自动化时，可使用：

```bash
bash sing-box-oneclick.sh help       # 查看帮助，不执行安装
bash sing-box-oneclick.sh deps       # 安装依赖，需确认
bash sing-box-oneclick.sh install    # 安装官方核心，并保存管理脚本
```

当前固定核心版本为 **1.14.4**；`install` 安装脚本指定版本，不追踪最新版本。

安装完成后，统一用下面的入口打开菜单：

```bash
bash /etc/sb-manager/manager.sh
```

`help` 不安装任何内容。单独执行 `install` 只安装核心和管理入口；无参数启动脚本才会进入连续引导。空配置不会自动启动。

### 2. 选择协议并填写参数

主菜单与实际脚本一致：

```text
1 创建节点
2 查看节点和连接信息
3 修改或删除节点
4 设置中转和出口
5 服务状态与故障检查
6 核心与脚本管理
7 使用帮助
0 退出
```

进入 **1 创建节点**，选择协议编号。填写参数后检查预览，输入 `yes` 保存。成功后会显示新节点的分享信息。

| 编号 | 协议 | 需要放行 | 创建时的主要专用参数 | CDN |
|---|---|---|---|---|
| 1 | VLESS-Reality-Vision | TCP | REALITY SNI、握手目标地址和端口 | — |
| 2 | VLESS-WS | TCP | 直连/CDN、证书、WS 路径 | 支持 |
| 3 | Hysteria2 | UDP | TLS 域名、证书 | — |
| 4 | TUIC | UDP | TLS 域名、证书 | — |
| 5 | Trojan | TCP | TLS 域名、证书 | — |
| 6 | Trojan-WS | TCP | 直连/CDN、证书、WS 路径 | 支持 |
| 7 | AnyTLS | TCP | TLS 域名、证书 | — |
| 8 | Shadowsocks-2022 | TCP + UDP | 自动生成 32 字节 Base64 密钥 | — |
| 9 | VMess-WS | TCP | 直连/CDN、证书、WS 路径 | 支持 |
| 10 | Snell-v6 | TCP | 自动生成 PSK | — |
| 11 | SOCKS5 | TCP | 自动生成认证密码，用户名为 `user` | — |

所有节点均需名称、连接地址和端口。名称只能使用字母、数字、点、下划线、短横线，以字母或数字开头；它也是后续命令中的节点 ID，例如 `home-ws`。SOCKS5 虽有认证，但传输本身不加密。

**输入规则：**回车接受提示中的默认值，`q` 取消，`0` 在提供该选项的菜单中返回。多选协议用 `2 6 9` 或 `2,6,9`，每个节点分别填写，最后整批保存；任意节点取消或校验失败，整批不保存。

### 3. 启动服务并导入客户端

首次引导保存节点后，按提示输入 `yes` 即可启动。若选择暂不启动，可进入 **5 服务状态与故障检查 → 1 启动**，或退出菜单执行：

```bash
bash /etc/sb-manager/manager.sh start
bash /etc/sb-manager/manager.sh status
```

将创建时的链接导入支持该协议的客户端。也可随时进入 **2 查看节点和连接信息 → 1 分享单个/全部** 重新获取。

需要完整 sing-box 客户端配置时，在服务器导出后传到客户端设备：

```bash
umask 077
bash /etc/sb-manager/manager.sh client-config home-ws > home-ws-client.json
```

导出的配置在客户端监听 `127.0.0.1:2080`，提供 HTTP/SOCKS 混合代理；它不会自动开启系统代理或 TUN。使用节点第一个连接地址，自签节点会带上证书信任配置。链接和 JSON 都含认证信息。

## WS 走 CDN：完整示例

以 **VLESS-WS + Cloudflare + 443** 为例，Trojan-WS 和 VMess-WS 操作相同。

### 先准备 Cloudflare 和证书

1. 使用自己管理的域名，例如 `proxy.example.com`，将其 DNS 记录指向源站，开启代理（橙云）。
2. 开启 WebSocket，SSL/TLS 使用 **Full (strict)**；边缘 HTTPS 证书需已可用。
3. 准备覆盖该域名的公开可信完整证书链，或从 Cloudflare 获取 Origin CA 源站证书及对应私钥，保存到服务器。
4. 确认源站 TCP 443 可供 sing-box 监听且允许 CDN 回源；如果已有网站占用 443，先规划其他受支持端口或反向代理。

这里假设证书和私钥已分别保存为 `/root/origin.pem`、`/root/origin.key`。这两个文件要由你准备，脚本不会自动申请证书。

### 在创建向导中这样填写

进入 **1 创建节点 → 2 VLESS-WS**：

| 提示 | 示例填写 |
|---|---|
| 节点名称 | `home-ws` |
| 连接方式 | `2`，Cloudflare CDN |
| CDN 业务域名 | `proxy.example.com` |
| 客户端连接 CDN 的 HTTPS 端口 | `443` |
| 服务端监听端口 | `443` |
| 展开监听范围和备用连接地址 | 回车，使用默认监听 |
| 证书类型 | `2`，Cloudflare Origin CA；公开可信证书则选 `1` |
| 完整证书链 PEM 路径 | `/root/origin.pem` |
| 未加密私钥 PEM 路径 | `/root/origin.key` |
| WebSocket 路径 | `/my-ws`，或回车接受随机路径 |
| 保存确认 | `yes` |

CDN 模式自动将客户端地址、SNI 和 WS Host 设为 `proxy.example.com`，无需另填 `apple.com` 等其他域名。

```text
客户端 → proxy.example.com:443（CDN 边缘）→ 源站:443 → sing-box
          验证边缘证书                    验证源站证书
```

保存后启动服务、导入客户端，并实际访问验证。脚本校验的是配置和证书，不能代替 DNS、CDN 回源及公网连通测试。

### CDN 端口和源站端口怎么选

向导接受 `443 / 2053 / 2083 / 2087 / 2096 / 8443` 作为 Cloudflare HTTPS 连接端口。**没有设置端口映射时，保持 CDN 端口和源站监听端口一致。**

例如希望客户端连接 CDN 的 443，而 sing-box 监听 27301，必须先通过 Origin Rule、NAT 或反向代理完成转发；仅在脚本里填 27301 不会建立映射。反向代理还需正确转发 WebSocket 和路径，当前脚本不会替你配置它。

多个 WS 节点不能直接复用同一监听端口。按路径共用 443 需要自行部署反向代理。当前向导仅提供 Cloudflare Full (strict) 方案，不提供 Flexible 或明文回源模式。

## 直连、SNI 与证书

| 参数 | 含义 | 示例 |
|---|---|---|
| 客户端连接地址 | 客户端实际连接的公网 IP、域名或裸 IPv6 | `192.0.2.10` |
| 服务端监听端口 | sing-box 在服务器上监听的端口 | `24443` |
| 客户端连接端口 | 公网端口；无 NAT 时通常与监听端口相同 | `24443` |
| TLS SNI | 客户端预期的证书域名，必须匹配证书 | `proxy.example.com` |
| WS Host | WebSocket 请求的 HTTP Host | 通常与证书域名一致 |
| WS 路径 | 客户端和源站必须一致的路径 | `/my-ws` |

TLS 直连可以使用公开可信证书，或选择 `3` 生成节点专属自签证书。自签节点建议使用上面的客户端 JSON 导出；其他客户端需要单独导入信任证书：

```bash
bash /etc/sb-manager/manager.sh certificate home-ws > home-ws-cert.pem
```

分享链接不会跳过证书验证，因此“导入自签节点链接”本身不等于客户端已信任证书。Cloudflare Origin CA 只用于 CDN 回源，不能用于普通直连。

**REALITY 是单独的创建流程**：SNI 和目标地址用于 REALITY 握手，需要你选择满足该协议要求的握手目标；它不是给普通 TLS 节点随便填写第三方域名的替代方案。

## 常用操作

| 需要做什么 | 菜单位置 / 操作说明 |
|---|---|
| 修改地址、端口、WS 路径 | **3 修改或删除节点 → 输入节点名 → 1 修改** |
| 替换续期证书 | 编辑节点，选择替换证书并输入新 PEM 路径 |
| 更换 UUID / 密码 / 密钥 | 编辑节点，最后选择重新生成认证信息；随后重新导入客户端 |
| 删除节点 | **3 修改或删除节点 → 输入节点名 → 2 删除** |
| 新增或编辑出口 | **4 设置中转和出口 → 1 新增 / 2 修改** |
| 给多个节点绑定出口 | **4 → 4 绑定节点**，填写节点名列表或 `all` |
| 恢复直接访问目标 | **4 → 5 恢复直连**，选择节点 |
| 设置 DDNS 分享域名 | **2 查看节点和连接信息 → 2 设置 DDNS 分享域名** |
| 启动、停止、重启、排错 | **5 服务状态与故障检查** |
| 安装指定核心、卸载、查看版本 | **6 核心与脚本管理** |

服务运行时，成功保存修改会自动重启应用；服务原本停止则保持停止。更换连接参数或认证信息后，需要重新获取客户端配置。证书是导入时保存的副本，替换磁盘上的 PEM 文件不会自动续期节点证书。

中转示例：在服务器 A 添加服务器 B 的出站，再把 A 的入站节点绑定到它，流量成为“客户端 → A → B → 目标网站”。具体操作、DDNS、IPv6、更新卸载和完整命令见 [使用手册](docs/USAGE.md)。

## 常见问题

**填 SNI 后为什么没有走 CDN？**

SNI 只说明 TLS 预期域名。需要在 WS 向导选择 CDN，并完成自己域名的代理、证书及回源设置；不能只把 SNI 改成 `apple.com`。

**配置保存了，客户端仍无法连接？**

先检查 `status` 和 `check`，再核对服务是否启动、TCP/UDP 安全组、NAT、客户端端口和证书信任。CDN 还需核对代理状态、边缘证书、Full (strict)、源站证书及回源端口。详细步骤见 [故障排查](docs/USAGE.md#故障排查)。

**服务器重启后会自动运行吗？**

默认部署在 systemd/OpenRC 下注册并启用服务。后台进程模式不提供开机自启，需要自己配置启动方式。实际系统启动行为仍应在部署机验证。

**配置和证书保存在哪里？**

默认存放于 `/etc/sb-manager`，其中包含节点认证信息和证书私钥。文件布局见 [架构文档](docs/ARCHITECTURE.md)，卸载保留配置与清理数据的区别见 [使用手册](docs/USAGE.md#卸载)。

## 项目文档与开发

- [使用手册](docs/USAGE.md)：中转、链式出站、DDNS、IPv6、服务维护、完整命令与排错。
- [架构与状态格式](docs/ARCHITECTURE.md)：模块边界、JSON 格式、事务和证书信任。
- [验证记录](docs/VALIDATION.md)：已执行测试和未覆盖的实机验证。

源码在 `src/`，`sing-box.sh` 是模块入口，`dist/sing-box-oneclick.sh` 是单文件产物。修改源码后执行 `bash build.sh`。测试命令与环境说明见验证记录和源码测试目录。
