#!/bin/bash
# ============================================================
# samba-ad.sh — Автоматическое развёртывание домена Samba AD
#                  (Альт Домен / ALT Domain)
#
# Использование:
#   ./samba-ad.sh install   — Развёртывание домена
#   ./samba-ad.sh status    — Проверка статуса домена
#   ./samba-ad.sh delete    — Удаление (понижение роли) домена
#
# Конфигурация загружается из файла samba-ad.cfg,
# расположенного рядом со скриптом, либо по пути --cfg <файл>
# ============================================================

set -euo pipefail

# ======================== ЦВЕТА ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==================== КОНСТАНТЫ ========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CFG="${SCRIPT_DIR}/samba-ad.cfg"
LOG_FILE="/var/log/samba-ad-deploy.log"

# ================== ПЕРЕМЕННЫЕ КОНФИГА ==================
# Значения по умолчанию — переопределяются из .cfg
REALM=""
DOMAIN=""
NETBIOS=""
HOSTNAME=""
HOST_IP=""
ADMIN_PASS=""
DNS_BACKEND="SAMBA_INTERNAL"
DNS_FORWARDERS="8.8.8.8"
SERVER_ROLE="dc"
FUNCTION_LEVEL="2008_R2"
USE_RFC2307="yes"
BACKEND_STORE="tdb"
BACKEND_STORE_SIZE="4"
NTP_POOL="ru.pool.ntp.org"
NETWORK_IFACE="eth0"
BACKUP_DIR="/var/backups/samba-ad"
DEBUG_LEVEL="1"
AUTO_YES=0

# =================== УТИЛИТЫ ==========================

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

info()  { echo -e "${GREEN}[ИНФО]${NC}  $*";  log "INFO" "$*"; }
warn()  { echo -e "${YELLOW}[ВНИМ]${NC} $*";  log "WARN" "$*"; }
error() { echo -e "${RED}[ОШИБ]${NC} $*";     log "ERROR" "$*"; }
step()  { echo -e "${BLUE}[ШАГ]${NC}  $*";    log "STEP" "$*"; }
ok()    { echo -e "${GREEN}[  OK ]${NC} $*";   log "OK" "$*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*";      log "FAIL" "$*"; }

separator() {
    echo -e "${CYAN}============================================================${NC}"
}

header() {
    separator
    echo -e "${CYAN}  $*${NC}"
    separator
}

# Проверка: запущен ли скрипт от root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Скрипт должен быть запущен от имени root (sudo)."
        exit 1
    fi
}

# Проверка: установлен ли пакет
pkg_installed() {
    rpm -q "$1" &>/dev/null
}

# Установка пакета если не установлен
ensure_pkg() {
    local pkg="$1"
    if pkg_installed "${pkg}"; then
        ok "Пакет ${pkg} уже установлен"
    else
        step "Установка пакета ${pkg}..."
        apt-get install -y "${pkg}" || { error "Не удалось установить ${pkg}"; return 1; }
        ok "Пакет ${pkg} установлен"
    fi
}

# ================== ЗАГРУЗКА КОНФИГА ===================

load_config() {
    local cfg_file="${1:-${DEFAULT_CFG}}"

    if [[ ! -f "${cfg_file}" ]]; then
        error "Конфигурационный файл не найден: ${cfg_file}"
        error "Создайте файл samba-ad.cfg или укажите путь через --cfg <файл>"
        exit 1
    fi

    info "Загрузка конфигурации из ${cfg_file}..."

    # Читаем .cfg файл, пропуская комментарии и пустые строки
    while IFS='=' read -r key value; do
        # Убираем начальные/конечные пробелы
        key="$(echo "${key}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        value="$(echo "${value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        # Пропускаем комментарии и пустые строки
        [[ -z "${key}" || "${key}" == \#* ]] && continue

        # Убираем кавычки из значения
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"

        # Присваиваем переменные
        case "${key}" in
            REALM)              REALM="${value}" ;;
            DOMAIN)             DOMAIN="${value}" ;;
            NETBIOS)            NETBIOS="${value}" ;;
            HOSTNAME)           HOSTNAME="${value}" ;;
            HOST_IP)            HOST_IP="${value}" ;;
            ADMIN_PASS)         ADMIN_PASS="${value}" ;;
            DNS_BACKEND)        DNS_BACKEND="${value}" ;;
            DNS_FORWARDERS)     DNS_FORWARDERS="${value}" ;;
            SERVER_ROLE)        SERVER_ROLE="${value}" ;;
            FUNCTION_LEVEL)     FUNCTION_LEVEL="${value}" ;;
            USE_RFC2307)        USE_RFC2307="${value}" ;;
            BACKEND_STORE)      BACKEND_STORE="${value}" ;;
            BACKEND_STORE_SIZE) BACKEND_STORE_SIZE="${value}" ;;
            NTP_POOL)           NTP_POOL="${value}" ;;
            NETWORK_IFACE)      NETWORK_IFACE="${value}" ;;
            BACKUP_DIR)         BACKUP_DIR="${value}" ;;
            DEBUG_LEVEL)        DEBUG_LEVEL="${value}" ;;
            *) warn "Неизвестный параметр в конфиге: ${key}=${value}" ;;
        esac
    done < "${cfg_file}"

    ok "Конфигурация загружена"
}

