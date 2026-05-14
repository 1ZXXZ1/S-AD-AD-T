#!/usr/bin/env bash
# ============================================================
#  Module 03 — Configure File Shares
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

step_shares() {
  require_root
  log_step "Configuring Samba file shares"

  # --- Build share config block ---
  local share_block=""
  local share_list=()
  while IFS='|' read -r name subdir ro br go cm dm; do
    name="$(echo "$name" | xargs)"
    subdir="$(echo "$subdir" | xargs)"
    ro="$(echo "$ro" | xargs)"
    br="$(echo "$br" | xargs)"
    go="$(echo "$go" | xargs)"
    cm="$(echo "$cm" | xargs)"
    dm="$(echo "$dm" | xargs)"

    [[ -z "$name" ]] && continue
    share_list+=("$name")

    local share_path="${SHARES_ROOT}/${subdir}"
    case "$name" in
      profiles) share_path="$PROFILES_ROOT" ;;
      redirected) share_path="$REDIRECT_ROOT" ;;
      apps) share_path="$APPS_ROOT" ;;
    esac

    local extra=""
    # Add VFS for regular shares, skip profiles/redirected/dfs/apps
    case "$name" in
      profiles|redirected|dfs|apps) extra="" ;;
      *) extra="    vfs objects = ${VFS_OBJECTS}
    shadow:snapdir = ${SNAPSHOTS_ROOT}/${subdir}
    shadow:format = @GMT-%Y.%m.%d-%H.%M.%S" ;;
    esac

    share_block+="[${name}]
    path = ${share_path}
    read only = ${ro}
    browseable = ${br}
    guest ok = ${go}
    create mask = ${cm}
    directory mask = ${dm}
"

    if [[ "$name" == "profiles" ]]; then
      share_block+="    csc policy = disable
    vfs objects = acl_xattr
    inherit acls = yes
    map acl inherit = yes
    store dos attributes = yes
    ea support = yes
"
    fi
    if [[ "$name" == "redirected" ]]; then
      share_block+="    vfs objects = acl_xattr
    inherit acls = yes
    map acl inherit = yes
    store dos attributes = yes
    ea support = yes
"
    fi
    if [[ "$name" == "users" ]]; then
      share_block+="    inherit acls = yes
    map acl inherit = yes
    store dos attributes = yes
    ea support = yes
"
    fi
    if [[ "$name" == "dfs" ]]; then
      share_block+="    msdfs root = yes
"
    fi

    share_block+="${extra}
"
  done <<< "$SHARES_LIST"

  # --- Write to smb.conf (rewrite toolkit block idempotently) ---
  backup_file "$SMB_CONF"
  if grep -q 'TOOLKIT CUSTOM SHARES' "$SMB_CONF" 2>/dev/null; then
    python3 - "$SMB_CONF" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = re.sub(r"\n# TOOLKIT CUSTOM SHARES\n.*?# TOOLKIT CUSTOM SHARES END\n?", "\n", text, flags=re.S)
path.write_text(text.rstrip() + "\n", encoding="utf-8")
PY
  fi
  cat >> "$SMB_CONF" <<EOF

# TOOLKIT CUSTOM SHARES
${share_block}# TOOLKIT CUSTOM SHARES END
EOF
  log "Shares written to $SMB_CONF"

  # --- Publish bundled app installers to the apps share ---
  if [[ -d "${TOOLKIT_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}/apps" ]]; then
    mkdir_p "$APPS_ROOT"
    run_root rsync -a "${TOOLKIT_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}/apps/" "$APPS_ROOT/"
  fi

  # --- Remove stale profile acls from any section (not supported in AD DC mode) ---
  if grep -q 'profile acls' "$SMB_CONF" 2>/dev/null; then
    python3 - "$SMB_CONF" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = re.sub(r"^\s*profile\s+acls\s*=.*\n", "", text, flags=re.I | re.M)
path.write_text(text.rstrip() + "\n", encoding="utf-8")
PY
    log "Removed all 'profile acls' directives (not supported in AD DC mode)"
  fi

  # --- Ensure base ACL settings in [global] ---
  if ! grep -q 'inherit acls' "$SMB_CONF" 2>/dev/null; then
    backup_file "$SMB_CONF"
    sed -i '/\[global\]/a\    inherit acls = yes\n    map acl inherit = yes' "$SMB_CONF" 2>/dev/null || true
    log "Added inherit acls / map acl inherit to [global]"
  fi
  if ! grep -q 'store dos attributes' "$SMB_CONF" 2>/dev/null; then
    backup_file "$SMB_CONF"
    sed -i '/\[global\]/a\    store dos attributes = yes' "$SMB_CONF" 2>/dev/null || true
    log "Added store dos attributes to [global]"
  fi

  # --- Initial snapshots ---
  for name in public departments users; do
    if [[ -d "${SHARES_ROOT}/${name}" ]]; then
      create_snapshot "$name"
    fi
  done

  # --- Verify ---
  log "Running testparm..."
  run_root testparm -s 2>&1 | tail -20
  svc_restart samba.service 2>/dev/null || true

  log_ok "Shares configured: ${share_list[*]}"
}

step_shares
