#!/usr/bin/env bash
# ============================================================
#  Module 10 — AD Backup & Restore
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

step_backup() {
  require_root
  local action="${1:-backup}"

  case "$action" in
    backup)
      log_step "Creating AD backup"
      local backup_subdir="${BACKUP_DIR}/$(date +%Y%m%d_%H%M%S)"
      mkdir_p "$backup_subdir"

      # --- Offline backup via samba-tool ---
      samba_tool domain backup offline --targetdir="$backup_subdir"

      # --- Backup config files ---
      mkdir_p "${backup_subdir}/etc"
      for f in "$SMB_CONF" "$DHCP_CONF" /etc/resolv.conf /etc/hosts /etc/chrony.conf; do
        if [[ -f "$f" ]]; then
          run_root cp -a "$f" "${backup_subdir}/etc/"
        fi
      fi

      # --- Backup config.cfg ---
      local toolkit_cfg
      toolkit_cfg="$(_resolve_config)"
      run_root cp -a "$toolkit_cfg" "${backup_subdir}/config.cfg"

      # --- List result ---
      log "Backup created at: $backup_subdir"
      find "$backup_subdir" -maxdepth 1 -type f -name '*.tar.bz2' | sort
      log_ok "Backup complete"

      # --- Cleanup old backups (keep last 10) ---
      local backups
      backups="$(find "$BACKUP_DIR" -maxdepth 1 -type d | sort | tail -n +11)"
      if [[ -n "$backups" ]]; then
        echo "$backups" | while read -r old; do
          log "Removing old backup: $old"
          rm -rf "$old"
        done
      fi
      ;;

    restore)
      local restore_dir="${2:-}"
      if [[ -z "$restore_dir" ]]; then
        log_err "Usage: samba-ad.sh backup restore /path/to/backup/dir"
        exit 1
      fi
      if [[ ! -d "$restore_dir" ]]; then
        log_err "Backup directory not found: $restore_dir"
        exit 1
      fi

      confirm "WARNING: Restore will OVERWRITE the current AD. Continue?" || exit 0

      log_step "Restoring AD from: $restore_dir"
      svc_disable samba.service 2>/dev/null || true
      run_root pkill -x samba 2>/dev/null || true
      sleep 2

      # --- Restore backup ---
      local backup_file
      backup_file="$(find "$restore_dir" -maxdepth 1 -name '*.tar.bz2' | sort | tail -n1)"
      if [[ -z "$backup_file" ]]; then
        log_err "No backup file found in $restore_dir"
        exit 1
      fi

      samba_tool domain backup restore --targetdir="$restore_dir" --backupfile="$backup_file"

      svc_enable samba.service
      log_ok "Restore complete. Reboot recommended."
      ;;

    list)
      log "Available backups:"
      if [[ -d "$BACKUP_DIR" ]]; then
        find "$BACKUP_DIR" -maxdepth 1 -type d | sort | tail -n +2 | while read -r d; do
          local size
          size="$(du -sh "$d" 2>/dev/null | cut -f1)"
          echo "  $d ($size)"
        done
      else
        echo "  (none)"
      fi
      ;;

    *)
      log_err "Unknown action: $action"
      echo "Usage: samba-ad.sh backup {backup|restore|list}"
      exit 1
      ;;
  esac
}

step_backup "${1:-backup}"
