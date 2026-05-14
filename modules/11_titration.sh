#!/usr/bin/env bash
# ============================================================
#  Module 11 — Titration (comprehensive validation & load test)
#
#  Validates that the entire Samba AD DC deployment works
#  correctly and can handle expected load ("prove the weight").
#
#  Usage:
#    ./samba-ad.sh titration              # Full validation
#    ./samba-ad.sh titration --quick       # Quick check (no load test)
#    ./samba-ad.sh titration --load        # Only load test
#    ./samba-ad.sh titration --report      # Save report to file
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
_load_config

# ── Colors ────────────────────────────────────────────────────
T_GREEN='\033[0;32m'
T_RED='\033[0;31m'
T_YELLOW='\033[1;33m'
T_CYAN='\033[0;36m'
T_BOLD='\033[1m'
T_NC='\033[0m'

# ── Counters ──────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0
TEST_TOTAL=0
REPORT_LINES=()

# ── Parse args ────────────────────────────────────────────────
MODE="full"
SAVE_REPORT="no"

while (($#)); do
  case "$1" in
    --quick)  MODE="quick";  shift ;;
    --load)   MODE="load";   shift ;;
    --report) SAVE_REPORT="yes"; shift ;;
    *) shift ;;
  esac
done

# ── Report helpers ────────────────────────────────────────────
_record() {
  local status="$1" msg="$2"
  TEST_TOTAL=$((TEST_TOTAL + 1))
  REPORT_LINES+=("${status}|${msg}")
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
  esac
}

pass() {
  local msg="$1"
  echo -e "  ${T_GREEN}[PASS]${T_NC} ${msg}"
  _record "PASS" "$msg"
}

fail() {
  local msg="$1"
  echo -e "  ${T_RED}[FAIL]${T_NC} ${msg}"
  _record "FAIL" "$msg"
}

warn() {
  local msg="$1"
  echo -e "  ${T_YELLOW}[WARN]${T_NC} ${msg}"
  _record "WARN" "$msg"
}

skip() {
  local msg="$1"
  echo -e "  ${T_CYAN}[SKIP]${T_NC} ${msg}"
  _record "SKIP" "$msg"
}

info() {
  local msg="$1"
  echo -e "  ${T_CYAN}[INFO]${T_NC} ${msg}"
}

# ── Section header ────────────────────────────────────────────
section() {
  echo ""
  echo -e "${T_BOLD}${T_CYAN}━━━ $1 ━━━${T_NC}"
  REPORT_LINES+=("SECTION|$1")
}

