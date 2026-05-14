#!/usr/bin/env bash
# ============================================================
#  Module 05 — Users & Groups Management
#  FIX v1.1.6:
#    - Automatically set displayName from CSV (DisplayName column)
#  FIX v1.1.5:
#    - Fixed LDIF backslash escaping for UNC paths
#    - Replaced wbinfo SID resolution with Python samba modules
#    - NT ACL on user directories now works reliably in AD DC mode
#  FIX v1.1.4:
#    - Removed 'profile acls' references (not supported in AD DC mode)
#    - Fixed LDIF trailing '-' separator issue
#    - Added || true around create_group calls in user processing
#    - Wrapped set_user_ntacl calls with error handling
#    - Suppressed samba-tool "Unknown parameter" stderr noise
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

# Ensure DOMAIN_DN is set
if [[ -z "${DOMAIN_DN:-}" ]]; then
    DOMAIN_DN="DC=$(echo "$DOMAIN" | sed 's/\./,DC=/g')"
    export DOMAIN_DN
fi

create_group() {
  local gname="$1"
  local gdesc="$2"
  if samba_tool group show "$gname" >/dev/null 2>&1; then
    log "Group exists: $gname"
    return 0
  fi
  log "Creating group: $gname — $gdesc"
  samba_tool group add "$gname" --description="$gdesc" 2>/dev/null || {
    log_warn "Failed to create group: $gname (may already exist)"
    return 0
  }
}

create_ou() {
  local ou_name="$1"
  local ou_desc="${2:-}"
  local ou_dn="OU=${ou_name},${DOMAIN_DN}"

  if ldbsearch -H /var/lib/samba/private/sam.ldb -b "$ou_dn" -s base dn 2>/dev/null | grep -q "^dn:"; then
    log "OU exists: $ou_name"
    return 0
  fi

  log "Creating OU: $ou_name ($ou_dn)"
  local ldif
  ldif="dn: ${ou_dn}\nchangetype: add\nobjectClass: organizationalUnit\nou: ${ou_name}"
  if [[ -n "$ou_desc" ]]; then
    ldif="${ldif}\ndescription: ${ou_desc}"
  fi
  local ldif_out
  if ldif_out="$(echo -e "$ldif" | ldbmodify -H /var/lib/samba/private/sam.ldb 2>&1)"; then
    log "OU created: $ou_name"
  else
    log_warn "Failed to create OU $ou_name: $ldif_out"
    samba_tool ou create "$ou_name" 2>/dev/null && log "OU created via samba-tool: $ou_name" || true
  fi
}

