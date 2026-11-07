# 02. Администрирование, репликация и масштабирование баз данных

> **ОТКРЫТЫЙ ПРИНЦИП ВЫБОРА СУБД:** Перечисленные ниже СУБД (PostgreSQL, MySQL/MariaDB, YugabyteDB/CockroachDB, Redis/Valkey/KeyDB, MongoDB, ClickHouse, Tarantool, Cassandra/ScyllaDB, Elasticsearch/OpenSearch, Kafka/RabbitMQ и др.) приведены как **базовые референсные образцы, а НЕ исчерпывающий список**.
> - Если в проекте уже эксплуатируется конкретная СУБД — диагностируй, настраивай и масштабируй именно её, не предлагая смену движка без прямого архитектурного запроса.
> - При проектировании новой системы выбирай СУБД по инженерным критериям (модель данных, профиль чтения/записи, требования ACID vs BASE, распределённость, RPO/RTO).

---

## 1. Архитектурная матрица выбора и классификации СУБД

| Класс СУБД | Примеры технологий (не исчерпывающий список) | Профиль нагрузки и гарантии | Типовая схема отказоустойчивости (HA) и масштабирования |
|---|---|---|---|
| **Реляционные (RDBMS)** | PostgreSQL, MySQL, MariaDB, MS SQL Server, Oracle | Строгий ACID, сложные JOIN, транзакционная целостность (OLTP) | Primary-Standby репликация (Streaming/Binlog/AlwaysOn) + оркестратор автофейловера (Patroni, Orchestrator) + пулер коннектов (PgBouncer, Odyssey, ProxySQL). |
| **Распределённые SQL (NewSQL)** | YugabyteDB, CockroachDB, TiDB | Горизонтальное масштабирование записи + распределённый ACID поверх Raft/Paxos | Кворумная репликация шардов/таблетов по зонам (RF=3/5), синхронизация часов (NTP/Chrony, HLC), гео-партиционирование и Follower Reads. |
| **In-Memory / Key-Value** | Redis, Valkey, KeyDB, Tarantool, Dragonfly | Субмиллисекундная латентность, кэш, сессии, очереди, rate-limiting | Master-Replica + Sentinel или шардированный Cluster; в KeyDB — мультипоточность и Active-Active репликация. |
| **Документные и Wide-Column NoSQL** | MongoDB, Couchbase, Apache Cassandra, ScyllaDB | Гибкая схема (JSON/BSON) или сверхвысокий поток записи без JOIN | MongoDB: Replica Set (Oplog) + Sharded Cluster. Cassandra/Scylla: безлидерное кольцо с настраиваемым кворумом (`LOCAL_QUORUM`). |
| **Колоночные аналитические (OLAP)** | ClickHouse, Greenplum, Apache Doris, StarRocks | Агрегация миллиардов строк в реальном времени, телеметрия, логи, BI | Шардирование + репликация таблиц (`ReplicatedMergeTree` через ClickHouse Keeper / ZooKeeper), разделение Compute и Storage (S3). |

---

## 2. Настройка, пулинг соединений и производительность

### 2.1. Универсальные правила настройки ОС под любую СУБД

1. **Память и Swap:**
   - `vm.swappiness = 1..10` (минимизировать вытеснение страниц буферного пула БД в swap, но не ставить `0` на старых ядрах во избежание мгновенного OOM).
   - Отключить **Transparent Huge Pages (THP)** персистентно через `systemd`/`tuned` (THP вызывает латентные спайки и фрагментацию памяти при `fork()`/CoW в Redis/KeyDB, MongoDB, PostgreSQL).
   - Для крупных инстансов PostgreSQL/Oracle выделять статические **HugePages** (`vm.nr_hugepages`), чтобы уменьшить размер Page Tables и промахи TLB.
