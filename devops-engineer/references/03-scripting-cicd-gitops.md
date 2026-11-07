# 03. Скриптинг, программирование (Bash / Python / Go), CI/CD и GitOps

> **Принцип универсальности:** Паттерны в этом справочнике применимы к любым CI/CD-платформам (GitHub Actions, GitLab CI, Jenkins, TeamCity, Azure Pipelines, Tekton, Woodpecker, Drone) и GitOps-движкам (ArgoCD, Flux, werf).

---

## 1. Написание скриптов и инструментов автоматизации

### 1.1. Матрица выбора языка автоматизации

| Задача | Рекомендуемый инструмент | Почему |
|---|---|---|
| Короткая обвязка CLI-команд (< 100 строк), init-скрипты, обёртки деплоя | **Bash / POSIX Shell** (`shellcheck`-compliant) | Доступен везде без внешних рантаймов; идеален для конвейеров команд. |
| Сложная логика (> 100 строк), работа с REST/GraphQL API, парсинг JSON/YAML, динамические инвентори, CLI-утилиты | **Python 3.11+** (`typer`/`argparse`, `httpx`, `pydantic`, `subprocess` без `shell=True`) | Читаемость, строгая валидация схем, полноценное модульное тестирование (`pytest`). |
| Высокопроизводительные CLI, плагины Terraform/kubectl, **Kubernetes Operators / Controllers**, сетевые агенты | **Go (Golang)** (`cobra`, `client-go`, `controller-runtime`, `kubebuilder`) | Статическая компиляция в один бинарник без зависимостей, нативная экосистема Cloud Native (K8s, Docker, Terraform, Prometheus написаны на Go). |

### 1.2. Стандарт защищённого производственного Bash-скрипта

Любой Bash-скрипт обязан быть идемпотентным, защищённым от гонок (race conditions), корректно убирать временные файлы при выходе и никогда не подставлять неэкранированные переменные:

```bash
#!/usr/bin/env bash
# Строгий режим: выход при ошибке (-e), неопределенной переменной (-u), ошибке в пайпе (-o pipefail)
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly LOCK_FILE="/var/lock/${SCRIPT_NAME}.lock"
TMP_DIR=""

log_info()  { printf '[%s] [INFO]  %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

cleanup() {
  local exit_code=$?
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}"
  fi
  if (( exit_code != 0 )); then
    log_error "Скрипт завершился с кодом ошибки ${exit_code}"
  fi
}
trap cleanup EXIT

# Защита от параллельного запуска (flock)
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log_info "Другой экземпляр ${SCRIPT_NAME} уже выполняется. Выход."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
```

### 1.3. Разработка Kubernetes-операторов и контроллеров (Go / Python)

Когда стандартных примитивов Kubernetes (`Deployment`, `StatefulSet`, `CronJob`) недостаточно (например, нужно автоматизировать переключение мастера БД, создание схем, ротацию внешних ключей или самовосстановление сложного кластера по бизнес-метрикам) — создавай **Kubernetes Operator** по паттерну **Reconcile Loop**:

1. **Золотые правила Reconcile Loop (Go `controller-runtime` / `kubebuilder` или Python `kopf`):**
   - **Уровневая логика (Level-Triggered, а не Edge-Triggered):** функция `Reconcile(ctx, req)` не полагается на тип события («создан» / «изменён»), а каждый раз сравнивает текущее состояние кластера (`Actual State`) с желаемым (`Spec` в Custom Resource) и делает ровно один идемпотентный шаг к сближению.
   - **Запрет костылей:** вместо cron-скриптов с `kubectl delete pod` оператор отслеживает состояние подов, метрики здоровья и `PodDisruptionBudget`, выполняя контролируемый дрейнинг и замену одного узла за раз.
   - **Обновление `.status` и `Conditions`:** всегда фиксируй прогресс в `status.conditions` (`Ready`, `Degraded`, `Progressing`) и `status.observedGeneration`, чтобы внешние GitOps-системы (ArgoCD/Flux) понимали статус ресурса.
   - **Finalizers:** используй финалайзеры для гарантированного освобождения внешних ресурсов (БД, S3-бакетов, DNS-записей) перед удалением Custom Resource.

```go
// Каркас идемпотентного Reconcile в Go (controller-runtime)
func (r *DatabaseClusterReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := ctrl.LoggerFrom(ctx)

    var cluster v1alpha1.DatabaseCluster
    if err := r.Get(ctx, req.NamespacedName, &cluster); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // 1. Обработка удаления через Finalizer
    if !cluster.ObjectMeta.DeletionTimestamp.IsZero() {
        return r.reconcileDelete(ctx, &cluster)
    }

    // 2. Идемпотентная синхронизация дочерних ресурсов (StatefulSet, Service, PDB)
    if err := r.ensureStatefulSet(ctx, &cluster); err != nil {
        meta.SetStatusCondition(&cluster.Status.Conditions, metav1.Condition{
            Type: "Ready", Status: metav1.ConditionFalse, Reason: "SyncFailed", Message: err.Error(),
        })
        _ = r.Status().Update(ctx, &cluster)
        return ctrl.Result{RequeueAfter: 30 * time.Second}, err
    }

    return ctrl.Result{RequeueAfter: 5 * time.Minute}, nil
}
```

