# TUIC One-Click Installer

This repository provides `install-tuic.sh`, a one-click installer for:

- Latest stable TUIC server release from GitHub
- Dual-stack listener (`[::]:443` by default)
- HTTPS frontend on TCP/443 via Nginx or Caddy
- ACME certificate issuance/renewal with shared cert for TUIC + frontend
- Firewall automation (`ufw`, `firewalld`, or `iptables/ip6tables` fallback)

## Quick start

Run as root on a supported distro:

- Ubuntu 22.04/24.04
- Debian 12
- CentOS/RHEL-family (systemd-based)

```bash
sudo ./install-tuic.sh \
  --domain example.com \
  --email admin@example.com \
  --non-interactive
```

## CLI options

```text
--domain <fqdn>
--email <email>
--port-udp <port>        (default: 443)
--https-front <nginx|caddy> (default: nginx)
--site-root <path>       (default: /var/www/https-front)
--repo <owner/repo>      (default: Itsusinn/tuic)
--non-interactive
--update
--upgrade-core           upgrade only the TUIC server binary
--status                 show TUIC/frontend service status
--restart                restart TUIC and the configured HTTPS frontend
--dry-run
--force
--help
```

## Operations

Check the current TUIC and HTTPS frontend status:

```bash
sudo ./install-tuic.sh --status
```

Restart all relevant services:

```bash
sudo ./install-tuic.sh --restart
```

Both commands reuse `/etc/tuic/.env` when present, including whether the
frontend is `nginx` or `caddy`.

## Upgrade TUIC core only

To upgrade only the TUIC server binary while preserving the existing config,
certificates, HTTPS frontend, and firewall rules:

```bash
sudo ./install-tuic.sh --upgrade-core
```

The command reuses `/etc/tuic/.env` when present. To upgrade from a different
TUIC GitHub repository for this run:

```bash
sudo ./install-tuic.sh --upgrade-core --repo owner/repo
```

## Notes

- The script validates both A and AAAA DNS records and checks dual-stack prerequisites.
- ACME uses `acme.sh` in standalone mode.
- Installer metadata and summary are stored in `/etc/tuic/`.
- If `/etc/tuic/.env` exists, interactive runs ask whether to reuse the last saved configuration.