2. **Дисковая подсистема и ФС:**
   - Монтировать тома данных с `noatime,nodiratime` (XFS или ext4).
   - Разносить по разным физическим дискам/томам основной датасет и журнал предзаписи (**WAL / Binlog / Redo Log / Raft WAL**), так как WAL критичен к задержке `fsync` (`w_await < 2..5 ms`).
   - Планировщик ввода-вывода для NVMe/SSD/виртуальных дисков: `none` или `mq-deadline`.

### 2.2. Базовые ориентиры конфигурации (на примере PostgreSQL)

- `shared_buffers` = `25%` от RAM ноды (остальное используется страничным кэшем ОС).
- `effective_cache_size` = `75%` от RAM (ориентир для планировщика запросов).
- `work_mem` = рассчитывать осторожно (`16MB–64MB`), так как выделяется на каждую операцию сортировки/хэширования каждого параллельного соединения.
- `maintenance_work_mem` = `1GB–2GB` (ускоряет `VACUUM`, `CREATE INDEX`).
- `checkpoint_completion_target = 0.9`, `max_wal_size = 16GB..64GB` (размазывает запись грязных буферов во времени, устраняя пики I/O на чекпоинтах).
- **Пулинг соединений обязателен:** прямое открытие > 200–300 активных сессий к PostgreSQL деградирует производительность из-за переключения контекста и расхода памяти на бэкенд-процессы. Ставь **PgBouncer** или **Odyssey** в режиме `transaction` pooling перед базой.

### 2.3. Базовые ориентиры для In-Memory и NewSQL (Redis / Valkey / KeyDB, YugabyteDB / CockroachDB)

- **Redis / Valkey / KeyDB:**
  - Всегда задавай жёсткий потолок `maxmemory <65-75% RAM>` и политику вытеснения (`allkeys-lru` / `volatile-lru` для кэша, `noeviction` для персистентных очередей), оставляя запас памяти под Copy-on-Write при фоновом `BGSAVE` / `BGREWRITEAOF`.
  - Для межплощадочной репликации увеличивай кольцевой буфер `repl-backlog-size` (например, `256mb–1gb`) и `client-output-buffer-limit replica 1024mb 256mb 120`, чтобы кратковременная просадка сети не вызывала бесконечный цикл полного ресинка (`Full Resync`).
- **Raft-кластеры (YugabyteDB / CockroachDB / Patroni etcd):**
  - Жёсткий контроль синхронизации времени через `chrony` (`clock skew < 10–20 ms`), иначе нарушается консистентность Hybrid Logical Clocks (HLC) и ноды выводятся из кластера.
  - Явное ограничение памяти процесса (`--memory_limit_hard_bytes` в YugabyteDB, `--cache` и `--max-sql-memory` в CockroachDB) для предотвращения системного OOM.
  - Размещение лидеров партиций/таблетов в основной зоне (`preferred_zones`) и использование **Follower Reads** для читающих реплик в удалённых ЦОД.

---

## 3. Диагностика и устранение проблем репликации

### Алгоритм триажа при росте лага репликации (Replication Lag)

1. **Проверить узкое место на уровне сети (L3/L4):**
   - Нет ли потерь пакетов, ретрансляций (`TcpExtTCPRetransSegs`) или PMTUD blackhole между мастером и репликой.
   - Не упёрся ли канал в полосу пропускания при массовом `UPDATE`/`BACKFILL`.
2. **Проверить диск и CPU на реплике (Apply Bottleneck):**
   - `iostat -xz 1` на реплике: если `w_await` высокий или диск утилизирован на 100%, реплика физически не успевает применять WAL/Binlog/Oplog.
   - В однопоточной репликации (например, классический MySQL без параллельных воркеров) включить многопоточное применение (`replica_parallel_workers = 8..16`, `replica_preserve_commit_order = ON`).