# ============================================================
#  1. SERVICES CHECK
# ============================================================
check_services() {
  section "1. Services"

  # samba
  if svc_status samba.service | grep -q "active"; then
    pass "samba.service is running"
  else
    fail "samba.service is NOT running"
  fi

  # chrony
  if svc_status chronyd 2>/dev/null | grep -q "active"; then
    pass "chronyd is running (NTP)"
  else
    warn "chronyd is not running — time sync may be broken"
  fi

  if command -v chronyc >/dev/null 2>&1; then
    local chrony_tracking chrony_sources
    chrony_tracking="$(chronyc tracking 2>/dev/null || true)"
    chrony_sources="$(chronyc sources 2>/dev/null || true)"

    if echo "$chrony_tracking" | grep -q "Leap status[[:space:]]*:[[:space:]]*Normal"; then
      pass "Chrony tracking reports normal synchronization"
    else
      warn "Chrony tracking is not in Normal state"
    fi

    if echo "$chrony_sources" | grep -q '^\^\*'; then
      pass "Chrony has an active preferred time source"
    else
      warn "Chrony preferred source not found in 'chronyc sources'"
    fi

    info "chronyc tracking:"
    while IFS= read -r line; do
      [[ -n "$line" ]] && info "  $line"
    done <<< "$chrony_tracking"

    info "chronyc sources:"
    while IFS= read -r line; do
      [[ -n "$line" ]] && info "  $line"
    done <<< "$chrony_sources"
  else
    warn "chronyc command not found"
  fi

  # Check samba processes
  local proc_count
  proc_count="$(pgrep -c samba 2>/dev/null || echo 0)"
  if [[ "$proc_count" -gt 0 ]]; then
    pass "samba processes detected: ${proc_count}"
  else
    fail "No samba processes found"
  fi

  # Check listening ports (both TCP and UDP)
  # FIX: Removed port 9389 — Samba AD DC does NOT support AD Web Services.
  #      Port 9389 is Microsoft AD-specific and will never listen on Samba.
  # FIX v1.1.3b: Rewritten port detection to be reliable across different
  #      ss output formats (ALT Linux, Debian, RHEL, etc.).
  #      Uses ss without -p flag and a robust regex that handles IPv4/IPv6
  #      addresses and various ss column formats.
  local port_protos="
53:tcp,udp
88:tcp,udp
389:tcp,udp
445:tcp
636:tcp
"
  while IFS=: read -r port protos; do
    port="$(echo "$port" | xargs)"
    protos="$(echo "$protos" | xargs)"
    [[ -z "$port" ]] && continue
    local found_proto=""
    for proto in ${protos//,/ }; do
      # Use ss without -p (no process info) to avoid PID false positives
      # Pattern matches :PORT followed by space, colon, asterisk, or end-of-line
      # This covers all ss output formats:
 #   *:88  *:*    (wildcard IPv4)
      #   0.0.0.0:88  0.0.0.0:*  (specific IPv4)
      #   [::]:88  [::]:*  (IPv6)
      #   :::88  :::*  (compact IPv6)
      if ss -${proto:0:1}ln 2>/dev/null | grep -qE ":${port}([[:space:]:*]|$)"; then
        found_proto="${proto}"
        break
      fi
    done
    if [[ -n "$found_proto" ]]; then
      pass "Port ${port} is listening (${found_proto})"
    else
      fail "Port ${port} is NOT listening"
    fi
  done <<< "$port_protos"

  # Port 9389 — explicitly skip with explanation
  skip "Port 9389 (ADWS) — not supported by Samba AD DC (Microsoft-specific)"
}

# ============================================================
#  2. DNS VALIDATION
# ============================================================
check_dns() {
  section "2. DNS Resolution"

  # Internal: resolve domain controller
  local dc_ip
  dc_ip="$(dig +short "${FQDN}" 2>/dev/null || echo "")"
  if [[ -n "$dc_ip" && "$dc_ip" == "$HOST_IP" ]]; then
    pass "DNS: ${FQDN} resolves to ${HOST_IP}"
  elif [[ -n "$dc_ip" ]]; then
    warn "DNS: ${FQDN} resolves to ${dc_ip} (expected ${HOST_IP})"
  else
    fail "DNS: ${FQDN} does NOT resolve"
  fi

  # SRV records
  local srv
  srv="$(dig +short _ldap._tcp."${DOMAIN}" SRV 2>/dev/null || echo "")"
  if [[ -n "$srv" ]]; then
    pass "DNS: _ldap._tcp.${DOMAIN} SRV record exists: ${srv}"
  else
    fail "DNS: _ldap._tcp.${DOMAIN} SRV record NOT found"
  fi

  srv="$(dig +short _kerberos._tcp."${DOMAIN}" SRV 2>/dev/null || echo "")"
  if [[ -n "$srv" ]]; then
    pass "DNS: _kerberos._tcp.${DOMAIN} SRV record exists: ${srv}"
  else
    fail "DNS: _kerberos._tcp.${DOMAIN} SRV record NOT found"
  fi

  # Forward DNS resolution via samba-tool
  local dns_test
  dns_test="$(samba_tool dns query "${FQDN}" "${DOMAIN}" @ ALL -U "${ADMIN_USER}"%"${ADMIN_PASS}" 2>&1 || true)"
  if echo "$dns_test" | grep -q "Name="; then
    pass "DNS: samba-tool dns query works (SOA found)"
  else
    fail "DNS: samba-tool dns query failed"
  fi

  # External DNS forwarder
  local ext_ip
  ext_ip="$(dig +short ya.ru @127.0.0.1 2>/dev/null || echo "")"
  if [[ -n "$ext_ip" ]]; then
    pass "DNS: external resolution works (ya.ru -> ${ext_ip})"
  else
    warn "DNS: external resolution failed — check DNS forwarders"
  fi

  # Reverse DNS
  local rev_name
  rev_name="$(dig +short -x "${HOST_IP}" 2>/dev/null || echo "")"
  if [[ -n "$rev_name" ]]; then
    pass "DNS: reverse lookup ${HOST_IP} -> ${rev_name}"
  else
    warn "DNS: reverse lookup for ${HOST_IP} not configured — run: samba-tool dns zonecreate ${FQDN} <reverse-zone> && samba-tool dns add ${FQDN} <reverse-zone> PTR ${HOST_IP} ${FQDN}"
  fi
}

# ============================================================
#  3. DOMAIN & AUTHENTICATION
# ============================================================
check_domain() {
  section "3. Domain & Authentication"

  # Domain info (try with FQDN, fallback to -U credentials)
  local domain_info=""
  domain_info="$(samba_tool domain info "${FQDN}" 2>&1 || true)"
  if ! echo "$domain_info" | grep -qi "domain\|realm\|name"; then
    domain_info="$(samba_tool domain info "${FQDN}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" 2>&1 || true)"
  fi
  if echo "$domain_info" | grep -qi "domain\|realm\|name"; then
    pass "Domain is provisioned and responding"
    info "$(echo "$domain_info" | head -4 | tr '\n' ' ')"
  else
    fail "Cannot get domain info — domain may not be provisioned"
    info "samba-tool output: ${domain_info}"
  fi

  # Kerberos: kinit
  if command -v kinit >/dev/null 2>&1; then
    # Remove old tickets
    kdestroy -A 2>/dev/null || true

    local kinit_out
    kinit_out="$(echo "${ADMIN_PASS}" | kinit "${ADMIN_USER}"@"${REALM}" 2>&1)" && {
      pass "Kerberos: kinit for ${ADMIN_USER} succeeded"
      kdestroy -A 2>/dev/null || true
    } || {
      fail "Kerberos: kinit failed — ${kinit_out}"
    }
  else
    warn "Kerberos: kinit not available — skipping Kerberos test"
  fi

  # NTLM: smbclient authentication
  local smb_out
  smb_out="$(smbclient -L "${FQDN}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" -c 'exit' 2>&1)" && {
    pass "NTLM: smbclient auth with ${ADMIN_USER} succeeded"
  } || {
    # Try with localhost
    smb_out="$(smbclient -L "127.0.0.1" -U "${ADMIN_USER}"%"${ADMIN_PASS}" -c 'exit' 2>&1)" && {
      pass "NTLM: smbclient auth via 127.0.0.1 succeeded"
    } || {
      fail "NTLM: smbclient auth failed — check credentials and SMB service"
    }
  }

  # wbinfo: check winbind
  if command -v wbinfo >/dev/null 2>&1; then
    if wbinfo -t 2>/dev/null; then
      pass "Winbind: secret check (wbinfo -t) passed"
    else
      fail "Winbind: wbinfo -t failed"
    fi

    local dc_name
    dc_name="$(wbinfo --discovery="${DOMAIN}" 2>/dev/null || echo "")"
    if [[ -n "$dc_name" ]]; then
      pass "Winbind: DC discovery found ${dc_name}"
    else
      # NOTE: In AD DC mode, wbinfo --discovery may not work as expected
      # because the DC IS the local machine. This is informational only.
      warn "Winbind: DC discovery failed (expected in AD DC mode — local machine is the DC)"
    fi
  else
    skip "Winbind: wbinfo not available"
  fi

  # getent: domain users
  local getent_user
  getent_user="$(getent passwd "${ADMIN_USER}" 2>/dev/null || echo "")"
  if [[ -n "$getent_user" ]]; then
    pass "NSS: getent passwd ${ADMIN_USER} works"
  else
    # NOTE: In pure AD DC mode (not domain member), NSS/winbind may not
    # resolve domain users via getent. This is expected behavior.
    warn "NSS: getent passwd ${ADMIN_USER} failed — expected in pure AD DC mode (not a domain member)"
  fi
}

# ============================================================
#  4. USERS & GROUPS
# ============================================================
check_users_groups() {
  section "4. Users & Groups"

  # List users
  local user_count=0
  local user_list
  user_list="$(samba_tool user list 2>/dev/null || echo "")"
  if [[ -n "$user_list" ]]; then
    user_count="$(echo "$user_list" | wc -l)"
    pass "Users: ${user_count} user(s) found in AD"
    info "  $(echo "$user_list" | tr '\n' ' ')"
  else
    fail "Users: cannot list users — AD may not be working"
  fi

  # Check admin user
  if echo "$user_list" | grep -qi "administrator"; then
    pass "Users: Administrator account exists"
  else
    fail "Users: Administrator account NOT found"
  fi

  # Check expected groups from config
  local grp_found=0
  local grp_total=0
  while IFS='|' read -r gname gdesc; do
    gname="$(echo "$gname" | xargs)"
    [[ -z "$gname" ]] && continue
    grp_total=$((grp_total + 1))

    if samba_tool group list 2>/dev/null | grep -qi "^${gname}$"; then
      grp_found=$((grp_found + 1))
      pass "Groups: '${gname}' exists"
    else
      warn "Groups: '${gname}' NOT found in AD"
    fi
  done <<< "$GROUPS_LIST"

  if [[ "$grp_total" -gt 0 ]]; then
    if [[ "$grp_found" -eq "$grp_total" ]]; then
      pass "Groups: all ${grp_total} configured groups found"
    else
      warn "Groups: ${grp_found}/${grp_total} configured groups found"
    fi
  fi

  # Check test user authentication (if any non-admin user exists)
  local test_user=""
  for u in $user_list; do
    if [[ "$u" != "Administrator" && "$u" != "krbtgt" && "$u" != "Guest" ]]; then
      test_user="$u"
      break
    fi
  done

  if [[ -n "$test_user" ]]; then
    # Test password auth for first non-admin user
    local test_out
    test_out="$(smbclient -L "${FQDN}" -U "${test_user}"%"${DEFAULT_USER_PASS}" -c 'exit' 2>&1)" && {
      pass "Users: '${test_user}' authentication successful"
    } || {
      warn "Users: '${test_user}' auth with default password failed (password may have been changed)"
    }
  else
    skip "Users: no non-admin users found to test authentication"
  fi
}

# ============================================================
#  5. FILE SHARES
# ============================================================
check_shares() {
  section "5. File Shares"

  # List shares via smbclient
  local share_list
  share_list="$(smbclient -L "${FQDN}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" 2>/dev/null | grep -oP '^\s+\K\S+' || echo "")"
  if [[ -n "$share_list" ]]; then
    local share_count
    share_count="$(echo "$share_list" | wc -l)"
    pass "Shares: ${share_count} share(s) visible via smbclient"
    info "  $(echo "$share_list" | tr '\n' ' ')"
  else
    fail "Shares: cannot enumerate shares"
  fi

  # Check expected shares from config
  # FIX: For non-browseable shares (browseable=no), smbclient -L won't list them.
  #      We must try a DIRECT connection instead of relying on the share listing.
  local sh_found=0
  local sh_total=0
  while IFS='|' read -r sname sdir ro br go cm dm; do
    sname="$(echo "$sname" | xargs)"
    sdir="$(echo "$sdir" | xargs)"
    br="$(echo "$br" | xargs)"
    [[ -z "$sname" ]] && continue
    sh_total=$((sh_total + 1))

    if [[ "$br" == "no" ]]; then
      # FIX: Non-browseable share — try direct SMB connection
      if smbclient "//${FQDN}/${sname}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" -c 'exit' 2>/dev/null; then
        sh_found=$((sh_found + 1))
        pass "Shares: '${sname}' is accessible (non-browseable, verified via direct connect)"
      else
        fail "Shares: '${sname}' is NOT accessible (direct connection failed)"
      fi
    else
      # Browseable share — check via listing (original logic)
      if echo "$share_list" | grep -q "^${sname}$"; then
        sh_found=$((sh_found + 1))
        pass "Shares: '${sname}' is accessible"
      else
        fail "Shares: '${sname}' is NOT accessible"
      fi
    fi
  done <<< "$SHARES_LIST"

  if [[ "$sh_total" -gt 0 ]]; then
    if [[ "$sh_found" -eq "$sh_total" ]]; then
      pass "Shares: all ${sh_total} configured shares accessible"
    else
      warn "Shares: ${sh_found}/${sh_total} configured shares accessible"
    fi
  fi

  # Write test: upload a file to a writable share
  local writable_share=""
  local wt_file="/tmp/titration_wt_${RANDOM}.txt"
  echo "titration-write-test" > "$wt_file"
  for sname in public departments users; do
    if smbclient "//${FQDN}/${sname}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" -c "put ${wt_file} titration_test.tmp" 2>/dev/null; then
      writable_share="$sname"
      break
    fi
  done

  if [[ -n "$writable_share" ]]; then
    pass "Shares: write test passed on '${writable_share}'"

    # Cleanup test file on share
    smbclient "//${FQDN}/${writable_share}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" \
      -c 'rm titration_test.tmp' 2>/dev/null || true
    rm -f "$wt_file"

    # Read test: create a temp file with known content, upload, download, compare
    local test_file="/tmp/titration_test_${RANDOM}.txt"
    local test_content="titration-test-$(date +%s)-$$"
    echo "$test_content" > "$test_file"

    smbclient "//${FQDN}/${writable_share}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" \
      -c "mkdir __titration_test; cd __titration_test; put ${test_file} verify.txt" 2>/dev/null

    if smbclient "//${FQDN}/${writable_share}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" \
      -c "cd __titration_test; get verify.txt ${test_file}.download" 2>/dev/null; then
      local downloaded_content
      downloaded_content="$(cat "${test_file}.download" 2>/dev/null || echo "")"
      if [[ "$downloaded_content" == "$test_content" ]]; then
        pass "Shares: read/write integrity verified (content matches)"
      else
        fail "Shares: file content mismatch after upload/download"
      fi
    else
      warn "Shares: could not download test file for integrity check"
    fi

    # Cleanup
    smbclient "//${FQDN}/${writable_share}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" \
      -c "cd __titration_test; rm verify.txt" 2>/dev/null || true
    smbclient "//${FQDN}/${writable_share}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" \
      -c "rmdir __titration_test" 2>/dev/null || true
    rm -f "$test_file" "${test_file}.download"
  else
    warn "Shares: no writable share found for write test"
  fi

  # Check share directories exist on disk
  while IFS='|' read -r sname sdir _; do
    sname="$(echo "$sname" | xargs)"
    sdir="$(echo "$sdir" | xargs)"
    [[ -z "$sname" ]] && continue
    local share_path="${SHARES_ROOT}/${sdir}"
    case "$sname" in
      profiles) share_path="${PROFILES_ROOT}" ;;
      redirected) share_path="${REDIRECT_ROOT}" ;;
      apps) share_path="${APPS_ROOT}" ;;
    esac
    if [[ -d "${share_path}" ]]; then
      pass "Shares: directory ${share_path} exists"
    else
      fail "Shares: directory ${share_path} does NOT exist"
    fi
  done <<< "$SHARES_LIST"
}