### 1.4. Инструменты автоматизации, плагины и K8s-операторы на Python

- **Правила безопасной разработки CLI и плагинов на Python (`kubectl-*`, Ansible-модули, CI-утилиты):**
  - Вызов внешних команд — **строго списком аргументов с `shell=False` и явным `timeout`**:
    `subprocess.run(["kubectl", "get", "pods", "-n", namespace, "-o", "json"], check=True, shell=False, capture_output=True, text=True, timeout=30)`.
  - Сетевые вызовы к API облаков/кластеров всегда выполняются с раздельными таймаутами (`connect=5.0, read=15.0`) и экспоненциальным ретраем с джиттером (**Exponential Backoff + Jitter**) только для транзиентных ошибок (`429`, `502`, `503`, `504`).
  - Любой бинарник или скрипт в `PATH` с именем `kubectl-<plugin_name>` и правом `+x` автоматически становится субкомандой `kubectl <plugin_name>`.
- **Пример легковесного Kubernetes-оператора на Python (`kopf`):**
  ```python
  import kopf
  import kubernetes

  @kopf.on.create("platform.internal", "v1alpha1", "databasebackups")
  @kopf.on.update("platform.internal", "v1alpha1", "databasebackups")
  def reconcile_backup(spec, name, namespace, logger, **kwargs):
      schedule = spec.get("schedule", "0 2 * * *")
      # Идемпотентное создание/обновление дочернего CronJob с привязкой ownerReference
      cronjob_manifest = {
          "apiVersion": "batch/v1",
          "kind": "CronJob",
          "metadata": {"name": f"backup-{name}", "namespace": namespace},
          "spec": {"schedule": schedule, "concurrencyPolicy": "Forbid", "jobTemplate": {...}},
      }
      kopf.adopt(cronjob_manifest)  # Автоматический Garbage Collection при удалении CRD
      api = kubernetes.client.BatchV1Api()
      # Патч или создание ресурса...
      logger.info(f"Reconciled CronJob backup-{name}")
      return {"synced": True}
  ```

---

## 2. Непрерывная интеграция и доставка (CI/CD)

### 2.1. Эталонная архитектура пайплайна (Shift-Left DAG)

Любой производственный пайплайн строится как направленный ациклический граф (DAG) с быстрой обратной связью и обязательными гейтами безопасности:

```
[Stage 1: Verify & Secret Scan (< 2m)]
  ├── Gitleaks (поиск секретов в истории коммитов)
  ├── Linting & Formatting (golangci-lint / ruff / eslint / hadolint / tflint)
  └── Unit Tests (с проверкой покрытия)
          │
          ▼
[Stage 2: Security & Build (< 5m)]
  ├── SAST & SCA (Semgrep / CodeQL / Trivy fs)
  ├── Multi-stage Container Build (BuildKit + Secret Mounts, тег = Git SHA)
  └── Container Image Scan (Trivy image: блокировка при CRITICAL/HIGH с доступным фиксом) + SBOM (Syft) + Sign (Cosign)
          │
          ▼
[Stage 3: Staging & Integration (< 10m)]
  ├── Zero-Downtime DB Migration (Expand phase)
  ├── Deploy to Staging (GitOps commit / Helm upgrade --atomic)
  └── E2E / Smoke / Contract Tests
          │
          ▼
[Stage 4: Production Rollout (Safe Rollout Gate)]
  ├── Проверка Error Budget и ручной/автоматический гейт одобрения
  ├── Progressive Delivery (Canary / Blue-Green / Rolling)
  └── Post-deploy SLI verification (автооткат при росте 5xx или латентности p99)
```

### 2.2. Ключевые правила безопасности и скорости CI/CD (GitHub Actions / GitLab CI / Jenkins)

1. **Никаких долгоживущих облачных ключей в переменных CI:**
   - Используй федеративную аутентификацию **OIDC** (`id-token: write` в GitHub Actions, `id_tokens` в GitLab CI) для получения краткоживущих токенов в AWS STS, GCP Workload Identity, Azure AD или HashiCorp Vault.
2. **Фиксация версий экшенов и базовых образов (Supply-Chain Security):**
   - В публичных и критичных пайплайнах фиксируй сторонние GitHub Actions по полному SHA коммита (или проверенному мажорному тегу внутренней витрины), никогда не используй `@master` / `@main`.
3. **Изоляция кэшей и раннеров:**
   - Не разделяй rw-кэши сборки между непривилегированными PR-ветками и защищённой веткой `main` (`Cache Poisoning`).
   - Сборка контейнеров на Kubernetes-раннерах выполняется без привилегированного Docker-in-Docker (`--privileged`) — используй **BuildKit rootless** или **Kaniko**.
