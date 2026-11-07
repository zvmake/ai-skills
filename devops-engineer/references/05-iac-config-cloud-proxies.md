# 05. Инфраструктура как код (IaC), Configuration Management, Балансировщики и Облака

> **ОТКРЫТЫЙ ПРИНЦИП ВЫБОРА ОБЛАКОВ И ИНСТРУМЕНТОВ:** Приведённые ниже облачные провайдеры (AWS, GCP, Azure, Yandex Cloud, Cloud.ru, Selectel, VK Cloud, OpenStack, Proxmox, VMware vSphere) и инструменты IaC/CM (Terraform, OpenTofu, Terragrunt, Pulumi, Crossplane, Ansible, SaltStack, Puppet) являются **референсными примерами, а НЕ закрытым списком**. Архитектурные паттерны (идемпотентность, удалённый стейт с блокировками, модульность, сетевая сегментация, L4/L7 балансировка) универсальны для любой платформы.

---

## 1. Инфраструктура как код (IaC: Terraform / OpenTofu / Pulumi / Crossplane)

### 1.1. Матрица выбора инструмента IaC

| Инструмент | Когда выбирать | Ключевое преимущество |
|---|---|---|
| **Terraform / OpenTofu** (+ **Terragrunt**) | Универсальное управление облачной и локальной инфраструктурой (VPC, VM, K8s, S3, DNS, IAM, Proxmox/OpenStack/vSphere) | Огромная экосистема провайдеров, декларативный HCL, предсказуемый граф состояния (`tfstate`). |
| **Pulumi** | Команды со сложной алгоритмической логикой генерации инфраструктуры на TypeScript / Python / Go | Полноценные языки программирования, модульные тесты (`unit`/`property testing`) и типизация. |
| **Crossplane** | Platform Engineering внутри Kubernetes, где разработчики заказывают инфраструктуру (БД, S3) через YAML-манифесты K8s | Непрерывный Reconcile Loop (автоматическое устранение дрейфа в отличие от разового запуска `terraform apply`). |

### 1.2. Железные правила архитектуры Terraform / OpenTofu

1. **Изоляция состояния (Remote State + Locking):**
   - Никогда не храни `terraform.tfstate` в Git или локально — используй удалённый бэкенд с шифрованием и блокировками (S3 + DynamoDB / YDB / встроенный S3 state lock в OpenTofu / PostgreSQL backend / Consul).
   - **Разделяй стейты по слоям и окружениям (Blast Radius Reduction):** отдельные стейты для `01-network`, `02-data-stores`, `03-k8s-cluster`, `04-apps` и строгая изоляция `prod` / `stage` / `dev` (через отдельные каталоги или Terragrunt, а не через `terraform workspace` на одном бакете без разделения прав).
2. **Фиксация версий и детерминированный пайплайн:**
   - В `versions.tf` всегда фиксируй версию ядра (`required_version`) и версии всех провайдеров (`~> X.Y`), а файл `.terraform.lock.hcl` коммить в Git.
   - Обязательный конвейер выполнения в CI/CD:
     ```bash
     terraform fmt -check -recursive
     terraform init -input=false
     terraform validate
     tflint --recursive
     trivy config . --severity CRITICAL,HIGH --exit-code 1
     terraform plan -input=false -out=tfplan.binary
     # Гейт ревью плана человеком (в MR/PR) перед применением:
     terraform apply -input=false tfplan.binary
     ```
3. **Защита критичных ресурсов от случайного пересоздания:**
   - Для баз данных, персистентных дисков, S3-бакетов и KMS-ключей обязательно указывай блок жизненного цикла:
     ```hcl
     lifecycle {
       prevent_destroy = true
     }
     ```
   - Чувствительные переменные и выводы всегда помечай `sensitive = true`.

---

## 2. Управление конфигурацией (Ansible и аналоги)

### 2.1. Правила проектирования идемпотентных ролей и плейбуков Ansible

