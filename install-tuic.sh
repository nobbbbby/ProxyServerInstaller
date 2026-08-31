#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.2.1"
DEFAULT_UDP_PORT="443"
DEFAULT_HTTPS_FRONT="nginx"
DEFAULT_SITE_ROOT="/var/www/https-front"
TUIC_REPO_DEFAULT="Itsusinn/tuic"
TUIC_BIN="/usr/local/bin/tuic-server"
TUIC_DIR="/etc/tuic"
TUIC_CONFIG="${TUIC_DIR}/config.json"
TUIC_ENV="${TUIC_DIR}/.env"
TUIC_SUMMARY="${TUIC_DIR}/install-summary.json"
TUIC_SERVICE="/etc/systemd/system/tuic.service"
CERT_DIR="${TUIC_DIR}/certs"
CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
CERT_KEY="${CERT_DIR}/privkey.pem"
ACME_HOME="/root/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
RELOAD_HOOK="/usr/local/bin/tuic-cert-reload.sh"
ACME_PRE_HOOK="/usr/local/bin/tuic-acme-pre-hook.sh"
ACME_POST_HOOK="/usr/local/bin/tuic-acme-post-hook.sh"
ACME_RENEW_SERVICE="/etc/systemd/system/tuic-cert-renew.service"
ACME_RENEW_TIMER="/etc/systemd/system/tuic-cert-renew.timer"
WEB_DOMAIN=""
ACME_EMAIL=""
UDP_PORT="${DEFAULT_UDP_PORT}"
HTTPS_FRONT="${DEFAULT_HTTPS_FRONT}"
SITE_ROOT="${DEFAULT_SITE_ROOT}"
NON_INTERACTIVE="false"
DRY_RUN="false"
FORCE="false"
UPDATE_MODE="false"
UPGRADE_CORE_MODE="false"
STATUS_MODE="false"
RESTART_MODE="false"
REPAIR_CERT_RENEWAL_MODE="false"
OS_FAMILY=""
declare -a PKG_INSTALL_CMD=()
declare -a PKG_UPDATE_CMD=()
ARCH=""
TAG=""
ASSET_URL=""
TUIC_VERSION=""
TUIC_REPO="${TUIC_REPO_DEFAULT}"
TUIC_REPO_EXPLICIT="false"

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERROR] %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: install-tuic.sh [options]

Options:
  --domain <fqdn>          Domain used for TLS certificate and HTTPS frontend
  --email <email>          Email for ACME account registration
  --port-udp <port>        UDP listening port for TUIC (default: 443)
  --https-front <type>     HTTPS frontend: nginx|caddy (default: nginx)
  --site-root <path>       Site root for HTTPS frontend (default: /var/www/https-front)
  --repo <owner/repo>      TUIC GitHub repo (default: Itsusinn/tuic)
  --non-interactive        Fail instead of prompting for missing options
  --update                 Update mode; reuse /etc/tuic/.env when possible
  --upgrade-core           Upgrade only the TUIC server binary from the selected repo
  --status                 Show TUIC/frontend service status and listening sockets
  --restart                Restart TUIC and the configured HTTPS frontend
  --repair-cert-renewal    Repair and verify automatic certificate renewal only
  --dry-run                Show planned actions without making changes
  --force                  Overwrite existing configs without prompts
  --help                   Show this help
EOF
}

run_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] $(printf '%q ' "$@")"
    return 0
  fi
  "$@"
}

write_file() {
  local path="$1"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] write file ${path}"
    cat >/dev/null
    return 0
  fi
  cat >"${path}"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root (or with sudo)."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) WEB_DOMAIN="${2:-}"; shift 2 ;;
      --email) ACME_EMAIL="${2:-}"; shift 2 ;;
      --port-udp) UDP_PORT="${2:-}"; shift 2 ;;
      --https-front) HTTPS_FRONT="${2:-}"; shift 2 ;;
      --site-root) SITE_ROOT="${2:-}"; shift 2 ;;
      --repo) TUIC_REPO="${2:-}"; TUIC_REPO_EXPLICIT="true"; shift 2 ;;
      --non-interactive) NON_INTERACTIVE="true"; shift ;;
      --update) UPDATE_MODE="true"; shift ;;
      --upgrade-core|--upgrade-tuic-core) UPGRADE_CORE_MODE="true"; shift ;;
      --status|status) STATUS_MODE="true"; shift ;;
      --restart|restart) RESTART_MODE="true"; shift ;;
      --repair-cert-renewal) REPAIR_CERT_RENEWAL_MODE="true"; shift ;;
      --dry-run) DRY_RUN="true"; shift ;;
      --force) FORCE="true"; shift ;;
      --help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

load_runtime_env() {
  local key value line
  [[ -f "${TUIC_ENV}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" == *"="* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    case "${key}" in
      DOMAIN) WEB_DOMAIN="${value}" ;;
      EMAIL) ACME_EMAIL="${value}" ;;
      PORT_UDP) UDP_PORT="${value}" ;;
      FRONTEND) HTTPS_FRONT="${value}" ;;
      SITE_ROOT_PATH) SITE_ROOT="${value}" ;;
      TUIC_REPO_SAVED) TUIC_REPO="${value}" ;;
    esac
  done < "${TUIC_ENV}"
}