create_user() {
  local uname="$1"
  local upass="$2"
  local udesc="$3"   # description / displayName
  local uou="${4:-}"
  local must_change="${5:-false}"
  local noexpire="${6:-false}"

  if samba_tool user show "$uname" 2>/dev/null >/dev/null; then
    log "User exists (updating password): $uname"
    samba_tool user setpassword "$uname" --newpassword="$upass" >/dev/null 2>&1 || true
  else
    log "Creating user: $uname"
    local user_ou_arg=""
    if [[ -n "$uou" ]]; then
        if [[ "$uou" != OU=* && "$uou" != CN=* ]]; then
            uou="OU=${uou}"
        fi
        create_ou "${uou#OU=}" || true
        user_ou_arg="--userou=$uou"
    fi

    local create_args=("$uname" "$upass" "--description=$udesc")
    [[ -n "$user_ou_arg" ]] && create_args+=("$user_ou_arg")

    if ! samba_tool user create "${create_args[@]}" 2>/tmp/user_create_err 1>/dev/null; then
        log_err "Failed to create user $uname. Error: $(cat /tmp/user_create_err 2>/dev/null)"
        log "Debug: DOMAIN=$DOMAIN, REALM=$REALM, DOMAIN_DN=$DOMAIN_DN, OU=$uou"
        rm -f /tmp/user_create_err
        return 1
    fi
    rm -f /tmp/user_create_err
  fi

  # Установить displayName (автоматически из CSV)
  local user_dn_display
  user_dn_display="$(samba_tool user show "$uname" 2>/dev/null | awk '/^dn: /{sub(/^dn: /, "", $0); print; exit}')"
  if [[ -n "$user_dn_display" ]]; then
    log "  Setting displayName to '$udesc' for $uname"
    echo "dn: $user_dn_display
changetype: modify
replace: displayName
displayName: $udesc" | ldbmodify -H /var/lib/samba/private/sam.ldb >/dev/null 2>&1 || log_warn "  Could not set displayName for $uname"
  fi

  if [[ "$must_change" == "true" ]]; then
    samba_tool user setpassword "$uname" --newpassword="$upass" --must-change-at-next-login >/dev/null 2>&1 || true
  fi
  if [[ "$noexpire" == "true" ]]; then
    samba_tool user setexpiry "$uname" --noexpiry >/dev/null 2>&1 || true
  fi
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

clear_user_profile_path() {
  local user_dn="$1"
  cat <<EOF | ldbmodify -H /var/lib/samba/private/sam.ldb >/dev/null 2>&1 || true
dn: $user_dn
changetype: modify
delete: profilePath
EOF
}

normalize_home_directory() {
  local uname="$1"
  local home_dir="$2"
  if [[ "$home_dir" == "\\\\${DOMAIN}\\homes\\"* || "$home_dir" == "\\\\${FQDN}\\homes\\"* ]]; then
    printf '\\\\%s\\users\\%s\n' "$FQDN" "$uname"
  else
    printf '%s\n' "$home_dir"
  fi
}

normalize_profile_directory() {
  local uname="$1"
  local profile_dir="$2"
  if [[ "$profile_dir" == "\\\\${DOMAIN}\\profiles\\"* || "$profile_dir" == "\\\\${FQDN}\\profiles\\"* ]]; then
    printf '\\\\%s\\profiles\\%s\n' "$FQDN" "$uname"
  else
    printf '%s\n' "$profile_dir"
  fi
}

find_user_dn() {
  local uname="$1"
  local user_dn=""
  user_dn="$(samba_tool user show "$uname" 2>/dev/null | awk '/^dn: /{sub(/^dn: /, "", $0); print; exit}')" || true
  if [[ -n "$user_dn" ]]; then
    printf '%s\n' "$user_dn"
    return 0
  fi
  user_dn="$(ldbsearch -H /var/lib/samba/private/sam.ldb -b "$DOMAIN_DN" "(&(objectClass=user)(sAMAccountName=${uname}))" dn 2>/dev/null \
    | awk '/^dn: /{sub(/^dn: /, "", $0); print; exit}')" || true
  [[ -n "$user_dn" ]] && printf '%s\n' "$user_dn"
}

find_user_sid() {
  local uname="$1"
  local sid=""
  sid="$(samba_tool user show "$uname" 2>/dev/null | awk '/^objectSid: /{sub(/^objectSid: /, "", $0); print; exit}')" || true
  [[ -n "$sid" ]] && printf '%s\n' "$sid"
}

set_user_ntacl() {
  local service="$1"
  local path="$2"
  local uname="$3"
  local sid=""
  sid="$(find_user_sid "$uname")" || true

  if [[ -z "$sid" ]]; then
    log_warn "  Cannot resolve SID for ${NETBIOS}\\${uname} — skipping NT ACL on $path"
    return 0
  fi

  log "  Setting NT ACL on $path (owner=$sid, share=[$service])"
  samba_tool ntacl set \
    "O:${sid}G:BAD:(A;OICI;FA;;;${sid})(A;OICI;FA;;;DA)(A;OICI;FA;;;SY)" \
    "$path" \
    --use-s3fs \
    --service="$service" \
    -s "$SMB_CONF" >/dev/null 2>&1 || log_warn "  Failed to set NT ACL on $path"
  return 0
}

# Build LDIF for setting user profile/home attributes (safe printf)
_ldif_set_user_attrs() {
  local user_dn="$1"
  local uprofile="${2:-}"
  local uhome="${3:-}"
  local uhome_drive="${4:-}"
  local has_mods="no"

  if [[ -z "$uprofile" && -z "$uhome" && -z "$uhome_drive" ]]; then
    return 1
  fi

  printf '%s\n' "dn: $user_dn" "changetype: modify"

  if [[ -n "$uprofile" ]]; then
    printf '%s\n' "replace: profilePath" "profilePath: $uprofile"
    has_mods="yes"
  fi
  if [[ -n "$uhome" ]]; then
    [[ "$has_mods" == "yes" ]] && printf '%s\n' "-"
    printf '%s\n' "replace: homeDirectory" "homeDirectory: $uhome"
    has_mods="yes"
  fi
  if [[ -n "$uhome_drive" ]]; then
    [[ "$has_mods" == "yes" ]] && printf '%s\n' "-"
    printf '%s\n' "replace: homeDrive" "homeDrive: $uhome_drive"
  fi
}

step_users() {
  require_root
  log_step "Configuring users and groups"

  local csv="${USERS_CSV:-}"
  if [[ -z "$csv" ]]; then
    csv="$(cd "${SCRIPT_DIR}/.." && pwd)/templates/users_auto.csv"
  fi

  if [[ ! -f "$csv" ]]; then
    log_warn "No users CSV found at $csv — skipping user creation."
    log "You can specify a CSV file: TOOLKIT_CFG=config.cfg samba-ad.sh users --csv /path/to/file.csv"
    return 0
  fi

  log "Using CSV: $csv"

  # --- Create groups from config ---
  while IFS='|' read -r gname gdesc; do
    gname="$(echo "$gname" | xargs)"
    gdesc="$(echo "$gdesc" | xargs)"
    [[ -z "$gname" ]] && continue
    create_group "$gname" "$gdesc" || true
  done <<< "$GROUPS_LIST"

  local first_line
  first_line="$(head -1 "$csv" | tr -d '\r')"
  if [[ "$first_line" != "SamAccountName,DisplayName,Password,Groups,NeverExpires,ProfilePath,HomeDirectory,HomeDrive,RedirectFolders" ]]; then
    log_err "Unsupported CSV header in $csv"
    log_err "Expected users_auto.csv format"
    return 1
  fi
  log "CSV format: users_auto.csv"

  local processed=0 created=0 updated=0
  local roaming_profiles_enabled="${ROAMING_PROFILES_ENABLED:-no}"

  while IFS=',' read -r uname ufname upass ugroups unoexpire uprofile uhome uhome_drive ufolders _rest; do
    uname="$(echo "${uname:-}" | xargs)"
    [[ -z "$uname" || "$uname" == "SamAccountName" || "${uname:0:1}" == "#" ]] && continue

    ufname="$(trim_value "${ufname:-}")"
    upass="$(trim_value "${upass:-}")"
    ugroups="$(trim_value "${ugroups:-}")"
    unoexpire="$(trim_value "${unoexpire:-false}")"
    uprofile="$(trim_value "${uprofile:-}")"
    uhome="$(trim_value "${uhome:-}")"
    uhome_drive="$(trim_value "${uhome_drive:-}")"

    uprofile="$(normalize_profile_directory "$uname" "$uprofile")"

    if [[ "$roaming_profiles_enabled" != "yes" ]]; then
      uprofile=""
    fi

    uhome="$(normalize_home_directory "$uname" "$uhome")"

    [[ -z "$upass" ]] && upass="${DEFAULT_USER_PASS:-TempPass2026}"

    processed=$((processed + 1))
    if samba_tool user show "$uname" 2>/dev/null >/dev/null; then
      updated=$((updated + 1))
    else
      created=$((created + 1))
    fi

    if ! create_user "$uname" "$upass" "$ufname" "" "false" "$unoexpire"; then
        continue
    fi

    if [[ "$uprofile" == *"\\"* || "$uhome" == *"\\"* ]]; then
        local user_dn
        user_dn="$(find_user_dn "$uname")" || true
        if [[ -n "$user_dn" ]]; then
            if [[ "$roaming_profiles_enabled" != "yes" ]]; then
                clear_user_profile_path "$user_dn"
            fi
            log "  Setting LDAP attributes for $uname (DN: $user_dn)..."
            local ldb_out=""
            if ldb_out="$(_ldif_set_user_attrs "$user_dn" "$uprofile" "$uhome" "$uhome_drive" | ldbmodify -H /var/lib/samba/private/sam.ldb 2>&1)"; then
                log "  LDAP attributes set successfully for $uname"
            else
                log_warn "  Failed to set LDAP attributes for $uname: ${ldb_out}"
            fi
        fi
    fi

    if [[ -n "$uprofile" || -n "$uhome" ]]; then
        mkdir -p "${REDIRECT_ROOT}/${uname}" "${HOMES_ROOT}/${uname}" "${SHARES_ROOT}/users/${uname}" 2>/dev/null || true
        if [[ -n "$uprofile" ]]; then
            mkdir -p "${PROFILES_ROOT}/${uname}" 2>/dev/null || true
        fi
        for folder in Desktop Documents Downloads Music Pictures Videos Public Templates; do
            mkdir -p "${REDIRECT_ROOT}/${uname}/${folder}" 2>/dev/null || true
        done
        chmod -R 0777 "${REDIRECT_ROOT}/${uname}" "${HOMES_ROOT}/${uname}" "${SHARES_ROOT}/users/${uname}" 2>/dev/null || true
        if [[ -n "$uprofile" ]]; then
            chmod -R 0777 "${PROFILES_ROOT}/${uname}" 2>/dev/null || true
            set_user_ntacl "profiles" "${PROFILES_ROOT}/${uname}" "$uname" || true
        fi
        set_user_ntacl "redirected" "${REDIRECT_ROOT}/${uname}" "$uname" || true
        set_user_ntacl "users" "${SHARES_ROOT}/users/${uname}" "$uname" || true
    fi

    if [[ -n "$ugroups" ]]; then
      IFS=';' read -ra glist <<< "$ugroups"
      for g in "${glist[@]}"; do
        g="$(echo "$g" | xargs)"
        [[ -z "$g" ]] && continue
        create_group "$g" "$g" || true
        samba_tool group addmembers "$g" "$uname" >/dev/null 2>&1 || true
      done
    fi
  done < "$csv"

  log "Users processed: $processed (created: $created, updated: $updated)"

  log "Domain users:"
  samba_tool user list 2>/dev/null | sort | head -40
  log "Groups:"
  samba_tool group list 2>/dev/null | sort | head -20

  log_ok "Users and groups configured"
}

step_users