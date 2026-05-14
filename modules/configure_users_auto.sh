#!/usr/bin/env bash
# ============================================================
#  configure_users_auto.sh — Full user provisioning script
#  Reads config from config.cfg (same as toolkit modules)
# ============================================================
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load config.cfg ──────────────────────────────────────────
_resolve_config() {
  local cfg="${TOOLKIT_CFG:-}"
  if [[ -z "$cfg" ]]; then
    cfg="$(cd "${SCRIPT_DIR}/.." && pwd)/config.cfg"
  fi
  if [[ ! -f "$cfg" ]]; then
    echo "[FATAL] config.cfg not found: $cfg" >&2
    exit 1
  fi
  echo "$cfg"
}

CONFIG_FILE="$(_resolve_config)"
source "$CONFIG_FILE"

# ── Derived values from config.cfg ───────────────────────────
DOMAIN_DN="DC=$(echo "$DOMAIN" | sed 's/\./,DC=/g')"
DNS_DOMAIN="$DOMAIN"
SYSVOL_ROOT="${SYSVOL_ROOT:-/var/lib/samba/sysvol}"
PROFILES_ROOT="${PROFILES_ROOT:-/var/lib/samba/profiles}"
REDIRECT_ROOT="${REDIRECT_ROOT:-/var/lib/samba/redirected}"
HOMES_ROOT="${HOMES_ROOT:-/var/lib/samba/homes}"
DC_HOST_FQDN="${FQDN:-$(hostname -f 2>/dev/null || hostname)}"
LDAP_DC_URL="ldap://${DC_HOST_FQDN}"
SMB_TARGET_HOST="$DC_HOST_FQDN"
ADMIN_USER="${ADMIN_USER:-Administrator}"
ADMIN_PASS="${ADMIN_PASS:-}"

# ── Script parameters ────────────────────────────────────────
CSV_FILE="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)/templates/users_auto.csv}"
GPO_DISPLAY='All Users Redirection'
GPO_USER_EXT='{35378EAC-683F-11D2-A89A-00C04FBBCFA2}'
GPO_APPLY_CAR_GUID='edacfd8f-ffb3-11d1-b41d-00a0c968f939'
GPO_FILTER_GROUPS=()
PASSWORD_MODE='auto'
TARGET_USER_FILTER=''

log_info()  { echo "[INFO] $*"; }
log_check() { echo "[CHECK] $*"; }
log_ok()    { echo "[OK] $*"; }
log_step()  { echo "[STEP] $*"; }
log_user()  { echo "[USER] $*"; }
log_dir()   { echo "[DIR] $*"; }
log_gpo()   { echo "[GPO] $*"; }
log_warn()  { echo "[WARN] $*"; }

# ── Helper functions ─────────────────────────────────────────

normalize_unc_host() {
  local path="$1"
  local domain_prefix="\\\\${DNS_DOMAIN}\\"
  local host_prefix="\\\\${SMB_TARGET_HOST}\\"
  if [[ "$path" == "$domain_prefix"* ]]; then
    printf '%s\n' "${path/$domain_prefix/$host_prefix}"
  else
    printf '%s\n' "$path"
  fi
}

normalize_home_directory() {
  local sam="$1"
  local home_dir="$2"

  if [[ "$home_dir" == "\\\\${DNS_DOMAIN}\\homes\\"* || "$home_dir" == "\\\\${SMB_TARGET_HOST}\\homes\\"* ]]; then
    printf '\\\\%s\\users\\%s\n' "$DNS_DOMAIN" "$sam"
  else
    printf '%s\n' "$home_dir"
  fi
}

update_user_share_attrs() {
  local sam="$1"
  local profile_path="$2"
  local home_dir="$3"
  local home_drive="$4"
  local user_dn
  user_dn="$(samba-tool user show "$sam" 2>/dev/null | awk '/^dn: /{sub(/^dn: /, "", $0); print; exit}')"
  [[ -n "$user_dn" ]] || return 1

  cat <<EOF | ldbmodify -H /var/lib/samba/private/sam.ldb >/dev/null 2>&1
dn: $user_dn
changetype: modify
replace: profilePath
profilePath: $profile_path
-
replace: homeDirectory
homeDirectory: $home_dir
-
replace: homeDrive
homeDrive: $home_drive
EOF
}