4. **Эталонный паттерн GitLab CI (`.gitlab-ci.yml`: DAG через `needs`, `workflow:rules`, OIDC `id_tokens`):**
   ```yaml
   workflow:
     rules:
       - if: $CI_PIPELINE_SOURCE == "merge_request_event"
       - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

   stages: [verify, build, deploy]

   gitleaks-and-lint:
     stage: verify
     image: zricethezav/gitleaks:v8.18.4
     script:
       - gitleaks detect --source . --verbose

   build-rootless:
     stage: build
     needs: ["gitleaks-and-lint"]
     image:
       name: moby/buildkit:rootless
       entrypoint: [""]
     variables:
       BUILDKITD_FLAGS: --oci-worker-no-process-sandbox
     script:
       - buildctl-daemonless.sh build --frontend dockerfile.v0 --local context=. --local dockerfile=.
         --output type=image,name=$CI_REGISTRY_IMAGE:sha-$CI_COMMIT_SHORT_SHA,push=true

   deploy-prod-oidc:
     stage: deploy
     needs: ["build-rootless"]
     rules:
       - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
     environment:
       name: production
     id_tokens:
       VAULT_ID_TOKEN:
         aud: https://vault.internal
     script:
       - export VAULT_TOKEN=$(vault write -field=token auth/jwt/login role=ci-prod jwt=$VAULT_ID_TOKEN)
       - helm upgrade --install app ./chart -n prod --set image.tag="sha-$CI_COMMIT_SHORT_SHA" --atomic --wait
   ```

---

## 3. GitOps и Стратегии развертывания (Progressive Delivery)

### 3.1. Архитектура GitOps (ArgoCD / Flux)

- **Разделение репозиториев (Code Repo vs Config/GitOps Repo):**
  - CI-пайплайн в репозитории приложения собирает, сканирует и подписывает иммутабельный образ `app:<git-sha>`, после чего обновляет тег образа в GitOps-репозитории (через коммит или Pull Request), а **не** вызывает `kubectl apply` напрямую с CI-раннера (Pull-модель безопаснее Push-модели, так как ключи кластера не покидают периметр K8s).
- **Структура GitOps-репозитория:**
  ```
  gitops-infra/
  ├── apps/
  │   ├── base/                  # Общие Kustomize/Helm манифесты приложения
  │   └── overlays/
  │       ├── dev/               # Патчи реплик, ресурсов и ингрессов для dev
  │       ├── staging/           # Конфигурация staging
  │       └── production/        # Продакшен-конфигурация (PDB, HPA, жесткие лимиты)
  └── clusters/
      └── prod-cluster/
          ├── argocd-apps/       # Application / ApplicationSet (App-of-Apps)
          └── infra-controllers/ # ingress-nginx, cert-manager, external-secrets, monitoring
  ```
- **Защита от дрейфа и каскадного удаления в ArgoCD:**
  - Включай `selfHeal: true` для автоматического отката ручных изменений (`kubectl edit`) в кластере.
  - Для критичных ресурсов с данными (`PersistentVolumeClaim`, `Namespace`, операторные CRD баз данных) отключай автоудаление при ошибке в Git (`Prune=false` в `syncOptions`), чтобы случайное удаление файла в Git не уничтожило продакшен-базу.

### 3.2. Матрица выбора стратегии развертывания

| Стратегия | Как работает | Скорость отката | Стоимость по ресурсам | Когда применять |
|---|---|---|---|---|
| **Rolling Update** | Постепенная замена старых подов новыми (`maxSurge: 25%, maxUnavailable: 0`) | Средняя (1–3 мин через `rollout undo`) | Низкая (+25% на время выкатки) | Стандартные stateless-сервисы с обратно совместимым API и БД. |
| **Blue-Green** | Поднимается полный дубль окружения (`Green`), проверяется, затем балансировщик мгновенно переключает трафик с `Blue` на `Green` | Мгновенная (< 5 сек переключением селектора) | Высокая (2x ресурсов на время релиза) | Монолиты, критичные сервисы, где нельзя смешивать версии трафика, но схема БД совместима. |
| **Canary (Argo Rollouts / Flagger)** | Новая версия получает `5% -> 20% -> 50% -> 100%` трафика с автоматическим анализом метрик Prometheus (SLI 5xx, p99) на каждом шаге | Мгновенная (автоматический сброс веса канарейки в 0%) | Низкая (+1..2 пода для канарейки) | Высоконагруженные платежные и клиентские сервисы, где нужен автоматический контроль деградации на реальном трафике. |
| **Shadow / Dark Launch** | Продакшен-трафик зеркалируется (дублируется асинхронно) в новую версию без возврата ответа клиенту | Не требуется (клиент не видит ответов теневой версии) | Высокая (до 2x на вычислительный контур) | Тестирование производительности новых алгоритмов или миграции движка под реальным профилем запросов. |
