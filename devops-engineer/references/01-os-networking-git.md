# 01. Фундаментальная база: ОС (Linux / Windows), Компьютерные сети и Git

> **Принцип универсальности:** Команды, дистрибутивы (RHEL/Alma/Rocky, Debian/Ubuntu, SLES, Astra/ALT/RED OS, Windows Server) и сетевые стеки в этом справочнике являются базовыми ориентирами. Любое изменение параметров ОС и сети должно фиксироваться персистентно (в файлах конфигурации и коде IaC/Ansible/GPO/DSC), а не только в оперативной памяти.

---

## 1. Администрирование ОС Linux

### 1.1. Методология диагностики ресурсов (Метод USE Брендана Грегга)

Для каждого аппаратного и ядерного ресурса проверяй три метрики в строгом порядке — **U**tilization (загрузка), **S**aturation (насыщение / очередь), **E**rrors (ошибки):

| Ресурс | Utilization (Загрузка) | Saturation (Очередь / Дефицит) | Errors (Ошибки) |
|---|---|---|---|
| **CPU** | `mpstat -P ALL 1`, `pidstat -u 1`, `top`/`htop` (`%usr`, `%sys`, `%iowait`, `%steal`) | `vmstat 1` (`r` > числа ядер), `/proc/schedstat`, `psi/cpu` (Pressure Stall Information) | `dmesg -T \| grep -iE 'mce\|hardware error'`, `perf stat` |
| **Memory** | `free -m`, `cat /proc/meminfo` (`MemAvailable`, `Slab`, `PageTables`) | `vmstat 1` (`si`/`so` > 0), `sar -B 1` (page faults), `/proc/pressure/memory` | `dmesg -T \| grep -iE 'out of memory\|oom-kill\|killed process'` |
| **Disk I/O** | `iostat -xz 1` (`%util`), `iotop -oP` | `iostat -xz 1` (`aqu-sz` > 1, `r_await` / `w_await` > нормы носителя), `/proc/pressure/io` | `smartctl -a /dev/sdX`, `dmesg -T \| grep -iE 'I/O error\|ext4\|xfs'` |
| **Network** | `sar -n DEV 1`, `ip -s link` | `ss -s`, `ss -lnt` (`Recv-Q` близко к `Send-Q`), `nstat -az \| grep -iE 'Drop\|Overflow'` | `ip -s link` (`errors`, `dropped`, `overrun`), `ethtool -S eth0` |

### 1.2. Управление процессами, памятью, cgroups v2 и systemd

- **Состояния процессов:**
  - `D` (Uninterruptible sleep) — зависание на системном вызове I/O (NFS, деградировавший диск, блокировка ядра). Проверяй стек ядра: `cat /proc/<PID>/stack` и `cat /proc/<PID>/wchan`.
  - `Z` (Zombie) — процесс завершился, но родитель (`PPID`) не вызвал `wait()`. Убивать `kill -9` самого зомби бесполезно — нужно отправить `SIGCHLD` родителю или перезапустить родительский сервис.
- **Файловые дескрипторы и сокеты:**
  - Проверка текущих открытых дескрипторов процесса: `ls -1 /proc/<PID>/fd | wc -l` и лимитов: `cat /proc/<PID>/limits`.
  - Поиск удалённых файлов, удерживающих место на диске (`df -h` расходится с `du -sh`): `lsof +L1`.
- **Защита от OOM-Killer и изоляция через systemd (cgroups v2):**
  Никогда не оставляй критичные демоны (БД, балансировщики, агенты мониторинга) без настройки cgroups и приоритета OOM в unit-файле (`/etc/systemd/system/<service>.service.d/override.conf`):
  ```ini
  [Service]
  # Мягкий и жесткий пороги памяти в cgroups v2
  MemoryHigh=75%
  MemoryMax=85%
  # Защита от убийства OOM-киллером (-1000 — полный иммунитет, -500 — высокий приоритет выживания)
  OOMScoreAdjust=-500
  # Лимит открытых файлов и задач
  LimitNOFILE=1048576
  TasksMax=65535
  # Безопасная остановка
  TimeoutStopSec=60s
  KillMode=mixed
  ```
