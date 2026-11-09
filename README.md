# sing-box 一键部署管理脚本

自动识别 Linux 系统架构与运行环境，安装依赖和 sing-box 核心，并通过交互式菜单管理多协议节点、出站和运行状态。

## 特性

- **一键部署**：自动识别架构、安装依赖、下载核心并注册系统服务
- **静态核心**：优先使用官方 musl 静态构建，兼容 Alpine 和旧 glibc 系统
- **多系统支持**：systemd 与 OpenRC 双服务后端
- **11 种常用节点协议**：覆盖 VLESS、Hysteria2、TUIC、Trojan、AnyTLS、Shadowsocks、VMess、Snell、SOCKS5
- **批量创建**：一次多选协议，按 IP 国家码 + 协议自动命名
- **自动命名**：单节点新增时默认填充“国家码-协议”，可直接回车或手动修改
- **节点级分流**：可为指定节点或协议绑定不同出站，例如 AnyTLS-TLS → HK、Hysteria2 → UK
- **自动分享链接**：节点创建完成后直接输出新节点的分享链接
- **一键查看链接**：主菜单直接查看全部节点的分享链接
- **完整管理菜单**：节点、出站、运行、核心四套管理功能
- **模块化源码**：协议、菜单和服务逻辑拆分到独立模块，另提供单文件构建版

## 系统支持

| 系统 | 包管理 | 服务管理 |
|---|---|---|
| Ubuntu / Debian | apt | systemd |
| CentOS / RHEL / Rocky / AlmaLinux / Fedora | yum / dnf | systemd |
| Alpine Linux | apk | OpenRC |
| openSUSE | zypper | systemd |
| Arch Linux | pacman | systemd |

支持 x86_64、aarch64、armv7、armv6、i386、riscv64、s390x、ppc64le 等架构，并会识别 32 位用户态环境。

## 快速开始

### 一键安装

以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/FlyFly-a/sing-box/main/dist/sing-box-oneclick.sh \
  -o /usr/local/bin/sb
chmod +x /usr/local/bin/sb
sb
```

之后随时执行 `sb` 打开管理菜单。

### 从源码运行

```bash
git clone https://github.com/FlyFly-a/sing-box.git
cd sing-box
bash sing-box.sh
```

也可以直接运行已构建的单文件版：

```bash
bash dist/sing-box-oneclick.sh
```

### 命令行参数

```bash
bash sing-box.sh install   # 安装/更新核心并注册系统服务
bash sing-box.sh status    # 查看运行状态
bash sing-box.sh help      # 查看用法
```

## 功能菜单

| 菜单 | 功能 |
|---|---|
| 节点管理 | 新增节点（支持多选批量）、删除节点、编辑节点、查看节点 |
| 出站管理 | 新增出站、删除出站、编辑出站、更改出站（默认/节点分流）、查看出站 |
| 运行管理 | 启动核心、停止核心、重启核心、查看日志、查看运行状态 |
| 核心管理 | 更新核心、卸载核心、查看核心版本 |
| 分享链接 | 一次显示全部节点的分享链接或客户端配置 |
| 使用帮助 | 证书、防火墙、客户端配置与常见问题 |

### 批量创建

节点管理 → 新增节点，在协议编号提示处直接输入多个编号，用空格或逗号分隔：

```text
请选择协议: 1 3 10
```

- 输入一个编号进入单节点向导；输入多个编号进入批量创建，不会重复显示协议列表
- 单节点新增和批量创建都会询问监听端口，直接回车使用随机监听端口；编辑节点时直接回车保留原端口
- TLS 节点与 REALITY 共用同一个伪装域名，创建时统一输入，不使用固定默认值
- REALITY 回源端口单独询问，默认 443
- TLS 节点统一自动使用同一个随机命名的自签证书，所有需要证书的协议自动复用
- UUID、密码、PSK 和传输路径自动生成
- 节点按“两位国家码-协议”命名，例如 `JP-VLESS-Reality-Vision`、`GB-Hysteria2`、`SG-AnyTLS-TLS`
- 国家码来自服务器公网 IP，可在创建时手动修改
- 查询失败时显示 `XX`，可直接输入两位国家码，例如 `JP`、`US`、`SG`
- 单节点新增时也会默认填充该名称，直接回车即可接受，也可以手动改名

### 节点出站分流

出站管理 → 更改出站 / 节点分流

| 选项 | 功能 |
|---|---|
| 设置默认出站 | 未单独分配出站的节点使用该出站 |
| 为指定节点分配出站 | 精确到某一个节点 |
| 按协议批量分配出站 | 同一协议的所有节点统一使用某个出站 |
| 查看节点出站分配 | 查看每个节点当前使用的出站 |
| 清除节点出站分配 | 清除单个或全部绑定，恢复默认出站 |

例如：

- `AnyTLS-TLS` 节点 → `HK` 出站
- `Hysteria2` 节点 → `UK` 出站
- 其他节点 → 默认出站

## 支持协议

| 分类 | 协议 |
|---|---|
| VLESS | VLESS-Reality-Vision、VLESS-WS-TLS |
| Hysteria2 / TUIC | Hysteria2、TUIC |
| Trojan | Trojan-TLS、Trojan-WS-TLS |
| Shadowsocks | Shadowsocks-2022 |
| VMess | VMess-WS-TLS |
| 其他 | AnyTLS-TLS、Snell-v6、SOCKS5 |

## 目录结构

```text
sing-box.sh                  模块化入口
build.sh                     单文件构建脚本
README.md                    项目说明
lib/
  modules.list               模块加载顺序
  base.sh                    常量、颜色、交互输入、权限检测
  system.sh                  依赖安装、架构识别、核心下载、systemd/OpenRC
  config.sh                  目录初始化、配置合并与校验
  utils.sh                   密钥生成、公网 IP、URL 编码
  runtime.sh                 启动/停止/重启、状态、日志
  node-common.sh             节点通用逻辑、监听端口检查、证书处理
  node-vless.sh              VLESS 系列
  node-quic.sh               Hysteria2、TUIC
  node-ss.sh                 Shadowsocks-2022
  node-trojan-vmess.sh       Trojan、VMess
  node-anytls-socks5.sh      AnyTLS、SOCKS5
  node-snell.sh              Snell-v6
  node-links.sh              节点详情与分享链接
  node-menu.sh               节点管理菜单
  outbound-common.sh         出站公共逻辑
  outbound-create.sh         各协议出站创建
  outbound-menu.sh           出站管理菜单
  core.sh                    核心更新/卸载/版本
  runtime-menu.sh            运行管理菜单
  help.sh                    使用帮助
  menu.sh                    主菜单与状态栏
  main.sh                    命令行参数与首次安装引导