# ============================================================
#  6. GPO VALIDATION
# ============================================================
check_gpo() {
  section "6. Group Policy Objects (GPO)"

  # List GPOs
  local gpo_out
  gpo_out="$(samba_tool gpo listall -H ldap://"${FQDN}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" 2>&1 || true)"
  if echo "$gpo_out" | grep -q "GPO"; then
    local gpo_count
    gpo_count="$(echo "$gpo_out" | grep -c "GPO")" || true
    [[ -z "$gpo_count" ]] && gpo_count=0
    pass "GPO: ${gpo_count} GPO(s) found"
    info "  $(echo "$gpo_out" | grep "displayName" | sed 's/.*displayName: //' | tr '\n' ' ')"
  else
    fail "GPO: cannot list GPOs"
  fi

  # Check specific expected GPOs
  if [[ "${GPO_USB_RESTRICTION_ENABLED:-no}" == "yes" ]]; then
    if echo "$gpo_out" | grep -qi "USB"; then
      pass "GPO: USB Restriction policy exists"
    else
      warn "GPO: USB Restriction expected but not found"
    fi
  fi

  if [[ "${GPO_AUDIT_ENABLED:-no}" == "yes" ]]; then
    if echo "$gpo_out" | grep -qi "audit"; then
      pass "GPO: Audit policy exists"
    else
      warn "GPO: Audit policy expected but not found"
    fi
  fi

  if [[ "${GPO_FOLDER_REDIR_ENABLED:-no}" == "yes" ]]; then
    if echo "$gpo_out" | grep -qi "folder\|redirect"; then
      pass "GPO: Folder Redirection policy exists"
    else
      warn "GPO: Folder Redirection expected but not found"
    fi
  fi

  if [[ "${GPO_DRIVE_MAPS_ENABLED:-no}" == "yes" ]]; then
    if echo "$gpo_out" | grep -qi "drive\|map"; then
      pass "GPO: Drive Maps policy exists"
    else
      warn "GPO: Drive Maps expected but not found"
    fi
  fi

  # Check SYSVOL
  if [[ -d "${SYSVOL_ROOT}/${DOMAIN}" ]]; then
    pass "SYSVOL: ${SYSVOL_ROOT}/${DOMAIN} exists"
  else
    fail "SYSVOL: ${SYSVOL_ROOT}/${DOMAIN} does NOT exist"
  fi

  if [[ -d "${SYSVOL_POLICY_ROOT}" ]]; then
    local policy_count
    policy_count="$(find "${SYSVOL_POLICY_ROOT}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
    pass "SYSVOL: ${policy_count} policy directory(ies) in Policies"
  else
    warn "SYSVOL: Policy directory not found"
  fi
}

