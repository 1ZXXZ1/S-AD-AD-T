#!/usr/bin/env bash
# ============================================================
#  Samba AD DC Auto-Deploy Toolkit
#  ALT Server 11.1 | Samba 4
#
#  Usage:
#    ./samba-ad.sh install          — Full install (bootstrap + provision + shares + users + GPO + DFS + security + firewall)
#    ./samba-ad.sh install --step bootstrap   — Run single step
#    ./samba-ad.sh install --step shares      — Run single step
#    ./samba-ad.sh delete           — Remove domain (with confirmation)
#    ./samba-ad.sh delete --full    — Remove domain AND packages
#    ./samba-ad.sh reload           — Re-read config, restart services
#    ./samba-ad.sh status           — Show current status
#    ./samba-ad.sh backup           — Create AD backup
#    ./samba-ad.sh backup restore /path  — Restore from backup
#    ./samba-ad.sh backup list      — List backups
#    ./samba-ad.sh users --csv /path/to/users_auto.csv  — Create users from unified CSV
#    ./samba-ad.sh users --auto                         — Alias of users
#    ./samba-ad.sh gpo [all|usb|audit|drive-maps|folder-redir|apps-install|list]
#    ./samba-ad.sh titration [--quick|--load|--report]
#    ./samba-ad.sh fix-dns          — Fix port 53 conflict (systemd-resolved, etc.)
#    ./samba-ad.sh fix-ssl          — Configure TLS/LDAPS (port 636)
#    ./samba-ad.sh help
#
#  Config: edit config.cfg before running
# ============================================================
set -euo pipefail

# ── Resolve toolkit root ─────────────────────────────────────
TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TOOLKIT_ROOT
MODULES_DIR="${TOOLKIT_ROOT}/modules"
LIB_SH="${MODULES_DIR}/lib.sh"

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_banner() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║       Samba AD DC Auto-Deploy Toolkit            ║"
  echo "║       ALT Server 11.1 | Samba 4                  ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ── Load library ─────────────────────────────────────────────
if [[ ! -f "$LIB_SH" ]]; then
  echo "[FATAL] Library not found: $LIB_SH" >&2
  exit 1
fi
# shellcheck source=modules/lib.sh
source "$LIB_SH"
_load_config

# ── Step runners ─────────────────────────────────────────────
STEPS_ORDER=(
  "01_bootstrap.sh"
  "02_provision.sh"
  "03_shares.sh"
  "04_dhcp.sh"
  "05_users.sh"
  "06_gpo.sh"
  "07_dfs.sh"
  "08_security.sh"
  "09_firewall.sh"
)

run_step() {
  local step="$1"
  shift
  local script="${MODULES_DIR}/${step}"
  if [[ ! -f "$script" ]]; then
    echo -e "${RED}[ERROR] Module not found: $script${NC}" >&2
    return 1
  fi
  echo -e "${GREEN}>>> Running: ${step} ${*}${NC}"
  bash "$script" "$@"
  echo -e "${GREEN}>>> Done: ${step}${NC}"
  echo
}