configured_https_front() {
  if [[ "${HTTPS_FRONT}" =~ ^(nginx|caddy)$ ]]; then
    printf '%s\n' "${HTTPS_FRONT}"
    return 0
  fi
  if systemctl is-active --quiet caddy && ! systemctl is-active --quiet nginx; then
    printf 'caddy\n'
    return 0
  fi
  printf '%s\n' "${DEFAULT_HTTPS_FRONT}"
}

show_current_status() {
  local frontend
  load_runtime_env
  frontend="$(configured_https_front)"

  log "Service state"
  systemctl --no-pager --full status tuic "${frontend}" || true

  log "Certificate renewal timer state"
  systemctl --no-pager --full status tuic-cert-renew.timer || true
  systemctl list-timers --all --no-pager tuic-cert-renew.timer || true

  log "Active check"
  systemctl is-active tuic "${frontend}" || true

  log "Listening sockets"
  ss -H -l -n -u "sport = :${UDP_PORT}" || true
  ss -H -l -n -t "sport = :443" || true

  if [[ -f "${TUIC_SUMMARY}" ]]; then
    log "Install summary"
    cat "${TUIC_SUMMARY}"
  fi
}

restart_relevant_services() {
  local frontend
  load_runtime_env
  frontend="$(configured_https_front)"

  log "Restarting TUIC and ${frontend}"
  run_cmd systemctl restart tuic "${frontend}"

  log "Service state"
  systemctl is-active tuic "${frontend}"
}

ask_if_missing() {
  local var_name="$1"
  local prompt="$2"
  local current="${!var_name}"
  if [[ -n "${current}" ]]; then
    return 0
  fi
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    die "${prompt} is required in --non-interactive mode."
  fi
  read -r -p "${prompt}: " current
  [[ -n "${current}" ]] || die "${prompt} cannot be empty."
  printf -v "${var_name}" '%s' "${current}"
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-Y}"
  local reply=""
  while true; do
    if [[ "${default}" == "Y" ]]; then
      read -r -p "${prompt} [Y/n]: " reply
      reply="${reply:-Y}"
    else
      read -r -p "${prompt} [y/N]: " reply
      reply="${reply:-N}"
    fi
    case "${reply}" in
      Y|y|yes|YES) return 0 ;;
      N|n|no|NO) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

load_existing_env() {
  local key value line
  local saved_domain="" saved_email="" saved_port="" saved_frontend="" saved_site_root="" saved_repo=""
  [[ -f "${TUIC_ENV}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" == *"="* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    case "${key}" in
      DOMAIN) saved_domain="${value}" ;;
      EMAIL) saved_email="${value}" ;;
      PORT_UDP) saved_port="${value}" ;;
      FRONTEND) saved_frontend="${value}" ;;
      SITE_ROOT_PATH) saved_site_root="${value}" ;;
      TUIC_REPO_SAVED) saved_repo="${value}" ;;
    esac
  done < "${TUIC_ENV}"

  WEB_DOMAIN="${WEB_DOMAIN:-${saved_domain}}"
  ACME_EMAIL="${ACME_EMAIL:-${saved_email}}"
  UDP_PORT="${UDP_PORT:-${saved_port:-${DEFAULT_UDP_PORT}}}"
  HTTPS_FRONT="${HTTPS_FRONT:-${saved_frontend:-${DEFAULT_HTTPS_FRONT}}}"
  SITE_ROOT="${SITE_ROOT:-${saved_site_root:-${DEFAULT_SITE_ROOT}}}"
  if [[ "${TUIC_REPO_EXPLICIT}" != "true" && -n "${saved_repo}" ]]; then
    TUIC_REPO="${saved_repo}"
  fi
  log "Loaded existing settings from ${TUIC_ENV}"
}

validate_input() {
  [[ "${HTTPS_FRONT}" =~ ^(nginx|caddy)$ ]] || die "--https-front must be nginx or caddy"
  [[ "${UDP_PORT}" =~ ^[0-9]+$ ]] || die "--port-udp must be numeric"
  (( UDP_PORT > 0 && UDP_PORT <= 65535 )) || die "--port-udp must be 1-65535"
  [[ "${WEB_DOMAIN}" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Invalid --domain format"
  [[ "${ACME_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Invalid --email format"
}

detect_os() {
  [[ -f /etc/os-release ]] || die "/etc/os-release missing"
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID,,}:${ID_LIKE,,}" in
    ubuntu:*|debian:*|*:debian*|*:ubuntu*)
      OS_FAMILY="debian"
      PKG_UPDATE_CMD=(apt-get update -y)
      PKG_INSTALL_CMD=(apt-get install -y)
      ;;
    centos:*|rhel:*|rocky:*|almalinux:*|*:rhel*|*:fedora*)
      OS_FAMILY="rhel"
      if command -v dnf >/dev/null 2>&1; then
        PKG_UPDATE_CMD=(dnf makecache)
        PKG_INSTALL_CMD=(dnf install -y)
      else
        PKG_UPDATE_CMD=(yum makecache)
        PKG_INSTALL_CMD=(yum install -y)
      fi
      ;;
    *)
      err "Detected OS: ${PRETTY_NAME:-unknown}"
      exit 10
      ;;
  esac
  log "Detected OS family: ${OS_FAMILY}"
}