# ============================================================
#  7. DFS NAMESPACE
# ============================================================
check_dfs() {
  section "7. DFS Namespace"

  if [[ -d "${DFS_ROOT}" ]]; then
    pass "DFS: root directory ${DFS_ROOT} exists"
  else
    fail "DFS: root directory ${DFS_ROOT} does NOT exist"
  fi

  # Check DFS share via smbclient
  if smbclient -L "${FQDN}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" 2>/dev/null | grep -q "dfs"; then
    pass "DFS: share 'dfs' is accessible"
  else
    warn "DFS: share 'dfs' not visible"
  fi

  # Check DFS links from config
  # FIX: MSDFS symlinks use "msdfs:" URI prefix and are dangling symlinks
  #      (the target is not a real filesystem path). The original check used
  #      -d which follows symlinks and fails on dangling ones.
  #      Use -L to check for symlink existence instead.
  local dfs_count=0
  while IFS='|' read -r link_name _; do
    link_name="$(echo "$link_name" | xargs)"
    [[ -z "$link_name" ]] && continue
    dfs_count=$((dfs_count + 1))

    if [[ -L "${DFS_ROOT}/${link_name}" ]]; then
      local link_target
      link_target="$(readlink "${DFS_ROOT}/${link_name}" 2>/dev/null || echo "unknown")"
      pass "DFS: link '${link_name}' exists -> ${link_target}"
    elif [[ -d "${DFS_ROOT}/${link_name}" ]]; then
      pass "DFS: link '${link_name}' directory exists"
    else
      warn "DFS: link '${link_name}' not found — run './samba-ad.sh install --step dfs' to create"
    fi
  done <<< "$DFS_LINKS"
}

