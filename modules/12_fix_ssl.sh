#!/usr/bin/env bash
# ============================================================
#  Module 12 — TLS / LDAPS Configuration
#
#  Generates a self-signed TLS certificate and configures
#  Samba AD DC to listen on port 636 (LDAPS).
#
#  Usage:
#    ./samba-ad.sh install --step fix_ssl
#    sudo bash modules/12_fix_ssl.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

step_fix_ssl() {
  require_root
  log_step "Configuring TLS for LDAPS (port 636)"

  local SSL_DIR="/var/lib/samba/private/tls"
  local CERT_FILE="${SSL_DIR}/cert.pem"
  local KEY_FILE="${SSL_DIR}/key.pem"
  local CA_FILE="${SSL_DIR}/ca.pem"

  # --- Create TLS directory ---
  mkdir_p "$SSL_DIR"
  chmod 0700 "$SSL_DIR"

  # --- Generate self-signed certificate if not exists ---
  if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
    log "TLS certificate already exists at ${CERT_FILE}"
    log "  Subject: $(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null || echo 'unknown')"
    log "  Expires: $(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2 || echo 'unknown')"
    log "To regenerate: rm -rf ${SSL_DIR} and re-run this module"
  else
    log "Generating self-signed TLS certificate..."

    # Generate certificate with proper SAN (Subject Alternative Name)
    # Required for LDAPS to work correctly
    openssl req -x509 -nodes -days 3650 \
      -newkey rsa:2048 \
      -keyout "$KEY_FILE" \
      -out "$CERT_FILE" \
      -subj "/CN=${FQDN}/O=${NETBIOS}/C=RU" \
      -addext "subjectAltName=DNS:${FQDN},DNS:${HOST_SHORTNAME},IP:${HOST_IP}" \
      2>/dev/null

    chmod 0600 "$KEY_FILE"
    chmod 0644 "$CERT_FILE"

    # Create CA file (same as cert for self-signed)
    cp -a "$CERT_FILE" "$CA_FILE"

    log "Certificate generated:"
    log "  Cert:  ${CERT_FILE}"
    log "  Key:   ${KEY_FILE}"
    log "  CA:    ${CA_FILE}"
    log "  Subject: $(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null)"
    log "  SAN:      $(openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null | tail -1)"
  fi

  # --- Configure smb.conf ---
  log "Configuring TLS in smb.conf..."

  # Backup first
  backup_file "$SMB_CONF"

  # Remove old TLS settings if present (idempotent)
  sed -i '/^[[:space:]]*tls enabled/d' "$SMB_CONF" 2>/dev/null || true
  sed -i '/^[[:space:]]*tls certfile/d' "$SMB_CONF" 2>/dev/null || true
  sed -i '/^[[:space:]]*tls keyfile/d' "$SMB_CONF" 2>/dev/null || true
  sed -i '/^[[:space:]]*tls cafile/d' "$SMB_CONF" 2>/dev/null || true

  # Add TLS settings to [global] section
  # Use python for reliable insertion after [global]
  python3 - <<PY
from pathlib import Path
import re

path = Path('${SMB_CONF}')
text = path.read_text(encoding='utf-8')

tls_block = """    tls enabled  = yes
    tls certfile = ${CERT_FILE}
    tls keyfile  = ${KEY_FILE}
    tls cafile   = ${CA_FILE}"""

# Find [global] section and insert after it
pattern = r'(\[global\][^\[]*)'
match = re.search(pattern, text, re.DOTALL)
if match:
    # Insert before the next section or at end
    insert_pos = match.end()
    text = text[:insert_pos] + '\n' + tls_block + '\n' + text[insert_pos:]
    path.write_text(text, encoding='utf-8')
    print("TLS settings added to [global] section")
else:
    print("ERROR: Could not find [global] section in smb.conf")
    raise SystemExit(1)
PY

  # --- Verify smb.conf syntax ---
  log "Verifying smb.conf..."
  run_root testparm -s 2>&1 | tail -5

  # --- Restart Samba ---
  log "Restarting Samba service..."
  svc_restart samba.service

  # --- Verify port 636 ---
  local ldaps_listening="no"
  for _ in {1..10}; do
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ':636$'; then
      ldaps_listening="yes"
      break
    fi
    sleep 1
  done
  if [[ "$ldaps_listening" == "yes" ]]; then
    log_ok "Port 636 is now listening (LDAPS active)"
  else
    log_warn "Port 636 is NOT listening after restart — check Samba logs: journalctl -u samba -n 50"
  fi

  # --- Test LDAPS connection ---
  log "Testing LDAPS connection..."
  if command -v ldapsearch >/dev/null 2>&1; then
    if LDAPTLS_REQCERT=allow ldapsearch -x -H ldaps://"${FQDN}" -b "${DOMAIN_DN}" -D "${ADMIN_USER}@${REALM}" -w "${ADMIN_PASS}" \
        -s base "(objectclass=*)" dn 2>/dev/null | grep -q "dn:"; then
      log_ok "LDAPS connection verified"
    else
      log_warn "LDAPS test query failed — may need TLS troubleshooting"
    fi
  else
    log "ldapsearch not available — skipping LDAPS connection test"
    log "Install with: apt-get install openldap-clients"
  fi

  log_ok "TLS/LDAPS configuration complete"
}

step_fix_ssl