detect_arch() {
  local raw
  raw="$(uname -m)"
  case "${raw}" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) die "Unsupported architecture: ${raw}" ;;
  esac
  log "Detected architecture: ${ARCH}"
}

ensure_base_dependencies() {
  log "Installing base dependencies"
  run_cmd "${PKG_UPDATE_CMD[@]}"
  if [[ "${OS_FAMILY}" == "debian" ]]; then
    run_cmd "${PKG_INSTALL_CMD[@]}" curl jq tar openssl ca-certificates iproute2 dnsutils socat
  else
    run_cmd "${PKG_INSTALL_CMD[@]}" curl jq tar openssl ca-certificates iproute bind-utils socat
  fi
}

ensure_core_upgrade_dependencies() {
  log "Installing TUIC core upgrade dependencies"
  run_cmd "${PKG_UPDATE_CMD[@]}"
  if [[ "${OS_FAMILY}" == "debian" ]]; then
    run_cmd "${PKG_INSTALL_CMD[@]}" curl jq ca-certificates
  else
    run_cmd "${PKG_INSTALL_CMD[@]}" curl jq ca-certificates
  fi
}

install_web_front_dependencies() {
  case "${HTTPS_FRONT}" in
    nginx)
      run_cmd "${PKG_INSTALL_CMD[@]}" nginx
      ;;
    caddy)
      run_cmd "${PKG_INSTALL_CMD[@]}" caddy
      ;;
  esac
}

get_public_ip4() {
  curl -4fsSL --max-time 6 https://api.ipify.org 2>/dev/null || true
}

get_public_ip6() {
  curl -6fsSL --max-time 6 https://api64.ipify.org 2>/dev/null || true
}

resolve_domain_records() {
  local family="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short "${WEB_DOMAIN}" "${family}" | sed '/^$/d' || true
  else
    getent ahosts "${WEB_DOMAIN}" | awk -v fam="${family}" '
      fam=="A" && $1 ~ /^[0-9.]+$/ {print $1}
      fam=="AAAA" && $1 ~ /:/ {print $1}
    ' | sort -u
  fi
}

validate_dns_matches_host() {
  log "Validating A and AAAA records for ${WEB_DOMAIN}"
  local a_records aaaa_records pub4 pub6
  a_records="$(resolve_domain_records A)"
  aaaa_records="$(resolve_domain_records AAAA)"
  [[ -n "${a_records}" ]] || { err "No A record found for ${WEB_DOMAIN}"; exit 12; }
  [[ -n "${aaaa_records}" ]] || { err "No AAAA record found for ${WEB_DOMAIN}"; exit 12; }

  pub4="$(get_public_ip4)"
  pub6="$(get_public_ip6)"
  if [[ -n "${pub4}" ]] && ! grep -Fxq "${pub4}" <<<"${a_records}"; then
    err "A records do not include host public IPv4 (${pub4})"
    exit 12
  fi
  if [[ -n "${pub6}" ]] && ! grep -Fxq "${pub6}" <<<"${aaaa_records}"; then
    err "AAAA records do not include host public IPv6 (${pub6})"
    exit 12
  fi
  log "DNS validation passed"
}

validate_dual_stack() {
  local bindv6only
  bindv6only="$(sysctl -n net.ipv6.bindv6only 2>/dev/null || echo 0)"
  if [[ "${bindv6only}" == "1" ]]; then
    err "net.ipv6.bindv6only=1 prevents transparent dual-stack v6 socket behavior"
    exit 13
  fi
  ip -6 addr show scope global | grep -q 'inet6' || {
    err "No global IPv6 address found on host interfaces"
    exit 13
  }
  log "Dual-stack prerequisite checks passed"
}

port_in_use() {
  local proto="$1"
  local port="$2"
  ss -H -l -n "-${proto}" "sport = :${port}" | sed '/^$/d' || true
}

validate_ports() {
  local udp_used tcp_used
  udp_used="$(port_in_use u "${UDP_PORT}")"
  tcp_used="$(port_in_use t 443)"

  if [[ -n "${udp_used}" ]] && [[ "${FORCE}" != "true" ]] && [[ "${UPDATE_MODE}" != "true" ]]; then
    err "UDP/${UDP_PORT} is in use. Re-run with --force if this is expected."
    exit 16
  fi
  if [[ -n "${tcp_used}" ]] && [[ "${FORCE}" != "true" ]] && [[ "${UPDATE_MODE}" != "true" ]]; then
    err "TCP/443 is in use. Re-run with --force if this is expected."
    exit 16
  fi
  log "Port checks passed"
}

install_acme() {
  if [[ -x "${ACME_BIN}" ]]; then
    log "acme.sh already installed"
    return 0
  fi
  log "Installing acme.sh"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] curl -fsSL https://get.acme.sh | sh -s email=${ACME_EMAIL}"
  else
    local acme_installer
    acme_installer="$(mktemp)"
    curl -fsSL -o "${acme_installer}" https://get.acme.sh
    sh "${acme_installer}" email="${ACME_EMAIL}"
    rm -f "${acme_installer}"
  fi
  [[ "${DRY_RUN}" == "true" ]] || [[ -x "${ACME_BIN}" ]] || die "acme.sh install failed"
}