# ============================================================
#  8. PASSWORD POLICY
# ============================================================
check_password_policy() {
  section "8. Password Policy"

  local policy_out
  policy_out="$(samba_tool domain passwordsettings show 2>&1 || true)"
  if [[ -n "$policy_out" ]]; then
    pass "Password policy is readable"

    # Check minimum length
    local min_len
    min_len="$(echo "$policy_out" | grep -oP 'Minimum password length:\s*\K\d+' || echo "")"
    if [[ -n "$min_len" ]]; then
      if [[ "$min_len" -ge "${PASSWORD_MIN_LENGTH:-8}" ]]; then
        pass "Password min length: ${min_len} (>= ${PASSWORD_MIN_LENGTH})"
      else
        warn "Password min length: ${min_len} (expected >= ${PASSWORD_MIN_LENGTH})"
      fi
    fi

    # Check complexity
    if echo "$policy_out" | grep -qi "complexity.*on"; then
      pass "Password complexity: enabled"
    else
      warn "Password complexity: disabled"
    fi

    # Check lockout
    local lockout
    lockout="$(echo "$policy_out" | grep -oP 'Account lockout threshold:\s*\K\d+' || echo "")"
    if [[ -n "$lockout" ]]; then
      pass "Account lockout threshold: ${lockout}"
    fi
  else
    fail "Cannot read password policy"
  fi
}