- **Персистентное отключение Transparent Huge Pages (THP) для СУБД (Redis/KeyDB, MongoDB, PostgreSQL):**
  Вместо разового `echo never > /sys/kernel/mm/transparent_hugepage/enabled` (слетает после перезагрузки) создай systemd-unit или профиль `tuned`:
  ```ini
  # /etc/systemd/system/disable-thp.service
  [Unit]
  Description=Disable Transparent Huge Pages (THP)
  DefaultDependencies=no
  After=sysinit.target local-fs.target
  Before=mongod.service postgresql.service redis.service keydb.service

  [Service]
  Type=oneshot
  ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag'

  [Install]
  WantedBy=basic.target
  ```

### 1.3. Пользователи, права, PAM, SSH и мандатный контроль доступа

- **Принцип минимальных привилегий:**
  - Сервисные учётные записи создаются без интерактивного шелла (`useradd -r -s /usr/sbin/nologin <svc_user>`).
  - Вместо выдачи `root` для бинда портов `< 1024` или сетевой диагностики назначай точечные Linux Capabilities: `setcap 'cap_net_bind_service=+ep' /usr/local/bin/app`.
  - Конфигурации `sudoers` хранятся в `/etc/sudoers.d/` и всегда проверяются через `visudo -cf /etc/sudoers.d/<file>`.
- **SSH Hardening (`/etc/ssh/sshd_config.d/99-hardening.conf`):**
  - `PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`, `KbdInteractiveAuthentication no`, `MaxAuthTries 3`, `AllowGroups ssh-admins`.
  - Обязательная проверка перед рестартом: `sshd -t && systemctl reload sshd`.
- **SELinux / AppArmor / Astra Parsec:**
  - Никогда не отключай SELinux (`setenforce 0`) без веской причины — диагностируй отказы через `ausearch -m AVC -ts recent` и `audit2why`, восстанавливай контексты файлов через `restorecon -Rv /path`, управляй булевыми переключателями через `setsebool -P httpd_can_network_connect 1`.
- **Расширенные права доступа (POSIX ACL, спецбиты и атрибуты ФС):**
  - Спецбиты: `SUID` (`4000`), `SGID` (`2000` — наследование группы каталога новыми файлами: `chmod g+s /shared`), `Sticky Bit` (`1000` — запрет удаления чужих файлов в общем каталоге, например `/tmp`). Поиск опасных SUID-бинарников: `find / -perm /4000 -type f 2>/dev/null`.
  - POSIX ACL (точечные права без создания лишних групп): `getfacl /path`, `setfacl -m u:deploy:rwx /var/www/app`, наследование по умолчанию для новых файлов: `setfacl -R -d -m g:devops:rwx /var/www/app`.
  - Неизменяемые атрибуты ext4/XFS: `lsattr /etc/resolv.conf`, защита критичного файла от перезаписи даже пользователем `root`: `chattr +i <file>`.

### 1.4. Дисковая подсистема (LVM, RAID, ZFS) и Загрузка ОС (Boot & Troubleshooting)

- **Управление томами LVM и расширение на лету (Online Resize):**
  - Проверка цепочки `Physical Volume (PV) -> Volume Group (VG) -> Logical Volume (LV)`: `pvs`, `vgs`, `lvs`, `lsblk -f`.
  - Безопасное онлайн-расширение тома вместе с файловой системой (ext4 / XFS) одной командой:
    `lvextend -r -L +20G /dev/mapper/vg0-lv_var` (флаг `-r` автоматически вызывает `resize2fs` или `xfs_growfs`).
  - Расширение XFS возможно только в сторону увеличения (уменьшить XFS нельзя!).
- **Программный RAID (`mdadm`):**
  - Диагностика деградации массива: `cat /proc/mdstat`, `mdadm --detail /dev/md0`.
- **Загрузка Linux (Boot Sequence) и аварийное восстановление:**
  - Цепочка: `BIOS/UEFI -> Загрузчик (GRUB2 / systemd-boot) -> Ядро (vmlinuz) + initramfs (dracut/initramfs-tools) -> PID 1 (systemd) -> default.target (multi-user.target)`.
  - В `/etc/fstab` всегда монтируй внешние/сетевые/некритичные диски по `UUID=...` с опцией `nofail` (и `_netdev` для NFS/iSCSI), иначе при отвале дополнительного диска сервер уйдёт в `emergency.target` при перезагрузке.
  - Перед перезагрузкой после правки `/etc/fstab` всегда проверяй монтирование командой `mount -a` и пересборку конфигов systemd: `systemctl daemon-reload`.
  - Анализ медленной загрузки и упавших юнитов: `systemd-analyze blame`, `systemd-analyze critical-chain`, `systemctl --failed`, `journalctl -xb -p err`.