run_all_steps() {
  _banner
  log_step "Full install starting..."
  echo "  Domain:  ${DOMAIN}"
  echo "  Realm:   ${REALM}"
  echo "  NetBIOS: ${NETBIOS}"
  echo "  FQDN:    ${FQDN}"
  echo "  IP:      ${HOST_IP}"
  echo

  for step in "${STEPS_ORDER[@]}"; do
    run_step "$step"
  done

  # FIX v1.1.3: Auto-configure TLS if enabled in config
  if [[ "${TLS_ENABLED:-no}" == "yes" ]]; then
    run_step "12_fix_ssl.sh"
  fi

  echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  INSTALL COMPLETE${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
  echo
  echo "  Domain:  ${DOMAIN}"
  echo "  Server:  ${FQDN} (${HOST_IP})"
  echo "  Admin:   ${ADMIN_USER}"
  echo
  echo "  Verify:  samba-tool domain info ${FQDN}"
  echo "  Users:   samba-tool user list"
  echo "  Shares:  smbclient -L ${FQDN} -U ${ADMIN_USER}"
  echo "  GPOs:    ./samba-ad.sh gpo list"
  echo "  Validate: ./samba-ad.sh titration --report"
}

# ── Commands ──────────────────────────────────────────────────

cmd_install() {
  local single_step=""
  local gpo_action="all"

  while (($#)); do
    case "$1" in
      --step)
        single_step="${2:-}"
        shift 2
        ;;
      --gpo)
        gpo_action="${2:-all}"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ -n "$single_step" ]]; then
    _banner
    # FIX v1.1.3: Include fix modules in step search
    local all_steps=(
      "${STEPS_ORDER[@]}"
      "10_backup.sh"
      "11_titration.sh"
      "12_fix_ssl.sh"
      "13_fix_dns_port.sh"
      "configure_users_auto.sh"
    )
    local found=""
    for step in "${all_steps[@]}"; do
      if [[ "$step" == *"$single_step"* ]]; then
        found="$step"
        break
      fi
    done
    if [[ -z "$found" ]]; then
      echo -e "${RED}[ERROR] Unknown step: $single_step${NC}"
      echo "Available steps:"
      for step in "${all_steps[@]}"; do
        echo "  ${step}"
      done
      exit 1
    fi
    if [[ "$found" == "06_gpo.sh" ]]; then
      run_step "$found" "$gpo_action"
    else
      run_step "$found"
    fi
  else
    run_all_steps
  fi
}

cmd_delete() {
  require_root
  local full="no"

  while (($#)); do
    case "$1" in
      --full) full="yes"; shift ;;
      *) shift ;;
    esac
  done

  echo -e "${RED}WARNING: This will REMOVE the Samba AD DC!${NC}"
  echo "  Domain: ${DOMAIN}"
  echo "  All users, groups, GPOs, and domain data will be deleted."
  echo

  if [[ "$full" == "yes" ]]; then
    echo -e "${RED}  FULL mode: packages will also be removed.${NC}"
  fi

  confirm "Are you absolutely sure?" || exit 0

  log_step "Removing Samba AD DC..."

  # Stop services
  svc_disable samba.service 2>/dev/null || true
  run_root pkill -x samba 2>/dev/null || true
  sleep 2

  # Remove domain data
  log "Removing domain data..."
  run_root rm -rf /var/lib/samba/private
  run_root rm -rf "${SYSVOL_ROOT}"
  run_root rm -f "$SMB_CONF"

  if [[ "$full" == "yes" ]]; then
    log "Removing packages..."
    run_root apt-get remove -y task-samba-dc samba samba-common-bin samba-dc 2>/dev/null || true
    run_root apt-get autoremove -y 2>/dev/null || true
    log "Removing data directories..."
    run_root rm -rf "$SHARES_ROOT" "$PROFILES_ROOT" "$REDIRECT_ROOT" "$HOMES_ROOT" "$DFS_ROOT" "$SNAPSHOTS_ROOT" "$APPS_ROOT" "$WORKDIR"
  fi

  # Restore DNS
  log "Restoring DNS..."
  cat > /etc/resolv.conf <<EOF
nameserver ${DNS_FORWARDER_1}
nameserver ${DNS_FORWARDER_2}
EOF

  echo -e "${GREEN}Domain removed.${NC}"
  echo "To reinstall: ./samba-ad.sh install"
}

cmd_reload() {
  require_root
  log_step "Reloading configuration..."

  # Re-read config
  export _CONFIG_LOADED=0
  _load_config

  log "Restarting Samba..."
  svc_restart samba.service
  svc_restart chronyd 2>/dev/null || true

  log "Reloading firewall..."
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --reload 2>/dev/null || true
  fi

  log_ok "Configuration reloaded"
}

