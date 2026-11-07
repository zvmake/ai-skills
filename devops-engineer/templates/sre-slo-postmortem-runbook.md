# Эталонные шаблоны SRE: Multi-Window Burn Rate Alerting, Runbook и Blameless Postmortem

---

## 1. Правила Prometheus: Multi-Window, Multi-Burn-Rate (SLO = 99.9%, Error Budget = 0.1%)

> **КРИТИЧЕСКОЕ ПРАВИЛО:**
> - Будить дежурного (`severity: critical`) разрешено только при одновременном превышении порога выгорания бюджета ошибок на **длинном и коротком окне** (`1h` + `5m` при `14.4x` или `6h` + `30m` при `6x`).
> - Каждое правило обязано содержать `annotations.runbook_url` и `annotations.dashboard_url`.
> - Ресурсные сигналы (CPU ноды, троттлинг контейнера) выносятся в `severity: warning` (тикет/диагностический сигнал).

```yaml
groups:
  - name: payments-sli-recording-rules
    interval: 30s
    rules:
      # Доля ошибок 5xx за окна 5m, 30m, 1h, 6h (Availability SLI Error Ratio)
      # Конструкция `or 0 * ...` гарантирует возврат 0 (а не empty vector) при отсутствии 5xx,
      # а фильтр `> 0` в знаменателе защищает от деления на ноль без искажения RPS < 1
      - record: job:http_requests_error_ratio:rate5m
        expr: |
          (
            sum by (namespace, service) (rate(http_requests_total{namespace="payments-prod", status=~"5.."}[5m]))
            or
            0 * sum by (namespace, service) (rate(http_requests_total{namespace="payments-prod"}[5m]))
          )
          /
          (sum by (namespace, service) (rate(http_requests_total{namespace="payments-prod"}[5m])) > 0)

      - record: job:http_requests_error_ratio:rate30m
        expr: |
          (
            sum by (namespace, service) (rate(http_requests_total{namespace="payments-prod", status=~"5.."}[30m]))
            or
            0 * sum by (namespace, service) (rate(http_requests_total{namespace="payments-prod"}[30m]))
          )
          /
          (sum by (namespace, service) (rate(http_requests_total{namespace="payments-prod"}[30m])) > 0)

      - record: job:http_requests_error_ratio:rate1h
        expr: |
          (
            sum by (namespace, service) (rate(http_requests_total{namespace="payments-prod", status=~"5.."}[1h]))
            or
            0 * sum by (namespace, service) (rate(http_requests_total{namespace="payments-prod"}[1h]))
          )
          /
          (sum by (namespace, service) (rate(http_requests_total{namespace="payments-prod"}[1h])) > 0)

      - record: job:http_requests_error_ratio:rate6h
        expr: |
          (
            sum by (namespace, service) (rate(http_requests_total{namespace="payments-prod", status=~"5.."}[6h]))
            or
            0 * sum by (namespace, service) (rate(http_requests_total{namespace="payments-prod"}[6h]))
          )
          /
          (sum by (namespace, service) (rate(http_requests_total{namespace="payments-prod"}[6h])) > 0)

  - name: payments-slo-burn-rate-alerts
    rules:
      # 1. CRITICAL (Page): Fast Burn 14.4x (сжигает 2% месячного бюджета за 1 час)
      # При SLO 99.9% (бюджет 0.001) порог = 14.4 * 0.001 = 0.0144 (1.44% ошибок)
      - alert: PaymentsSLOFastBurnCritical
        expr: |
          job:http_requests_error_ratio:rate1h{namespace="payments-prod"} > (14.4 * 0.001)
          and
          job:http_requests_error_ratio:rate5m{namespace="payments-prod"} > (14.4 * 0.001)
        for: 2m
        labels:
          severity: critical
          slo: availability
        annotations:
          summary: "[CRITICAL] {{ $labels.service }}: быстрое выгорание Error Budget (14.4x)"
          description: "Доля 5xx превысила 1.44% одновременно за 1ч и 5м (текущее: {{ $value | humanizePercentage }}). При таком темпе 30-дневный бюджет сгорит за 50 часов."
          runbook_url: "https://runbooks.internal/payments/slo-fast-burn"
          dashboard_url: "https://grafana.internal/d/payments-red/payments-slo-overview"

      # 2. CRITICAL (Page): Medium Burn 6x (сжигает 5% месячного бюджета за 6 часов)
      - alert: PaymentsSLOMediumBurnCritical
        expr: |
          job:http_requests_error_ratio:rate6h{namespace="payments-prod"} > (6 * 0.001)
          and
          job:http_requests_error_ratio:rate30m{namespace="payments-prod"} > (6 * 0.001)
        for: 5m
        labels:
          severity: critical
          slo: availability
        annotations:
          summary: "[CRITICAL] {{ $labels.service }}: устойчивое выгорание Error Budget (6x)"
          description: "Доля 5xx превысила 0.6% за 6ч и 30м."
          runbook_url: "https://runbooks.internal/payments/slo-fast-burn"
          dashboard_url: "https://grafana.internal/d/payments-red/payments-slo-overview"

      # 3. CRITICAL (Page): Latency SLO Burn (p99 > 2.5s одновременно на 1h и 5m)
      - alert: PaymentsLatencySLOBurnCritical
        expr: |
          histogram_quantile(0.99, sum by (le, service) (rate(http_request_duration_seconds_bucket{namespace="payments-prod"}[5m]))) > 2.5
          and
          histogram_quantile(0.99, sum by (le, service) (rate(http_request_duration_seconds_bucket{namespace="payments-prod"}[1h]))) > 2.0
        for: 3m
        labels:
          severity: critical
          slo: latency
        annotations:
          summary: "[CRITICAL] {{ $labels.service }}: деградация Latency SLO (p99 > 2.5s)"
          runbook_url: "https://runbooks.internal/payments/high-latency-triage"
          dashboard_url: "https://grafana.internal/d/payments-red/payments-slo-overview"

      # 4. WARNING (Ticket / Diagnostic): Троттлинг CPU контейнера (частая причина роста p99)
      - alert: PaymentsContainerCPUThrottlingWarning
        expr: |
          sum by (namespace, pod, container) (rate(container_cpu_cfs_throttled_periods_total{namespace="payments-prod", container!="", container!="POD"}[5m]))
          /
          sum by (namespace, pod, container) (rate(container_cpu_cfs_periods_total{namespace="payments-prod", container!="", container!="POD"}[5m])) > 0.25
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "[WARNING] Под {{ $labels.pod }} (контейнер {{ $labels.container }}) троттлится по CPU (> 25%)"
          runbook_url: "https://runbooks.internal/k8s/cpu-throttling"
          dashboard_url: "https://grafana.internal/d/k8s-pods/pod-resources"
```