acme_domain_conf_path() {
  local candidate
  for candidate in \
    "${ACME_HOME}/${WEB_DOMAIN}_ecc/${WEB_DOMAIN}.conf" \
    "${ACME_HOME}/${WEB_DOMAIN}/${WEB_DOMAIN}.conf"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

acme_encoded_conf_value() {
  local value="$1"
  printf '__ACME_BASE64__START_%s__ACME_BASE64__END_' "$(printf '%s' "${value}" | openssl base64 -A)"
}

set_acme_domain_conf_value() {
  local conf key value encoded escaped
  key="$1"
  value="$2"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] update acme.sh domain config ${key}"
    return 0
  fi
  conf="$(acme_domain_conf_path)" || {
    warn "Could not find acme.sh domain config for ${WEB_DOMAIN}; renewal hooks were not patched."
    return 0
  }
  encoded="$(acme_encoded_conf_value "${value}")"
  escaped="$(printf '%s' "${encoded}" | sed 's/[\/&]/\\&/g')"
  if grep -q "^${key}=" "${conf}"; then
    sed -i.bak "s/^${key}=.*/${key}='${escaped}'/" "${conf}"
  else
    printf "%s='%s'\n" "${key}" "${encoded}" >> "${conf}"
  fi
}

persist_acme_renewal_hooks() {
  set_acme_domain_conf_value "Le_PreHook" "${ACME_PRE_HOOK}"
  set_acme_domain_conf_value "Le_PostHook" "${ACME_POST_HOOK}"
}

write_acme_renewal_hooks() {
  write_file "${ACME_PRE_HOOK}" <<HOOK
#!/usr/bin/env bash
set -e
echo "Stopping ${HTTPS_FRONT} for the ACME standalone challenge"
systemctl stop ${HTTPS_FRONT}
HOOK
  write_file "${ACME_POST_HOOK}" <<HOOK
#!/usr/bin/env bash
set -e
echo "Starting ${HTTPS_FRONT} after the ACME standalone challenge"
systemctl start ${HTTPS_FRONT}
HOOK
  run_cmd chmod 750 "${ACME_PRE_HOOK}" "${ACME_POST_HOOK}"
}

write_certificate_reload_hook() {
  write_file "${RELOAD_HOOK}" <<HOOK
#!/usr/bin/env bash
set -e
echo "Reloading ${HTTPS_FRONT} with the renewed certificate"
systemctl reload ${HTTPS_FRONT} || systemctl restart ${HTTPS_FRONT}
if systemctl cat tuic >/dev/null 2>&1; then
  echo "Restarting TUIC with the renewed certificate"
  systemctl restart tuic
fi
HOOK
  run_cmd chmod 750 "${RELOAD_HOOK}"
}

install_acme_renewal_timer() {
  log "Installing persistent certificate renewal timer"
  write_file "${ACME_RENEW_SERVICE}" <<EOF
[Unit]
Description=Renew TUIC TLS certificate with acme.sh
Documentation=https://github.com/acmesh-official/acme.sh
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
UMask=0077
ExecStart=${ACME_BIN} --cron --home ${ACME_HOME}
EOF

  write_file "${ACME_RENEW_TIMER}" <<'EOF'
[Unit]
Description=Check TUIC TLS certificate renewal every six hours

[Timer]
OnCalendar=*-*-* 00,06,12,18:00:00
RandomizedDelaySec=45m
Persistent=true
AccuracySec=1m
Unit=tuic-cert-renew.service

[Install]
WantedBy=timers.target
EOF

  run_cmd chmod 644 "${ACME_RENEW_SERVICE}" "${ACME_RENEW_TIMER}"
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable --now tuic-cert-renew.timer
  if [[ "${DRY_RUN}" != "true" ]]; then
    systemctl is-enabled --quiet tuic-cert-renew.timer || die "Certificate renewal timer is not enabled"
    systemctl is-active --quiet tuic-cert-renew.timer || die "Certificate renewal timer is not active"
    log "Certificate renewal timer enabled; logs are available with: journalctl -u tuic-cert-renew.service"
  fi
}

