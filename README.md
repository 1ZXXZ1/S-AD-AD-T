# Samba AD DC Auto-Deploy Toolkit
# ALT Server 11.1 | Samba 4

## Быстрый старт

```bash
# 1. Скопировать toolkit на сервер
scp -r samba-ad-toolkit/ root@<server>:/root/

# 2. Зайти на сервер и отредактировать конфиг
cd /root/samba-ad-toolkit
nano config.cfg   # ← ОБЯЗАТЕЛЬНО: указать IP, домен, пароль

# 3. Запустить полную установку
chmod +x samba-ad.sh modules/*.sh
./samba-ad.sh install

# 4. Проверить статус
./samba-ad.sh status
```

## Структура

```
samba-ad-toolkit/
├── config.cfg              ← ВСЕ параметры здесь (IP, домен, DNS, пароли)
├── samba-ad.sh             ← Главный скрипт
├── modules/
│   ├── lib.sh              ← Общие функции (логирование, бэкап, снапшоты)
│   ├── 01_bootstrap.sh     ← Установка пакетов, hostname, chrony
│   ├── 02_provision.sh     ← Провижн Samba AD DC
│   ├── 03_shares.sh        ← Файловые шары + VFS + снапшоты
│   ├── 04_dhcp.sh          ← DHCP шаблон (выключен по умолчанию)
│   ├── 05_users.sh         ← Пользователи и группы из users_auto.csv
│   ├── 06_gpo.sh           ← GPO диспетчер (вызывает Python)
│   ├── 06_gpo.py           ← GPO: USB, аудит, диски, редирект, приложения
│   ├── 07_dfs.sh           ← DFS namespace
│   ├── 08_security.sh      ← Политики паролей, ACL, отключение SMBv1
│   ├── 09_firewall.sh      ← Firewalld / iptables
│   └── 10_backup.sh        ← Бэкап / восстановление AD
└── templates/
    └── users_auto.csv      ← Единый шаблон пользователей
```

## Команды

| Команда | Описание |
|---------|----------|
| `./samba-ad.sh install` | Полная установка (все шаги) |
| `./samba-ad.sh install --step bootstrap` | Только один шаг |
| `./samba-ad.sh delete` | Удалить домен |
| `./samba-ad.sh delete --full` | Удалить домен + пакеты + данные |
| `./samba-ad.sh reload` | Перечитать config и рестарт |
| `./samba-ad.sh status` | Текущий статус |
| `./samba-ad.sh backup` | Создать бэкап AD |
| `./samba-ad.sh backup list` | Список бэкапов |
| `./samba-ad.sh backup restore /path` | Восстановить из бэкапа |
| `./samba-ad.sh users --csv file.csv` | Создать пользователей из users_auto.csv |
| `./samba-ad.sh gpo all` | Все GPO |
| `./samba-ad.sh gpo usb` | Только USB GPO |
| `./samba-ad.sh gpo audit` | Только аудит GPO |
| `./samba-ad.sh gpo drive-maps` | Только маппинг дисков |
| `./samba-ad.sh gpo folder-redir` | Только редирект папок |

## Конфигурация (config.cfg)

Все хардкод-значения вынесены в `config.cfg`. Перед установкой обязательно укажите:

- `HOST_IP` — IP-адрес сервера
- `HOST_SHORTNAME` — короткое имя хоста
- `DOMAIN` — DNS-имя домена
- `ADMIN_PASS` — пароль Administrator

Опционально:
- Список шар (`SHARES_LIST`)
- Список групп (`GROUPS_LIST`)
- GPO параметры (включение/выключение отдельных политик)
- Firewall порты
- DHCP настройки

## GPO

GPO создаются через Python-модуль `06_gpo.py`, который использует Python bindings Samba:
- **USB Storage Restriction** — блокировка USB-накопителей (мышь/клавиатура работают)
- **Audit Logon Logoff** — аудит входа/выхода
- **Drive Maps** — маппинг сетевых дисков через GPO
- **Folder Redirection** — редирект Desktop/Documents/Downloads и т.д.
- **Apps Auto Install** — автозагрузка приложений при старте

Каждая GPO включается/выключается в `config.cfg` через `GPO_*_ENABLED=yes/no`.

## Требования

- ALT Server 11.1
- Samba 4 (пакет `task-samba-dc`)
- Python 3 с `python3-module-samba` и `ldb-tools`
- Root-доступ

## Известные проблемы и решения

См. `info-bag.txt` — баг-трекер с описанием проблем и решений:
- **Баг 1**: Конфликт DNS на порту 53 (named/BIND9)
- **Баг 2**: Нет доступа к ресурсам — отсутствуют разрешения
- **Баг 3**: Ошибка подключения клиента к 127.0.0.1
- **Баг 4**: getent не показывает доменных пользователей и групп
- **Баг 5**: Ошибка ввода Windows-клиента в домен (DNS/имя компьютера)
- **Баг 6**: samba-tool domain info не принимает IP-адрес (Samba 4.21+)
- **Баг 7**: smbclient с подстановкой %*** вместо реального пароля

## История изменений

### v1.2-fixed
- **02_provision.sh**: Исправлена ошибка верификации — `samba-tool domain info` теперь вызывается с FQDN вместо IP-адреса (Samba 4.21+ не принимает IP); добавлен DNS-запрос при верификации
- **samba-ad.sh**: Убран плейсхолдер `%***` из подсказки проверки шар (приводил к NT_STATUS_LOGON_FAILURE при копировании); исправлена подсказка `domain info` на использование FQDN; добавлен вывод domain info в команде `status`
- **info-bag.txt**: Добавлены Баг 5 (ошибка ввода Windows-клиента в домен — DNS/имя компьютера/firewall), Баг 6 (samba-tool domain info и IP-адрес), Баг 7 (smbclient с %***)

### v1.1-fixed
- **03_shares.sh**: Исправлена критическая ошибка записи шар в smb.conf (мусор вместо конфига)
- **08_security.sh**: ACL теперь проверяют резолв имён групп через getent/wbinfo, fallback на GID
- **05_users.sh**: Улучшена обработка OU (fallback на samba-tool ou create), улучшен лог ошибок
- **configure_users_auto.sh**: Убраны захардкоженные значения (DOMAIN_DN, ADMIN_PASS и др.), теперь читает из config.cfg; добавлен fallback при создании пользователя с profilePath
- **info-bag.txt**: Полностью переработан — исправлены опечатки, добавлены решения из документации Альт Домен

## Лицензия

Использование и модификация — без ограничений.