# ============================================================
#  9. FIREWALL
# ============================================================
check_firewall() {
  section "9. Firewall"

  if command -v firewall-cmd >/dev/null 2>&1; then
    local fw_state
    fw_state="$(firewall-cmd --state 2>&1 || echo "not running")"
    if [[ "$fw_state" == "running" ]]; then
      pass "firewalld is running"

      # Check required ports
      local port_ok=true
      while IFS='/' read -r proto port; do
        proto="$(echo "$proto" | xargs)"
        port="$(echo "$port" | xargs)"
        [[ -z "$proto" || -z "$port" ]] && continue

        # Skip ranges for individual check
        if [[ "$port" == *"-"* ]]; then
          continue
        fi

        if firewall-cmd --list-ports 2>/dev/null | grep -q "${port}/${proto}"; then
          : # port is open
        else
          # Check services
          local found_in_service="no"
          if firewall-cmd --list-services 2>/dev/null | grep -q "samba\|dc\|dns\|kerberos\|ldap"; then
            found_in_service="yes"
          fi
          if [[ "$found_in_service" == "no" ]]; then
            warn "Firewall: port ${port}/${proto} not explicitly opened"
          fi
        fi
      done <<< "$FIREWALL_PORTS"

      pass "Firewall: port configuration verified"
    else
      warn "firewalld is not running"
    fi
  else
    warn "firewall-cmd not available — firewall status unknown"
  fi
}