issue_or_renew_cert() {
  log "Issuing/renewing certificate for ${WEB_DOMAIN}"
  run_cmd mkdir -p "${CERT_DIR}"
  if ! run_cmd "${ACME_BIN}" --register-account -m "${ACME_EMAIL}" --server letsencrypt; then
    warn "ACME account registration returned non-zero; continuing."
  fi
  write_acme_renewal_hooks
  local -a issue_cmd
  issue_cmd=(
    "${ACME_BIN}"
    --issue
    -d "${WEB_DOMAIN}"
    --standalone
    --keylength ec-256
    --server letsencrypt
    --ecc
    --pre-hook "${ACME_PRE_HOOK}"
    --post-hook "${ACME_POST_HOOK}"
  )
  if [[ "${FORCE}" == "true" ]]; then
    issue_cmd+=(--force)
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] $(printf '%q ' "${issue_cmd[@]}")"
  else
    if ! "${issue_cmd[@]}"; then
      warn "ACME issue step returned non-zero; continuing and trying to install existing cert."
    fi
  fi
  persist_acme_renewal_hooks
  write_certificate_reload_hook
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] ${ACME_BIN} --install-cert -d ${WEB_DOMAIN} --ecc --fullchain-file ${CERT_FULLCHAIN} --key-file ${CERT_KEY} --reloadcmd '${RELOAD_HOOK}'"
  else
    "${ACME_BIN}" --install-cert -d "${WEB_DOMAIN}" --ecc --fullchain-file "${CERT_FULLCHAIN}" --key-file "${CERT_KEY}" --reloadcmd "${RELOAD_HOOK}" || {
      err "ACME install-cert failed. Ensure certificate issuance succeeded for ${WEB_DOMAIN}."
      exit 15
    }
  fi
  [[ "${DRY_RUN}" == "true" ]] || [[ -s "${CERT_FULLCHAIN}" && -s "${CERT_KEY}" ]] || { err "Certificate files are missing after ACME step"; exit 15; }
  run_cmd chmod 600 "${CERT_KEY}"
}

repair_certificate_renewal() {
  [[ -f "${TUIC_ENV}" ]] || die "${TUIC_ENV} is missing; run the full installer first."
  load_existing_env
  validate_input
  [[ -x "${ACME_BIN}" ]] || die "${ACME_BIN} is missing; run the full installer first."
  acme_domain_conf_path >/dev/null || die "No acme.sh certificate configuration found for ${WEB_DOMAIN}."

  log "Repairing automatic certificate renewal for ${WEB_DOMAIN}"
  write_acme_renewal_hooks
  persist_acme_renewal_hooks
  write_certificate_reload_hook
  install_acme_renewal_timer

  if [[ "${DRY_RUN}" != "true" ]]; then
    log "Running an immediate renewal check"
    systemctl start tuic-cert-renew.service
    systemctl --no-pager --full status tuic-cert-renew.service || true
  fi
}

resolve_latest_tuic_release() {
  log "Resolving latest stable release from ${TUIC_REPO}"
  local api release_json stable_release asset_pattern
  api="https://api.github.com/repos/${TUIC_REPO}/releases"
  release_json="$(curl -fsSL "${api}")" || { err "Failed to fetch releases from ${api}"; exit 14; }

  # Some upstream projects publish tags such as v2.0.0-dev3 without setting
  # GitHub's prerelease flag. Require a release tag that ends in a complete
  # stable semantic version so those builds cannot silently become the default.
  stable_release="$(select_latest_stable_release <<<"${release_json}")"
  TAG="$(jq -r '.tag_name // empty' <<<"${stable_release}")"
  [[ -n "${TAG}" ]] || { err "No stable release found in ${TUIC_REPO}"; exit 14; }
  TUIC_VERSION="${TAG}"

  asset_pattern="tuic-server.*${ARCH}.*linux.*(gnu|musl)"
  ASSET_URL="$(jq -r --arg p "${asset_pattern}" '.assets[]?.browser_download_url | select(test($p;"i"))' <<<"${stable_release}" | head -n1)"
  [[ -n "${ASSET_URL}" ]] || { err "No matching Linux asset found for ${ARCH} at ${TAG}"; exit 14; }
  log "Selected release: ${TAG}"
}

# GitHub's prerelease field is publisher-controlled and is not sufficient on
# its own. Accept plain semantic-version tags and conventional component tags
# such as "tuic-server-1.0.0", but reject suffixes including -dev, -rc, and beta.
select_latest_stable_release() {
  jq -c '
    [
      .[]
      | select(.draft == false and .prerelease == false)
      | select(.tag_name | test("(^|[-_/])v?[0-9]+\\.[0-9]+\\.[0-9]+$"))
    ][0] // empty
  '
}

install_tuic_binary() {
  log "Installing TUIC binary"
  local tmp_dir bin_file sum_url sum_file asset_name
  tmp_dir="$(mktemp -d)"
  asset_name="$(basename "${ASSET_URL}")"
  bin_file="${tmp_dir}/${asset_name}"
  run_cmd curl -fsSL -o "${bin_file}" "${ASSET_URL}"
  run_cmd chmod +x "${bin_file}"

  sum_url="$(dirname "${ASSET_URL}")/sha256sums.txt"
  if curl -fsI "${sum_url}" >/dev/null 2>&1; then
    sum_file="${tmp_dir}/sha256sums.txt"
    run_cmd curl -fsSL -o "${sum_file}" "${sum_url}"
    if [[ "${DRY_RUN}" != "true" ]]; then
      if grep -Fq "${asset_name}" "${sum_file}"; then
        (cd "${tmp_dir}" && sha256sum -c "${sum_file}" --ignore-missing) || die "Checksum verification failed"
      else
        warn "Checksum file does not list selected asset; continuing"
      fi
    fi
  else
    warn "No sha256sums.txt found for ${TAG}; skipping checksum verification"
  fi

  run_cmd install -m 0755 "${bin_file}" "${TUIC_BIN}"
  run_cmd rm -rf "${tmp_dir}"
}

