# Карта поверхности проверки (универсальная, без привязки к стеку)

Справочник типовых узлов веб-приложения для Фазы 0–1 (определение стека и карты маршрутов) и Фазы 3 (анализ кода и проверка на запущенном стенде).

В Фазе 0 определи стек по манифестам проекта (`package.json`, `pyproject.toml`/`requirements.txt`, `pom.xml`/`build.gradle`, `go.mod`, `composer.json`, `Gemfile`, `*.csproj`, `Cargo.toml`) и сопоставь универсальные понятия ниже с конструкциями конкретного фреймворка.

---

## 1. Сводная матрица конструкций по экосистемам

| Узел проверки | Node.js / TS (Express, NestJS, Fastify, Next.js) | Python (Django, FastAPI, Flask) | Java / Kotlin (Spring Boot) | .NET (ASP.NET Core) | Go (net/http, Gin, Echo) | PHP (Laravel, Symfony) | Ruby (Rails) | Rust (Axum, Actix-web) |
|---|---|---|---|---|---|---|---|---|
| **Точка входа и глобальные middleware** | `main.ts`, `app.ts`, `middleware.ts`, `app.use(...)` | `settings.py`, `MIDDLEWARE`, `FastAPI()` | `SecurityFilterChain`, `@Configuration` | `Program.cs`, `Startup.cs`, `app.Use*` | `main.go`, `r.Use(...)` | `Kernel.php`, `bootstrap/app.php` | `config/application.rb`, `config/environments/*` | `main.rs`, `Router::layer`, `App::wrap` |
| **Маршруты и контроллеры** | `@Controller`, `router.get/post`, `app/**/route.ts`, `'use server'` | `urls.py`, `@app.get/post`, `views.py` | `@RestController`, `@RequestMapping`, `@GetMapping` | `[ApiController]`, `[HttpGet/Post]`, `MapGet` | `r.GET/POST`, `http.HandleFunc` | `routes/web.php`, `routes/api.php`, `#[Route]` | `config/routes.rb`, `ApplicationController` | `Router::route`, `#[get/post]`, `web::resource` |
| **Проверка доступа (Guards / Filters)** | `@UseGuards`, auth middleware | `@login_required`, `Depends(...)`, `permission_classes` | `@PreAuthorize`, `@Secured`, `SecurityFilterChain` | `[Authorize]`, `[AllowAnonymous]`, Policies | auth middleware в группе роутов | `middleware('auth')`, Gates, Policies | `before_action :authenticate_*`, Pundit/CanCanCan | Extractor / Tower Layer / `FromRequestParts` |
| **Схемы и валидация ввода (DTO)** | `class-validator`, `zod`, `joi`, `ValidationPipe` | `Pydantic` (`BaseModel`), `Serializer`, `Form` | `@Valid`, `jakarta.validation` (`@NotNull`, `@Size`) | DataAnnotations, `FluentValidation` | `validator/v10`, `ShouldBindJSON` | `FormRequest`, `$request->validate()` | Strong Parameters (`params.require.permit`) | `serde` (`deny_unknown_fields`), `validator`, `garde` |
| **Слой БД и сырые запросы (Raw SQL)** | `$queryRaw`, `$executeRaw`, `sequelize.query`, `knex.raw` | `cursor.execute`, `RawSQL`, `.raw()`, `text()` | `JdbcTemplate.query`, `createNativeQuery`, `@Query(nativeQuery=true)` | `FromSqlRaw`, `ExecuteSqlRaw`, `SqlCommand` | `db.Query`, `db.Exec`, `gorm.Raw` | `DB::raw`, `DB::select`, `whereRaw` | `find_by_sql`, `where("...")`, `connection.execute` | `sqlx::query(&format!(...))`, `Statement::from_string` |
| **Вызов ОС / интерпретатора** | `child_process.exec/spawn`, `eval`, `new Function` | `subprocess.*(shell=True)`, `os.system`, `eval`, `exec` | `Runtime.exec`, `ProcessBuilder`, `ScriptEngine` | `Process.Start` | `exec.Command("sh", "-c", ...)` | `exec`, `shell_exec`, `system`, `proc_open`, `eval` | `system`, `` `...` ``, `Open3`, `eval`, `send` | `std::process::Command::new("sh").arg("-c")` |
| **Исходящие HTTP-запросы (SSRF)** | `fetch`, `axios`, `got`, `http.request` | `requests`, `httpx`, `urllib.request`, `aiohttp` | `HttpClient`, `RestTemplate`, `WebClient` | `HttpClient` | `http.Get`, `http.Client` | `Http::get`, `curl_exec`, `file_get_contents` | `Net::HTTP`, `Faraday`, `HTTParty` | `reqwest::Client`, `ureq`, `hyper` |
| **Шаблонизация (SSTI)** | EJS, Handlebars, Nunjucks, Pug | Jinja2, Mako, Django Templates | Thymeleaf, FreeMarker, Velocity, SpEL | Razor | `html/template`, `text/template` | Blade, Twig | ERB, Slim, Haml | `Tera`, `Askama`, `Handlebars` |
| **Небезопасный рендеринг на клиенте (XSS)** | `dangerouslySetInnerHTML`, `bypassSecurityTrust*`, `v-html`, `innerHTML` | `\|safe`, `mark_safe` | `th:utext` | `@Html.Raw` | `template.HTML(...)` | `{!! $var !!}`, `\|raw` | `raw`, `.html_safe` | `\|safe` (Tera/Askama) |
| **Десериализация / Память** | `node-serialize`, `js-yaml.load` (старый) | `pickle`, `yaml.load` (без `SafeLoader`), `marshal` | `ObjectInputStream.readObject`, `XMLDecoder`, Jackson polymorphic | `BinaryFormatter`, `NetDataContractSerializer`, `TypeNameHandling` | `gob`, кастомные анмаршалеры | `unserialize`, Phar | `Marshal.load`, `YAML.load` | блоки `unsafe`, `bincode`/`rmp-serde` с недоверенным размером |

