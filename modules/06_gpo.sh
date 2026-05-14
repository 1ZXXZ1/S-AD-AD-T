#!/usr/bin/env bash
# ============================================================
#  Module 06 — GPO Management (USB, Audit, Drive Maps, Folder Redirect, Apps)
# ============================================================
#  This script calls the Python GPO helper (06_gpo.py)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

step_gpo() {
  require_root
  log_step "Configuring Group Policy Objects"

  local gpo_script="${SCRIPT_DIR}/06_gpo.py"
  if [[ ! -f "$gpo_script" ]]; then
    log_err "GPO script not found: $gpo_script"
    return 1
  fi

  # Ensure Python dependencies
  if ! python3 -c "import ldb; import samba" 2>/dev/null; then
    log_err "Python samba/ldb modules not available. Install: apt-get install python3-module-samba ldb-tools"
    return 1
  fi

  local action="${1:-all}"
  local config_file
  config_file="$(_resolve_config)"

  case "$action" in
    usb)
      log "Configuring USB restriction GPO..."
      python3 "$gpo_script" --config "$config_file" --gpo usb
      ;;
    audit)
      log "Configuring Audit GPO..."
      python3 "$gpo_script" --config "$config_file" --gpo audit
      ;;
    drive-maps)
      log "Configuring Drive Maps GPO..."
      python3 "$gpo_script" --config "$config_file" --gpo drive-maps
      ;;
    folder-redir)
      log "Configuring Folder Redirection GPO..."
      python3 "$gpo_script" --config "$config_file" --gpo folder-redir
      ;;
    apps-install)
      log "Configuring Apps Auto-Install GPO..."
      python3 "$gpo_script" --config "$config_file" --gpo apps-install
      ;;
    all)
      if [[ "$GPO_USB_RESTRICTION_ENABLED" == "yes" ]]; then
        python3 "$gpo_script" --config "$config_file" --gpo usb
      else
        log "USB GPO skipped (disabled in config)"
      fi
      if [[ "$GPO_AUDIT_ENABLED" == "yes" ]]; then
        python3 "$gpo_script" --config "$config_file" --gpo audit
      else
        log "Audit GPO skipped (disabled in config)"
      fi
      if [[ "$GPO_DRIVE_MAPS_ENABLED" == "yes" ]]; then
        python3 "$gpo_script" --config "$config_file" --gpo drive-maps
      else
        log "Drive Maps GPO skipped (disabled in config)"
      fi
      if [[ "$GPO_FOLDER_REDIR_ENABLED" == "yes" ]]; then
        python3 "$gpo_script" --config "$config_file" --gpo folder-redir
      else
        log "Folder Redirection GPO skipped (disabled in config)"
      fi
      if [[ "$GPO_APPS_INSTALL_ENABLED" == "yes" ]]; then
        python3 "$gpo_script" --config "$config_file" --gpo apps-install
      else
        log "Apps Install GPO skipped (disabled in config)"
      fi
      ;;
    *)
      log_err "Unknown GPO action: $action"
      echo "Usage: $0 {usb|audit|drive-maps|folder-redir|apps-install|all}"
      return 1
      ;;
  esac

  log "Resetting SYSVOL ACLs after GPO changes..."
  if samba_tool ntacl sysvolreset >/dev/null 2>&1; then
    log "SYSVOL ACLs synchronized"
  else
    log_warn "SYSVOL ACL reset failed — client-side GPO access should be checked manually"
  fi

  log_ok "GPO configuration complete"
}

step_gpo "${1:-all}"
