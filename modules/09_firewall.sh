#!/usr/bin/env bash
# ============================================================
#  Module 09 — Firewall Configuration
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

step_firewall() {
  require_root

  if [[ "$FIREWALL_ENABLED" != "yes" ]]; then
    log "Firewall disabled in config, skipping."
    return 0
  fi

  log_step "Configuring firewall"

  # Try firewalld first, fall back to iptables
  if command -v firewall-cmd >/dev/null 2>&1; then
    log "Using firewalld..."
    svc_enable firewalld

    # Create a service for Samba AD DC
    firewall-cmd --permanent --new-service=samba-ad-dc 2>/dev/null || true

    while IFS='/' read -r proto port; do
      proto="$(echo "$proto" | xargs)"
      port="$(echo "$port" | xargs)"
      [[ -z "$proto" || -z "$port" ]] && continue

      firewall-cmd --permanent --service=samba-ad-dc --add-port="${port}/${proto}" 2>/dev/null || true
      log "  Port: ${port}/${proto}"
    done <<< "$FIREWALL_PORTS"

    firewall-cmd --permanent --add-service=samba-ad-dc
    firewall-cmd --permanent --add-service=rpc-bind
    firewall-cmd --permanent --add-service=kerberos
    firewall-cmd --permanent --add-service=samba
    firewall-cmd --reload

    log "Firewall rules:"
    firewall-cmd --list-all 2>/dev/null

  elif command -v iptables >/dev/null 2>&1; then
    log "Using iptables..."
    while IFS='/' read -r proto port; do
      proto="$(echo "$proto" | xargs)"
      port="$(echo "$port" | xargs)"
      [[ -z "$proto" || -z "$port" ]] && continue

      run_root iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
      log "  Port: ${port}/${proto}"
    done <<< "$FIREWALL_PORTS"

    # Save rules
    if command -v iptables-save >/dev/null 2>&1; then
      run_root iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

  else
    log_warn "Neither firewalld nor iptables found. Skipping firewall configuration."
    return 0
  fi

  log_ok "Firewall configured"
}

step_firewall
