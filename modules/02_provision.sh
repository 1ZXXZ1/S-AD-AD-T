#!/usr/bin/env bash
# ============================================================
#  Module 02 — Provision Samba AD DC
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

ensure_reverse_dns() {
  [[ "${REVERSE_DNS_ENABLED:-no}" == "yes" ]] || return 0

  local octet1 octet2 octet3 host_octet reverse_zone zone_err ptr_err
  octet1="$(echo "$HOST_IP" | cut -d. -f1)"
  octet2="$(echo "$HOST_IP" | cut -d. -f2)"
  octet3="$(echo "$HOST_IP" | cut -d. -f3)"
  host_octet="$(echo "$HOST_IP" | cut -d. -f4)"
  reverse_zone="${octet3}.${octet2}.${octet1}.in-addr.arpa"

  # FIX v1.1.5: Wait for DNS RPC to be ready before creating reverse zone
  local max_wait=15
  local waited=0
  while [[ $waited -lt $max_wait ]]; do
    if samba_tool dns query 127.0.0.1 "$DOMAIN" @ ALL -U "${ADMIN_USER}%${ADMIN_PASS}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if [[ $waited -ge $max_wait ]]; then
    log_warn "DNS RPC not ready after ${max_wait}s — reverse DNS creation may fail"
  fi

  log "Ensuring reverse DNS zone..."

  zone_err="$(samba_tool dns zonecreate 127.0.0.1 "${reverse_zone}" -U "${ADMIN_USER}%${ADMIN_PASS}" 2>&1)" || {
    if echo "$zone_err" | grep -qi "already exist"; then
      log "Reverse zone ${reverse_zone} already exists"
    else
      log_warn "Reverse zone creation failed: ${zone_err}"
    fi
  }

  ptr_err="$(samba_tool dns add 127.0.0.1 "${reverse_zone}" "${host_octet}" PTR "${FQDN}." \
      -U "${ADMIN_USER}%${ADMIN_PASS}" 2>&1)" && \
    log "PTR record created: ${HOST_IP} -> ${FQDN}" || {
    if echo "$ptr_err" | grep -qi "already exist"; then
      log "PTR record already exists: ${HOST_IP} -> ${FQDN}"
    else
      log_warn "PTR record creation failed: ${ptr_err}"
    fi
  }
}

step_provision() {
  require_root
  log_step "Provisioning Samba AD DC: ${REALM} / ${NETBIOS}"

  if is_provisioned; then
    log_warn "Domain already provisioned (/var/lib/samba/private/sam.ldb exists). Skipping."
    ensure_reverse_dns
    log "To re-provision, run: samba-ad.sh delete --full"
    return 0
  fi

  # --- Remove old smb.conf if it exists and is not an AD config ---
  if [[ -f "$SMB_CONF" ]] && ! grep -q 'active directory domain controller' "$SMB_CONF"; then
    backup_file "$SMB_CONF"
    rm -f "$SMB_CONF"
  fi

  # --- Provision ---
  log "Running samba-tool domain provision..."
  samba_tool domain provision \
    --realm="$REALM" \
    --domain="$NETBIOS" \
    --server-role=dc \
    --dns-backend="$DNS_BACKEND" \
    --use-rfc2307 \
    --host-name="$HOST_SHORTNAME" \
    --host-ip="$HOST_IP" \
    --adminpass="$ADMIN_PASS"

  # --- Configure DNS forwarder ---
  log "Setting DNS forwarders..."
  sed -i "s/^[[:space:]]*dns forwarder = .*/\tdns forwarder = ${DNS_FORWARDER_1}, ${DNS_FORWARDER_2}/" "$SMB_CONF" || true

  # --- Start samba ---
  if systemctl list-unit-files | grep -q '^samba\.service'; then
    pkill -x named 2>/dev/null || true
    svc_enable samba.service
  elif [[ -x /usr/sbin/samba ]]; then
    pkill -x named 2>/dev/null || true
    run_root /usr/sbin/samba -D
  else
    log_err "Neither samba.service nor /usr/sbin/samba found."
    exit 1
  fi

  # --- Final resolv.conf ---
  cat >/etc/resolv.conf <<EOF
search $DOMAIN
nameserver 127.0.0.1
EOF

  ensure_reverse_dns

  # --- Verify ---
  log "Verifying provision..."
  log "--- Domain info ---"
  samba_tool domain info "$FQDN" || true
  log "--- DNS query (${DOMAIN}) ---"
  samba_tool dns query "$FQDN" "$DOMAIN" @ ALL -U "${ADMIN_USER}%${ADMIN_PASS}" || true
  log "--- DNS zones ---"
  samba_tool dns zonelist "$FQDN" -U "${ADMIN_USER}%${ADMIN_PASS}" || true

  # FIX v1.1.3: Verify reverse DNS
  if [[ "${REVERSE_DNS_ENABLED:-no}" == "yes" ]]; then
    local rev_test
    rev_test="$(dig +short -x "${HOST_IP}" @127.0.0.1 2>/dev/null || echo "")"
    if [[ -n "$rev_test" ]]; then
      log "Reverse DNS: ${HOST_IP} -> ${rev_test}"
    else
      log_warn "Reverse DNS not resolving yet — may need a moment to propagate"
    fi
  fi

  log_ok "Provision complete: ${REALM}"
}

step_provision
