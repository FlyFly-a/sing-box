# sing-box 一键部署管理脚本

自动识别 Linux 系统架构与运行环境，安装依赖和 sing-box 核心，并通过交互式菜单管理多协议节点、出站和运行状态。

## 特性

- **一键部署**：自动识别架构、安装依赖、下载核心并注册系统服务
- **静态核心**：优先使用官方 musl 静态构建，兼容 Alpine 和旧 glibc 系统
- **多系统支持**：systemd 与 OpenRC 双服务后端
- **21 种节点协议**：覆盖 VLESS、Hysteria2、TUIC、Shadowsocks、Trojan、VMess、AnyTLS、SOCKS5
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
curl -fsSL https://raw.githubusercontent.com/FlyFly-a/sing-box/main/dist/sing-box-oneclick.sh
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
| 节点管理 | 新增节点、删除节点、编辑节点、查看节点 |
| 出站管理 | 新增出站、删除出站、编辑出站、更改默认出站、查看出站 |
| 运行管理 | 启动核心、停止核心、重启核心、查看日志、查看运行状态 |
| 核心管理 | 更新核心、卸载核心、查看核心版本 |
| 使用帮助 | 证书、防火墙、客户端配置与常见问题 |

## 支持协议

| 分类 | 协议 |
|---|---|
| VLESS | REALITY、Vision-TLS、TLS、gRPC-TLS、WS-TLS、HTTPUpgrade-TLS |
| Hysteria2 / TUIC | Hysteria2-QUIC、TUIC-QUIC |
| Shadowsocks | AEAD、2022-128、2022-256、ShadowTLS |
| Trojan | TLS、gRPC-TLS、WS-TLS |
| VMess | TCP、TCP-TLS、WS-TLS、gRPC-TLS |
| 其他 | AnyTLS-TLS、SOCKS5 |

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
  node-common.sh             节点通用逻辑、端口检查、证书处理
  node-vless.sh              VLESS 系列
  node-quic.sh               Hysteria2、TUIC
  node-ss.sh                 Shadowsocks、SS2022、ShadowTLS
  node-trojan-vmess.sh       Trojan、VMess
  node-misc.sh               AnyTLS、SOCKS5
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
| `/usr/local/bin/sing-box` | 核心二进制 |

## 注意事项

- 需要 root 权限运行。
- TLS 类协议需要域名证书；自签证书在客户端需开启“允许不安全连接”。
- Hysteria2、TUIC 使用 UDP 端口，请在安全组和防火墙中放行 UDP。
- AnyTLS 需要 sing-box 1.12 及以上版本。
- Shadowsocks-2022 的密码必须是 16 或 32 字节 Base64 密钥。
- 核心优先使用官方 musl 静态版，Alpine 和旧 glibc 系统无需额外安装 `gcompat`。
- Alpine 极简系统需要 bash 和 curl，可先执行 `apk add --no-cache bash curl`。
- `dist/sing-box-oneclick.sh` 由 `build.sh` 生成，请修改 `lib/` 源码而不是直接编辑构建产物。