# Проверка обязательных параметров
validate_config() {
    local missing=0

    if [[ -z "${REALM}" ]]; then error "REALM не задан в конфиге"; missing=1; fi
    if [[ -z "${DOMAIN}" ]]; then error "DOMAIN не задан в конфиге"; missing=1; fi
    if [[ -z "${NETBIOS}" ]]; then error "NETBIOS не задан в конфиге"; missing=1; fi
    if [[ -z "${HOSTNAME}" ]]; then error "HOSTNAME не задан в конфиге"; missing=1; fi
    if [[ -z "${ADMIN_PASS}" ]]; then error "ADMIN_PASS не задан в конфиге"; missing=1; fi

    if [[ "${DNS_BACKEND}" != "SAMBA_INTERNAL" && "${DNS_BACKEND}" != "BIND9_DLZ" ]]; then
        error "DNS_BACKEND должен быть SAMBA_INTERNAL или BIND9_DLZ"
        missing=1
    fi

    if [[ "${missing}" -eq 1 ]]; then
        error "Обязательные параметры отсутствуют. Проверьте samba-ad.cfg"
        exit 1
    fi

    ok "Параметры конфигурации проверены"
}

# Вывод текущей конфигурации
show_config() {
    echo ""
    info "=== Текущая конфигурация ==="
    echo "  REALM           = ${REALM}"
    echo "  DOMAIN          = ${DOMAIN}"
    echo "  NETBIOS         = ${NETBIOS}"
    echo "  HOSTNAME        = ${HOSTNAME}"
    echo "  HOST_IP         = ${HOST_IP}"
    echo "  DNS_BACKEND     = ${DNS_BACKEND}"
    echo "  DNS_FORWARDERS  = ${DNS_FORWARDERS}"
    echo "  SERVER_ROLE     = ${SERVER_ROLE}"
    echo "  FUNCTION_LEVEL  = ${FUNCTION_LEVEL}"
    echo "  USE_RFC2307     = ${USE_RFC2307}"
    echo "  NTP_POOL        = ${NTP_POOL}"
    echo "  NETWORK_IFACE   = ${NETWORK_IFACE}"
    echo "  BACKUP_DIR      = ${BACKUP_DIR}"
    echo ""
}

# ============================================================
#                    УСТАНОВКА ДОМЕНА (install)
# ============================================================

