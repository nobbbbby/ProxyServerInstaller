# TUIC One-Click Installer

This repository provides `install-tuic.sh`, a one-click installer for:

- Latest stable TUIC server release from GitHub
- Dual-stack listener (`[::]:443` by default)
- HTTPS frontend on TCP/443 via Nginx or Caddy
- ACME certificate issuance/renewal with shared cert for TUIC + frontend
- Persistent systemd certificate-renewal scheduling with journal logs
- Firewall automation (`ufw`, `firewalld`, or `iptables/ip6tables` fallback)

## Quick start

Run as root on a supported distro:

- Ubuntu 22.04/24.04
- Debian 12
- CentOS/RHEL-family (systemd-based)

Download the installer and start setup (requires `curl` and `sudo`):

```bash
curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/nobbbbby/ProxyServerInstaller/main/install-tuic.sh \
  --output install-tuic.sh && chmod +x ./install-tuic.sh && sudo ./install-tuic.sh
```

Setup prompts for your domain and ACME email. Point the domain's DNS records at
the server before running it. To supply the values without prompts after downloading:

```bash
sudo bash ./install-tuic.sh \
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
--upgrade-script         update the local installer file
--source-url <url>        build core from an HTTPS or SSH Git remote
--source-ref <ref>        branch, tag, or full commit SHA (default: HEAD)
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

## Update the installer itself

```bash
sudo bash ./install-tuic.sh --upgrade-script
```

This downloads the latest installer from this repository's `main` branch,
checks its header, version marker, and Bash syntax, then atomically replaces
the local script and makes it executable. Run the script again afterwards to
use the updated version. Download or validation failures leave the existing
file intact. Self-update requires a saved, regular script file; symlinks and
piped input are not supported. Use `--dry-run` to preview without downloading.

This operation only updates the installer file. Use `--upgrade-core` to upgrade
TUIC, or `--update` to rerun setup with saved configuration. Operation modes
cannot be combined. For older copies without `--upgrade-script`, repeat the
`curl` download step from Quick start, omitting the commands after `&&` to avoid
starting setup again.

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

Stable release selection checks both GitHub's draft/prerelease metadata and the
release tag. Tags with development suffixes such as `-dev`, `-rc`, or `-beta`
are not installed by default, even if the publisher did not mark the GitHub
release as a prerelease.

## Build TUIC core from custom source

Build and upgrade from an HTTPS or SSH Git remote instead of release assets:

```bash
sudo ./install-tuic.sh --upgrade-core \
  --source-url https://github.com/owner/tuic.git \
  --source-ref my-branch
```

`--source-ref` accepts a branch, tag, or full commit SHA; it defaults to the
remote's `HEAD`. Use a full commit SHA to pin the exact source revision. SSH
remotes such as `git@github.com:owner/tuic.git` use the invoking user's SSH
configuration (normally root under `sudo`); configure authentication and host
trust beforehand. HTTPS URLs with embedded credentials are rejected.

Install a Rust toolchain compatible with the fork before running this command.
`cargo` and `rustc` must be on the root user's PATH. The script installs Git,
C/C++ build tools, pkg-config, OpenSSL development headers, and CMake through the
system package manager. Additional fork-specific dependencies must be installed
separately. The repository must contain a Cargo project at its root, a committed
`Cargo.lock`, and a binary target named `tuic-server`, compatible with the
existing TUIC configuration and service command. Compilation uses
[`cargo build --release --locked`](https://doc.rust-lang.org/cargo/commands/cargo-build.html)
with the fork's default features and toolchain configuration.

Only build trusted repositories: Cargo configuration and build scripts execute
with the installer's privileges. The script fetches into a temporary directory,
logs the resolved commit, builds and checks the executable's `--version`, then
atomically replaces `/usr/local/bin/tuic-server` and restarts TUIC. Fetch or build
failure leaves the installed binary and running service untouched. Temporary
files are cleaned up on failure. A service startup failure is reported; automatic
rollback after replacement is not provided.

The upgrade preserves the existing configuration, certificates, HTTPS frontend,
and firewall rules. Source URL, requested ref, and resolved commit are recorded
in `/etc/tuic/.env` if that file exists. Supply the source options on each source
upgrade; a later plain `--upgrade-core` resumes release-binary upgrades from the
saved GitHub release repository. `--repo` and `--source-url` cannot be combined.
Source builds are supported only with `--upgrade-core`, after initial setup.
Use `--dry-run` to preview the source upgrade without fetching or building.

## Repair certificate auto-renewal

Servers installed with an older version may have a missing `acme.sh` cron entry
or incomplete standalone-renewal hooks. After updating this script, repair the
hooks and install the persistent systemd timer without reinstalling TUIC:

```bash
sudo ./install-tuic.sh --repair-cert-renewal
```

The command also runs one immediate renewal check. Inspect the schedule and the
most recent renewal log with:

```bash
systemctl list-timers tuic-cert-renew.timer
journalctl -u tuic-cert-renew.service -n 100 --no-pager
```

## Notes

- The script validates both A and AAAA DNS records and checks dual-stack prerequisites.
- ACME uses `acme.sh` in standalone mode. The installer registers renewal hooks
  that stop the HTTPS frontend before the challenge, start it afterwards, and
  restart TUIC after a renewed certificate is installed.
- A persistent systemd timer runs the supported `acme.sh --cron` renewal check
  every six hours. The randomized delay prevents all installed servers from
  contacting the certificate authority at the same instant. Renewal output is
  retained in the systemd journal for diagnosis.
- Installer metadata and summary are stored in `/etc/tuic/`.
- If `/etc/tuic/.env` exists, interactive runs ask whether to reuse the last saved configuration.
