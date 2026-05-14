#!/usr/bin/env bash
# ============================================================
#  Module 04 — DHCP Configuration
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

step_dhcp() {
  require_root
  log_step "Configuring DHCP for ${DOMAIN}"

  backup_file "$DHCP_CONF"

  cat > "$DHCP_CONF" <<EOF
# Samba AD Toolkit — DHCP template for ${DOMAIN}
ddns-update-style interim;
update-static-leases on;
ddns-updates on;
authoritative;
option domain-name "${DOMAIN}";
option domain-name-servers 127.0.0.1;
default-lease-time ${DEFAULT_LEASE_TIME};
max-lease-time ${MAX_LEASE_TIME};

subnet ${SUBNET} netmask ${NETMASK} {
    range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
    option routers ${GATEWAY};
    option broadcast-address ${BROADCAST};
}

# DNS update hooks are prepared but the service stays disabled.
EOF

  if [[ "$DHCP_ENABLED" == "yes" ]]; then
    log "Enabling DHCP service..."
    svc_enable dhcpd.service
  else
    log "DHCP is DISABLED (service stays off). Set DHCP_ENABLED=yes in config.cfg to enable."
    svc_disable dhcpd.service 2>/dev/null || true
  fi

  log_ok "DHCP configured (enabled=${DHCP_ENABLED})"
}

step_dhcp