---

## 2. Шаблон операционного Runbook (Инструкция дежурного по алерту)

```markdown
# Runbook: PaymentsSLOFastBurnCritical / PaymentsLatencySLOBurnCritical

## 1. Триаж за 2 минуты (Определение точки отказа)
1. Проверить недавние релизы и конфиги (за последние 30 минут):
   `kubectl rollout history deployment/payment-service -n payments-prod`
2. Проверить состояние подов, рестарты и OOM:
   `kubectl get pods -n payments-prod -o wide`
   `kubectl get events -n payments-prod --sort-by='.lastTimestamp' | tail -n 20`
3. Проверить дашборд зависимостей (БД, пулер коннектов, внешние платежные шлюзы):
   - Если `upstream_response_time` к банку-эквайеру вырос -> проблема на внешнем шлюзе.
   - Если пул `PgBouncer` в `cl_waiting > 0` -> затык или блокировка в БД.

## 2. Немедленная митигация (Сначала восстанови сервис!)
- **Сценарий А: Проблема началась сразу после релиза** -> Немедленный откат:
  `kubectl rollout undo deployment/payment-service -n payments-prod`
  `kubectl rollout status deployment/payment-service -n payments-prod --timeout=120s`
- **Сценарий Б: Зависла/деградировала часть подов (без релиза)** -> Поочередный перезапуск без даунтайма (с учетом PDB и Readiness):
  `kubectl rollout restart deployment/payment-service -n payments-prod`
- **Сценарий В: Всплеск трафика / нехватка воркеров** -> Масштабирование:
  `kubectl scale deployment/payment-service -n payments-prod --replicas=12`
```

