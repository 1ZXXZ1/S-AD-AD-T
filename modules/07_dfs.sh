#!/usr/bin/env bash
# ============================================================
#  Module 07 — DFS Namespace
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

step_dfs() {
  require_root
  log_step "Configuring DFS namespace"

  # --- Enable msdfs in smb.conf ---
  if ! grep -q '^ *host msdfs = yes' "$SMB_CONF" 2>/dev/null; then
    backup_file "$SMB_CONF"
    python3 - <<PY
from pathlib import Path
path = Path('${SMB_CONF}')
text = path.read_text(encoding='utf-8')
needle = 'workgroup = ${NETBIOS}\n'
insert = needle + 'host msdfs = yes\n'
if 'host msdfs = yes' not in text:
    if needle not in text:
        raise SystemExit('Could not find workgroup line in smb.conf')
    text = text.replace(needle, insert, 1)
    path.write_text(text, encoding='utf-8')
PY
  fi

  # --- Create DFS root and links ---
  mkdir_p "$DFS_ROOT"

  while IFS='|' read -r link_name target_share; do
    link_name="$(echo "$link_name" | xargs)"
    target_share="$(echo "$target_share" | xargs)"
    [[ -z "$link_name" ]] && continue

    local target_unc="msdfs:${FQDN}\\${target_share}"
    ln -sfn "$target_unc" "${DFS_ROOT}/${link_name}"
    log "DFS link: ${link_name} -> ${target_share}"
  done <<< "$DFS_LINKS"

  # --- Additional common DFS links if configured ---
  if [[ -d "${SHARES_ROOT}/common" ]]; then
    ln -sfn "msdfs:${FQDN}\\common" "${DFS_ROOT}/common" 2>/dev/null || true
    # Individual folders
    for sub in "${SHARES_ROOT}/common"/*/; do
      if [[ -d "$sub" ]]; then
        local folder_name
        folder_name="$(basename "$sub")"
        ln -sfn "msdfs:${FQDN}\\common\\${folder_name}" "${DFS_ROOT}/${folder_name}" 2>/dev/null || true
      fi
    done
  fi

  # --- Kerberos SPN ---
  samba_tool spn add "cifs/${DOMAIN}" "${NETBIOS}\$" 2>/dev/null || true
  samba_tool spn add "cifs/${FQDN}" "${NETBIOS}\$" 2>/dev/null || true

  svc_restart samba.service 2>/dev/null || true

  # --- Verify ---
  log "DFS links:"
  run_root ls -la "$DFS_ROOT" 2>/dev/null | head -20
  run_root testparm -s >/dev/null 2>&1

  log_ok "DFS configured"
}

step_dfs