---

## 2. Бэкенд и API (общие узлы)

### Точки входа и маршрутизация
- **Глобальная конфигурация**: настройки префиксов API, CORS, заголовков безопасности, пайпов/перехватчиков валидации, глобальных проверок авторизации и обработчиков ошибок. Именно здесь чаще всего глобально ослабляют защиту.
- **Объявления маршрутов**: все публичные и приватные HTTP-методы (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`). Для каждого маршрута проверь наличие проверки аутентификации, авторизации и строгой схемы входных данных.
- **Декораторы/аннотации обхода авторизации** (`@Public`, `@AllowAnonymous`, `@SkipAuth`, `permission_classes = [AllowAny]`): проверь, не помечены ли ими чувствительные или мутирующие маршруты.

### Аутентификация и контроль доступа (AuthN / AuthZ)
- **Проверка доступа на уровне маршрута**: наличие middleware/guard/filter на всех приватных и мутирующих операциях.
- **BOLA / IDOR**: места, где идентификатор ресурса или пользователя берётся из параметров запроса (`params`, `query`, `body`) и используется для выборки/изменения записи без проверки владельца (`ownerId === currentUser.id`) или принадлежности к тенанту.
- **BFLA (функциональный доступ)**: административные и служебные операции должны явно проверять роль/привилегии на сервере, а не полагаться на скрытие кнопок в UI.
- **Токены и сессии**: алгоритм подписи, проверка срока действия (`exp`), издателя (`iss`) и аудитории (`aud`), отсутствие захардкоженных секретов, перегенерация идентификатора сессии при входе, корректная инвалидация при выходе.

### Валидация входных данных и Mass Assignment
- Входящие структуры данных должны валидироваться по строгой схеме с отбрасыванием или отклонением неописанных полей (белый список полей).
- Прямая привязка тела запроса к модели БД или сущности (`Object.assign(entity, req.body)`, `Model.create(req.body)`, `update_attributes(params)`) без фильтрации полей позволяет перезаписать служебные атрибуты (`role`, `isAdmin`, `balance`, `isVerified`, `tenantId`).

### Инъекции и работа с данными
- **SQL / NoSQL / ORM Operator Injection**: конкатенация или интерполяция пользовательских строк в запросах к БД, динамические имена колонок и порядок сортировки (`ORDER BY`) без белого списка, а также передача невалидированных JSON-объектов/словарей напрямую в фильтры ORM (например, `{"$ne": null}` в Mongo, `where: { token: req.body.token }` с `{"not": null}`/`{"startsWith": "..."}` в Prisma/Sequelize или `Model.objects.filter(**request.data)` с `__regex`/`__startswith` в Django ORM).
- **Командные вызовы и eval**: передача невалидированных параметров в системную оболочку или динамический вычислитель выражений.
- **Файловые операции (Path Traversal / Zip Slip)**: конструирование пути к файлу из пользовательского ввода без нормализации и проверки принадлежности разрешённому базовому каталогу; проверка как при чтении/записи, так и при распаковке архивов.

### Исходящие запросы (SSRF)
- Любая функция, принимающая URL, домен или вебхук от пользователя (предпросмотр ссылок, импорт по URL, загрузка аватара, интеграции, конвертация HTML в PDF), должна:
  1. проверять схему (`http`/`https`) и хост по белому списку;
  2. блокировать приватные, loopback, link-local, CGNAT и облачные метаданные как в IPv4 (`0.0.0.0/8`, `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` включая `169.254.169.254`, `100.64.0.0/10`), так и в IPv6 (`::1`, `fc00::/7`, `fe80::/10`, IPv4-mapped `::ffff:0:0/96`);
  3. защищать от **DNS rebinding** (разрешать доменное имя в IP один раз, проверять этот IP по списку блокировки и устанавливать соединение именно с проверенным IP) и не следовать автоматически HTTP-редиректам (`301`/`302`/`307`/`308`) без повторной проверки целевого адреса.

### Конфигурация и устойчивость
- **CORS**: разрешение произвольного источника (`*`, зеркалирование заголовка `Origin`, разрешение `Origin: null` или уязвимая проверка `startsWith`/`endsWith`/неэкранированной точки в regex) в сочетании с `Access-Control-Allow-Credentials: true`.
- **Заголовки безопасности и Cookie**: наличие `Strict-Transport-Security`, `Content-Security-Policy` (`frame-ancestors`), `X-Content-Type-Options: nosniff`, `Referrer-Policy`, `X-Frame-Options`, `Cache-Control: no-store` на приватных ответах; наличие флагов `HttpOnly`, `Secure`, `SameSite` (и префиксов `__Host-`/`__Secure-`) на сессионных cookie.
- **Ограничение ресурсов**: лимиты на размер тела запроса, размер загружаемых файлов, глубину JSON и частоту вызовов на чувствительных маршрутах (вход, регистрация, восстановление доступа, отправка кодов, ресурсоёмкие отчёты, платные вызовы LLM).
- **Секреты**: отсутствие ключей, паролей и приватных сертификатов в исходном коде, истории коммитов (`git log`), конфигурационных файлах, Docker-образах (проверка `.dockerignore` при `COPY . .`) и клиентских сборках.

---

## 3. Условные модули (проверять при наличии в проекте)

### 3a. OAuth 2.0 / OIDC / SAML / SSO
- **Привязка аккаунтов**: связывание внешнего профиля с локальной учётной записью по email без проверки подтверждённости адреса у провайдера (`email_verified`) или без подтверждения владения локальным аккаунтом.
- **`redirect_uri` / `callbackURL`**: строгая сверка со списком разрешённых адресов по точному совпадению, отсутствие динамического переопределения из параметров запроса.
- **`state` и `PKCE`**: обязательная проверка привязки `state` к сессии и использование PKCE для потока с кодом авторизации.
- **Проверка токенов провайдера**: криптографическая проверка подписи, срока жизни, `iss`, `aud` и `nonce` у `id_token` / SAML Assertion.
- **Передача токенов клиенту**: отсутствие передачи `access_token` или `refresh_token` через URL query string (утечка через историю браузера, логи и заголовок `Referer`).

### 3b. WebSocket / Real-time шлюзы
- **Аутентификация при подключении**: проверка токена или сессии на этапе рукопожатия (handshake) и проверка `Origin`.
- **Авторизация каждого сообщения**: отдельная проверка прав на каждый тип события и команду, а не только при установке соединения.
- **Изоляция каналов и комнат**: проверка прав пользователя перед подпиской на канал/комнату с ресурсами других пользователей или тенантов.
- **Валидация и лимиты**: проверка схемы входящих сообщений и ограничение частоты отправки сообщений от одного клиента.

### 3c. GraphQL
- **Introspection и IDE в production**: отключение интроспекции схемы и встроенных песочниц в продуктовой среде, если API не является публичным.
- **Авторизация на уровне резолверов и полей**: проверка прав в каждом query/mutation и во вложенных field-резолверах, через которые можно обойти проверку корневого запроса.
- **Ограничение сложности**: лимиты глубины вложенности, стоимости запроса и количества алиасов/батчинга в одном HTTP-запросе.
- **Обработка ошибок**: отсутствие трассировки стека и внутренней структуры БД в блоке `extensions` ответа.

### 3d. Шаблонизаторы, XML и слияние объектов
- **XXE**: при разборе XML, SOAP, SVG или офисных документов в формате XML внешние сущности и DTD должны быть явно отключены в настройках парсера.
- **SSTI**: пользовательские данные должны передаваться в шаблон только как контекст переменных, никогда — путём конкатенации в текст самого шаблона перед компиляцией.
- **Prototype Pollution (для JS/TS)**: глубокое рекурсивное слияние пользовательских JSON-объектов без фильтрации ключей `__proto__`, `constructor`, `prototype`.

### 3e. Входящие Webhooks и платёжные коллбэки
- **Проверка подписи**: верификация HMAC/криптографической подписи провайдера по сырому телу запроса (raw body) с использованием constant-time сравнения до выполнения бизнес-логики.
- **Защита от повторов (Replay) и идемпотентность**: проверка допустимого окна `timestamp` и атомарная фиксация уникального идентификатора события (`event_id`).

### 3f. Интеграции с LLM / AI-агентами
- **Разделение контекста и RAG**: фильтрация извлекаемых документов и истории по `userId`/`tenantId` на сервере до формирования промпта.
- **Безопасность вывода и вызовов инструментов (Tool Calling)**: санитизация HTML/Markdown из ответа модели перед рендерингом; серверная проверка авторизации текущего пользователя при вызове любых функций/инструментов моделью.

### 3g. Файловое хранилище (S3-совместимое / presigned URL)
- **Presigned URL**: ограниченный срок действия (TTL), привязка к конкретному ключу объекта, HTTP-методу (`GET` vs `PUT`) и ожидаемому `Content-Type`/размеру.
- **Права доступа к бакетам**: отсутствие публичного чтения/записи на приватных бакетах; проверка прямого обращения к URL объекта без подписи.
- **Безопасная отдача пользовательских файлов**: принудительный `Content-Disposition: attachment` и `X-Content-Type-Options: nosniff` (или раздача с изолированного sandbox-домена) для предотвращения Stored XSS через загруженные `.html`, `.svg`, `.xml`.

### 3h. Мультитенантность (Cross-Tenant изоляция в B2B/SaaS)
- **Изоляция запросов**: все выборки, изменения, поиск, экспорт и фоновые задачи обязаны фильтровать данные по `tenantId` / `organizationId`, полученному из серверного контекста аутентификации, а не из тела запроса или произвольного заголовка без проверки принадлежности пользователя к этому тенанту.
- **Кэш и очереди**: ключи серверного кэша и задания в очередях должны включать идентификатор тенанта.

### 3i. SSR / Fullstack-фреймворки (Next.js, Nuxt, Remix, SvelteKit) и BaaS (Supabase, PostgREST, Firebase)
- **Server Actions (`'use server'` в Next.js / form actions в SvelteKit/Remix)**: каждая экспортируемая функция является публичным HTTP POST-эндпоинтом, который можно вызвать напрямую без UI; проверяй наличие серверной проверки сессии/прав и строгой валидации аргументов внутри каждой функции.
- **Обход проверок в `layout` и `middleware`**: проверка авторизации только в `layout.tsx` не защищает API Route Handlers (`app/api/**/route.ts`) и Server Actions; авторизация должна проверяться в слое доступа к данным (Data Access Layer) и каждом обработчике. Проверяй также защиту от подмены внутренних заголовков прокси/middleware (`x-middleware-subrequest`).
- **Утечка полей в SSR/RSC-сериализацию (`__NEXT_DATA__`, RSC Flight payload, `window.__NUXT__`)**: передача полного объекта пользователя/модели БД из Server Component в Client Component сериализует все поля (`passwordHash`, `secret`, внутренние флаги) в HTML-ответ страницы, даже если компонент рендерит только имя.
- **BaaS и Row Level Security (Supabase / PostgREST / Firebase)**: при использовании публичного клиентского ключа (`NEXT_PUBLIC_SUPABASE_ANON_KEY`) проверь, что на всех таблицах включён `RLS` с корректными политиками `SELECT/INSERT/UPDATE/DELETE`, а сервисный ключ (`SUPABASE_SERVICE_ROLE_KEY`) нигде не попадает в клиентский код.

---

## 4. Фронтенд и клиентская часть

- **Контекстное экранирование и DOM XSS**: поиск мест, где штатное экранирование фреймворка явно отключено или данные из `location`, `postMessage`, хранилищ браузера передаются напрямую в DOM-приёмники (`innerHTML`, `outerHTML`, `document.write`, `eval`).
- **Секреты в клиентском бандле**: проверка переменных окружения, попадающих в сборку (`VITE_*`, `NEXT_PUBLIC_*`, `REACT_APP_*`, `environment.*.ts`), на отсутствие приватных ключей и серверных токенов.
- **Хранение токенов и чувствительных данных**: оценка использования `localStorage`/`sessionStorage` по сравнению с `HttpOnly; Secure; SameSite` cookie; очистка состояния при выходе.
- **Клиентская маршрутизация**: клиентские проверки ролей (`RouteGuard`, `canActivate`, приватные роуты SPA) служат только для UX и обязательно должны дублироваться проверкой на сервере.

---

## 5. Слой данных и инфраструктура

- **Сериализация ответов БД**: модели пользователей и прочих сущностей не должны возвращать в API хэши паролей, секреты MFA, токены сброса и внутренние служебные поля; используй явный выбор полей или выходные DTO.
- **Контейнеры и оркестрация (`Dockerfile`, `docker-compose.yml`, манифесты K8s)**: отсутствие запуска от `root`, закрытые наружу порты СУБД и внутренних очередей, отсутствие дефолтных паролей и захардкоженных секретов.
- **Зависимости (SCA)**: проверка дерева пакетов штатным аудитором экосистемы и наличие фиксированного lock-файла.

---

## 6. Специфичные ловушки фреймворков и поисковые шаблоны (Фаза 1)

При анализе конкретного стека обращай внимание на характерные для него ошибки конфигурации и используй готовые поисковые паттерны (`rg` / `grep -rn`):

### Node.js / TypeScript (NestJS, Express, Fastify, Angular, React, Prisma)
- **NestJS**: глобальный `ValidationPipe` без `whitelist: true, forbidNonWhitelisted: true` открывает Mass Assignment; `@UseGuards` на контроллере или GraphQL `@Resolver`, забытый на отдельном методе, `@ResolveField` или WebSocket `@SubscribeMessage`; декораторы `@Public()` / `@SkipAuth()` на мутирующих маршрутах.
- **Prisma**: `$queryRaw` / `$executeRaw` с шаблонной строкой `` $queryRaw`... ${id}` `` безопасен (параметризуется), но `$queryRawUnsafe` / `$executeRawUnsafe` или конкатенация строк уязвимы к SQLi; возврат моделей без `select`/`omit` раскрывает `passwordHash`, `refreshToken`, `twoFactorSecret`.
- **Angular / React / Vue**: `bypassSecurityTrustHtml`/`bypassSecurityTrustScript`/`bypassSecurityTrustUrl` (`DomSanitizer`), `dangerouslySetInnerHTML`, `v-html` без `DOMPurify`; секреты в `environment.prod.ts` / `NEXT_PUBLIC_*` / `VITE_*`; проверка ролей только в клиентском `canActivate`.
- **Паттерны поиска**:
  ```bash
  rg -n "\$queryRaw|\$executeRaw|sequelize\.query|knex\.raw"
  rg -n "exec\(|execSync\(|spawn\(|eval\(|new Function"
  rg -n "bypassSecurityTrust|dangerouslySetInnerHTML|v-html|innerHTML"
  rg -n "@UseGuards|@Public|@SkipAuth|enableCors|origin:\s*['\"\*]|origin:\s*true"
  rg -n "rejectUnauthorized:\s*false|ignoreExpiration:\s*true"
  rg -n "merge\(|defaultsDeep|__proto__|prototype\["
  ```

### Python (Django, FastAPI, Flask, SQLAlchemy)
- **Django / DRF**: `permission_classes = [AllowAny]` или отсутствие `get_queryset()` с фильтрацией по текущему пользователю/тенанту; `extra()`, `RawSQL`, `.raw()`, `mark_safe` и шаблонный фильтр `|safe`; `DEBUG = True` и `CORS_ALLOW_ALL_ORIGINS = True` в `settings.py`.
- **FastAPI / Pydantic**: эндпоинты без `Depends(get_current_user)`; возврат ORM-модели напрямую без `response_model` (утечка хэшей и внутренних полей); `render_template_string(user_input)` в Flask/Jinja2 (SSTI).
- **Паттерны поиска**:
  ```bash
  rg -n "raw\(|RawSQL|cursor\.execute|text\("
  rg -n "subprocess\.|os\.system|os\.popen|eval\(|exec\(|pickle\.loads|yaml\.load\("
  rg -n "mark_safe|\|safe|render_template_string|verify\s*=\s*False"
  rg -n "AllowAny|csrf_exempt|CORS_ALLOW_ALL_ORIGINS"
  ```

### Java / Kotlin (Spring Boot, Hibernate / JPA)
- **Spring Security**: `permitAll()` на лишних префиксах в `SecurityFilterChain`, отключённый CSRF при cookie-сессиях, отсутствие `@PreAuthorize` / `@Secured` на методах контроллеров; `@Query(value = "...", nativeQuery = true)` с конкатенацией, `JdbcTemplate` со строками; `SpelExpressionParser` на пользовательском вводе; Actuator-эндпоинты (`/actuator/env`, `/actuator/heapdump`), открытые наружу.
- **Паттерны поиска**:
  ```bash
  rg -n "createNativeQuery|nativeQuery\s*=\s*true|JdbcTemplate"
  rg -n "Runtime\.getRuntime\(\)\.exec|ProcessBuilder|SpelExpressionParser|ObjectInputStream|XMLInputFactory"
  rg -n "permitAll\(\)|@CrossOrigin|th:utext|management\.endpoints\.web\.exposure"
  ```

### Go, .NET, PHP, Ruby, Rust (ключевые маркеры)
- **Go**: `db.Query`/`db.Exec`/`gorm.Raw` с `fmt.Sprintf`, `template.HTML(...)`, `InsecureSkipVerify: true`, `exec.Command("sh", "-c", ...)`.
- **.NET**: `FromSqlRaw` / `ExecuteSqlRaw` с интерполяцией без параметризации, `[AllowAnonymous]`, `@Html.Raw(...)`, `BinaryFormatter` / `TypeNameHandling.All`.
- **PHP (Laravel/Symfony)**: `DB::raw` / `whereRaw` с интерполяцией, `$guarded = []` (Mass Assignment), `{!! $var !!}` / `|raw`, `unserialize()`, `shell_exec`/`exec`.
- **Ruby on Rails**: `where("... #{params[:x]}")`, `find_by_sql`, `params.permit!`, `.html_safe` / `raw`, `YAML.load` / `Marshal.load`, `skip_before_action :verify_authenticity_token`.
- **Rust (Axum/Actix/SQLx/SeaORM)**: `sqlx::query(&format!(...))`, `Statement::from_string`, блоки `unsafe`, отсутствие `#[serde(deny_unknown_fields)]` на чувствительных DTO, фильтр `|safe` в шаблонах Tera/Askama, `danger_accept_invalid_certs(true)` в `reqwest`.