---

## 2. Администрирование Windows Server и Доменов (Active Directory / FreeIPA)

### 2.1. Управление процессами, памятью и портами в Windows Server

- **Диагностика процессов и дескрипторов (PowerShell):**
  ```powershell
  # Топ процессов по рабочей памяти и дескрипторам (Handles)
  Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 Name, Id, Handles, @{N='RAM_MB';E={[math]::Round($_.WorkingSet64/1MB,1)}}

  # Группировка TCP-соединений по состоянию и процессу (поиск утечки сокетов / TIME_WAIT / SYN_SENT)
  Get-NetTCPConnection | Group-Object State, OwningProcess | Sort-Object Count -Descending | Select-Object -First 15 Count, Name
  ```
- **Исчерпание эфемерных портов (Event ID 4227 / 4231):**
  По умолчанию Windows выделяет только 16 384 динамических порта (`49152–65535`) и держит `TIME_WAIT` 120 секунд. Персистентный тюнинг для высоконагруженных узлов:
  ```powershell
  # Персистентное расширение пула портов (сохраняется после перезагрузки)
  netsh int ipv4 set dynamicport tcp start=10000 num=55535 store=persistent
  netsh int ipv4 set dynamicport udp start=10000 num=55535 store=persistent

  # Сокращение задержки TIME_WAIT со 120 до 30 сек в реестре
  Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "TcpTimedWaitDelay" -Value 30 -Type DWord
  ```

### 2.2. Доменная инфраструктура (Active Directory, Kerberos vs NTLM, GPO/DSC)

- **Аутентификация Kerberos против NTLM:**
  - NTLM создаёт синхронные RPC-запросы к контроллерам домена (DC) на каждую авторизацию и упирается в лимит семафора `MaxConcurrentApi` (по умолчанию 10 одновременных вызовов), вызывая ошибки `0xC000005E`, Event ID **5719 / 5805** и рост `Netlogon -> Semaphore Timeouts`.
  - **Приоритетное решение:** перевод сервисов на **Kerberos** (проверка SPN и отсутствия дублей: `setspn -X`, `setspn -L <account>`, использование **gMSA** — Group Managed Service Accounts для автоматической ротации паролей сервисов).
  - Если легаси-контур временно требует NTLM — увеличь `MaxConcurrentApi` через групповую политику (GPO) или реестр:
    ```powershell
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" -Name "MaxConcurrentApi" -Value 50 -Type DWord
    Restart-Service Netlogon
    ```
- **Диагностика контроллеров домена и репликации AD:**
  - `dcdiag /v /c /d /e` — комплексная проверка здоровья контроллеров домена.
  - `repadmin /replsummary` и `repadmin /showrepl * /csv` — проверка лагов и ошибок репликации между сайтами AD.
  - `w32tm /query /status` и `w32tm /monitor` — контроль рассинхронизации времени (при расхождении > 5 минут Kerberos полностью отказывает с `KRB_AP_ERR_SKEW`).
- **Linux в домене (AD / FreeIPA / Samba AD / ALD Pro):**
  - Предпочтительный стек интеграции: `realmd` + `sssd` + `krb5` + `oddjob-mkhomedir` (для FreeIPA / ALD Pro — `ipa-client-install`).
  - В `/etc/sssd/sssd.conf` включай кэширование учётных данных (`cache_credentials = True`), чтобы Linux-серверы продолжали пускать администраторов при временной недоступности DC.