---

## 3. Шаблон Blameless Postmortem (Отчёт о разборе инцидента без поиска виновных)

```markdown
# Postmortem: [ID инцидента] Деградация платежного сервиса [Дата]

- **Уровень критичности:** SEV-1 / SEV-2
- **Incident Commander:** @ic_handle
- **Статус:** Завершён, Action Items запланированы

## 1. Резюме для бизнеса и влияние на SLI/SLO (Executive Summary)
- **Окно инцидента:** ДД.ММ.ГГГГ ЧЧ:ММ – ЧЧ:ММ UTC (общая длительность: XX мин).
- **Влияние на пользователей:** задержка проведения оплат (p99 вырос со 120 мс до 3.0 с), X.X% запросов завершились ошибками 502/504 (затронуто ~N транзакций).
- **Влияние на SLO и Error Budget:**
  - Целевой SLO доступности: `99.9%` (месячный бюджет ошибок: `43.2 мин`).
  - Сожжено бюджета за инцидент: **XX.X% месячного Error Budget** (остаток бюджета: YY.Y%).
- **Метрики оперативности (SRE Metrics):**
  - **MTTD (Time to Detect):** X мин (от начала деградации до срабатывания алерта).
  - **MTTM (Time to Mitigate):** Y мин (от алерта до восстановления SLI через откат/митигацию).
  - **MTTR (Time to Resolve):** Z мин (до полного устранения корневой причины).

## 2. Поминутная хронология (Timeline, UTC)
- **ЧЧ:ММ** — [Событие-триггер: выкатка релиза / рост трафика / сбой зависимости].
- **ЧЧ:ММ** — Срабатывание алерта `PaymentsSLOFastBurnCritical`, подключение дежурного SRE.
- **ЧЧ:ММ** — Локализация проблемы по трейсам OpenTelemetry и метрикам пула БД.
- **ЧЧ:ММ** — Выполнение митигации (`kubectl rollout undo` / переключение трафика).
- **ЧЧ:ММ** — Возврат p99 и доли 2xx в пределы SLO.

## 3. Анализ первопричины методом «5 Почему» (Blameless Root Cause Analysis)
> Примечание: По стандарту SRE человеческий фактор не считается корневой причиной. Мы ищем системные пробелы в автоматизации, тестировании и архитектурных барьерах.

1. **Почему пользователи получили 502/504?** — Воркеры сервиса исчерпали пул соединений и превысили таймаут ответа балансировщика.
2. **Почему исчерпался пул соединений?** — Запросы к внешнему API / БД зависали без установленного клиентского таймаута (`context.WithTimeout`).
3. **Почему код без таймаута попал в продакшен?** — Отсутствовало правило статического анализа (SAST/linter) и нагрузочный/хаос-тест на деградацию апстрима.
4. **Почему выкатка затронула сразу 100% трафика?** — Использовался обычный RollingUpdate вместо Canary-выкатки с автооткатом по метрикам SLI.
5. **Почему деградация не вылечилась автоматически?** — Отсутствовали Circuit Breaker и настроенная стратегия автоматического отката (Argo Rollouts).

## 4. Что сработало хорошо / Где были слепые зоны
- **Что помогло:** быстрая доставка логов и трейсов, наличие подготовленной команды отката.
- **Что нужно улучшить:** шумные ресурсные алерты по CPU ноды не сигнализировали о деградации p99; отсутствовал автоматический Canary-гейт.

## 5. План системных инженерных мер (Action Items)
| ID | Тип (Prevent / Detect / Mitigate) | Инженерная мера защиты | Владелец | Приоритет | Срок |
|---|---|---|---|---|---|
| AI-1 | **Prevent** | Внедрить обязательные таймауты HTTP/DB клиентов и Circuit Breaker + правило Semgrep в CI | @backend-lead | P0 | ДД.ММ |
| AI-2 | **Detect** | Перевести алертинг на Multi-Window SLO Burn Rate (14.4x / 6x) и алерт на CFS CPU Throttling | @sre-team | P0 | ДД.ММ |
| AI-3 | **Mitigate** | Настроить Canary-деплой (5% -> 25% -> 100%) с автоматическим откатом при 5xx > 1% | @devops-team | P1 | ДД.ММ |
```