cmd_status() {
  _banner
  echo "  Domain:    ${DOMAIN} (${REALM})"
  echo "  FQDN:      ${FQDN}"
  echo "  IP:        ${HOST_IP}"
  echo "  Config:    $(_resolve_config)"
  echo

  echo "── Services ──────────────────────────────────────"
  echo "  samba:    $(svc_status samba.service)"
  echo "  chrony:   $(svc_status chronyd)"
  local dhcpd_status
  dhcpd_status="$(systemctl is-active dhcpd.service 2>/dev/null || true)"
  [[ -z "$dhcpd_status" ]] && dhcpd_status="not installed"
  echo "  dhcpd:    ${dhcpd_status}"
  if command -v chronyc >/dev/null 2>&1; then
    echo "  chronyc tracking:"
    chronyc tracking 2>/dev/null | sed 's/^/    /' || true
    echo "  chronyc sources:"
    chronyc sources 2>/dev/null | sed 's/^/    /' || true
  fi
  echo

  if is_provisioned; then
    echo "── Domain ───────────────────────────────────────"
    echo -n "  Provisioned: "
    echo -e "${GREEN}YES${NC}"
    samba_tool domain info "$FQDN" 2>/dev/null | sed 's/^/  /' || true
    echo

    echo "── Users ────────────────────────────────────────"
    samba_tool user list 2>/dev/null | sort | sed 's/^/  /'
    echo

    echo "── Groups ───────────────────────────────────────"
    samba_tool group list 2>/dev/null | sort | sed 's/^/  /'
    echo

    echo "── Shares ───────────────────────────────────────"
    run_root testparm -s 2>/dev/null | grep '^\[' | sed 's/^/  /'
    echo

    echo "── GPOs ─────────────────────────────────────────"
    samba_tool gpo listall -H ldap://"${FQDN}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" 2>/dev/null | head -20 | sed 's/^/  /' || echo "  (unable to query GPOs)"
    echo

    echo "── DNS ──────────────────────────────────────────"
    samba_tool dns zonelist "$FQDN" -U "${ADMIN_USER}%${ADMIN_PASS}" 2>/dev/null | sed 's/^/  /' || echo "  (unable to query)"
  else
    echo -n "  Provisioned: "
    echo -e "${RED}NO${NC}"
    echo "  Run './samba-ad.sh install' to deploy."
  fi
  echo
}

cmd_backup() {
  local action="${1:-backup}"
  local extra="${2:-}"

  case "$action" in
    backup)
      bash "${MODULES_DIR}/10_backup.sh" backup
      ;;
    restore)
      if [[ -z "$extra" ]]; then
        echo -e "${RED}Usage: samba-ad.sh backup restore /path/to/backup${NC}"
        exit 1
      fi
      bash "${MODULES_DIR}/10_backup.sh" restore "$extra"
      ;;
    list)
      bash "${MODULES_DIR}/10_backup.sh" list
      ;;
    *)
      echo -e "${RED}Usage: samba-ad.sh backup {backup|restore|list}${NC}"
      exit 1
      ;;
  esac
}

cmd_users() {
  local csv=""
  while (($#)); do
    case "$1" in
      --csv) csv="${2:-}"; shift 2 ;;
      --auto) shift ;;
      *) shift ;;
    esac
  done

  if [[ -n "$csv" ]]; then
    export USERS_CSV="$csv"
  fi

  run_step "05_users.sh"
}

cmd_gpo() {
  local action="${1:-all}"
  case "$action" in
    list|listall|status)
      require_root
      samba_tool gpo listall -H ldap://"${FQDN}" -U "${ADMIN_USER}"%"${ADMIN_PASS}"
      ;;
    show)
      require_root
      local guid="${2:-}"
      if [[ -z "$guid" ]]; then
        echo -e "${RED}Usage: $0 gpo show <GUID>${NC}" >&2
        exit 1
      fi
      samba_tool gpo show "$guid" -H ldap://"${FQDN}" -U "${ADMIN_USER}"%"${ADMIN_PASS}"
      ;;
    all|usb|audit|drive-maps|folder-redir|apps-install)
      run_step "06_gpo.sh" "$action"
      ;;
    *)
      echo -e "${RED}Unknown GPO action: $action${NC}" >&2
      echo "Usage: $0 gpo [all|usb|audit|drive-maps|folder-redir|apps-install|list|show <GUID>]" >&2
      exit 1
      ;;
  esac
}