- **Архитектура Active Directory (FSMO, GPO, SYSVOL) и права в Windows:**
  - **5 ролей FSMO (`netdom query fsmo`):** на уровне леса — *Schema Master*, *Domain Naming Master*; на уровне домена — *PDC Emulator* (главный источник времени, смены паролей и блокировок аккаунтов), *RID Master*, *Infrastructure Master*.
  - **Групповые политики (GPO):** применяются строго в порядке **LSDOU** (`Local -> Site -> Domain -> Organizational Unit`). Диагностика результирующей политики на узле: `gpresult /r` или `gpresult /h gpo-report.html`, принудительное обновление: `gpupdate /force`.
  - **Репликация SYSVOL (DFSR):** проверка состояния репликации политик и скриптов между контроллерами домена через `dfsrdiag ReplicationState`.
  - **Управление правами NTFS (`icacls`) и удалённым администрированием (WinRM):**
    - Просмотр и резервное сохранение ACL дерева папок перед изменениями: `icacls "D:\Data" /save acl_backup.txt /t`.
    - Настройка защищённого управления для Ansible/PowerShell Remoting: `winrm quickconfig -transport:https` (или Kerberos с шифрованием сообщения в доменной среде).

---

## 3. Компьютерные сети (OSI, TCP/IP, Маршрутизация, Подсети, Протоколы)

### 3.1. Сопоставление моделей OSI (L1–L7) и TCP/IP, PDU и Иерархическая диагностика

| Уровень OSI | Уровень TCP/IP | Единица данных (PDU) | Ключевые протоколы и механизмы | Инструменты диагностики и типовые сбои |
|---|---|---|---|---|
| **L7 (Application)** | **Application** | Данные (Data / Message) | HTTP/1.1, HTTP/2, HTTP/3 (QUIC), gRPC, DNS, DHCP, NTP, SSH, SMTP, LDAP/Kerberos | `curl -vkw`, `dig +trace`, `chronyc tracking`. Сбои: отсутствие HTTP `keepalive`, DNS TTL/NXDOMAIN, clock skew > 5м. |
| **L6 (Presentation)** | **Application** | Данные (Data) | TLS 1.2/1.3, mTLS, X.509, SNI, ALPN, сериализация (Protobuf, JSON, Gzip/Brotli) | `openssl s_client -connect h:p -servername sni`. Сбои: просроченный сертификат, неполная цепочка Intermediate CA, mismatch шифров. |
| **L5 (Session)** | **Application** | Данные (Data) | Управление сессиями, RPC, NetBIOS, SOCKS, TLS Session Resumption | Разрыв долгоживущих сессий из-за агрессивного idle-таймаута на промежуточном NAT / балансировщике. |
| **L4 (Transport)** | **Transport** | Сегмент (TCP) / Датаграмма (UDP) | TCP (3-way handshake, congestion control BBR/CUBIC, sliding window), UDP, QUIC | `ss -tanop`, `nstat -az`, `conntrack -S`, `tcpdump`. Сбои: `SYN_SENT` (файрвол / переполнен `somaxconn`), `CLOSE_WAIT` (утечка сокетов в коде), `TIME_WAIT` exhaustion. |
| **L3 (Network)** | **Internet** | Пакет (Packet) | IPv4, IPv6, ICMP, OSPF, BGP, VRRP (Keepalived), IPsec, WireGuard, GRE, NAT | `ip route get`, `ip rule`, `mtr -rn`, `ping -M do -s`. Сбои: **PMTUD Blackhole** в туннелях, асимметричная маршрутизация (`rp_filter`), петли маршрутизации. |
| **L2 (Data Link)** | **Network Access (Link)** | Кадр (Frame) | Ethernet (802.3), VLAN (802.1Q), LACP Bonding (802.3ad), ARP / NDP, STP, VXLAN | `ip -s link`, `ip neigh`, `bridge fdb`. Сбои: несовпадение MTU/VLAN tag, переполнение ARP-кэша (`gc_thresh`), дублирование IP/MAC. |
| **L1 (Physical)** | **Network Access (Link)** | Бит (Bit / Symbol) | Оптика, витая пара, SFP+ трансиверы, автосогласование скорости и дуплекса | `ethtool eth0`, `ethtool -S eth0`. Сбои: рост `CRC errors`, `frame errors`, `carrier drops`, деградация патч-корда/SFP. |

### 3.1.1. Ключевые сетевые механизмы (Маршрутизация, NAT, Файрволы, VRRP, DNS)

- **Жизненный цикл TCP:**
  - Установка (`3-way handshake`): `Client [SYN] -> Server [SYN+ACK] -> Client [ACK] (ESTABLISHED)`. Очередь полуоткрытых соединений регулируется `tcp_max_syn_backlog`, очередь полностью установленных до `accept()` — `net.core.somaxconn`.
  - Закрытие (`4-way teardown`): сторона, первой вызвавшая `close()` (Active Close), проходит `FIN_WAIT_1 -> FIN_WAIT_2 -> TIME_WAIT (2*MSL)`. Сторона, получившая `FIN` (Passive Close), переходит в `CLOSE_WAIT`: если сокеты висят в `CLOSE_WAIT` часами — это **100% баг в коде приложения** (приложение не закрывает дескриптор сокета).
