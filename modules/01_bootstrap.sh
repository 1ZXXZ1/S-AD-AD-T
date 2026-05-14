#!/usr/bin/env bash
# ============================================================
#  Module 01 — Bootstrap: packages, hostname, DNS, chrony
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

step_bootstrap() {
  require_root
  log_step "Bootstrap: installing packages and preparing system"

  # --- Backup resolv.conf ---
  if [[ -f /etc/resolv.conf ]]; then
    backup_file /etc/resolv.conf
  fi

  # --- Temporary DNS for package install ---
  cat >/etc/resolv.conf <<EOF
search $DOMAIN
nameserver ${DNS_FORWARDER_1}
nameserver ${DNS_FORWARDER_2}
EOF

  log "Updating package index..."
  run_root apt-get update -y

  log "Installing packages (ALT Linux names)..."
  # task-samba-dc is the meta-package for AD DC on ALT
  run_root apt-get install -y \
    task-samba-dc \
    samba \
    samba-dc \
    samba-client \
    chrony \
    dhcp-server \
    rsync \
    ldb-tools \
    python3-module-samba \
    python3-module-pip \
    python3-module-setuptools \
    firewalld \
    bash-completion

  log "Verifying Samba/Python tooling..."
  if ! python3 -c "import ldb; import samba" 2>/dev/null; then
    log_err "Python Samba bindings are missing. Install package: python3-module-samba"
    return 1
  fi
  if ! command -v samba-tool >/dev/null 2>&1; then
    log_err "samba-tool is missing after package installation."
    return 1
  fi
  if ! command -v ldbsearch >/dev/null 2>&1; then
    log_err "ldbsearch is missing after package installation. Install package: ldb-tools"
    return 1
  fi

  # --- Set hostname ---
  log "Setting hostname: $FQDN"
  run_root hostnamectl set-hostname "$FQDN"
  if ! grep -qF "$FQDN" /etc/hosts; then
    printf '%s\t%s\t%s\n' "$HOST_IP" "$FQDN" "$HOST_SHORTNAME" >> /etc/hosts
    log "Added $FQDN to /etc/hosts"
  fi

  # --- Point DNS to self (will be active after provision) ---
  cat >/etc/resolv.conf <<EOF
search $DOMAIN
nameserver 127.0.0.1
EOF

  # --- Chrony ---
  log "Configuring chrony..."
  if ! grep -qF "allow ${NTP_SUBNET}" /etc/chrony.conf 2>/dev/null; then
    cat >> /etc/chrony.conf <<EOF

# Samba AD DC NTP
allow ${NTP_SUBNET}
local stratum ${NTP_STRATUM}
EOF
  fi
  svc_enable chronyd
  sleep 2
  log "Forcing initial time correction with chronyc makestep..."
  if chronyc makestep >/dev/null 2>&1; then
    log_ok "System time corrected via chrony"
  else
    log_warn "chronyc makestep failed — check chrony sources/network if Kerberos time drift appears"
  fi
  if command -v chronyc >/dev/null 2>&1; then
    log "chronyc tracking:"
    chronyc tracking 2>/dev/null || log_warn "chronyc tracking failed"
    log "chronyc sources:"
    chronyc sources 2>/dev/null || log_warn "chronyc sources failed"
  fi

  # --- Disable conflicting services ---
  log "Disabling conflicting services..."
  svc_disable dhcpd.service 2>/dev/null || true
  svc_disable dhcpd6.service 2>/dev/null || true
  svc_disable named.service 2>/dev/null || true
  svc_disable bind9.service 2>/dev/null || true
  run_root systemctl mask named.service bind9.service 2>/dev/null || true
  svc_disable smb.service nmb.service samba-bgqd.service winbind.service 2>/dev/null || true

  # --- Create directory structure ---
  log "Creating directory structure..."
  mkdir_p "$WORKDIR"
  while IFS='|' read -r _name subdir _ro _br _go _cm _dm; do
    mkdir_p "${SHARES_ROOT}/${subdir}"
    mkdir_p "${SNAPSHOTS_ROOT}/${subdir}"
  done <<< "$SHARES_LIST"
  mkdir_p "$PROFILES_ROOT" "$REDIRECT_ROOT" "$HOMES_ROOT" "$DFS_ROOT" "$APPS_ROOT"
  run_root chmod -R 0777 "$PROFILES_ROOT" "$REDIRECT_ROOT"

  # --- Set permissions for config.cfg ---
  chmod 0600 "${TOOLKIT_CFG:-$SCRIPT_DIR/../config.cfg}" 2>/dev/null || true

  log_ok "Bootstrap complete"
}

step_bootstrap