3. **Проверить конфликты чтения на реплике и удержание WAL на мастере:**
   - В PostgreSQL долгие аналитические запросы на реплике блокируют применение WAL (`max_standby_streaming_delay`), а забытые слоты репликации (`pg_replication_slots` со статусом `active = false`) переполняют диск мастера файлами `pg_wal`.
   - **Команды проверки PostgreSQL:**
     ```sql
     -- Проверка лага и статуса реплик на мастере
     SELECT client_addr, state, sync_state,
            pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn) AS send_lag_bytes,
            pg_wal_lsn_diff(sent_lsn, write_lsn) AS write_lag_bytes,
            pg_wal_lsn_diff(write_lsn, replay_lsn) AS replay_lag_bytes
     FROM pg_stat_replication;

     -- Поиск неактивных слотов репликации, удерживающих WAL
     SELECT slot_name, plugin, active,
            pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
     FROM pg_replication_slots
     WHERE NOT active;
     ```

### 3.1. Обслуживание БД (Autovacuum, Bloat, Блокировки) и Масштабирование (Partitioning, Sharding, Switchover)

1. **Контроль Bloat, Autovacuum и защита от XID Wraparound (на примере PostgreSQL):**
   - В MVCC-движках `UPDATE` и `DELETE` не перезаписывают строку на месте, а создают новую версию (`dead tuples`). Если `autovacuum` не успевает их вычищать, таблицы раздуваются (bloat), а при приближении возраста транзакций (`age(datfrozenxid)`) к 2 млрд база аварийно останавливает запись для предотвращения потери данных (**Transaction ID Wraparound**).
   - Для горячих таблиц тюнингуй параметры точечно: `ALTER TABLE payments SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_cost_limit = 2000);`. Для онлайн-сжатия распухших таблиц без эксклюзивных блокировок используй `pg_repack`.
2. **Диагностика блокировок и медленных запросов:**
   - Включай `pg_stat_statements` / `slow_query_log`, анализируй планы через `EXPLAIN (ANALYZE, BUFFERS)` (обращай внимание на `shared read` vs `shared hit` и `Seq Scan` на больших таблицах).
   - Быстрый поиск блокирующего процесса в PostgreSQL:
     ```sql
     SELECT pid, pg_blocking_pids(pid) AS blocked_by, state, wait_event_type,
            now() - query_start AS duration, left(query, 120) AS query
     FROM pg_stat_activity
     WHERE cardinality(pg_blocking_pids(pid)) > 0;
     ```
3. **Паттерны масштабирования СУБД и защита от Split-Brain:**
   - **Read/Write Split и Read Replicas:** вынос отчётных и читающих запросов на реплики через прокси/балансировщик (HAProxy с проверкой HTTP-эндпоинта Patroni `:8008/primary` и `:8008/replica?lag=10MB`, ProxySQL для MySQL) с учётом возможного чтения чуть устаревших данных (`Eventual Consistency`).
   - **Декларативное партиционирование (Partitioning):** разделение крупных таблиц (`> 50–100 ГБ`) по времени (`RANGE` по месяцам/дням через `pg_partman`) или хэшу (`HASH`), что позволяет мгновенно удалять старые архивы через `DROP TABLE partition_old` вместо тяжёлого `DELETE` и удерживать индексы активной партиции в RAM.
   - **Горизонтальное шардирование (Sharding):** распределение записи по нескольким узлам по ключу шардирования (`shard_key` с высокой кардинальностью и равномерным распределением: `tenant_id`, `user_id`) с помощью нативных механизмов (YugabyteDB, CockroachDB, MongoDB Sharded Cluster, Redis Cluster `16384` слота, ClickHouse Distributed) или расширений (Citus, Vitess).
   - **Защита от Split-Brain при авто-фейловере:** оркестратор кластера (Patroni, Raft/etcd/Consul) обязан использовать строгий кворум нечётного числа узлов (`3` или `5` нод в разных AZ) и аппаратный/программный **Watchdog (`/dev/watchdog`) + Fencing**, чтобы изолированный старый мастер гарантированно снял с себя роль лидера до того, как новый мастер начнёт принимать запись.

---

## 4. Zero-Downtime миграции схемы БД (Паттерн Expand → Backfill → Contract)