- **Маршрутизация, Policy-Based Routing (PBR) и отказоустойчивость шлюзов:**
  - Если у сервера несколько сетевых интерфейсов в разных подсетях (multi-homing), настраивай **Policy Routing** (`ip rule add from <SRC_IP> table 100 && ip route add default via <GW_IP> dev eth1 table 100`), чтобы ответы уходили через тот же интерфейс, куда пришёл запрос, и не дропались проверкой обратного пути (`net.ipv4.conf.all.rp_filter = 1` или `2` для loose mode при асимметрии).
  - **VRRP (Keepalived):** объединяет 2+ узла балансировщиков (HAProxy/Nginx) под плавающим виртуальным IP (VIP) с проверкой живого процесса через `vrrp_script` (`killall -0 haproxy`).
  - **Динамическая маршрутизация (BGP / FRRouting / Bird):** стандарт для анонса сервисных `/32` IP в ЦОД (Anycast, MetalLB, Cilium BGP) и отказоустойчивого стыка с облаками (в связке с **BFD** для детекции обрыва за `< 300 мс`).
- **Порядок прохождения пакетов в Netfilter (`nftables` / `iptables`) и NAT:**
  - Входящий трафик самому хосту: `PREROUTING (raw -> mangle -> nat/DNAT) -> INPUT (mangle -> filter) -> Local Process`.
  - Транзитный трафик (маршрутизатор / K8s-нода): `PREROUTING -> FORWARD (mangle -> filter) -> POSTROUTING (mangle -> nat/SNAT/Masquerade)`.
  - Исходящий трафик от хоста: `Local Process -> OUTPUT -> POSTROUTING`.
- **DNS-архитектура и диагностика:**
  - Основные записи: `A` (IPv4), `AAAA` (IPv6), `CNAME` (алиас — нельзя вешать на корень зоны `@`, для корня используется `ALIAS`/`ANAME`), `MX` (почта), `TXT` (SPF/DKIM/верификация), `SRV` (`_service._proto.name` — порт и вес для сервис-дискавери и Active Directory), `NS` (серверы зоны), `SOA` (серийный номер и TTL негативного кэширования `NXDOMAIN`), `PTR` (обратная зона `in-addr.arpa`).
  - При миграции IP заранее (за 24–48 ч) снижай `TTL` записи до `60–300` секунд, чтобы избежать залипания старого IP в кэшах провайдеров.

### 3.2. Расчёт подсетей (CIDR / VLSM) — Быстрая шпаргалка

| Маска CIDR | Маска подсети | Всего IP | Доступно хостам (Classic / On-Prem -2) | Доступно в облачных VPC (AWS/Yandex/GCP -4..-5) | Типовое назначение |
|---|---|---|---|---|---|
| `/32` | `255.255.255.255` | 1 | 1 | 1 | Loopback, точечный маршрут / хост в ACL |
| `/30` | `255.255.255.252` | 4 | 2 | — | Точка-точка (P2P линковка маршрутизаторов / BGP) |
| `/28` | `255.255.255.240` | 16 | 14 | 11–12 | Малая сервисная подсеть (балансировщики, бастионы) |
| `/24` | `255.255.255.0` | 256 | 254 | 251 | Стандартная подсеть зоны доступности (AZ) для VM / БД |
| `/20` | `255.255.240.0` | 4 096 | 4 094 | 4 091 | Подсеть рабочих узлов и подов Kubernetes (CNI) |
| `/16` | `255.255.0.0` | 65 536 | 65 534 | 65 531 | Корневой CIDR всего VPC / виртуальной сети региона |

> **Правило проектирования IPAM:** Всегда закладывай непересекающиеся диапазоны CIDR между всеми окружениями (`prod`, `stage`, `dev`) и площадками (`on-prem`, `cloud`) для бесшовной маршрутизации по VPN / Direct Connect / BGP без двойного NAT.

