# 04. Контейнеризация (Docker, Compose) и Оркестрация (Kubernetes, Helm)

> **Принцип универсальности:** Правила применимы к любым OCI-рантаймам (`containerd`, `CRI-O`, `Docker`, `Podman`) и любым дистрибутивам Kubernetes (Vanilla K8s, OpenShift, Rancher/RKE2, k3s, Talos, Deckhouse, управляемые облачные кластеры).

---

## 1. Docker и Docker Compose

### 1.1. Чек-лист производственного `Dockerfile`

1. **Multi-Stage сборка:** компиляторы, SDK, заголовки (`gcc`, `cargo`, `go`, `maven`, `node_modules` devDependencies) остаются в `builder`-стейдже; в финальный образ копируется только скомпилированный артефакт/runtime.
2. **Минимальный базовый образ с фиксированной версией:**
   - Используй `gcr.io/distroless/static-debian12:nonroot`, `alpine:3.20` или `debian:bookworm-slim` с привязкой к конкретной версии и/или `@sha256:...`. Тег `:latest` запрещён.
3. **Оптимизация кэширования слоёв:**
   - Сначала копируй только файлы манифестов зависимостей (`COPY go.mod go.sum ./`, `COPY package.json package-lock.json ./`), скачивай зависимости с `--mount=type=cache`, и только после этого копируй исходный код (`COPY . .`).
4. **Никаких секретов в слоях (`ARG` / `ENV`):**
   - Для доступа к приватным репозиториям во время сборки используй **BuildKit Secret Mount**:
     ```dockerfile
     # syntax=docker/dockerfile:1.7
     RUN --mount=type=secret,id=netrc,target=/root/.netrc \
         --mount=type=cache,target=/go/pkg/mod \
         go mod download
     ```
5. **Обработка сигналов PID 1 (Graceful Shutdown):**
   - Используй только `exec`-форму `ENTRYPOINT ["/app"]` (не shell-форму `ENTRYPOINT /app`, которая запускает `/bin/sh -c` и не пробрасывает `SIGTERM` приложению).
   - Для рантаймов, не умеющих убирать зомби-процессы (Node.js, Python, JVM, скрипты), оборачивай запуск в `tini` или `dumb-init`: `ENTRYPOINT ["/usr/bin/dumb-init", "--"]`.
6. **Непривилегированный пользователь:**
   - Всегда переключайся на пользователя с `UID >= 10001` (`USER 10001:10001` или `USER nonroot:nonroot`).

### 1.2. Архитектура Docker Compose для мульти-окружений

Разделяй конфигурацию на базовый `compose.yml` и профильные оверлеи (`compose.override.yml` для локальной разработки и `compose.prod.yml` для single-node продакшена):
- В `compose.prod.yml` обязательны:
  - `restart: unless-stopped`
  - `read_only: true` + `tmpfs: ["/tmp"]`
  - `security_opt: ["no-new-privileges:true"]` и `cap_drop: ["ALL"]`
  - Лимиты `deploy.resources.limits` (`cpus`, `memory`) и настройка ротации логов (`logging.driver: json-file`, `max-size: "10m"`, `max-file: "3"`), чтобы логи контейнера не переполнили диск хоста.
  - Явные `healthcheck` с условием запуска зависимых сервисов `depends_on: { db: { condition: service_healthy } }`.

---

## 2. Kubernetes (K8s): Нагрузки, Сеть, Хранилища и Безопасность

### 2.1. Матрица выбора контроллера нагрузки (Workload Kind)

| Тип нагрузки | Контроллер K8s | Ключевые особенности |
|---|---|---|
| Stateless API, веб-сервисы, воркеры очередей | `Deployment` | Взаимозаменяемые поды, `RollingUpdate` (`maxUnavailable: 0`), горизонтальное автошкалирование (`HPA` / `KEDA`). |
| Кластерные БД, брокеры, координаторы (Kafka, Zookeeper, etcd, ClickHouse) | `StatefulSet` | Стабильные сетевые имена (`pod-0.<svc>`), привязка собственного `PersistentVolumeClaim` к каждому поду (`volumeClaimTemplates`), упорядоченный старт/стоп. |
| Сетевые агенты, сборщики логов/метрик на каждом узле (FluentBit, Node Exporter, CNI) | `DaemonSet` | Гарантированно по одному поду на каждую ноду (с учётом `tolerations` для control-plane). |
| Миграции БД, разовые задачи и периодические фоновые расчёты | `Job` / `CronJob` | Обязательно задавай `backoffLimit`, `activeDeadlineSeconds`, `concurrencyPolicy: Forbid` и `ttlSecondsAfterFinished`. |

### 2.2. Пробы здоровья (Startup, Readiness, Liveness) и Graceful Shutdown

Неправильно настроенные пробы убивают здоровые поды под нагрузкой. Соблюдай разделение ролей:

