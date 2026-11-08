# sing-box 一键部署管理脚本（模块化版）

自动识别 Linux 系统架构、安装依赖与 sing-box 核心，并通过菜单管理多协议节点、出站和运行状态。

## 快速使用

### 方式一：单文件版（推荐部署）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/FlyFly-a/sing-box/main/dist/sing-box-oneclick.sh)
```

单文件版可以直接上传到服务器运行，无需携带 `lib/` 目录。

### 方式二：模块化源码版

```bash
bash sing-box.sh
```

模块化入口会按 `lib/modules.list` 的顺序加载模块，适合阅读、修改和扩展。

### 命令行参数

```bash
bash sing-box.sh install   # 安装/更新核心并写入 systemd 服务
bash sing-box.sh status    # 查看运行状态
bash sing-box.sh help      # 查看用法
```

## 构建单文件版

修改 `lib/` 中的任意模块后执行：

```bash
bash build.sh
```

将重新生成 `dist/sing-box-oneclick.sh`，并自动执行语法校验。

## 目录结构

```text
sing-box.sh                       模块化入口
build.sh                          单文件构建脚本
lib/
  modules.list                    模块加载顺序
  00-base.sh                      常量、颜色、交互输入、权限检测
  10-system.sh                    依赖安装、架构识别、核心下载、systemd
  20-config.sh                    目录初始化、config.json 合并生成与校验
  25-utils.sh                     UUID/密钥生成、公网 IP、URL 编码
  30-runtime.sh                   启动/停止/重启、状态、日志
  40-node-common.sh               节点通用逻辑、端口检查、证书处理
  41-node-vless.sh                VLESS 全系列
  42-node-quic.sh                 Hysteria2、TUIC
  43-node-ss.sh                   Shadowsocks、SS2022、ShadowTLS
  44-node-trojan-vmess.sh         Trojan、VMess
  45-node-misc.sh                 AnyTLS、SOCKS5
  50-node-links.sh                节点详情与分享链接
  51-node-menu.sh                 节点管理菜单
  60-outbound-common.sh           出站公共逻辑（tag、端口、TLS、传输）
  61-outbound-create.sh           各协议出站创建
  62-outbound-menu.sh             出站查看/删除/编辑/切换菜单
  70-core.sh                      核心更新/卸载/版本
  71-runtime-menu.sh              运行管理菜单
  80-help.sh                      使用帮助
  90-menu.sh                      主菜单与状态栏
  99-main.sh                      命令行参数与首次安装引导
dist/
  sing-box-oneclick.sh            构建产物（单文件版）
```

## 功能

- 节点管理：新增、删除、编辑、查看
- 出站管理：新增、删除、编辑、更改默认出站、查看
- 运行管理：启动、停止、重启、查看日志、查看运行状态
- 核心管理：更新核心、卸载核心、查看核心版本
- 使用帮助与公网 IP 刷新

## 支持的节点协议

VLESS-REALITY、VLESS-Vision-TLS、VLESS-TLS、VLESS-gRPC-TLS、VLESS-WS-TLS、VLESS-HTTPUpgrade-TLS、Hysteria2-QUIC、TUIC-QUIC、Shadowsocks-AEAD、Shadowsocks-2022-128、Shadowsocks-2022-256、Shadowsocks-ShadowTLS、Trojan-TLS、Trojan-gRPC-TLS、Trojan-WS-TLS、VMess-TCP、VMess-TCP-TLS、VMess-WS-TLS、VMess-gRPC-TLS、AnyTLS-TLS、SOCKS5。

## 数据目录

```text
/etc/sing-box/
  config.json            合并后的运行配置
  nodes/                 节点 JSON 与元数据
  outbounds/             自定义出站 JSON
  cert/                  TLS 证书与私钥
  log/sing-box.log       运行日志
  final_outbound         默认出站标记
```

## 注意事项

- 需要 root 权限运行。
- TLS 类协议需要域名证书；可让脚本生成自签证书，但客户端必须允许不安全连接。
- AnyTLS 需要 sing-box 1.12 及以上版本。
- Shadowsocks-2022 的密码必须是 16 或 32 字节 Base64 密钥。
- Hysteria2、TUIC 使用 UDP 端口，请在安全组和防火墙中放行 UDP。
- 单文件版由 `build.sh` 生成，请修改 `lib/` 源码而不是直接编辑构建产物。