# ============================================================
#  10. LOAD TEST (prove "the weight works")
# ============================================================
check_load() {
  section "10. Load Test (prove the weight)"

  local CONCURRENT=5
  local ITERATIONS=10
  local LOAD_DIR="/tmp/titration_load_$$"
  mkdir -p "$LOAD_DIR"

  info "Parameters: ${CONCURRENT} concurrent, ${ITERATIONS} iterations each"
  local start_time
  start_time="$(date +%s%N)"

  # --- 10a: Concurrent authentication ---
  info "Running concurrent authentication test..."
  local auth_fail=0
  local auth_ok=0
  for ((i = 0; i < CONCURRENT; i++)); do
    (
      for ((j = 0; j < ITERATIONS; j++)); do
        if smbclient -L "${FQDN}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" -c 'exit' >/dev/null 2>&1; then
          echo "ok" >> "${LOAD_DIR}/auth_${i}.log"
        else
          echo "fail" >> "${LOAD_DIR}/auth_${i}.log"
        fi
      done
    ) &
  done
  wait

  for ((i = 0; i < CONCURRENT; i++)); do
    if [[ -f "${LOAD_DIR}/auth_${i}.log" ]]; then
      local ok_count=0 fail_count=0
      ok_count="$(grep -c "^ok$" "${LOAD_DIR}/auth_${i}.log" 2>/dev/null)" || true
      fail_count="$(grep -c "^fail$" "${LOAD_DIR}/auth_${i}.log" 2>/dev/null)" || true
      [[ -z "$ok_count" ]] && ok_count=0
      [[ -z "$fail_count" ]] && fail_count=0
      auth_ok=$((auth_ok + ok_count))
      auth_fail=$((auth_fail + fail_count))
    fi
  done

  local auth_total=$((auth_ok + auth_fail))
  if [[ "$auth_fail" -eq 0 ]]; then
    pass "Load auth: ${auth_total}/${auth_total} authentication requests succeeded (0 failures)"
  else
    local auth_pct=$(( auth_ok * 100 / (auth_total > 0 ? auth_total : 1) ))
    warn "Load auth: ${auth_ok}/${auth_total} succeeded (${auth_pct}%, ${auth_fail} failures)"
  fi

  # --- 10b: File I/O stress test ---
  info "Running file I/O stress test..."

  # Create test files
  for ((i = 0; i < CONCURRENT; i++)); do
    dd if=/dev/urandom of="${LOAD_DIR}/stress_${i}.bin" bs=1024 count=100 2>/dev/null
  done

  # Upload/Download test
  # FIX v1.1.3b: Use 127.0.0.1 directly for I/O stress test to avoid
  #      intermittent DNS resolution failures under concurrent load.
  #      Sequential mkdir per worker avoids race conditions.
  local smb_host="127.0.0.1"
  local io_fail=0
  local io_ok=0
  for ((i = 0; i < CONCURRENT; i++)); do
    (
      if smbclient "//${smb_host}/public" -U "${ADMIN_USER}"%"${ADMIN_PASS}" \
        -c "mkdir __load_test_${i}; cd __load_test_${i}; put ${LOAD_DIR}/stress_${i}.bin stress_${i}.bin; get stress_${i}.bin ${LOAD_DIR}/dl_${i}.bin; rm stress_${i}.bin" >/dev/null 2>&1; then
        echo "ok" >> "${LOAD_DIR}/io_${i}.log"
      else
        echo "fail" >> "${LOAD_DIR}/io_${i}.log"
      fi
    ) &
  done
  wait

  for ((i = 0; i < CONCURRENT; i++)); do
    if [[ -f "${LOAD_DIR}/io_${i}.log" ]]; then
      local ok_c=0 fail_c=0
      ok_c="$(grep -c "^ok$" "${LOAD_DIR}/io_${i}.log" 2>/dev/null)" || true
      fail_c="$(grep -c "^fail$" "${LOAD_DIR}/io_${i}.log" 2>/dev/null)" || true
      [[ -z "$ok_c" ]] && ok_c=0
      [[ -z "$fail_c" ]] && fail_c=0
      io_ok=$((io_ok + ok_c))
      io_fail=$((io_fail + fail_c))
    fi
  done

  # Cleanup load test files on share
  for ((i = 0; i < CONCURRENT; i++)); do
    smbclient "//127.0.0.1/public" -U "${ADMIN_USER}"%"${ADMIN_PASS}" \
      -c "rmdir __load_test_${i}" 2>/dev/null || true
  done

  local io_total=$((io_ok + io_fail))
  if [[ "$io_fail" -eq 0 ]]; then
    pass "Load I/O: ${io_total}/${io_total} file operations succeeded (0 failures)"
  else
    local io_pct=$(( io_ok * 100 / (io_total > 0 ? io_total : 1) ))
    warn "Load I/O: ${io_ok}/${io_total} succeeded (${io_pct}%, ${io_fail} failures)"
  fi

  # --- 10c: LDAP query stress test ---
  info "Running LDAP query stress test..."
  local ldap_fail=0
  local ldap_ok=0
  for ((j = 0; j < ITERATIONS; j++)); do
    if samba_tool user list -H ldap://"${FQDN}" -U "${ADMIN_USER}"%"${ADMIN_PASS}" >/dev/null 2>&1; then
      ldap_ok=$((ldap_ok + 1))
    else
      ldap_fail=$((ldap_fail + 1))
    fi
  done

  local ldap_total=$((ldap_ok + ldap_fail))
  if [[ "$ldap_fail" -eq 0 ]]; then
    pass "Load LDAP: ${ldap_total}/${ldap_total} LDAP queries succeeded"
  else
    local ldap_pct=$(( ldap_ok * 100 / (ldap_total > 0 ? ldap_total : 1) ))
    warn "Load LDAP: ${ldap_ok}/${ldap_total} succeeded (${ldap_pct}%, ${ldap_fail} failures)"
  fi

  # --- 10d: Timing ---
  local end_time
  end_time="$(date +%s%N)"
  local elapsed_ms=$(( (end_time - start_time) / 1000000 ))

  local total_ops=$(( auth_total + io_total + ldap_total ))
  local total_fails=$(( auth_fail + io_fail + ldap_fail ))

  info "Total: ${total_ops} operations in ${elapsed_ms}ms (~$(( total_ops * 1000 / (elapsed_ms > 0 ? elapsed_ms : 1) )) ops/sec)"

  if [[ "$total_fails" -eq 0 ]]; then
    pass "Load test: ALL ${total_ops} operations passed — the weight works!"
  else
    warn "Load test: ${total_fails}/${total_ops} operations failed"
  fi

  # Cleanup
  rm -rf "$LOAD_DIR"
}