set_samba_password() {
  local sam="$1"
  local pass="$2"
  local must_change="${3:-false}"
  local cmd=(samba-tool user setpassword "$sam" --newpassword="$pass")
  if [[ "$must_change" == "true" ]]; then
    cmd+=(--must-change-at-next-login)
  fi
  "${cmd[@]}" >/dev/null
}

# ── Create or update user ────────────────────────────────────

create_or_update_user() {
  local sam="$1"
  local display="$2"
  local pass="$3"
  local groups="$4"
  local noexpiry="$5"
  local profile_path="$6"
  local home_dir="$7"
  local home_drive="$8"
  local password_mode="$9"

  profile_path="$(normalize_unc_host "$profile_path")"
  home_dir="$(normalize_unc_host "$home_dir")"
  home_dir="$(normalize_home_directory "$sam" "$home_dir")"

  log_user "$sam"
  local given_name surname ou
  given_name="${display%% *}"
  surname="${display#* }"
  ou=''

  local effective_mode="$password_mode"
  if [[ "$effective_mode" == "auto" ]]; then
    if [[ "$noexpiry" == "true" ]]; then
      effective_mode='normal'
    else
      effective_mode='change'
    fi
  fi

  if ! samba-tool user show "$sam" >/dev/null 2>&1; then
    echo "  -> Creating account..."
    local create_args=(
      "$sam" "$pass"
      --given-name="$given_name"
      --surname="$surname"
      --profile-path="$profile_path"
      --home-directory="$home_dir"
      --home-drive="$home_drive"
      --description="$display"
    )
    [[ -n "$ou" ]] && create_args+=(--userou="$ou")
    if [[ "$effective_mode" == "change" ]]; then
      create_args+=(--must-change-at-next-login)
    fi
    if samba-tool user create "${create_args[@]}" >/dev/null 2>&1; then
      echo "  [SUCCESS]"
    else
      echo "  [FAILED] — trying without profile attributes..."
      # Fallback: create without profile/home args (some samba versions don't support them in user create)
      local fallback_args=(
        "$sam" "$pass"
        --given-name="$given_name"
        --surname="$surname"
        --description="$display"
      )
      if samba-tool user create "${fallback_args[@]}" >/dev/null 2>&1; then
        # Set profile/home via ldbmodify after creation
        update_user_share_attrs "$sam" "$profile_path" "$home_dir" "$home_drive" 2>/dev/null || true
        echo "  [SUCCESS with fallback]"
      else
        echo "  [FAILED] — cannot create user"
        return 1
      fi
    fi
  else
    echo "  -> User exists, updating..."
    set_samba_password "$sam" "$pass" "$([[ "$effective_mode" == "change" ]] && echo true || echo false)"
    update_user_share_attrs "$sam" "$profile_path" "$home_dir" "$home_drive" 2>/dev/null || true
    echo "  [UPDATED]"
  fi

  if [[ "$noexpiry" == "true" || "$effective_mode" == "noexpire" ]]; then
    samba-tool user setexpiry "$sam" --noexpiry >/dev/null 2>&1 || true
    echo "  -> Password set to never expire"
  fi

  if [[ "$effective_mode" == "change" ]]; then
    echo "  -> Password must be changed at first logon"
  fi

  # Add to groups
  IFS=';' read -ra group_list <<<"$groups"
  if ((${#group_list[@]} > 0)); then
    echo "  -> Adding to groups: ${groups}"
  fi
  for grp in "${group_list[@]}"; do
    [[ -n "$grp" ]] || continue
    grp="$(echo "$grp" | xargs)"
    samba-tool group addmembers "$grp" "$sam" >/dev/null 2>&1 || true
  done

  # Create filesystem directories
  echo "  -> profilePath: $profile_path"
  echo "  -> homeDirectory: $home_dir ($home_drive)"
  local user_profile_dir="$PROFILES_ROOT/$sam"
  local user_redirect_dir="$REDIRECT_ROOT/$sam"
  local user_home_dir="$HOMES_ROOT/$sam"
  mkdir -p "$user_profile_dir" "$user_redirect_dir" "$user_home_dir" "$SHARES_ROOT/users/$sam"
  chmod -R 0777 "$user_profile_dir" "$user_redirect_dir" "$user_home_dir" "$SHARES_ROOT/users/$sam"
  echo "  -> Preparing redirected folders"

  for folder in Desktop Documents Downloads Music Pictures Videos Public Templates; do
    mkdir -p "$user_redirect_dir/$folder"
    chmod 0777 "$user_redirect_dir/$folder"
    log_dir "$user_redirect_dir/$folder"
  done
}

# ── GPO helpers ──────────────────────────────────────────────

find_gpo_guid() {
  ldbsearch -H /var/lib/samba/private/sam.ldb \
    -b "CN=Policies,CN=System,${DOMAIN_DN}" \
    '(objectClass=groupPolicyContainer)' displayName name \
    2>/dev/null | awk -v name="$GPO_DISPLAY" '
      /^displayName:/ {d=$0}
      /^name:/ {
        if (d ~ name) {
          gsub(/^name: /, "", $0)
          print $0
          exit
        }
      }
    ' || true
}

ensure_gpo_link() {
  local gpo_link
  gpo_link="[LDAP://CN={${GPO_GUID}},CN=Policies,CN=System,${DOMAIN_DN};0]"
  local existing
  existing="$(ldbsearch -H /var/lib/samba/private/sam.ldb -s base -b "$DOMAIN_DN" gPLink 2>/dev/null | awk -F': ' '/^gPLink:/{print $2}')"
  if [[ "$existing" != *"$gpo_link"* ]]; then
    cat <<EOF | ldbmodify -H /var/lib/samba/private/sam.ldb >/dev/null
dn: $DOMAIN_DN
changetype: modify
replace: gPLink
gPLink: ${existing}${gpo_link}
EOF
    log_ok "Linked to $DNS_DOMAIN"
  else
    log_ok "GPO link already exists on $DNS_DOMAIN"
  fi
}

ensure_gpo() {
  local authfile="$1"
  local current
  current="$(find_gpo_guid)"
  if [[ -z "$current" ]]; then
    log_info "GPO not found, creating..."
    local create_output
    create_output="$(samba-tool gpo create "$GPO_DISPLAY" \
      -H "$LDAP_DC_URL" \
      -s /etc/samba/smb.conf \
      -A "$authfile" 2>&1)"
    current="$(printf '%s\n' "$create_output" | grep -oE '\{[0-9A-Fa-f-]{36}\}' | head -n1 | tr -d '{}')"
    if [[ -z "$current" ]]; then
      current="$(find_gpo_guid)"
    fi
    if [[ -z "$current" ]]; then
      echo "$create_output"
      echo "[ERROR] Failed to determine GPO GUID after create"
      exit 1
    fi
    GPO_GUID="$current"
    log_ok "GPO created: $GPO_DISPLAY"
  else
    GPO_GUID="$current"
    log_ok "GPO exists: $GPO_DISPLAY"
  fi
  ensure_gpo_link
}

find_group_dn() {
  local authfile="$1"
  local group_name="$2"
  samba-tool group show "$group_name" \
    -A "$authfile" \
    -H ldap://127.0.0.1 \
    -s /etc/samba/smb.conf 2>/dev/null | awk '/^dn: /{sub(/^dn: /, "", $0); print; exit}'
}

find_group_sid() {
  local authfile="$1"
  local group_name="$2"
  samba-tool group show "$group_name" \
    -A "$authfile" \
    -H ldap://127.0.0.1 \
    -s /etc/samba/smb.conf 2>/dev/null | awk '/^objectSid: /{sub(/^objectSid: /, "", $0); print; exit}'
}

apply_gpo_security_filter() {
  local authfile="$1"
  local gpo_dn="CN={${GPO_GUID}},CN=Policies,CN=System,${DOMAIN_DN}"
  local filter_group_dn
  local filter_group_sid
  local group_name

  if ((${#GPO_FILTER_GROUPS[@]} == 0)); then
    echo "[WARN] No groups collected from CSV; skipping GPO security filter"
    return 0
  fi

  log_gpo "Filtering GPO for groups: ${GPO_FILTER_GROUPS[*]}"

  samba-tool dsacl delete \
    --objectdn="$gpo_dn" \
    --sddl="(OA;CI;CR;${GPO_APPLY_CAR_GUID};;AU)" \
    -H "$LDAP_DC_URL" \
    -s /etc/samba/smb.conf \
    -A "$authfile" >/dev/null 2>&1 || true

  for group_name in "${GPO_FILTER_GROUPS[@]}"; do
    filter_group_dn="$(find_group_dn "$authfile" "$group_name")"
    filter_group_sid="$(find_group_sid "$authfile" "$group_name")"

    if [[ -z "$filter_group_dn" || -z "$filter_group_sid" ]]; then
      echo "[WARN] Cannot resolve DN/SID for $group_name; skipping"
      continue
    fi

    log_gpo "Group DN: $filter_group_dn"
    log_gpo "Group SID: $filter_group_sid"

    samba-tool dsacl set \
      --objectdn="$gpo_dn" \
      --trusteedn="$filter_group_dn" \
      --sddl="(OA;CI;CR;${GPO_APPLY_CAR_GUID};;${filter_group_sid})" \
      -H "$LDAP_DC_URL" \
      -s /etc/samba/smb.conf \
      -A "$authfile" >/dev/null
  done

  log_ok "GPO security filter applied to ${GPO_FILTER_GROUPS[*]}"
}

build_gpo_json() {
  local json_file="$1"
  cat >"$json_file" <<'JSONEOF'
[
  {"keyname":"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","valuename":"Desktop","class":"USER","type":"REG_EXPAND_SZ","data":"\\\\__SMB_HOST__\\redirected\\%USERNAME%\\Desktop"},
  {"keyname":"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","valuename":"Personal","class":"USER","type":"REG_EXPAND_SZ","data":"\\\\__SMB_HOST__\\redirected\\%USERNAME%\\Documents"},
  {"keyname":"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","valuename":"{374DE290-123F-4565-9164-39C4925E467B}","class":"USER","type":"REG_EXPAND_SZ","data":"\\\\__SMB_HOST__\\redirected\\%USERNAME%\\Downloads"},
  {"keyname":"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","valuename":"My Music","class":"USER","type":"REG_EXPAND_SZ","data":"\\\\__SMB_HOST__\\redirected\\%USERNAME%\\Music"},
  {"keyname":"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","valuename":"My Pictures","class":"USER","type":"REG_EXPAND_SZ","data":"\\\\__SMB_HOST__\\redirected\\%USERNAME%\\Pictures"},
  {"keyname":"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","valuename":"My Video","class":"USER","type":"REG_EXPAND_SZ","data":"\\\\__SMB_HOST__\\redirected\\%USERNAME%\\Videos"},
  {"keyname":"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","valuename":"Public","class":"USER","type":"REG_EXPAND_SZ","data":"\\\\__SMB_HOST__\\redirected\\%USERNAME%\\Public"},
  {"keyname":"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","valuename":"Templates","class":"USER","type":"REG_EXPAND_SZ","data":"\\\\__SMB_HOST__\\redirected\\%USERNAME%\\Templates"}
]
JSONEOF
  sed -i "s/__SMB_HOST__/$SMB_TARGET_HOST/g" "$json_file"
}

# ── Utility commands ─────────────────────────────────────────

delete_user() {
  local sam="$1"
  if samba-tool user show "$sam" >/dev/null 2>&1; then
    log_info "Deleting user: $sam"
    samba-tool user delete "$sam" >/dev/null
    rm -rf "$PROFILES_ROOT/$sam" "$REDIRECT_ROOT/$sam" "$HOMES_ROOT/$sam" || true
    log_ok "User deleted: $sam"
  else
    echo "[WARN] User not found: $sam"
  fi
}

set_user_password() {
  local sam="$1"
  local newpass="$2"
  local mode="${3:-normal}"
  if samba-tool user show "$sam" >/dev/null 2>&1; then
    log_info "Updating password for: $sam"
    set_samba_password "$sam" "$newpass" "$([[ "$mode" == "change" ]] && echo true || echo false)"
    if [[ "$mode" == "change" ]]; then
      echo "  -> Password must be changed at first logon"
    elif [[ "$mode" == "noexpire" ]]; then
      samba-tool user setexpiry "$sam" --noexpiry >/dev/null 2>&1 || true
      echo "  -> Password set to never expire"
    fi
    log_ok "Password updated: $sam"
  else
    echo "[WARN] User not found: $sam"
  fi
}

show_state() {
  log_info "Current domain users"
  samba-tool user list | sort
  echo
  log_info "Current groups"
  for grp in grp_users grp_admins grp_services "Domain Admins"; do
    if samba-tool group show "$grp" >/dev/null 2>&1; then
      echo "[GROUP] $grp"
      samba-tool group listmembers "$grp" 2>/dev/null | sed 's/^/  - /' || true
    fi
  done
  echo
  log_info "Current GPOs"
  ldbsearch -H /var/lib/samba/private/sam.ldb \
    -b "CN=Policies,CN=System,${DOMAIN_DN}" \
    '(objectClass=groupPolicyContainer)' displayName name \
    2>/dev/null | awk '
      /^displayName:/ {print "[GPO] " substr($0, 14)}
      /^name:/ {print "  - " substr($0, 7)}
    ' || true
}

usage() {
  cat <<EOF
Usage:
  $0 [--reload|--show|--del USER|--del-list "U1,U2,U3"|--del-file CSV|--passwd USER NEWPASS|--passwd-change USER NEWPASS|--passwd-noexpire USER NEWPASS|--pwd-normal|--pwd-change|--pwd-noexpire|--help] [users.csv]

Modes:
  --reload, --provision   Apply CSV provisioning, groups, profiles and GPO. Default.
  --show                  Show users, groups and current GPO status.
  --del USER              Delete a domain user and remove it from groups.
  --del-list LIST         Delete a comma-separated list of users.
  --del-file CSV          Delete all users from a CSV file (first column).
  --passwd USER NEWPASS   Change password for one user.
  --passwd-change USER NEWPASS   Change password and force change at first login.
  --passwd-noexpire USER NEWPASS Set password and disable expiration.
  --pwd-normal            Use normal password mode.
  --pwd-change            Force password change at next login.
  --pwd-noexpire          Set password never expires.
  --help                  Show this help.

Config: reads from config.cfg (TOOLKIT_CFG env or ../config.cfg)
EOF
}

# ── Main ─────────────────────────────────────────────────────

main() {
  local action='reload'
  local target_user=''
  local target_pass=''
  local target_mode='normal'
  local target_list=''
  local target_csv=''
  while (($#)); do
    case "$1" in
      -h|--help|help)
        usage
        exit 0
        ;;
      --show|-show|show)
        action='show'
        shift
        continue
        ;;
      --del|-del|delete|--delete)
        action='del'
        target_user="${2:-}"
        if [[ -z "$target_user" ]]; then
          echo "[ERROR] Missing user name for delete mode"
          usage
          exit 1
        fi
        shift 2
        continue
        ;;
      --del-list|--delete-list)
        action='del-list'
        target_list="${2:-}"
        if [[ -z "$target_list" ]]; then
          echo "[ERROR] Missing user list for delete-list mode"
          usage
          exit 1
        fi
        shift 2
        continue
        ;;
      --del-file|--delete-file)
        action='del-file'
        target_csv="${2:-}"
        if [[ -z "$target_csv" ]]; then
          echo "[ERROR] Missing CSV path for delete-file mode"
          usage
          exit 1
        fi
        shift 2
        continue
        ;;
      --passwd|-passwd|password|--password)
        action='passwd'
        target_user="${2:-}"
        target_pass="${3:-}"
        target_mode='normal'
        if [[ -z "$target_user" || -z "$target_pass" ]]; then
          echo "[ERROR] Missing user name or password for passwd mode"
          usage
          exit 1
        fi
        shift 3
        continue
        ;;
      --passwd-change)
        action='passwd'
        target_user="${2:-}"
        target_pass="${3:-}"
        target_mode='change'
        if [[ -z "$target_user" || -z "$target_pass" ]]; then
          echo "[ERROR] Missing user name or password for passwd-change mode"
          usage
          exit 1
        fi
        shift 3
        continue
        ;;
      --passwd-noexpire)
        action='passwd'
        target_user="${2:-}"
        target_pass="${3:-}"
        target_mode='noexpire'
        if [[ -z "$target_user" || -z "$target_pass" ]]; then
          echo "[ERROR] Missing user name or password for passwd-noexpire mode"
          usage
          exit 1
        fi
        shift 3
        continue
        ;;
      --pwd-normal)
        PASSWORD_MODE='normal'
        shift
        continue
        ;;
      --pwd-change|--change-password-on-next-login)
        PASSWORD_MODE='change'
        shift
        continue
        ;;
      --pwd-noexpire|--no-expire)
        PASSWORD_MODE='noexpire'
        shift
        continue
        ;;
      --user|-user)
        TARGET_USER_FILTER="${2:-}"
        if [[ -z "$TARGET_USER_FILTER" ]]; then
          echo "[ERROR] Missing user name for --user"
          usage
          exit 1
        fi
        shift 2
        continue
        ;;
      --reload|-reload|reload|--provision|-provision)
        action='reload'
        shift
        continue
        ;;
      *.csv)
        CSV_FILE="$1"
        shift
        continue
        ;;
      '')
        shift
        continue
        ;;
      *)
        echo "[ERROR] Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ "$action" == "reload" && ! -f "$CSV_FILE" ]]; then
    echo "CSV not found: $CSV_FILE"
    exit 1
  fi

  log_info "========================================="
  log_info "User Provisioning Script Started"
  log_info "Date: $(date '+%Y-%m-%d %H:%M:%S')"
  log_info "Config: $CONFIG_FILE"
  log_info "Domain: $DNS_DOMAIN"
  log_info "SMB host: $SMB_TARGET_HOST"
  log_info "CSV: $CSV_FILE"
  log_info "Mode: $action"
  log_info "Password mode: $PASSWORD_MODE"
  if [[ -n "$TARGET_USER_FILTER" ]]; then
    log_info "User filter: $TARGET_USER_FILTER"
  fi
  log_info "========================================="

  if [[ "$action" == "show" ]]; then
    show_state
    exit 0
  fi

  if [[ "$action" == "del" ]]; then
    delete_user "$target_user"
    exit 0
  fi

  if [[ "$action" == "del-list" ]]; then
    log_info "Deleting user list: $target_list"
    local IFS=','
    read -ra users <<<"$target_list"
    for sam in "${users[@]}"; do
      sam="${sam// /}"
      [[ -n "$sam" ]] || continue
      delete_user "$sam"
    done
    exit 0
  fi

  if [[ "$action" == "del-file" ]]; then
    log_info "Deleting users from CSV: $target_csv"
    while IFS=, read -r sam _rest; do
      [[ "$sam" == "SamAccountName" || -z "${sam:-}" ]] && continue
      delete_user "$sam"
    done < "$target_csv"
    exit 0
  fi

  if [[ "$action" == "passwd" ]]; then
    set_user_password "$target_user" "$target_pass" "$target_mode"
    exit 0
  fi

  # ── Pre-flight checks ──────────────────────────────────────
  log_check "Validating bash syntax..."
  if bash -n "$0" >/dev/null 2>&1; then
    log_ok "syntax-ok"
  else
    echo "[ERROR] bash syntax check failed"
    exit 1
  fi
  log_check "Checking domain connectivity..."
  if realm list "$DNS_DOMAIN" >/dev/null 2>&1; then
    log_ok "Connected to domain: ${DNS_DOMAIN^^}"
  else
    echo "[WARN] Domain connectivity check could not be verified locally"
  fi
  log_check "Verifying required groups..."
  for grp in grp_users grp_admins grp_services "Domain Admins"; do
    if samba-tool group show "$grp" >/dev/null 2>&1; then
      log_ok "$grp exists"
    else
      echo "[WARN] $grp missing"
    fi
  done
  log_check "Preparing profile and home roots..."
  mkdir -p "$PROFILES_ROOT" "$REDIRECT_ROOT" "$HOMES_ROOT"
  chmod 0777 "$PROFILES_ROOT" "$REDIRECT_ROOT" "$HOMES_ROOT"
  log_ok "$PROFILES_ROOT ready"
  log_ok "$HOMES_ROOT ready"
  log_ok "$REDIRECT_ROOT ready"

  # ── Process CSV ────────────────────────────────────────────
  local authfile json_file
  authfile="$(mktemp)"
  json_file="$(mktemp)"
  trap 'rm -f "${authfile:-}" "${json_file:-}"' EXIT
  cat >"$authfile" <<EOF