do_install() {
    header "РАЗВЁРТЫВАНИЕ ДОМЕНА SAMBA AD"

    load_config "${CFG_FILE}"
    validate_config
    show_config

    # Подтверждение
    echo -e "${YELLOW}Внимание! Все существующие данные Samba будут удалены.${NC}"
    if [[ "${AUTO_YES}" -eq 1 ]]; then
        info "Автоматическое подтверждение (--yes)"
    else
        read -r -p "Продолжить развёртывание домена ${DOMAIN}? [y/N]: " confirm
        if [[ ! "${confirm}" =~ ^[YyДд]$ ]]; then
            info "Развёртывание отменено пользователем."
            exit 0
        fi
    fi

    # --- Шаг 1: Обновление системы ---
    step "1/11. Обновление системы..."
    apt-get update -y || warn "apt-get update завершился с предупреждением"
    ok "Система обновлена"

    # --- Шаг 2: Установка пакетов ---
    step "2/11. Установка необходимых пакетов..."
    # task-samba-dc — мета-пакет для Samba DC на ALT Linux
    ensure_pkg task-samba-dc
    ensure_pkg chrony
    ensure_pkg krb5-kdc
    ensure_pkg bind-utils 2>/dev/null || true

    if [[ "${DNS_BACKEND}" == "BIND9_DLZ" ]]; then
        ensure_pkg bind
        ensure_pkg bind-utils
    fi
    ok "Пакеты установлены"

    # --- Шаг 3: Настройка NTP ---
    step "3/11. Настройка NTP-сервера (chrony)..."
    if ! pkg_installed chrony; then
        apt-get install -y chrony || { error "Не удалось установить chrony"; exit 1; }
    fi

    # Включаем режим сервера
    control chrony server 2>/dev/null || true

    # Настраиваем пул NTP
    if ! grep -q "${NTP_POOL}" /etc/chrony.conf 2>/dev/null; then
        sed -i -r "s/^(pool.*)/#\1/" /etc/chrony.conf 2>/dev/null || true
        echo "pool ${NTP_POOL} iburst" >> /etc/chrony.conf
    fi

    systemctl enable --now chronyd || { error "Не удалось запустить chronyd"; exit 1; }

    # Даём chrony время на подключение к NTP-серверам
    info "Ожидание синхронизации с NTP-серверами (5 сек)..."
    sleep 5

    # Принудительная синхронизация времени (важно для Kerberos!)
    # Kerberos требует точности часов в пределах 5 минут
    info "Принудительная синхронизация времени..."
    chronyc makestep 2>/dev/null || warn "chronyc makestep не выполнен — время может быть неточным"

    # Проверяем смещение часов
    local clock_offset
    clock_offset="$(chronyc tracking 2>/dev/null | grep -oP 'System time\s*:\s*\K[-0-9.]+' || echo "unknown")"
    if [[ "${clock_offset}" != "unknown" ]]; then
        # Убираем минус если есть и сравниваем абсолютное значение
        local abs_offset="${clock_offset#-}"
        # Порог — 300 секунд (5 минут), критично для Kerberos
        if command -v bc &>/dev/null; then
            if echo "${abs_offset} > 300" | bc -l 2>/dev/null | grep -q 1; then
                warn "Часы смещены на ${clock_offset} сек — это больше 5 минут!"
                warn "Kerberos может НЕ работать. Дождитесь синхронизации или выполните: chronyc makestep"
            else
                ok "Смещение часов: ${clock_offset} сек (в пределах нормы)"
            fi
        else
            ok "Смещение часов: ${clock_offset} сек"
        fi
    else
        warn "Не удалось определить смещение часов — проверьте chronyc tracking"
    fi
    ok "NTP-сервер настроен"

    # --- Шаг 4: Установка имени хоста ---
    step "4/11. Установка имени хоста..."
    hostnamectl set-hostname "${HOSTNAME}" || { error "Не удалось установить hostname"; exit 1; }

    # /etc/hostname (ALT Linux)
    echo "${HOSTNAME}" > /etc/hostname

    # /etc/sysconfig/network (ALT Linux v1)
    if [[ -f /etc/sysconfig/network ]]; then
        if grep -q '^HOSTNAME=' /etc/sysconfig/network 2>/dev/null; then
            sed -i "s/^HOSTNAME=.*/HOSTNAME=${HOSTNAME}/" /etc/sysconfig/network
        else
            echo "HOSTNAME=${HOSTNAME}" >> /etc/sysconfig/network
        fi
    fi

    # Обновляем /etc/hosts
    if ! grep -q "${HOSTNAME}" /etc/hosts 2>/dev/null; then
        echo "${HOST_IP} ${HOSTNAME} ${HOSTNAME%%.*}" >> /etc/hosts
    fi

    # domainname
    domainname "${DOMAIN}" 2>/dev/null || true
    ok "Имя хоста установлено: ${HOSTNAME}"

    # --- Шаг 5: Настройка DNS / resolvconf ---
    step "5/11. Настройка DNS (resolvconf)..."

    # Настройка resolvconf.conf
    if ! grep -q "^name_servers=127.0.0.1" /etc/resolvconf.conf 2>/dev/null; then
        echo "name_servers=127.0.0.1" >> /etc/resolvconf.conf
    fi

    # Настройка resolv.conf на интерфейсе (ALT Linux: /etc/net/ifaces/)
    local iface_dir="/etc/net/ifaces/${NETWORK_IFACE}"
    local iface_resolv="${iface_dir}/resolv.conf"
    if [[ -d "${iface_dir}" ]]; then
        cat > "${iface_resolv}" << EOF
nameserver 127.0.0.1
search ${DOMAIN}
EOF
        ok "DNS интерфейса ${NETWORK_IFACE} настроен (127.0.0.1)"
    else
        warn "Директория интерфейса ${iface_dir} не найдена"
        warn "Настройте nameserver 127.0.0.1 вручную в /etc/net/ifaces/<интерфейс>/resolv.conf"
    fi

    # Обновление resolvconf
    resolvconf -u 2>/dev/null || true

    # Отключение DNSStubListener если используется systemd-resolved
    if systemctl is-active systemd-resolved &>/dev/null; then
        sed -i 's/^#*DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf 2>/dev/null || true
        systemctl restart systemd-resolved 2>/dev/null || true
        ok "DNSStubListener отключён в systemd-resolved"
    fi
    ok "DNS настроен"

    # --- Шаг 6: Остановка конфликтующих служб ---
    step "6/11. Остановка конфликтующих служб..."
    for svc in smb nmb krb5kdc slapd bind; do
        systemctl stop "${svc}" 2>/dev/null || true
        systemctl disable "${svc}" 2>/dev/null || true
    done
    ok "Конфликтующие службы остановлены"

    # --- Шаг 6b: Настройка BIND9 (если BIND9_DLZ) ---
    if [[ "${DNS_BACKEND}" == "BIND9_DLZ" ]]; then
        step "6b. Настройка BIND9 для BIND9_DLZ..."
        control bind-chroot disabled 2>/dev/null || true

        # KRB5RCACHETYPE
        grep -q KRB5RCACHETYPE /etc/sysconfig/bind 2>/dev/null || \
            echo 'KRB5RCACHETYPE="none"' >> /etc/sysconfig/bind 2>/dev/null || true

        # Подключение плагина BIND_DLZ
        grep -q 'bind-dns' /etc/bind/named.conf 2>/dev/null || \
            echo 'include "/var/lib/samba/bind-dns/named.conf";' >> /etc/bind/named.conf 2>/dev/null || true

        # Остановить bind — будет запущен после provision
        systemctl stop bind 2>/dev/null || true
        ok "BIND9 подготовлен"
    fi

    # --- Шаг 7: Очистка старой конфигурации Samba ---
    step "7/11. Очистка старой конфигурации Samba..."
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba
    rm -rf /var/cache/samba
    mkdir -p /var/lib/samba/sysvol
    ok "Старая конфигурация удалена"

    # --- Шаг 8: Развёртывание домена (samba-tool domain provision) ---
    step "8/11. Развёртывание домена ${DOMAIN}..."

    # Извлекаем короткое имя хоста (без домена)
    local short_hostname="${HOSTNAME%%.*}"

    # Определяем максимальный поддерживаемый функциональный уровень
    # Если запрошен уровень выше 2008_R2 — проверяем поддержку
    local effective_func_level="${FUNCTION_LEVEL}"
    if [[ "${FUNCTION_LEVEL}" == "2016" ]]; then
        # Проверяем: поддерживает ли данная сборка Samba уровень 2016
        # Пробуем сухой запуск — если не поддерживается, откатываемся на 2008_R2
        info "Проверка поддержки функционального уровня ${FUNCTION_LEVEL}..."
        local test_output
        test_output="$(samba-tool domain provision \
            --realm="${REALM}" --domain="${NETBIOS}" \
            --server-role=dc --dns-backend="${DNS_BACKEND}" \
            --function-level="${FUNCTION_LEVEL}" \
            --option "log level=0" \
            --targetdir="$(mktemp -d)" 2>&1)" || true
        rm -rf "$(echo "${test_output}" | grep -oP 'targetdir=\K\S+' 2>/dev/null)" 2>/dev/null || true

        if echo "${test_output}" | grep -qi "higher than its actual DC function level"; then
            warn "Сборка Samba НЕ поддерживает функциональный уровень ${FUNCTION_LEVEL}"
            warn "Автоматический откат на 2008_R2 (максимально поддерживаемый)"
            effective_func_level="2008_R2"
        else
            info "Функциональный уровень ${FUNCTION_LEVEL} поддерживается"
        fi
    fi

    # Собираем аргументы в массив — корректный способ передачи
    local -a PROVISION_ARGS=(
        --realm="${REALM}"
        --domain="${NETBIOS}"
        --adminpass="${ADMIN_PASS}"
        --dns-backend="${DNS_BACKEND}"
        --server-role="${SERVER_ROLE}"
        --host-name="${short_hostname}"
        --host-ip="${HOST_IP}"
    )

    # RFC2307
    if [[ "${USE_RFC2307}" == "yes" ]]; then
        PROVISION_ARGS+=("--use-rfc2307")
    fi

    # Функциональный уровень (отличный от умолчания 2008_R2)
    if [[ "${effective_func_level}" != "2008_R2" ]]; then
        PROVISION_ARGS+=("--function-level=${effective_func_level}")
    fi

    # DNS forwarder — через --option в формате key=value (без пробелов вокруг =)
    if [[ -n "${DNS_FORWARDERS}" ]]; then
        local first_forwarder=true
        for fwd in ${DNS_FORWARDERS}; do
            if [[ "${first_forwarder}" == "true" ]]; then
                PROVISION_ARGS+=(--option "dns forwarder=${fwd}")
                first_forwarder=false
            else
                # Дополнительные форвардеры добавим потом в smb.conf
                PROVISION_ARGS+=(--option "dns forwarder=${fwd}")
            fi
        done
    fi

    # Уровень логирования
    PROVISION_ARGS+=(--option "log level=${DEBUG_LEVEL}")

    # Показываем команду для отладки
    info "Выполнение: samba-tool domain provision ..."
    info "Аргументы: ${PROVISION_ARGS[*]}"

    # Запуск provision через массив аргументов
    if ! samba-tool domain provision "${PROVISION_ARGS[@]}"; then
        # Если ошибка из-за функционального уровня — пробуем с 2008_R2
        error "Развёртывание домена завершилось ошибкой!"

        # Проверяем: может быть проблема в функциональном уровне
        if [[ "${effective_func_level}" != "2008_R2" ]]; then
            warn "Возможно, функциональный уровень ${effective_func_level} не поддерживается"
            warn "Пробуем повторное развёртывание с уровнем 2008_R2..."
            effective_func_level="2008_R2"

            # Пересобираем массив без function-level (2008_R2 — умолчание)
            PROVISION_ARGS=(
                --realm="${REALM}"
                --domain="${NETBIOS}"
                --adminpass="${ADMIN_PASS}"
                --dns-backend="${DNS_BACKEND}"
                --server-role="${SERVER_ROLE}"
                --host-name="${short_hostname}"
                --host-ip="${HOST_IP}"
            )
            if [[ "${USE_RFC2307}" == "yes" ]]; then
                PROVISION_ARGS+=("--use-rfc2307")
            fi
            if [[ -n "${DNS_FORWARDERS}" ]]; then
                for fwd in ${DNS_FORWARDERS}; do
                    PROVISION_ARGS+=(--option "dns forwarder=${fwd}")
                done
            fi
            PROVISION_ARGS+=(--option "log level=${DEBUG_LEVEL}")

            info "Аргументы (повтор): ${PROVISION_ARGS[*]}"
            if ! samba-tool domain provision "${PROVISION_ARGS[@]}"; then
                error "Повторное развёртывание тоже завершилось ошибкой!"
                error "Проверьте лог: ${LOG_FILE}"
                exit 1
            fi
            warn "Домен развёрнут с функциональным уровнем 2008_R2 (вместо запрошенного ${FUNCTION_LEVEL})"
        else
            error "Проверьте лог: ${LOG_FILE}"
            exit 1
        fi
    fi
    ok "Домен ${DOMAIN} развёрнут успешно (функциональный уровень: ${effective_func_level})"

    # --- Шаг 9: Настройка Kerberos ---
    step "9/11. Настройка Kerberos..."
    if [[ -f /var/lib/samba/private/krb5.conf ]]; then
        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
        ok "krb5.conf скопирован из /var/lib/samba/private/"
    else
        # Генерация krb5.conf вручную
        cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_kdc = true
    dns_lookup_realm = false
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    rdns = false

[realms]
${REALM} = {
    default_domain = ${DOMAIN}
}

[domain_realm]
    .${DOMAIN} = ${REALM}
    ${DOMAIN} = ${REALM}
EOF
        ok "krb5.conf создан вручную"
    fi

    # Отключаем кеш KEYRING (рекомендация ALT)
    control krb5-conf-ccache default 2>/dev/null || true
    ok "Kerberos настроен"

    # --- Шаг 9b: Проверка/восстановление прав sysvol ---
    if [[ -d /var/lib/samba/sysvol ]]; then
        info "Проверка прав доступа к sysvol..."
        # Назначаем корректные права на sysvol
        chmod 3770 /var/lib/samba/sysvol 2>/dev/null || true
        chown root:root /var/lib/samba/sysvol 2>/dev/null || true
        ok "Права доступа sysvol проверены"
    fi

    # --- Шаг 10: Запуск служб ---
    step "10/11. Запуск служб..."
    systemctl enable --now samba || { error "Не удалось запустить samba"; exit 1; }

    # Даём samba время на полную инициализацию
    info "Ожидание полной загрузки службы samba (5 сек)..."
    sleep 5

    # Проверяем что служба действительно работает
    if ! systemctl is-active samba &>/dev/null; then
        warn "Служба samba не активна после запуска, пробуем перезапуск..."
        systemctl restart samba || { error "Не удалось перезапустить samba"; exit 1; }
        sleep 3
    fi

    if [[ "${DNS_BACKEND}" == "BIND9_DLZ" ]]; then
        # Закомментировать строки в local.conf для избежания конфликта зон
        if [[ -f /etc/bind/local.conf ]]; then
            sed -i 's/^[^#]/#&/' /etc/bind/local.conf
        fi
        systemctl enable --now bind || { error "Не удалось запустить bind"; exit 1; }
    fi

    # Перезапуск сети для применения DNS-настроек (ALT Linux)
    systemctl restart network 2>/dev/null || systemctl restart networking 2>/dev/null || true
    ok "Службы запущены"

    # --- Шаг 11: Проверка работоспособности ---
    step "11/11. Проверка работоспособности домена..."
    do_status

    header "РАЗВЁРТЫВАНИЕ ЗАВЕРШЕНО"
    info "Домен: ${DOMAIN}"
    info "Realm: ${REALM}"
    info "Контроллер домена: ${HOSTNAME}"
    info "DNS-бэкенд: ${DNS_BACKEND}"
    info ""
    warn "Рекомендуется перезагрузить сервер: reboot"
    info "После перезагрузки можно подключать клиентов к домену!"
}