dist/
  sing-box-oneclick.sh       构建产物（单文件版）
```

## 构建

修改 `lib/` 中的模块后执行：

```bash
bash build.sh
```

会重新生成 `dist/sing-box-oneclick.sh` 并自动执行语法校验。请保持 `lib/` 与 `dist/` 的同步提交。

## 数据目录

| 路径 | 说明 |
|---|---|
| `/etc/sing-box/config.json` | 合并后的运行配置 |
| `/etc/sing-box/nodes/` | 节点配置与元数据 |
| `/etc/sing-box/outbounds/` | 自定义出站 |
| `/etc/sing-box/cert/` | TLS 证书与私钥 |
| `/etc/sing-box/log/` | 运行日志 |
| `/etc/sing-box/routes/` | 节点级出站绑定 |
| `/etc/sing-box/server_country` | 公网 IP 国家码缓存 |
| `/usr/local/bin/sing-box` | 核心二进制 |

## 注意事项

- 需要 root 权限运行。
- 所有需要证书的节点共用同一个随机命名的自签证书；客户端需开启“允许不安全连接”。
- Hysteria2、TUIC 使用 UDP 端口，请在安全组和防火墙中放行 UDP。
- REALITY 默认回源端口为 443，新增节点时可自定义。
- 批量创建会查询公网 IP 国家码；如国家码不准，可在“使用帮助”中刷新缓存。
- 出站列表中的 `direct` 是内置直连，仅用于切换默认出站，无需重复新增。
- AnyTLS 需要 sing-box 1.12 及以上版本。
- Snell-v6 需要 sing-box 1.14 及以上版本，无需证书；没有标准分享链接，分享页会输出 Surge 配置和 sing-box 出站 JSON。
  Surge 格式：`节点名 = snell, 服务器, 端口, psk=密钥, version=6, reuse=true`。
- Shadowsocks-2022 的密码必须是 16 或 32 字节 Base64 密钥。
- 核心优先使用官方 musl 静态版，Alpine 和旧 glibc 系统无需额外安装 `gcompat`。
- Alpine 极简系统需要 bash 和 curl，可先执行 `apk add --no-cache bash curl`。
- `dist/sing-box-oneclick.sh` 由 `build.sh` 生成，请修改 `lib/` 源码而不是直接编辑构建产物。