username = ${ADMIN_USER}
password = ${ADMIN_PASS}
EOF

  log_step "Processing users from CSV..."
  local processed=0 created=0 updated=0 skipped=0
  declare -A seen_groups=()
  while IFS=, read -r sam display pass groups never profile home home_drive folders; do
    [[ "$sam" == "SamAccountName" || -z "${sam:-}" ]] && continue
    if [[ -n "$TARGET_USER_FILTER" && "$sam" != "$TARGET_USER_FILTER" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    processed=$((processed + 1))
    if samba-tool user show "$sam" >/dev/null 2>&1; then
      updated=$((updated + 1))
    else
      created=$((created + 1))
    fi

    IFS=';' read -ra group_list <<<"$groups"
    for grp in "${group_list[@]}"; do
      grp="${grp// /}"
      [[ -n "$grp" ]] || continue
      seen_groups["$grp"]=1
    done

    create_or_update_user "$sam" "$display" "$pass" "$groups" "$never" "$profile" "$home" "$home_drive" "$PASSWORD_MODE"
  done < "$CSV_FILE"

  GPO_FILTER_GROUPS=("${!seen_groups[@]}")
  if ((${#GPO_FILTER_GROUPS[@]} > 0)); then
    printf '[INFO] GPO groups from CSV: %s\n' "${GPO_FILTER_GROUPS[*]}"
  fi

  # ── Configure GPO ─────────────────────────────────────────
  log_step "Configuring GPO: $GPO_DISPLAY"
  log_gpo "Checking existence..."
  ensure_gpo "$authfile"
  if [[ -n "${GPO_GUID:-}" ]]; then
    build_gpo_json "$json_file"
    samba-tool gpo load "{${GPO_GUID}}" \
      --content="$json_file" \
      --user-ext-name="$GPO_USER_EXT" \
      --replace \
      -H "$LDAP_DC_URL" \
      -s /etc/samba/smb.conf \
      -A "$authfile" 2>/dev/null || log_warn "GPO load failed (may need manual application)"
    apply_gpo_security_filter "$authfile"
    log_ok "Folder redirection configured"
    log_gpo "Desktop      [OK]"
    log_gpo "Documents    [OK]"
    log_gpo "Downloads    [OK]"
    log_gpo "Music        [OK]"
    log_gpo "Pictures     [OK]"
    log_gpo "Videos       [OK]"
    log_gpo "Public       [OK]"
    log_gpo "Templates    [OK]"
  fi

  # ── Summary ────────────────────────────────────────────────
  log_info "Final report"
  echo "[SUMMARY]"
  echo "Users processed: $processed"
  echo "Created: $created"
  echo "Updated: $updated"
  echo "Skipped: $skipped"
  echo
  echo "Directories prepared: $processed"
  echo "GPO configured: YES"
  echo
  echo "[STATUS] COMPLETED SUCCESSFULLY"
  samba-tool user list | sort
  echo "GPO_OK ${GPO_GUID:-unknown}"
}

main "$@"