# ============================================================
#  REPORT GENERATION
# ============================================================
generate_report() {
  local report_file="${TOOLKIT_ROOT:-.}/titration_report_$(date +%Y%m%d_%H%M%S).txt"

  {
    echo "============================================================"
    echo "  TITRATION REPORT — Samba AD DC Validation"
    echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Server:    ${FQDN} (${HOST_IP})"
    echo "  Domain:    ${DOMAIN} (${REALM})"
    echo "  Mode:      ${MODE}"
    echo "============================================================"
    echo ""

    for line in "${REPORT_LINES[@]}"; do
      local st="${line%%|*}"
      local msg="${line#*|}"

      case "$st" in
        SECTION) echo ""; echo "=== ${msg} ===" ;;
        PASS)   echo "  [PASS] ${msg}" ;;
        FAIL)   echo "  [FAIL] ${msg}" ;;
        WARN)   echo "  [WARN] ${msg}" ;;
        SKIP)   echo "  [SKIP] ${msg}" ;;
      esac
    done

    echo ""
    echo "============================================================"
    echo "  SUMMARY"
    echo "============================================================"
    echo "  Total tests: ${TEST_TOTAL}"
    echo -e "  ${T_GREEN}Passed:       ${PASS_COUNT}${T_NC}"
    echo -e "  ${T_RED}Failed:       ${FAIL_COUNT}${T_NC}"
    echo -e "  ${T_YELLOW}Warnings:     ${WARN_COUNT}${T_NC}"
    echo "  Skipped:     ${SKIP_COUNT}"

    if [[ "$FAIL_COUNT" -eq 0 && "$WARN_COUNT" -eq 0 ]]; then
      echo ""
      echo -e "  ${T_GREEN}${T_BOLD}RESULT: ALL CHECKS PASSED — The weight works!${T_NC}"
    elif [[ "$FAIL_COUNT" -eq 0 ]]; then
      echo ""
      echo -e "  ${T_YELLOW}${T_BOLD}RESULT: PASSED with ${WARN_COUNT} warning(s)${T_NC}"
    else
      echo ""
      echo -e "  ${T_RED}${T_BOLD}RESULT: ${FAIL_COUNT} failure(s) detected — needs attention${T_NC}"
    fi
    echo "============================================================"
  } > "$report_file"

  echo ""
  log_ok "Report saved: ${report_file}"
}

# ============================================================
#  MAIN
# ============================================================
main() {
  echo ""
  echo -e "${T_BOLD}${T_CYAN}"
  echo "============================================================"
  echo "  TITRATION — Samba AD DC Comprehensive Validation"
  echo "  Proving the weight works..."
  echo "  Server: ${FQDN} (${HOST_IP})"
  echo "  Domain: ${DOMAIN}"
  echo "  Mode:   ${MODE}"
  echo "============================================================"
  echo -e "${T_NC}"

  if ! is_provisioned; then
    echo -e "${T_RED}[FATAL] Domain is not provisioned!${T_NC}"
    echo "Run './samba-ad.sh install' first."
    exit 1
  fi

  case "$MODE" in
    full)
      check_services
      check_dns
      check_domain
      check_users_groups
      check_shares
      check_gpo
      check_dfs
      check_password_policy
      check_firewall
      check_load
      ;;
    quick)
      check_services
      check_dns
      check_domain
      check_users_groups
      check_shares
      check_password_policy
      ;;
    load)
      check_services
      check_load
      ;;
    *)
      echo "Unknown mode: ${MODE}"
      exit 1
      ;;
  esac

  # ── Summary ──
  echo ""
  echo -e "${T_BOLD}============================================================${T_NC}"
  echo -e "${T_BOLD}  SUMMARY${T_NC}"
  echo -e "${T_BOLD}============================================================${T_NC}"
  echo -e "  Total tests:  ${TEST_TOTAL}"
  echo -e "  ${T_GREEN}Passed:        ${PASS_COUNT}${T_NC}"
  echo -e "  ${T_RED}Failed:        ${FAIL_COUNT}${T_NC}"
  echo -e "  ${T_YELLOW}Warnings:      ${WARN_COUNT}${T_NC}"
  echo "  Skipped:      ${SKIP_COUNT}"
  echo ""

  if [[ "$FAIL_COUNT" -eq 0 && "$WARN_COUNT" -eq 0 ]]; then
    echo -e "  ${T_GREEN}${T_BOLD}RESULT: ALL CHECKS PASSED — The weight works!${T_NC}"
  elif [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo -e "  ${T_YELLOW}${T_BOLD}RESULT: PASSED with ${WARN_COUNT} warning(s)${T_NC}"
  else
    echo -e "  ${T_RED}${T_BOLD}RESULT: ${FAIL_COUNT} failure(s) detected — needs attention${T_NC}"
    # Show failed tests
    echo ""
    echo "  Failed tests:"
    for line in "${REPORT_LINES[@]}"; do
      if [[ "$line" == FAIL\|* ]]; then
        echo -e "    ${T_RED}${line#*|}${T_NC}"
      fi
    done
  fi

  echo -e "${T_BOLD}============================================================${T_NC}"
  echo ""

  if [[ "$SAVE_REPORT" == "yes" ]]; then
    generate_report
  fi

  # Return code: 0 if no failures, 1 otherwise
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    return 1
  fi
  return 0
}

main
