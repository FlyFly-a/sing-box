# sing-box

Install the latest stable sing-box on Debian, Ubuntu, or Alpine. Supports systemd, OpenRC, and background mode for containers without an init system.

| Protocol | Port |
| --- | --- |
| VLESS + REALITY + XTLS Vision | tcp |
| Trojan | tcp |
| AnyTLS | tcp |
| Hysteria 2 | udp |
| TUIC v5 | udp |
| Snell v5 (v4-compatible clients) | tcp |
| Snell v6 | tcp |

REALITY uses the manually configured SNI for handshake masking.
Trojan, AnyTLS, Hysteria2, and TUIC use the manually configured SNI with a self-signed certificate; clients skip verification where needed.

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
