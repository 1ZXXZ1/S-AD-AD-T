#!/usr/bin/env bash
# ============================================================
#  Samba AD DC Toolkit — Common Library
# ============================================================

# Resolve config path: TOOLKIT_ROOT (exported), TOOLKIT_CFG env, or BASH_SOURCE fallback
_resolve_config() {
  local cfg="${TOOLKIT_CFG:-}"
  if [[ -z "$cfg" ]]; then
    # TOOLKIT_ROOT is exported by samba-ad.sh — use it first
    local root="${TOOLKIT_ROOT:-}"
    if [[ -n "$root" && -f "$root/config.cfg" ]]; then
      cfg="$root/config.cfg"
    else
      # Fallback: walk up from this file's location
      local src
      src="${BASH_SOURCE[0]}"
      cfg="$(cd "$(dirname "$src")/.." && pwd)/config.cfg"
    fi
  fi
  if [[ ! -f "$cfg" ]]; then
    echo "[FATAL] Config not found: $cfg" >&2
    echo "        TOOLKIT_ROOT=$TOOLKIT_ROOT" >&2
    echo "        Set TOOLKIT_CFG env or place config.cfg next to samba-ad.sh" >&2
    exit 1
  fi
  echo "$cfg"
}

# Load config (idempotent — safe to call multiple times)
_load_config() {
  local cfg
  cfg="$(_resolve_config)"
  # shellcheck source=/dev/null
  source "$cfg"
  
  # Derived values
  DOMAIN_DN="DC=$(echo "$DOMAIN" | sed 's/\./,DC=/g')"
  SYSVOL_POLICY_ROOT="${SYSVOL_ROOT}/${DOMAIN}/Policies"
  FQDN="${HOST_SHORTNAME}.${DOMAIN}"
  : "${REALM:="$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')"}"
  : "${NETBIOS:="$(echo "$DOMAIN" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')"}"
  
  # Export all variables from config.cfg so subshells see them
  # This fixes "DOMAIN: unbound variable" when running modules via bash script.sh
  export DOMAIN REALM NETBIOS FQDN HOST_IP HOST_SHORTNAME ADMIN_PASS ADMIN_USER
  export SYSVOL_ROOT PROFILES_ROOT REDIRECT_ROOT HOMES_ROOT SHARES_ROOT
  export DNS_FORWARDER_1 DNS_FORWARDER_2
  export DOMAIN_DN FQDN SYSVOL_POLICY_ROOT
  
  export _CONFIG_LOADED=1
}

# ----- Logging -----
_LOG_COLOR="${LOG_COLOR:-1}"
_log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log()    { echo "[$(_log_ts)] [INFO]  $*"; }
log_ok() { echo "[$(_log_ts)] [OK]    $*"; }
log_warn() { echo "[$(_log_ts)] [WARN]  $*" >&2; }
log_err() { echo "[$(_log_ts)] [ERROR] $*" >&2; }
log_step() { echo "[$(_log_ts)] [STEP]  === $* ==="; }

# ----- Privileges -----
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_err "Run as root (or with sudo)."
    exit 1
  fi
}

run_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# ----- samba-tool wrapper -----
samba_tool() {
  if command -v samba-tool >/dev/null 2>&1; then
    samba-tool "$@"
  else
    python3 - "$@" <<'PY'
import sys
from samba.netcmd.main import samba_tool
sys.exit(samba_tool(*sys.argv[1:]))
PY
  fi
}

# ----- File helpers -----
backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
    log "Backed up: $f"
  fi
}

mkdir_p() {
  run_root mkdir -p "$@"
}

# ----- Service helpers -----
svc_enable()  { run_root systemctl enable --now "$1" 2>/dev/null; }
svc_disable() { run_root systemctl disable --now "$1" 2>/dev/null; }
svc_restart() { run_root systemctl restart "$1" 2>/dev/null; }
svc_status()  { run_root systemctl is-active "$1" 2>/dev/null || echo "inactive"; }

# ----- Snapshot -----
create_snapshot() {
  local share="$1"
  local src="${SHARES_ROOT}/${share}"
  local snap="${SNAPSHOTS_ROOT}/${share}"
  local stamp
  stamp="$(date -u +%Y.%m.%d-%H.%M.%S)"
  local dir="${snap}/@GMT-${stamp}"
  mkdir_p "$dir"
  run_root rsync -a --delete "$src"/ "$dir"/
  log "Snapshot created: $dir"
}

# ----- Check if domain is provisioned -----
is_provisioned() {
  [[ -f "/var/lib/samba/private/sam.ldb" ]]
}

# ----- Confirm action -----
confirm() {
  local msg="${1:-Are you sure?}"
  local ans
  if [[ -t 0 ]]; then
    read -rp "$msg [y/N]: " ans
  else
    ans="${CONFIRM_YES:-N}"
  fi
  [[ "$ans" =~ ^[Yy]$ ]]
}