### 3.3. Эталонный персистентный профиль тюнинга сети и ядра Linux (`/etc/sysctl.d/99-devops-production.conf`)

```ini
# 1. Очереди сокетов и входящих соединений
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65535

# 2. Защита от SYN-flood и PMTUD Blackhole в туннелях/оверлеях
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_mtu_probing = 1

# 3. Пул локальных портов и быстрое переиспользование сокетов
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# 4. Таблица отслеживания соединений (при активном модуле nf_conntrack)
net.netfilter.nf_conntrack_max = 1048576

# 5. Память и файловая подсистема
vm.swappiness = 10
vm.min_free_kbytes = 262144
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
```
Применение: `sysctl --system` (с обязательной доставкой файла через Ansible/Puppet/Salt/Cloud-init).

---

## 4. Системы контроля версий (Продвинутый Git)

### 4.1. Выбор стратегии ветвления

| Стратегия | Когда выбирать | Ключевые правила |
|---|---|---|
| **Trunk-Based Development (TBD)** | Микросервисы, зрелый CI/CD, частые выкатки (несколько раз в день), наличие Feature Flags | Короткоживущие ветки (`< 1-2 дней`) вливаются в `main` через Squash/Rebase. Релизы формируются тегами или release-ветками от `main`. |
| **GitHub Flow / GitLab Flow** | Веб-сервисы и инфраструктурные репозитории (IaC / GitOps) с продвижением по окружениям (`main -> stage -> prod`) | Каждая задача — в отдельной ветке с обязательным MR/PR, прохождением пайплайна и аппрувом. |
| **GitFlow** | Коробочное/on-prem ПО с версионными релизами и долгосрочной поддержкой нескольких минорных веток (LTS) | Разделение `develop`, `release/*`, `hotfix/*`, `main`. Высокие накладные расходы на мерджи — не применять для динамичных микросервисов без необходимости. |

### 4.2. Инженерные практики и восстановление в Git

- **Безопасное обновление и перезапись истории:**
  - Никогда не используй слепой `git push --force` — всегда применяй `git push --force-with-lease`, который прервёт пуш, если коллега добавил коммит в удалённую ветку.
  - Интерактивный ребейз с авто-склейкой фиксов: `git commit --fixup <sha>` и `git rebase -i --autosquash origin/main`.
- **Автоматический поиск коммита, сломавшего сборку или инфраструктуру (`git bisect`):**
  ```bash
  git bisect start
  git bisect bad HEAD
  git bisect good v1.4.0
  # Автоматический прогон проверочного скрипта на каждом шаге бинарного поиска
  git bisect run ./scripts/verify-infra.sh
  git bisect reset
  ```
- **Аварийное восстановление потерянных коммитов/веток:**
  - `git reflog --date=iso` — нахождение SHA до неудачного `reset --hard` или `rebase`, затем `git branch recovery-branch <SHA>`.
- **Криптографическая подпись и защита цепочки поставки в Git:**
  - Включай подпись коммитов и тегов через GPG или SSH-ключи (`git config commit.gpgsign true`, `git config gpg.format ssh`).
  - В защищённых ветках (`main`, `production`) блокируй прямой пуш, требуй подписанные коммиты, прохождение всех проверок CI и минимум 1–2 ревью (CODEOWNERS для папок `terraform/`, `k8s/`, `.github/`).
- **Продвинутые приёмы для монорепозиториев и параллельной работы:**
  - **`git worktree`:** позволяет одновременно держать открытыми несколько веток в разных папках (`git worktree add ../hotfix-prod main`) без `git stash` и клонирования репозитория заново.
  - **Масштабирование больших репозиториев:** используй частичное клонирование без блобов истории (`git clone --filter=blob:none <url>`) и выборочное извлечение директорий (`git sparse-checkout set infra/k8s`).
  - **Git Hooks и `git rerere`:** включай `git config --global rerere.enabled true` (автоматическое запоминание и повторное применение разрешённых конфликтов слияния) и клиентские/серверные хуки (`pre-commit` для `gitleaks` и линтеров, `commit-msg` для проверки Conventional Commits).
  - **Глубокий поиск по истории кода (Pickaxe):** `git log -S "MAX_CONNECTIONS" -p` (находит коммиты, где строка появилась или исчезла) и `git blame -w -C -C -C <file>` (игнорирует пробелы и отслеживает перемещение строк между файлами).
