#!/usr/bin/env bash
# ============================================================
#  Module 08 — Security Hardening & Password Policy
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

# Resolve a group name to GID via getent; fall back to wbinfo
_resolve_group_gid() {
  local gname="$1"
  local gid
  gid="$(getent group "$gname" 2>/dev/null | cut -d: -f3)"
  if [[ -n "$gid" ]]; then
    echo "$gid"
    return 0
  fi
  # Try wbinfo with both bare and domain-qualified names
  local wb_name=""
  for wb_name in "$gname" "${NETBIOS}\\${gname}"; do
    gid="$(wbinfo --group-info="$wb_name" 2>/dev/null | cut -d: -f3)" || true
    if [[ -n "$gid" ]]; then
      echo "$gid"
      return 0
    fi
  done
  return 1
}

# Build a setfacl group spec: either g:NAME:perms or g:GID:perms
_acl_group() {
  local gname="$1"
  local perms="$2"
  local gid
  if gid="$(_resolve_group_gid "$gname")"; then
    echo "g:${gid}:${perms}"
  else
    log_warn "Cannot resolve group '$gname' — ACL entry skipped"
    echo ""
  fi
}

step_security() {
  require_root
  log_step "Configuring security policies"

  # --- Password policy ---
  log "Setting password policy..."
  samba_tool domain passwordsettings set \
    --account-lockout-threshold="${LOCKOUT_THRESHOLD}" \
    --account-lockout-duration="${LOCKOUT_DURATION}" \
    --reset-account-lockout-after="${RESET_LOCKOUT_AFTER}" \
    --min-pwd-length="${PASSWORD_MIN_LENGTH}" \
    --complexity="${PASSWORD_COMPLEXITY}" >/dev/null

  log "Password policy applied:"
  samba_tool domain passwordsettings show

  # --- Common share with ACLs (if exists or Drive Maps GPO enabled) ---
  local common_share="${SHARES_ROOT}/common"
  # FIX v1.1.5: Auto-create common share directory if Drive Maps GPO is enabled
  if [[ ! -d "$common_share" && "${GPO_DRIVE_MAPS_ENABLED:-no}" == "yes" ]]; then
    log "Auto-creating common share directory (needed by Drive Maps GPO)..."
    mkdir_p "${common_share}/папка1" "${common_share}/папка2"
    mkdir_p "${SNAPSHOTS_ROOT}/common"
    chmod -R 0770 "$common_share"
    log "Common share directory created: ${common_share}"
  fi

  if [[ -d "$common_share" ]]; then
    log "Configuring ACLs for common share..."

    mkdir_p "${common_share}/папка1" "${common_share}/папка2"
    mkdir_p "${SNAPSHOTS_ROOT}/common"

    # Resolve group ACL specs
    local users_acl admins_acl
    users_acl="$(_acl_group "grp_users" "rx")"
    admins_acl="$(_acl_group "grp_admins" "rwx")"

    # Build setfacl arguments (skip empty group entries)
    local base_acl="u::rwx,g::---,o::---"
    local acl_args=""
    [[ -n "$users_acl" ]]  && acl_args="${acl_args},${users_acl}"
    [[ -n "$admins_acl" ]] && acl_args="${acl_args},${admins_acl}"

    if [[ -n "$acl_args" ]]; then
      # Owner full, others none + group ACLs
      run_root setfacl -m "${base_acl}${acl_args}" "$common_share"
      run_root setfacl -d -m "${base_acl}${acl_args}" "$common_share"
      log "ACL applied to common share root"
    else
      log_warn "No group ACLs could be resolved for common share — skipping"
    fi

    # папка1 — read/write for all groups
    local f1_acl=""
    local f1_users="$(_acl_group "grp_users" "rwx")"
    local f1_admins="$(_acl_group "grp_admins" "rwx")"
    [[ -n "$f1_users" ]]  && f1_acl="${f1_acl},${f1_users}"
    [[ -n "$f1_admins" ]] && f1_acl="${f1_acl},${f1_admins}"
    if [[ -n "$f1_acl" ]]; then
      run_root setfacl -m "u::rwx,g::---,o::---${f1_acl}" "${common_share}/папка1"
      run_root setfacl -d -m "u::rwx,g::---,o::---${f1_acl}" "${common_share}/папка1"
      log "ACL applied to папка1 (rwx for users + admins)"
    fi

    # папка2 — read-only for users, write for admins
    local f2_acl=""
    local f2_users="$(_acl_group "grp_users" "rx")"
    local f2_admins="$(_acl_group "grp_admins" "rwx")"
    [[ -n "$f2_users" ]]  && f2_acl="${f2_acl},${f2_users}"
    [[ -n "$f2_admins" ]] && f2_acl="${f2_acl},${f2_admins}"
    if [[ -n "$f2_acl" ]]; then
      run_root setfacl -m "u::rwx,g::---,o::---${f2_acl}" "${common_share}/папка2"
      run_root setfacl -d -m "u::rwx,g::---,o::---${f2_acl}" "${common_share}/папка2"
      log "ACL applied to папка2 (rx for users, rwx for admins)"
    fi

    # Add common share to smb.conf if not present
    if ! grep -q '^\[common\]' "$SMB_CONF" 2>/dev/null; then
      cat >> "$SMB_CONF" <<EOF

[common]
    path = ${SHARES_ROOT}/common
    read only = no
    browseable = yes
    guest ok = no
    create mask = 0660
    directory mask = 0770
    inherit acls = yes
    map acl inherit = yes
    vfs objects = acl_xattr shadow_copy2
    shadow:snapdir = ${SNAPSHOTS_ROOT}/common
    shadow:format = @GMT-%Y.%m.%d-%H.%M.%S
EOF
      log "Added [common] share to smb.conf"
    fi

    log "ACL for common share:"
    run_root getfacl "$common_share" 2>/dev/null | head -20
  else
    log "Common share directory not found (${common_share}) — skipping ACL setup"
    log "Create it with: mkdir -p ${common_share}/{папка1,папка2}"
  fi

  # --- Disable SMBv1 for security ---
  log "Hardening: disabling SMBv1..."
  if ! grep -q 'server min protocol' "$SMB_CONF" 2>/dev/null; then
    backup_file "$SMB_CONF"
    sed -i '/\[global\]/a\    server min protocol = SMB2_10' "$SMB_CONF" 2>/dev/null || true
  fi

  svc_restart samba.service 2>/dev/null || true

  log_ok "Security hardening complete"
}

step_security
