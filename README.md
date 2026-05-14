# Samba AD DC Auto-Deploy Toolkit
# ALT Server 11.1 | Samba 4

## Быстрый старт

```bash
# 1. Зайти на сервер и отредактировать конфиг
cd /root/samba-ad-toolkit
nano config.cfg   # ← ОБЯЗАТЕЛЬНО: указать IP, домен, пароль

# 2. Запустить полную установку
chmod +x samba-ad.sh modules/*.sh
./samba-ad.sh install

# 3. Проверить статус
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


## Конфигурация (config.cfg)

Все хардкод-значения вынесены в `config.cfg`. Перед установкой обязательно укажите:

- `HOST_IP` — IP-адрес сервера
- `HOST_SHORTNAME` — короткое имя хоста
- `DOMAIN` — DNS-имя домена
- `ADMIN_PASS` — пароль Administrator

Опционально:
- Список шар (`SHARES_LIST`)
- Список групп (`GROUPS_LIST`)


## Требования

- ALT Server 11.1
- Samba 4 (пакет `task-samba-dc`)
- Python 3 с `python3-module-samba` и `ldb-tools`
- Root-доступ


## Лицензия

Использование и модификация — без ограничений.
