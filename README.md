# sing-box

Install the latest stable sing-box on Debian, Ubuntu, or Alpine. Supports systemd, OpenRC, and background mode for containers without an init system.

| Protocol | Port |
| --- | --- |
| VLESS + REALITY + XTLS Vision | 39001/tcp |
| Trojan | 39002/tcp |
| AnyTLS | 39003/tcp |
| Hysteria 2 | 39004/udp |
| TUIC v5 | 39005/udp |
| Snell v5 (v4-compatible clients) | 39006/tcp |
| Snell v6 | 39007/tcp |

REALITY, Hysteria2, and TUIC all use `www.tencentcloud.com` as the SNI. Hysteria2 and TUIC use a self-signed certificate, so clients skip certificate verification.

## Install

Run as root

```sh
curl -fsSL https://raw.githubusercontent.com/FlyFly-a/sing-box/main/sb.sh -o sb.sh && sh sb.sh
```

## Usage

```sh
sh sb.sh --show       # Show addresses, client links, and credentials
sh sb.sh --uninstall  # Stop and remove the installation
```