cmd_titration() {
  run_step "11_titration.sh" "$@"
}

# FIX v1.1.3: New command — fix DNS port 53 conflict
cmd_fix_dns() {
  run_step "13_fix_dns_port.sh"
}

# FIX v1.1.3: New command — fix TLS/LDAPS (port 636)
cmd_fix_ssl() {
  run_step "12_fix_ssl.sh"
}

cmd_help() {
  _banner
  cat <<HELPEOF
Usage: $0 <command> [options]

Commands:
  install [--step <name>]    Full installation or single step
  delete [--full]            Remove domain (full = also remove packages)
  reload                     Re-read config and restart services
  status                     Show current domain status
  backup {backup|restore|list}  AD backup management
  users [--csv <file>]       Create users from users_auto.csv
  users --auto [--csv <file>]  Alias of users
  gpo [all|usb|audit|drive-maps|folder-redir|apps-install|list|show <GUID>]
  titration [--quick|--load|--report]  Comprehensive validation & load test
  fix-dns                    Fix port 53 conflict (systemd-resolved, dnsmasq, etc.)
  fix-ssl                    Configure TLS/LDAPS (port 636) with self-signed cert
  help                       Show this help

Single steps (--step):
  bootstrap      Install packages, set hostname, DNS
  provision      Provision AD domain (includes reverse DNS zone)
  shares         Configure file shares
  dhcp           Configure DHCP template
  users          Create users and groups
  gpo            Configure Group Policy Objects
  dfs            Configure DFS namespace
  security       Password policy and security hardening
  firewall       Configure firewall rules
  fix_ssl        Configure TLS/LDAPS (port 636)
  fix_dns_port   Fix port 53 conflict
  titration      Run validation tests

Config file: config.cfg (edit before first install!)

Examples:
  $0 install                    # Full deployment
  $0 install --step bootstrap   # Only install packages
  $0 install --step provision   # Only provision domain
  $0 fix-dns                    # Fix port 53 conflict
  $0 fix-ssl                    # Enable LDAPS
  $0 status                     # Check status
  $0 users                      # Import from templates/users_auto.csv
  $0 users --csv ./users_auto.csv
  $0 gpo usb                    # Only USB restriction GPO
  $0 gpo list                   # List GPOs using config credentials
  $0 titration                  # Full validation + load test
  $0 titration --quick          # Quick check (no load test)
  $0 titration --load           # Load test only
  $0 titration --report         # Save report to file
  $0 backup                     # Create backup
  $0 delete --full              # Complete removal
HELPEOF
}

# ── Main dispatch ────────────────────────────────────────────
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  install)
    cmd_install "$@"
    ;;
  delete|uninstall|remove)
    cmd_delete "$@"
    ;;
  reload|restart)
    cmd_reload
    ;;
  status|info)
    cmd_status
    ;;
  backup)
    cmd_backup "$@"
    ;;
  users)
    cmd_users "$@"
    ;;
  gpo)
    cmd_gpo "$@"
    ;;
  titration|test|validate)
    cmd_titration "$@"
    ;;
  fix-dns|fix_dns|fixdns)
    cmd_fix_dns
    ;;
  fix-ssl|fix_ssl|fixssl)
    cmd_fix_ssl
    ;;
  help|-h|--help|"")
    cmd_help
    ;;
  *)
    echo -e "${RED}Unknown command: $COMMAND${NC}"
    echo "Run '$0 help' for usage."
    exit 1
    ;;
esac