| Проба | Назначение | Действие K8s при отказе | Главное правило настройки |
|---|---|---|---|
| **`startupProbe`** | Защищает медленно стартующие приложения (миграции, прогрев кэша/JVM) от преждевременного убийства | Перезапускает контейнер, если не стартовал за `failureThreshold * periodSeconds` | Всегда включай для сервисов со стартом > 10 сек. Пока `startupProbe` не прошла, `liveness` и `readiness` не опрашиваются. |
| **`readinessProbe`** | Определяет, готов ли под принимать клиентский трафик прямо сейчас | Убирает IP пода из `Endpoints` / `EndpointSlice` балансировщика (без рестарта!) | Проверяй локальную готовность воркера. **Не включай в `readinessProbe` жёсткую проверку внешних необязательных сервисов**, иначе сбой одного соседа каскадно выключит все поды из балансировки. |
| **`livenessProbe`** | Проверяет, не завис ли процесс в deadlock | Убивает и пересоздаёт контейнер (`SIGKILL` после `terminationGracePeriodSeconds`) | **Запрещено проверять внешние зависимости (БД, внешние API) в `livenessProbe`!** Просадка БД вызовет массовый рестарт всех подов приложения и шторм подключений. |

**Бесшовная остановка пода (Zero-Downtime Pod Termination):**
При удалении пода удаление его IP из `Endpoints` (kube-proxy / Ingress) и отправка `SIGTERM` контейнеру происходят **асинхронно и параллельно**. Чтобы на под не прилетали новые запросы после начала закрытия сокетов, добавь `preStop` хук:
```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep 5"]
terminationGracePeriodSeconds: 30
```

### 2.3. Управление ресурсами (Requests, Limits, QoS, PDB)

- **CPU:**
  - `requests.cpu` гарантирует вес планирования (CFS shares).
  - При установке жёсткого `limits.cpu` внимательно мониторь метрику **CFS CPU Throttling** (`container_cpu_cfs_throttled_periods_total / container_cpu_cfs_periods_total`): если троттлинг `> 15–25%`, у сервиса вырастет латентность `p99` даже при свободном CPU ноды. Для латентно-критичных сервисов либо поднимай `limits.cpu`, либо используй практику без CPU limit при строгом `requests.cpu` и ResourceQuota на неймспейс.
- **Memory:**
  - Память несжимаема: превышение `limits.memory` вызывает мгновенный **OOMKilled (Exit Code 137)**.
  - Для критичных сервисов и БД задавай `requests.memory == limits.memory`, чтобы получить класс обслуживания **Guaranteed QoS** (такие поды выселяются с ноды при нехватке памяти в самую последнюю очередь).
- **PodDisruptionBudget (PDB):**
  Каждый продакшен-сервис с `replicas >= 2` обязан иметь `PodDisruptionBudget` (`minAvailable: 50%` или `maxUnavailable: 1`), чтобы дрейнинг нод (`kubectl drain`) при обновлении кластера не остановил все реплики одновременно.

### 2.4. Сеть (CNI, Ingress / Gateway API, NetworkPolicy) и Хранилища (CSI)

- **CNI (Cilium, Calico, Flannel, Kube-OVN):**
  - В высоконагруженных кластерах предпочтителен **Cilium (eBPF)** в режиме замена `kube-proxy` (убирает накладные расходы тысяч правил `iptables` при большом числе `Service`).
  - Учитывай оверхед инкапсуляции (VXLAN -50 байт, Geneve -50..60 байт, WireGuard -60..80 байт) при настройке MTU подов и сетевых интерфейсов нод.
- **Сетевая изоляция (`NetworkPolicy`):**
  - По умолчанию в Kubernetes все поды во всех неймспейсах могут обращаться друг к другу. В каждом продакшен-неймспейсе применяй базовую политику **Default Deny All Ingress & Egress** с явным разрешением UDP/TCP порта `53` до `kube-dns`/`CoreDNS` в `kube-system` и разрешением трафика только между конкретными парами сервисов по label-селекторам.
- **Хранилища (CSI, StorageClass, PV/PVC):**
  - Для продакшена всегда задавай `reclaimPolicy: Retain` в `StorageClass`, чтобы случайное удаление `PVC` не привело к физическому уничтожению диска в облаке/СХД.
  - Используй `volumeBindingMode: WaitForFirstConsumer`, чтобы том создавался в той же зоне доступности (AZ), куда планировщик назначил под.
  - Включай `allowVolumeExpansion: true` для онлайн-расширения дисков без пересоздания подов.
