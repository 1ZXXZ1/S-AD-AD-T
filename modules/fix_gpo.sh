#!/usr/bin/env bash
# fix_gpo.sh — Полный сброс и пересоздание GPO согласно config.cfg
# Запуск: sudo bash fix_gpo.sh

set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TOOLKIT_ROOT
source "${TOOLKIT_ROOT}/modules/lib.sh"
_load_config

# Встроенные GPO, которые нельзя удалять
DEFAULT_GPO_GUIDS=(
    "{31B2F340-016D-11D2-945F-00C04FB984F9}"   # Default Domain Policy
    "{6AC1786C-016F-11D2-945F-00C04FB984F9}"   # Default Domain Controllers Policy
)

log_step "Сброс всех пользовательских GPO и повторное создание"

# 1. Получить список всех GPO
mapfile -t gpo_lines < <(samba-tool gpo listall -H ldap://"${FQDN}" -U "${ADMIN_USER}%${ADMIN_PASS}" 2>/dev/null | grep -E '^\s+GPO|^\s+displayName' || true)

declare -A display_names
current_guid=""
while IFS= read -r line; do
    if [[ "$line" =~ GPO\s*:\s*\{([^\}]+)\} ]]; then
        current_guid="{${BASH_REMATCH[1]}}"
    elif [[ "$line" =~ displayName\s*:\s*(.+) ]]; then
        display_name="${BASH_REMATCH[1]}"
        display_names["$current_guid"]="$display_name"
    fi
done <<< "$(printf '%s\n' "${gpo_lines[@]}")"

# 2. Удалить все GPO, кроме встроенных
deleted=0
for guid in "${!display_names[@]}"; do
    is_default="no"
    for def_guid in "${DEFAULT_GPO_GUIDS[@]}"; do
        if [[ "$guid" == "$def_guid" ]]; then
            is_default="yes"
            break
        fi
    done
    if [[ "$is_default" == "yes" ]]; then
        log "Пропущена встроенная GPO: ${display_names[$guid]} ($guid)"
        continue
    fi

    log "Удаление GPO: ${display_names[$guid]} ($guid)"
    if samba-tool gpo del "$guid" -H ldap://"${FQDN}" -U "${ADMIN_USER}%${ADMIN_PASS}" >/dev/null 2>&1; then
        deleted=$((deleted + 1))
        log "  ✓ удалена"
    else
        log_warn "  ✗ не удалось удалить $guid"
    fi
done

log "Удалено пользовательских GPO: $deleted"

# 3. Сбросить ACL на SYSVOL после удаления (опционально)
samba-tool ntacl sysvolreset >/dev/null 2>&1 || log_warn "sysvolreset завершился с ошибкой"

# 4. Пересоздать все GPO согласно config.cfg (только те, что включены)
log_step "Пересоздание GPO из конфигурации"
bash "${TOOLKIT_ROOT}/modules/06_gpo.sh" all

log_ok "Исправление GPO завершено. Текущий список:"
samba-tool gpo listall -H ldap://"${FQDN}" -U "${ADMIN_USER}%${ADMIN_PASS}" 2>/dev/null | grep -E 'displayName|GPO'