1. **Истинная идемпотентность (Zero Changed on Re-run):**
   - Повторный запуск плейбука на уже настроенном сервере **обязан** выдавать `changed=0, failed=0`.
   - Избегай модулей `ansible.builtin.shell` и `ansible.builtin.command` везде, где есть нативные модули (`ansible.posix.sysctl`, `ansible.builtin.systemd_service`, `ansible.builtin.template`, `ansible.builtin.user`, `community.general.ufw`).
   - Если вызов `command`/`shell` неизбежен — обязательно указывай `creates:`, `removes:` или явный `changed_when:` и `failed_when:`.
2. **Безопасная валидация конфигов перед перезагрузкой демона:**
   При генерации критичных конфигов (`sshd_config`, `nginx.conf`, `haproxy.cfg`, `sudoers`) используй параметр `validate` в модуле `template`, чтобы битый конфиг никогда не записался поверх рабочего, и перезагружай сервис через `handlers` (`reload`, а не `restart`, чтобы не рвать активные соединения):
   ```yaml
   - name: Deploy production sysctl tuning persistently
     ansible.posix.sysctl:
       name: "{{ item.key }}"
       value: "{{ item.value }}"
       sysctl_file: /etc/sysctl.d/99-devops-production.conf
       reload: true
       state: present
     loop:
       - { key: "net.core.somaxconn", value: "65535" }
       - { key: "net.ipv4.tcp_max_syn_backlog", value: "65535" }
       - { key: "net.ipv4.ip_local_port_range", value: "10240 65535" }
       - { key: "vm.swappiness", value: "10" }

   - name: Render and validate Nginx configuration before reload
     ansible.builtin.template:
       src: nginx.conf.j2
       dest: /etc/nginx/nginx.conf
       owner: root
       group: root
       mode: "0644"
       validate: "/usr/sbin/nginx -t -c %s"
     notify: Reload Nginx gracefully
   ```
3. **Тестирование и линтинг кода конфигурации:**
   - Прогоняй `ansible-lint` и проверяй роли в изолированных контейнерах/VM через **Molecule** + `testinfra` и в режиме `--check --diff` перед раскаткой на прод.

---

## 3. Веб-серверы и Балансировка нагрузки (Nginx, HAProxy, Envoy / Traefik)

### 3.1. Архитектурное разделение L4 и L7 балансировки

- **L4 (Transport Layer — TCP/UDP: HAProxy в `mode tcp`, IPVS, L4 NLB, MetalLB/Cilium BGP):**
  - Маршрутизирует пакеты/потоки по IP и порту без расшифровки полезной нагрузки. Минимальная задержка и расход CPU; используется для СУБД (PostgreSQL/Patroni, Redis, YugabyteDB), брокеров сообщений (Kafka), TLS Passthrough и входного периметра перед L7-ингрессами.
- **L7 (Application Layer — HTTP/1.1, HTTP/2, HTTP/3, gRPC: Nginx, HAProxy в `mode http`, Envoy, Traefik, Caddy):**
  - Терминирует TLS, маршрутизирует по Host/URI/Headers/Cookies, выполняет Rate Limiting, WAF-фильтрацию, сжатие (Brotli/Gzip), проверку JWT/mTLS и умные ретраи.

### 3.2. Критические настройки производительности и отказоустойчивости Nginx и HAProxy

1. **Пул постоянных соединений к бэкендам (Upstream Keepalive) — ОБЯЗАТЕЛЕН:**
   - По умолчанию Nginx открывает **новое TCP-соединение на каждый запрос к апстриму**, что под нагрузкой мгновенно выедает локальные эфемерные порты (`99: Cannot assign requested address`) и забивает таблицу `conntrack` и `TIME_WAIT`.
   - В каждом блоке `upstream` Nginx обязательно задавай `keepalive 128..512;`, а в `location` — `proxy_http_version 1.1;` и `proxy_set_header Connection "";`.
   - В HAProxy обязательно включай `http-reuse safe` (или `aggressive` для идемпотентных сервисов).