restart_tuic_service() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] systemctl restart tuic"
    return 0
  fi
  if systemctl cat tuic >/dev/null 2>&1; then
    systemctl restart tuic
  else
    warn "tuic.service is not installed; binary upgraded but service was not restarted."
  fi
}

verify_tuic_service_if_installed() {
  [[ "${DRY_RUN}" == "true" ]] && return 0
  if systemctl cat tuic >/dev/null 2>&1; then
    systemctl is-active --quiet tuic || { err "TUIC service is not active after upgrade"; exit 16; }
  fi
}

persist_core_upgrade_metadata() {
  [[ -f "${TUIC_ENV}" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v version="${TUIC_VERSION}" -v tag="${TAG}" -v asset="${ASSET_URL}" -v repo="${TUIC_REPO}" -v updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    BEGIN {
      seen_version=0
      seen_tag=0
      seen_asset=0
      seen_repo=0
      seen_updated=0
    }
    /^TUIC_VERSION=/ { print "TUIC_VERSION=" version; seen_version=1; next }
    /^TUIC_TAG=/ { print "TUIC_TAG=" tag; seen_tag=1; next }
    /^TUIC_ASSET_URL=/ { print "TUIC_ASSET_URL=" asset; seen_asset=1; next }
    /^TUIC_REPO_SAVED=/ { print "TUIC_REPO_SAVED=" repo; seen_repo=1; next }
    /^UPDATED_AT=/ { print "UPDATED_AT=" updated; seen_updated=1; next }
    { print }
    END {
      if (!seen_version) print "TUIC_VERSION=" version
      if (!seen_tag) print "TUIC_TAG=" tag
      if (!seen_asset) print "TUIC_ASSET_URL=" asset
      if (!seen_repo) print "TUIC_REPO_SAVED=" repo
      if (!seen_updated) print "UPDATED_AT=" updated
    }
  ' "${TUIC_ENV}" > "${tmp}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] update TUIC metadata in ${TUIC_ENV}"
    rm -f "${tmp}"
    return 0
  fi
  run_cmd install -m 0600 "${tmp}" "${TUIC_ENV}"
  run_cmd rm -f "${tmp}"
}

print_upgrade_result() {
  cat <<EOF
TUIC core upgrade completed.

TUIC repo: ${TUIC_REPO}
TUIC version: ${TUIC_VERSION}
Binary: ${TUIC_BIN}

Preserved:
  - ${TUIC_CONFIG}
  - ${TUIC_SERVICE}
  - ${TUIC_ENV}

EOF
}

backup_if_exists() {
  local f="$1"
  if [[ -f "${f}" ]]; then
    local ts
    ts="$(date +%Y%m%d%H%M%S)"
    run_cmd cp -a "${f}" "${f}.bak.${ts}"
  fi
}

generate_tuic_config() {
  log "Generating TUIC configuration"
  local uuid pass existing_uuid existing_pass

  existing_uuid=""
  existing_pass=""
  if [[ -f "${TUIC_CONFIG}" ]] && command -v jq >/dev/null 2>&1; then
    existing_uuid="$(jq -r '.users | keys[0] // empty' "${TUIC_CONFIG}" 2>/dev/null || true)"
    if [[ -n "${existing_uuid}" ]]; then
      existing_pass="$(jq -r --arg u "${existing_uuid}" '.users[$u] // empty' "${TUIC_CONFIG}" 2>/dev/null || true)"
    fi
  fi

  if [[ -n "${existing_uuid}" && -n "${existing_pass}" && "${FORCE}" != "true" ]]; then
    uuid="${existing_uuid}"
    pass="${existing_pass}"
    log "Reusing existing UUID/password from ${TUIC_CONFIG}"
  else
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    pass="$(openssl rand -hex 16)"
    log "Generated new UUID/password"
  fi

  run_cmd mkdir -p "${TUIC_DIR}"
  backup_if_exists "${TUIC_CONFIG}"
  write_file "${TUIC_CONFIG}" <<EOF
{
  "server": "[::]:${UDP_PORT}",
  "users": {
    "${uuid}": "${pass}"
  },
  "certificate": "${CERT_FULLCHAIN}",
  "private_key": "${CERT_KEY}",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "log_level": "warn"
}
EOF
  run_cmd chmod 600 "${TUIC_CONFIG}"
  export TUIC_USER_UUID="${uuid}"
  export TUIC_USER_PASSWORD="${pass}"
}

write_tuic_service() {
  log "Writing systemd service for TUIC"
  backup_if_exists "${TUIC_SERVICE}"
  write_file "${TUIC_SERVICE}" <<EOF
[Unit]
Description=TUIC Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${TUIC_BIN} -c ${TUIC_CONFIG}
Restart=on-failure
RestartSec=2
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${TUIC_DIR}
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable tuic
}

write_site_content() {
  run_cmd mkdir -p "${SITE_ROOT}"
  write_file "${SITE_ROOT}/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Service Status</title>
  <style>
    body{font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#f4f6f8;color:#1f2937;margin:0}
    .wrap{max-width:760px;margin:8vh auto;background:#fff;padding:28px;border-radius:12px;box-shadow:0 6px 30px rgba(0,0,0,.08)}
    h1{font-size:1.4rem;margin:0 0 12px}
    p{line-height:1.6;margin:.6rem 0}
    .ok{display:inline-block;padding:.2rem .5rem;border-radius:6px;background:#ecfdf5;color:#047857;font-weight:600}
  </style>
</head>
<body>
  <div class="wrap">
    <h1>Welcome</h1>
    <p><span class="ok">Online</span></p>
    <p>This endpoint serves standard HTTPS traffic.</p>
  </div>
</body>
</html>
EOF
}

configure_nginx() {
  local conf="/etc/nginx/conf.d/tuic-front.conf"
  backup_if_exists "${conf}"
  write_site_content
  write_file "${conf}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${WEB_DOMAIN};
    location / {
        return 301 https://\\\$host\\\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${WEB_DOMAIN};

    ssl_certificate ${CERT_FULLCHAIN};
    ssl_certificate_key ${CERT_KEY};
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer-when-downgrade always;

    root ${SITE_ROOT};
    index index.html;
    location / {
        try_files \\\$uri \\\$uri/ =404;
    }
}
EOF
  run_cmd nginx -t
  run_cmd systemctl enable nginx
}

configure_caddy() {
  local caddyfile="/etc/caddy/Caddyfile"
  backup_if_exists "${caddyfile}"
  write_site_content
  write_file "${caddyfile}" <<EOF
{
    auto_https off
}

http://${WEB_DOMAIN} {
    redir https://${WEB_DOMAIN}{uri} permanent
}

https://${WEB_DOMAIN} {
    tls ${CERT_FULLCHAIN} ${CERT_KEY}
    root * ${SITE_ROOT}
    file_server
    header {
        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "no-referrer-when-downgrade"
    }
}
EOF
  run_cmd caddy validate --config "${caddyfile}"
  run_cmd systemctl enable caddy
}

configure_https_front() {
  log "Configuring HTTPS frontend: ${HTTPS_FRONT}"
  case "${HTTPS_FRONT}" in
    nginx) configure_nginx ;;
    caddy) configure_caddy ;;
  esac
}

configure_firewall() {
  log "Configuring firewall rules"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi "Status: active"; then
    run_cmd ufw allow 80/tcp
    run_cmd ufw allow 443/tcp
    run_cmd ufw allow "${UDP_PORT}/udp"
    return 0
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    run_cmd firewall-cmd --permanent --add-port=80/tcp
    run_cmd firewall-cmd --permanent --add-port=443/tcp
    run_cmd firewall-cmd --permanent --add-port="${UDP_PORT}/udp"
    run_cmd firewall-cmd --reload
    return 0
  fi

  if command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log "[dry-run] iptables/ip6tables allow tcp/80 tcp/443 udp/${UDP_PORT}"
    else
      iptables -C INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
      iptables -C INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 443 -j ACCEPT
      iptables -C INPUT -p udp --dport "${UDP_PORT}" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p udp --dport "${UDP_PORT}" -j ACCEPT
      ip6tables -C INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || ip6tables -I INPUT -p tcp --dport 80 -j ACCEPT
      ip6tables -C INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || ip6tables -I INPUT -p tcp --dport 443 -j ACCEPT
      ip6tables -C INPUT -p udp --dport "${UDP_PORT}" -j ACCEPT >/dev/null 2>&1 || ip6tables -I INPUT -p udp --dport "${UDP_PORT}" -j ACCEPT
    fi
    warn "Applied iptables/ip6tables rules. Persist with your distro's firewall persistence service."
    return 0
  fi

  warn "No supported firewall manager detected; configure ports manually."
}

start_services() {
  log "Starting services"
  run_cmd systemctl restart tuic
  run_cmd systemctl enable tuic
  run_cmd systemctl restart "${HTTPS_FRONT}"
  run_cmd systemctl enable "${HTTPS_FRONT}"
}

verify_health() {
  [[ "${DRY_RUN}" == "true" ]] && return 0
  log "Running health checks"
  systemctl is-active --quiet tuic || { err "TUIC service is not active"; exit 16; }
  systemctl is-active --quiet "${HTTPS_FRONT}" || { err "${HTTPS_FRONT} service is not active"; exit 16; }

  ss -H -l -n -u "sport = :${UDP_PORT}" | grep -q ":${UDP_PORT}" || { err "TUIC UDP/${UDP_PORT} not listening"; exit 16; }
  ss -H -l -n -t "sport = :443" | grep -q ":443" || { err "HTTPS TCP/443 not listening"; exit 16; }
}

persist_env() {
  run_cmd mkdir -p "${TUIC_DIR}"
  write_file "${TUIC_ENV}" <<EOF
DOMAIN=${WEB_DOMAIN}
EMAIL=${ACME_EMAIL}
PORT_UDP=${UDP_PORT}
FRONTEND=${HTTPS_FRONT}
SITE_ROOT_PATH=${SITE_ROOT}
TUIC_VERSION=${TUIC_VERSION}
TUIC_TAG=${TAG}
TUIC_ASSET_URL=${ASSET_URL}
TUIC_REPO_SAVED=${TUIC_REPO}
UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  run_cmd chmod 600 "${TUIC_ENV}"
}

write_summary() {
  local cert_expiry
  cert_expiry="unknown"
  if [[ "${DRY_RUN}" != "true" ]] && [[ -f "${CERT_FULLCHAIN}" ]]; then
    cert_expiry="$(openssl x509 -in "${CERT_FULLCHAIN}" -noout -enddate | cut -d= -f2- || true)"
  fi
  write_file "${TUIC_SUMMARY}" <<EOF
{
  "script_version": "${SCRIPT_VERSION}",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "domain": "${WEB_DOMAIN}",
  "tuic_repo": "${TUIC_REPO}",
  "tuic_version": "${TUIC_VERSION}",
  "udp_port": ${UDP_PORT},
  "https_front": "${HTTPS_FRONT}",
  "site_root": "${SITE_ROOT}",
  "cert_expiry": "${cert_expiry}",
  "dual_stack_bind": "[::]:${UDP_PORT}"
}
EOF
  run_cmd chmod 600 "${TUIC_SUMMARY}"
}

print_result() {
  local client_uuid client_password
  client_uuid="${TUIC_USER_UUID:-}"
  client_password="${TUIC_USER_PASSWORD:-}"

  if [[ -f "${TUIC_CONFIG}" ]] && command -v jq >/dev/null 2>&1; then
    client_uuid="$(jq -r '.users | keys[0] // empty' "${TUIC_CONFIG}" 2>/dev/null || true)"
    if [[ -n "${client_uuid}" ]]; then
      client_password="$(jq -r --arg u "${client_uuid}" '.users[$u] // empty' "${TUIC_CONFIG}" 2>/dev/null || true)"
    fi
  fi

  client_uuid="${client_uuid:-unknown}"
  client_password="${client_password:-unknown}"

  cat <<EOF
Install completed.

Domain: ${WEB_DOMAIN}
TUIC version: ${TUIC_VERSION}
TUIC endpoint: ${WEB_DOMAIN}:${UDP_PORT}/udp
HTTPS frontend: ${HTTPS_FRONT} on tcp/443
Site root: ${SITE_ROOT}

Files:
  - ${TUIC_CONFIG}
  - ${TUIC_SERVICE}
  - ${TUIC_ENV}
  - ${TUIC_SUMMARY}

Client essentials:
  - Server: ${WEB_DOMAIN}
  - Port: ${UDP_PORT}
  - UUID: ${client_uuid}
  - Password: ${client_password}
  - ALPN: h3
  
EOF
}

main() {
  local operation_count=0
  parse_args "$@"
  require_root

  [[ "${STATUS_MODE}" == "true" ]] && ((operation_count += 1))
  [[ "${RESTART_MODE}" == "true" ]] && ((operation_count += 1))
  [[ "${UPDATE_MODE}" == "true" ]] && ((operation_count += 1))
  [[ "${UPGRADE_CORE_MODE}" == "true" ]] && ((operation_count += 1))
  [[ "${REPAIR_CERT_RENEWAL_MODE}" == "true" ]] && ((operation_count += 1))
  (( operation_count <= 1 )) || die "Use only one operation mode at a time."

  if [[ "${REPAIR_CERT_RENEWAL_MODE}" == "true" ]]; then
    repair_certificate_renewal
    return 0
  fi

  if [[ "${STATUS_MODE}" == "true" ]]; then
    show_current_status
    return 0
  fi

  if [[ "${RESTART_MODE}" == "true" ]]; then
    restart_relevant_services
    return 0
  fi

  if [[ "${UPGRADE_CORE_MODE}" == "true" ]]; then
    if [[ -f "${TUIC_ENV}" ]]; then
      load_existing_env
    fi
    [[ "${TUIC_REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid --repo format; expected owner/repo"
    detect_os
    detect_arch
    ensure_core_upgrade_dependencies
    resolve_latest_tuic_release
    install_tuic_binary
    restart_tuic_service
    verify_tuic_service_if_installed
    persist_core_upgrade_metadata
    print_upgrade_result
    return 0
  fi

  if [[ -f "${TUIC_ENV}" ]]; then
    if [[ "${UPDATE_MODE}" == "true" ]]; then
      load_existing_env
    elif [[ "${NON_INTERACTIVE}" == "true" ]]; then
      if [[ -z "${WEB_DOMAIN}" || -z "${ACME_EMAIL}" ]]; then
        log "Non-interactive mode: reusing saved configuration from ${TUIC_ENV}"
        load_existing_env
      fi
    else
      if ask_yes_no "Saved configuration found at ${TUIC_ENV}. Reuse it" "Y"; then
        load_existing_env
      else
        log "Continuing with new/manual configuration"
      fi
    fi
  fi

  ask_if_missing WEB_DOMAIN "Enter domain (FQDN)"
  ask_if_missing ACME_EMAIL "Enter ACME email"
  validate_input
  detect_os
  detect_arch
  ensure_base_dependencies
  install_web_front_dependencies
  validate_dns_matches_host
  validate_dual_stack
  validate_ports
  install_acme
  issue_or_renew_cert
  resolve_latest_tuic_release
  install_tuic_binary
  generate_tuic_config
  write_tuic_service
  configure_https_front
  configure_firewall
  start_services
  install_acme_renewal_timer
  verify_health
  persist_env
  write_summary
  print_result
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