- **Gateway API и Service Mesh (Istio / Linkerd / Cilium Service Mesh):**
  - Для новой маршрутизации трафика используй стандарт **Kubernetes Gateway API** (`GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`) с нативной поддержкой взвешенного Canary-сплиттинга (`backendRefs.weight`), зеркалирования трафика и разделения ролей между инфраструктурной командой и разработчиками.
  - При внедрении **Service Mesh** включай строгий взаимный TLS (**Strict mTLS**) между всеми подами по SPIFFE ID, настраивай `OutlierDetection` (Circuit Breaking — временное исключение сбойной реплики из пула) и распределённую трассировку на прокси-слое.
- **RBAC, обновление кластера и резервное копирование Control Plane (`etcd` & Velero):**
  - **RBAC:** никогда не выдавай сервисам или CI-раннерам роль `cluster-admin` или права с wildcard (`verbs: ["*"]`, `resources: ["*"]`). Создавай узкие `Role` в рамках конкретного `Namespace` и отключай автомонтирование токена (`automountServiceAccountToken: false`), если под не обращается к K8s API.
  - **Безопасное обновление кластера (Upgrade Policy):** обновляй Kubernetes строго последовательно по одной минорной версии за раз (`1.29 -> 1.30 -> 1.31`, соблюдая `Version Skew Policy`). Порядок: **1) Снять снапшот `etcd` → 2) Обновить узлы Control Plane по одному → 3) Обновить CoreDNS/CNI/CSI → 4) Поочерёдно дренировать (`kubectl cordon && kubectl drain --ignore-daemonsets --delete-emptydir-data`) и обновить рабочие ноды с учётом `PodDisruptionBudget`**.
  - **Бэкап кластера:** регулярный снапшот состояния `etcd` с шифрованием и выгрузкой в S3 (`ETCDCTL_API=3 etcdctl snapshot save backup.db && etcdctl snapshot status backup.db`), а также бэкап манифестов и снапшотов PVC через **Velero**.

### 2.5. Алгоритм траблшутинга подов в Kubernetes

Цепочка диагностики: `kubectl get pods -o wide` → `kubectl get events --sort-by='.lastTimestamp'` → `kubectl describe pod <pod>` → `kubectl logs <pod> --all-containers` → `kubectl logs <pod> --previous`.

| Статус / Симптом | Типовая корневая причина | Быстрая проверка и лечение |
|---|---|---|
| `Pending` | Недостаточно CPU/RAM на нодах, нет свободного узла без Taint, либо `PVC` не может забиндиться (нет диска в нужной AZ). | `kubectl describe pod` (секция `Events`: `FailedScheduling`). Проверить `kubectl top nodes`, `kubectl get pvc`, `nodeSelector` / `affinity`. |
| `ImagePullBackOff` / `ErrImagePull` | Неверный тег образа, отсутствует `imagePullSecrets`, сетевой блок до реестра или лимит Docker Hub. | Проверить точный `image:tag`, секрет `kubectl get secret <regcred> -o yaml` и доступность реестра с ноды. |
| `CrashLoopBackOff` | Приложение падает сразу после старта (ошибка конфига, недоступна БД) или его убивает `livenessProbe`. | **Всегда смотри логи предыдущего упавшего инстанса:** `kubectl logs <pod> --previous` и `State.Terminated.ExitCode` в `describe pod`. |
| `OOMKilled` (`Exit Code 137`) | Контейнер превысил `resources.limits.memory` либо на самой ноде сработал ядерный OOM. | Проверить `GOMEMLIMIT` / `-Xmx`, утечки памяти в профилировщике (`pprof`), поднять `limits.memory`. |
| `CreateContainerConfigError` | Отсутствует `ConfigMap` или `Secret`, на который ссылается `envFrom` / `volumeMounts`. | `kubectl describe pod` покажет точное имя недостающего `Secret` / `ConfigMap`. |
| `Terminating` (завис надолго) | Не отрабатывает `finalizer`, завис сетевой диск CSI/NFS или на ноде упал `kubelet`. | Проверить `metadata.finalizers`, состояние ноды (`kubectl get node`), статус демона `kubelet` и `containerd` на самом узле. |

---

## 3. Пакетное управление: Helm и Kustomize

1. **Разработка и проверка Helm-чартов:**
   - В `values.yaml` никогда не хардкодь секреты и специфичные для одного окружения домены — используй поокруженческие файлы `values-prod.yaml`, `values-stage.yaml` и `external-secrets`.
   - Чтобы поды автоматически перезапускались при изменении `ConfigMap`, добавляй аннотацию контрольной суммы в шаблон пода (`spec.template.metadata.annotations`):
     ```yaml
     checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
     ```
   - Обязательный конвейер валидации чарта перед деплоем:
     ```bash
     helm lint ./charts/my-app --strict
     helm template my-app ./charts/my-app -f values-prod.yaml | kubeconform -strict -summary
     ```
   - При выкатке через Helm CLI используй атомарный режим с ожиданием готовности проб:
     `helm upgrade --install my-app ./charts/my-app -n prod -f values-prod.yaml --atomic --wait --timeout 5m`.
