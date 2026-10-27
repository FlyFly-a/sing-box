# sing-box

Install the latest stable sing-box on Debian, Ubuntu, or Alpine. Supports systemd, OpenRC, and background mode for containers without an init system.

| Protocol | Port |
| --- | --- |
| VLESS + REALITY + XTLS Vision | 39001/tcp |
| Trojan | 39002/tcp |
| AnyTLS | 39003/tcp |
| Snell v5 (v4-compatible clients) | 39004/tcp |
| Snell v6 | 39005/tcp |


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