> **ЖЕЛЕЗНОЕ ПРАВИЛО:** При наличии 2 и более реплик приложения в Kubernetes / балансировщике старая и новая версии кода работают одновременно. Любая миграция схемы БД **обязана** быть обратно совместимой с текущей версией кода.

### 4.1. Запрещённые и безопасные операции в продакшене

| Задача | ❌ Опасно (положит продакшен) | ✅ Безопасно (Zero-Downtime) |
|---|---|---|
| **Переименование колонки** | `ALTER TABLE t RENAME COLUMN a TO b;` (ломает работающие реплики) | Фаза 1 (Expand): `ADD COLUMN b` + триггер/dual-write. Фаза 2 (Backfill): батчевый перенос. Фаза 3 (Switch): релиз кода, читающего `b`. Фаза 4 (Contract): `DROP COLUMN a` в следующем релизе. |
| **Добавление индекса** | `CREATE INDEX idx ON t(col);` (блокирует запись в таблицу) | `CREATE INDEX CONCURRENTLY idx ON t(col);` (PostgreSQL) / `ALGORITHM=INPLACE, LOCK=NONE` (MySQL). |
| **Добавление `NOT NULL` / `FOREIGN KEY`** | `ALTER TABLE t ALTER COLUMN c SET NOT NULL;` (полный скан под `ACCESS EXCLUSIVE` локом) | `ALTER TABLE t ADD CONSTRAINT c_nn CHECK (c IS NOT NULL) NOT VALID;` затем `ALTER TABLE t VALIDATE CONSTRAINT c_nn;` |
| **Защита от очереди блокировок** | Выполнение DDL без таймаутов (запрос ждёт долгую транзакцию, а за ним встают в очередь все `SELECT`/`UPDATE` приложения) | Всегда начинать миграцию с: `SET lock_timeout = '2s'; SET statement_timeout = '10s';` |

### 4.2. Шаблон батчевого Backfill без деградации IOPS и репликации

Никогда не делай `UPDATE table SET new_col = old_col;` одной транзакцией на миллионах строк (это раздует табличное пространство/undo-лог, забьёт WAL и остановит репликацию). Выполняй обновление батчами по `5 000 – 10 000` строк с паузой `50–100 мс` и контролем лага репликации:

```sql
-- Идемпотентный шаг одного батча
WITH batch AS (
    SELECT id FROM payments
    WHERE phone_number IS NULL AND user_phone IS NOT NULL
    LIMIT 10000
    FOR UPDATE SKIP LOCKED
)
UPDATE payments p
SET phone_number = p.user_phone
FROM batch b
WHERE p.id = b.id;
```

---

## 5. Резервное копирование и аварийное восстановление (Backup, PITR, RPO / RTO)

1. **Дамп (`pg_dump` / `mysqldump`) НЕ заменяет физический бэкап и PITR** на базах свыше десятков гигабайт: логический дамп долго восстанавливается и не позволяет откатиться на произвольную секунду до ошибки (`Point-in-Time Recovery`).
2. **Промышленный стандарт резервного копирования:**
   - Физический базовый бэкап + непрерывное архивирование журналов транзакций в объектное хранилище S3 (например, **pgBackRest** / **Wal-G** для PostgreSQL, **Percona XtraBackup** для MySQL, снапшоты в S3 для YugabyteDB/ClickHouse/MongoDB).
   - **Правило 3-2-1-1-0:** 3 копии данных, на 2 разных носителях, 1 копия в другом регионе/площадке, 1 копия неизменяемая (Immutable S3 Object Lock / WORM против шифровальщиков), **0 ошибок при автоматическом тестовом восстановлении**.
3. **Обязательная регулярная проверка восстановления:**
   Бэкап, который не проверяется автоматическим развёртыванием в тестовый инстанс (Restore Drill по расписанию в CI/CD с проверкой `SELECT count(*)`, контрольных сумм и фактического времени **RTO**), считается несуществующим.