# ============================================================
#                    СТАТУС ДОМЕНА (status)
# ============================================================

do_status() {
    header "СТАТУС ДОМЕНА SAMBA AD"

    # Загружаем конфиг если переменные ещё не установлены
    # (нужно для ADMIN_PASS и NETBIOS при проверке smbclient)
    if [[ -z "${ADMIN_PASS:-}" || -z "${NETBIOS:-}" ]]; then
        load_config "${CFG_FILE}" 2>/dev/null || true
    fi

    local all_ok=1

    # 1. Проверка службы samba
    step "Проверка службы samba..."
    if systemctl is-active samba &>/dev/null; then
        ok "Служба samba — АКТИВНА"
    else
        fail "Служба samba — НЕ ЗАПУЩЕНА"
        all_ok=0
    fi

    # 2. Проверка службы bind (если BIND9_DLZ)
    if [[ "${DNS_BACKEND:-}" == "BIND9_DLZ" ]]; then
        step "Проверка службы bind..."
        if systemctl is-active bind &>/dev/null; then
            ok "Служба bind — АКТИВНА"
        else
            fail "Служба bind — НЕ ЗАПУЩЕНА"
            all_ok=0
        fi
    fi

    # 3. Проверка службы chronyd
    step "Проверка службы chronyd..."
    if systemctl is-active chronyd &>/dev/null; then
        ok "Служба chronyd — АКТИВНА"

        # Проверка смещения часов (критично для Kerberos — допуск 5 минут)
        local clock_offset
        clock_offset="$(chronyc tracking 2>/dev/null | grep -oP 'System time\s*:\s*\K[-0-9.]+' || echo "unknown")"
        if [[ "${clock_offset}" != "unknown" ]]; then
            local abs_offset="${clock_offset#-}"
            if command -v bc &>/dev/null; then
                if echo "${abs_offset} > 300" | bc -l 2>/dev/null | grep -q 1; then
                    fail "Часы смещены на ${clock_offset} сек — БОЛЬШЕ 5 минут! Kerberos НЕ будет работать!"
                    fail "Выполните: chronyc makestep"
                    all_ok=0
                else
                    ok "Смещение часов: ${clock_offset} сек (Kerberos OK)"
                fi
            else
                ok "Смещение часов: ${clock_offset} сек"
            fi
        fi
    else
        fail "Служба chronyd — НЕ ЗАПУЩЕНА"
        all_ok=0
    fi

    # 4. Информация о домене
    step "Информация о домене..."
    if command -v samba-tool &>/dev/null; then
        local domain_info
        domain_info="$(samba-tool domain info 127.0.0.1 2>&1)" || true
        if [[ -n "${domain_info}" && ! "${domain_info}" =~ "error" ]]; then
            echo "${domain_info}"
            ok "Информация о домене получена"
        else
            warn "Не удалось получить информацию о домене"
            warn "${domain_info}"
            all_ok=0
        fi
    else
        warn "samba-tool не найден"
        all_ok=0
    fi

    # 5. Проверка DNS
    step "Проверка DNS..."
    if [[ -f /etc/resolv.conf ]]; then
        if grep -q "nameserver 127.0.0.1" /etc/resolv.conf 2>/dev/null; then
            ok "DNS указывает на 127.0.0.1"
        else
            warn "DNS НЕ указывает на 127.0.0.1 — проверьте /etc/resolv.conf"
            all_ok=0
        fi
    fi

    # Проверка разрешения DNS-записей домена
    if command -v host &>/dev/null; then
        local realm_lower
        realm_lower="$(echo "${REALM:-unknown}" | tr '[:upper:]' '[:lower:]')"
        if host "${realm_lower}" &>/dev/null; then
            ok "DNS-запись домена ${realm_lower} разрешается"
        else
            warn "DNS-запись домена ${realm_lower} НЕ разрешается"
            all_ok=0
        fi

        # SRV-записи
        if host -t SRV "_kerberos._udp.${realm_lower}." &>/dev/null; then
            ok "SRV-запись _kerberos._udp.${realm_lower} найдена"
        else
            warn "SRV-запись _kerberos._udp.${realm_lower} НЕ найдена"
            all_ok=0
        fi

        if host -t SRV "_ldap._tcp.${realm_lower}." &>/dev/null; then
            ok "SRV-запись _ldap._tcp.${realm_lower} найдена"
        else
            warn "SRV-запись _ldap._tcp.${realm_lower} НЕ найдена"
            all_ok=0
        fi
    else
        warn "Утилита host не установлена — DNS не проверена"
    fi

    # 6. Проверка Kerberos
    step "Проверка Kerberos..."
    if [[ -f /etc/krb5.conf ]]; then
        ok "Файл /etc/krb5.conf существует"
        local realm_in_krb5
        realm_in_krb5="$(grep -oP 'default_realm\s*=\s*\K.*' /etc/krb5.conf 2>/dev/null || true)"
        if [[ -n "${realm_in_krb5}" ]]; then
            ok "default_realm = ${realm_in_krb5}"
        else
            warn "default_realm не задан в krb5.conf"
            all_ok=0
        fi
    else
        fail "Файл /etc/krb5.conf НЕ найден"
        all_ok=0
    fi

    # 7. Проверка smb.conf
    step "Проверка smb.conf..."
    if [[ -f /etc/samba/smb.conf ]]; then
        ok "Файл /etc/samba/smb.conf существует"
        if command -v testparm &>/dev/null; then
            if testparm -s /etc/samba/smb.conf &>/dev/null; then
                ok "Конфигурация smb.conf корректна"
            else
                warn "Ошибки в smb.conf — выполните testparm"
                all_ok=0
            fi
        fi
    else
        fail "Файл /etc/samba/smb.conf НЕ найден — домен не развёрнут?"
        all_ok=0
    fi

    # 8. Общие ресурсы (используем авторизацию — анонимный доступ на AD DC запрещён)
    step "Проверка общих ресурсов (sysvol, netlogon)..."
    if command -v smbclient &>/dev/null; then
        local shares=""
        # Пробуем авторизованный доступ (AD DC не разрешает анонимный просмотр)
        if [[ -n "${ADMIN_PASS:-}" && -n "${NETBIOS:-}" ]]; then
            shares="$(smbclient -L localhost -U"${NETBIOS}\\Administrator%${ADMIN_PASS}" 2>&1)" || true
        fi
        # Если авторизованный не сработал — пробуем анонимный
        if [[ -z "${shares}" || ! "${shares}" =~ sysvol ]]; then
            shares="$(smbclient -L localhost -N 2>&1)" || true
        fi
        if echo "${shares}" | grep -q "sysvol"; then
            ok "Ресурс sysvol доступен"
        else
            warn "Ресурс sysvol НЕ доступен"
            all_ok=0
        fi
        if echo "${shares}" | grep -q "netlogon"; then
            ok "Ресурс netlogon доступен"
        else
            warn "Ресурс netlogon НЕ доступен"
            all_ok=0
        fi
    else
        warn "smbclient не установлен — ресурсы не проверены"
    fi

    # Итог
    echo ""
    if [[ "${all_ok}" -eq 1 ]]; then
        ok "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ — домен работает корректно"
    else
        warn "НЕКОТОРЫЕ ПРОВЕРКИ НЕ ПРОЙДЕНЫ — см. предупреждения выше"
    fi
    separator
}

