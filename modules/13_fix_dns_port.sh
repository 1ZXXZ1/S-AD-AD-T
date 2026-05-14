#!/usr/bin/env bash
# ============================================================
#  Module 13 — Fix Port 53 (DNS bind conflict)
#
#  Resolves the common issue where systemd-resolved or another
#  process binds to port 53 before Samba AD DC can start.
#
#  Usage:
#    sudo bash modules/13_fix_dns_port.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

step_fix_dns_port() {
  require_root
  log_step "Fixing DNS port 53 conflict"

  # --- Detect what's using port 53 ---
  log "Checking port 53 usage..."
  local port53_users
  port53_users="$(ss -tlnup 2>/dev/null | grep -E ":53[[:space:]]|:53$" || echo "")"

  if [[ -z "$port53_users" ]]; then
    log "Port 53 is currently free"
  else
    log "Current port 53 bindings:"
    echo "$port53_users"
  fi

  # --- Option 1: systemd-resolved (most common on modern Linux) ---
  if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    log "Found systemd-resolved — disabling its DNS stub listener..."

    # Disable the DNS stub listener (listens on 127.0.0.53:53)
    mkdir -p /etc/systemd/resolved.conf.d/
    cat > /etc/systemd/resolved.conf.d/ad-dns.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF

    # Restart resolved to apply
    systemctl restart systemd-resolved 2>/dev/null || true

    # Re-create /etc/resolv.conf as a regular file (not a symlink to stub)
    if [[ -L /etc/resolv.conf ]]; then
      log "Removing symlink /etc/resolv.conf (points to systemd-resolved stub)"
      rm -f /etc/resolv.conf
    fi

    cat > /etc/resolv.conf <<EOF
search $DOMAIN
nameserver 127.0.0.1
EOF

    log "systemd-resolved DNS stub disabled, resolv.conf updated"
  fi

  # --- Option 2: dnsmasq ---
  if systemctl is-active dnsmasq >/dev/null 2>&1; then
    log "Found dnsmasq — stopping and disabling..."
    svc_disable dnsmasq 2>/dev/null || true
    log "dnsmasq stopped and disabled"
  fi

  # --- Option 3: named/bind ---
  if systemctl is-active named 2>/dev/null || systemctl is-active bind9 2>/dev/null; then
    log "Found BIND/named — stopping and disabling..."
    svc_disable named 2>/dev/null || true
    svc_disable bind9 2>/dev/null || true
    log "BIND/named stopped and disabled"
  fi

  # --- Wait a moment for port to be released ---
  log "Waiting for port 53 to be released..."
  sleep 3

  # --- Verify port 53 is free ---
  if ss -tlnup 2>/dev/null | grep -qE ":53[[:space:]]|:53$"; then
    log_err "Port 53 is STILL in use by:"
    ss -tlnup 2>/dev/null | grep -E ":53[[:space:]]|:53$"
    log_err "Manual intervention required. Find the process and stop it."
    return 1
  fi

  log "Port 53 is now free"

  # --- Ensure resolv.conf points to localhost ---
  if ! grep -q "nameserver 127.0.0.1" /etc/resolv.conf 2>/dev/null; then
    log "Updating /etc/resolv.conf..."
    cat > /etc/resolv.conf <<EOF
search $DOMAIN
nameserver 127.0.0.1
EOF
  fi

  # --- Restart Samba ---
  log "Restarting Samba service..."
  svc_restart samba.service

  # --- Wait for Samba to fully start ---
  sleep 3

  # --- Verify port 53 is now listening ---
  if ss -tlnup 2>/dev/null | grep -qE ":53[[:space:]]|:53$"; then
    log_ok "Port 53 is now listening (Samba DNS active)"
    log "Port 53 listeners:"
    ss -tlnup 2>/dev/null | grep -E ":53[[:space:]]|:53$"
  else
    log_warn "Port 53 is NOT listening after Samba restart"
    log "Check Samba logs: journalctl -u samba -n 50 --no-pager"
    return 1
  fi

  # --- Quick DNS test ---
  log "Testing DNS resolution..."
  local test_result
  test_result="$(dig +short "${FQDN}" @127.0.0.1 2>/dev/null || echo "")"
  if [[ -n "$test_result" ]]; then
    log_ok "DNS resolves ${FQDN} -> ${test_result}"
  else
    log_warn "DNS resolution test failed — check Samba DNS configuration"
  fi

  log_ok "DNS port 53 fix complete"
}

step_fix_dns_port