2. **Жёсткие таймауты и защита от каскадных зависаний:**
   - Никогда не оставляй дефолтные 60-секундные таймауты коннекта: `proxy_connect_timeout` / `timeout connect` должен быть `2s–5s`, чтобы при падении одной ноды балансировщик мгновенно переключал запрос на живую реплику (`proxy_next_upstream error timeout http_502 http_503`).
   - Для неидемпотентных запросов (`POST`, `PATCH` без ключа идемпотентности) не включай автоматический повтор при `timeout` (`non_idempotent`), чтобы не вызвать двойное списание средств.
3. **Динамический DNS-резолвинг апстримов:**
   - Nginx резолвит доменные имена в `upstream` только один раз при старте/релоаде! Если за апстримом стоят динамические IP (K8s Service, Consul, облачный балансировщик), используй директиву `resolver <DNS_IP> valid=10s ipv6=off;` с переменной или `resolve` в коммерческой/Angie сборке, либо используй HAProxy с секцией `resolvers` (`hold valid 10s`).
4. **TLS Hardening и Безопасность заголовков:**
   - Разрешай только `TLSv1.2` и `TLSv1.3` с современными шифрами ECDHE, включай OCSP Stapling, HTTP/2 (`http2 on;`) и заголовки безопасности (`Strict-Transport-Security`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`).
   - Скрывай версию сервера (`server_tokens off;` в Nginx).

*(Готовые эталонные конфигурации см. в `templates/nginx-haproxy-production.conf`).*

---

## 4. Облачные платформы (Глобальные, Локальные / РФ и On-Premise / Гибридные)

### 4.1. Универсальная эталонная архитектура облачного/гибридного контура (Cloud-Agnostic Landing Zone)

Независимо от выбранного провайдера (AWS, GCP, Azure, Yandex Cloud, Cloud.ru, Selectel, VK Cloud или приватное облако на OpenStack / Proxmox / VMware), продакшен-инфраструктура строится по единым принципам:

1. **Изоляция аккаунтов / папок / проектов (Multi-Account / Multi-Folder):**
   - Раздельные изолированные контуры для `Production`, `Staging/Dev`, `Security & Audit Logs` (неизменяемый архив логов аудита и бэкапов) и `Shared Network / CI-CD`.
2. **Трёхслойная сетевая сегментация в нескольких зонах доступности (Multi-AZ):**
   - **Public Tier (DMZ):** только внешние L4/L7 балансировщики, NAT Gateway и VPN/DirectConnect-шлюзы. Ни одной рабочей VM или ноды K8s с публичным IP!
   - **Private Application Tier:** рабочие узлы Kubernetes, VM микросервисов и внутренние балансировщики (выход в интернет только через отказоустойчивый NAT Gateway или корпоративный egress-прокси).
   - **Isolated Data Tier:** кластеры СУБД, кэши, хранилища секретов (Vault) — без маршрута в интернет (`0.0.0.0/0`), доступ по Security Groups только с портам из `Private Application Tier`.
3. **Управление доступом (IAM & Zero Static Keys):**
   - Принцип наименьших привилегий (RBAC / ABAC), привязка сервисных аккаунтов к подам/VM через метаданные инстанса и OIDC (Workload Identity / IAM Roles for Service Accounts), полный запрет статических root-ключей.
4. **Гибридная связность (Cloud + On-Premise):**
   - Резервирование каналов связи (основной выделенный стык L2/L3 Direct Connect / Cloud Interconnect + резервный IPsec/WireGuard поверх интернета) с динамической маршрутизацией **BGP** и проверкой **BFD** (Bidirectional Forwarding Detection) для переключения маршрута за доли секунды.
   - Единый гибридный DNS (Conditional Forwarding между облачным DNS и локальным Active Directory / Bind / CoreDNS) и сквозной **TCP MSS Clamping** на всех туннельных интерфейсах.
5. **FinOps и оптимизация облачных затрат:**
   - Обязательное тегирование всех ресурсов (`env`, `service`, `owner`, `cost-center`) на уровне IaC-линтеров.
   - Комбинация базового зарезервированного пула (Reserved / Committed Use для 24/7 базы нагрузки) и Spot / Preemptible узлов для stateless-воркеров и CI-раннеров с корректной обработкой уведомления об изъятии ноды (`Node Termination Handler`).