# ============================================================
#                    УДАЛЕНИЕ ДОМЕНА (delete)
# ============================================================

do_delete() {
    header "УДАЛЕНИЕ ДОМЕНА SAMBA AD"

    load_config "${CFG_FILE}"

    # Подтверждение
    echo -e "${RED}ВНИМАНИЕ! Это действие полностью удалит домен с данного сервера!${NC}"
    echo -e "${RED}Все данные Active Directory будут уничтожены!${NC}"
    if [[ "${AUTO_YES}" -eq 1 ]]; then
        info "Автоматическое подтверждение (--yes)"
    else
        read -r -p "Вы уверены, что хотите удалить домен ${DOMAIN:-???}? [yes/NO]: " confirm
        if [[ "${confirm}" != "yes" ]]; then
            info "Удаление отменено."
            exit 0
        fi
    fi

    # --- Шаг 1: Проверка FSMO-ролей ---
    step "1/6. Проверка FSMO-ролей..."
    if command -v samba-tool &>/dev/null; then
        samba-tool fsmo show 2>/dev/null || warn "Не удалось проверить FSMO-роли"
    fi

    # --- Шаг 2: Понижение роли (demote) ---
    step "2/6. Понижение роли контроллера домена..."
    if systemctl is-active samba &>/dev/null; then
        if command -v samba-tool &>/dev/null; then
            info "Выполняется samba-tool domain demote..."
            samba-tool domain demote -Uadministrator || {
                warn "Понижение роли завершилось ошибкой. Возможно это единственный DC."
                warn "Продолжаем удаление вручную..."
            }
        fi
    else
        warn "Служба samba не запущена — понижение роли пропускается"
    fi

    # --- Шаг 3: Остановка служб ---
    step "3/6. Остановка служб..."
    systemctl stop samba 2>/dev/null || true
    systemctl disable samba 2>/dev/null || true
    systemctl stop bind 2>/dev/null || true
    systemctl disable bind 2>/dev/null || true
    ok "Службы остановлены"

    # --- Шаг 4: Очистка файлов Samba ---
    step "4/6. Удаление файлов Samba..."
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba
    rm -rf /var/cache/samba
    rm -f /etc/krb5.conf
    ok "Файлы Samba удалены"

    # --- Шаг 5: Восстановление resolv.conf ---
    step "5/6. Восстановление DNS-настроек..."

    # Убираем name_servers=127.0.0.1 из resolvconf.conf
    sed -i '/^name_servers=127.0.0.1/d' /etc/resolvconf.conf 2>/dev/null || true

    # Восстанавливаем DNS на интерфейсе
    local iface_resolv="/etc/net/ifaces/${NETWORK_IFACE}/resolv.conf"
    if [[ -f "${iface_resolv}" ]]; then
        cat > "${iface_resolv}" << EOF
nameserver 8.8.8.8
EOF
    fi

    resolvconf -u 2>/dev/null || true
    ok "DNS-настройки восстановлены"

    # --- Шаг 6: Восстановление NTP ---
    step "6/6. Восстановление NTP в режим клиента..."
    control chrony client 2>/dev/null || true
    ok "NTP переведён в режим клиента"

    header "УДАЛЕНИЕ ДОМЕНА ЗАВЕРШЕНО"
    info "Домен полностью удалён с данного сервера."
    info "Рекомендуется перезагрузить сервер: reboot"
}

# ============================================================
#                       СПРАВКА
# ============================================================

usage() {
    cat << EOF
${CYAN}samba-ad.sh${NC} — Автоматическое развёртывание домена Samba AD (Альт Домен)

${GREEN}Использование:${NC}
  $0 <команда> [опции]

${GREEN}Команды:${NC}
  ${YELLOW}install${NC}   — Развёртывание домена Samba AD (первый контроллер домена)
  ${YELLOW}status${NC}    — Проверка статуса и работоспособности домена
  ${YELLOW}delete${NC}    — Удаление домена (понижение роли DC + очистка)

${GREEN}Опции:${NC}
  ${YELLOW}--cfg <файл>${NC}  — Путь к конфигурационному .cfg файлу
                         (по умолчанию: samba-ad.cfg рядом со скриптом)
  ${YELLOW}-y, --yes${NC}    — Пропустить подтверждение (авто-yes)
  ${YELLOW}-h, --help${NC}   — Показать эту справку

${GREEN}Примеры:${NC}
  $0 install                    # Развёртывание с конфигом по умолчанию
  $0 install --yes              # Развёртывание без подтверждения
  $0 install --cfg /etc/samba-ad.cfg
  $0 delete --yes               # Удаление без подтверждения
  $0 status                     # Проверка статуса

${GREEN}Формат .cfg файла:${NC}
  REALM=TEST.ALT
  DOMAIN=test.alt
  NETBIOS=TEST
  HOSTNAME=dc1.test.alt
  ADMIN_PASS='Pa$$word'
  DNS_BACKEND=SAMBA_INTERNAL
  DNS_FORWARDERS="8.8.8.8"
  ...

EOF
}

# ============================================================
#                      ТОЧКА ВХОДА
# ============================================================

# Парсинг аргументов
COMMAND=""
CFG_FILE="${DEFAULT_CFG}"
AUTO_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        install|status|delete)
            COMMAND="$1"
            shift
            ;;
        --cfg)
            CFG_FILE="$2"
            shift 2
            ;;
        -y|--yes)
            AUTO_YES=1
            shift
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            error "Неизвестный аргумент: $1"
            usage
            exit 1
            ;;
    esac
done

# Проверка root
check_root

# Создание директории для логов
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

# Маршрутизация команд
case "${COMMAND}" in
    install)
        do_install
        ;;
    status)
        do_status
        ;;
    delete)
        do_delete
        ;;
    "")
        error "Команда не указана."
        usage
        exit 1
        ;;
    *)
        error "Неизвестная команда: ${COMMAND}"
        usage
        exit 1
        ;;
esac
