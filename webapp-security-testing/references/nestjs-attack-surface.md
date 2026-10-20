# Карта атакующей поверхности: NestJS + Angular + Prisma

Справочник типовых мест уязвимостей в стеке. Используй для Фазы 1 (Recon) и как чек-лист «где искать» в Фазе 3.

## 1. NestJS (бэкенд)

### Точки входа и роутинг
- `main.ts` — глобальная конфигурация: `app.setGlobalPrefix()`, `app.enableCors()`, `app.use(helmet())`, глобальные `ValidationPipe`, `app.useGlobalGuards()`. Здесь чаще всего отключают или неправильно настраивают защиту глобально.
- `*.controller.ts` — `@Controller('path')`, декораторы `@Get/@Post/@Put/@Patch/@Delete`. Проверь каждый эндпоинт на наличие guard и валидацию.

### Аутентификация / авторизация
- Guards (`*.guard.ts`, `@UseGuards()`) — есть ли guard на каждом мутирующем/приватном эндпоинте. Ищи эндпоинты без `@UseGuards` вообще, или где guard забыт на конкретном методе.
- IDOR/BOLA — где `userId`/`resourceId` берётся из `@Param('id')`/`@Query('id')` и напрямую передаётся в сервис, без сверки с владельцем из JWT/сессии. Пример опасности: `findUnique({ where: { id: params.id } })` без проверки `ownerId === user.id`.
- JWT — проверка `secret`, алгоритма (`jwt.sign` без `algorithm`), срока (`expiresIn`), хранения refresh-токенов. Ищи `secret: '...'` в коде, `ignoreExpiration: true`.
- Паспорт/стратегии — `validate()` возвращает неверные поля, лишние привилегии из `req.user`.

### Валидация входных данных
- DTO (`*.dto.ts`) — есть ли `class-validator`/`zod`-декораторы. Отсутствие валидации + глобальный `ValidationPipe` без `whitelist: true, forbidNonWhitelisted: true` = массовое присвоение лишних полей (Mass Assignment).
- `@Body()`, `@Param()`, `@Query()` без типизации — признак невалидированного ввода.

### Инъекции
- Prisma: прямой `$queryRaw`/`$executeRaw` с интерполяцией строк — главный признак SQL-инъекции. Приоритетно проверяй все `$queryRaw`, `$executeRaw`, `Prisma.sql` с шаблонными строками.
- Параметризованный `$queryRaw(Prisma.sql`...`)` с `Prisma.sql` + подстановкой через `${}` безопасен; опасна конкатенация `... WHERE id = '${id}'`.
- Command injection: `child_process.exec`, `execSync`, `spawn` с пользовательским вводом; `eval`, `new Function`.

### SSRF
- Исходящие запросы: `axios`, `fetch`, `http.request`, `got` где URL берётся из ввода пользователя. Ищи отсутствие валидации URL и блокировки `127.0.0.1`, `localhost`, `169.254.169.254` (метаданные облака), `[::1]`, `0.0.0.0`.

### File upload / Path traversal
- `multer`/`FileInterceptor` — проверка расширения/MIME/размера, где сохраняются файлы, доступны ли они по предсказуемому пути.
- `fs.readFile`/`createReadStream`/`sendFile` с путём из ввода — санитизация `../`, `path.resolve`/`path.join` vs `path.normalize`.

### Misconfiguration
- CORS: `enableCors({ origin: '*' })` или `origin: true` (отражение произвольного Origin) на приватных эндпоинтах. Критично при cookie-аутентификации.
- Отсутствие `helmet()` или отключённые заголовки CSP/HSTS/X-Frame-Options.
- `body-parser`/`json({ limit })` без ограничения размера.
- Rate limiting: отсутствие `@nestjs/throttler`/`ThrottlerGuard` на `/auth/login`, `/auth/register`, `/auth/recovery`.

### Секреты
- `process.env` — какие переменные используются и попадают ли дефолты в код.
- Закоммиченные `.env`, токены, ключи подписи JWT, ключи API в исходниках.

## 1a. OAuth / Passport SSO (всегда, если есть внешняя авторизация)

- `PassportStrategy` (`*.strategy.ts`, напр. `google.strategy.ts`, `github.strategy.ts`) — метод `validate()`: какие поля из провайдера доверяются без проверки (например, `email_verified` из Google не проверяется, а пользователь автоматически привязывается к аккаунту с таким же email — account takeover через неподтверждённый email у второго провайдера).
- Авторизационный `redirect_uri`/`callbackURL` — задаётся статически в конфиге стратегии или берётся из запроса/env без валидации — проверь, можно ли переопределить его через query-параметр.
- Callback-контроллеры (`@Get('auth/google/callback')`) — проверьется ли `state` перед выдачей сессии/токена; как и куда выдаются токен 12аклиенту (redirect с `access_token` в query string — утечка через `Referer`/логи прокси).
- Связывание внешнего аккаунта с существующим локальным аккаунтом по email без подтверждения владения локальным паролем — вектор захвата аккаунта.

DAST-проверки (`redirect_uri`, `state`, PKCE, `alg=none`/key confusion для `id_token`) — см. `owasp-top10.md`, раздел «OAuth2 / OIDC / SSO».

## 1b. WebSocket / Gateways (только если в проекте есть `@nestjs/websockets`, `@WebSocketGateway`)

- **Authn на handshake**: проверяется ли токен/сессия при подключении (`handleConnection`, middleware адаптера `io.use(...)`), или любой клиент может подключиться без авторизации.
- **Authz на уровне сообщений**: каждый `@SubscribeMessage('event')` должен проверять права отдельно — автентификация на handshake не гарантирует авторизацию на каждое событие (`@UseGuards` на gateway часто забывают на отдельных handler'ах).
- **Room/broadcast leakage**: подключение к «комнате» (`socket.join(roomId)`) без проверки, что пользователь имеет право быть в этой комнате — позволяет читать события чужого чата/канала, если `roomId` угадываем/берётся из клиентского ввода.
- **Input validation**: валидируются ли данные события (`@MessageBody()`) так же строго, как REST DTO — частая ошибка — валидацию делают только для HTTP-эндпоинтов.
- **DoS**: отсутствие лимита частоты событий от одного клиента; отсутствие лимита на количество одновременных соединений с одного IP.

**Как проверить динамически**: подключись через `socket.io-client`/Playwright `page.evaluate` без токена — проверь, разрешает ли сервер подключение; отправь событие с `roomId`/`userId` другого пользователя и проверь получение чужих событий.

## 1c. GraphQL (только если в проекте есть `@nestjs/graphql`, Apollo/Mercurius)

- **Introspection в проде**: если `introspection: true` (или `playground: true`) оставлено в production — атакующий может получить полную схему API через `{__schema{types{name}}}`.
- **Resolver-level authorization**: каждый `@Resolver()`/`@Query()`/`@Mutation()` должен иметь свой guard — обычная ошибка: guard стоит на модуле/контроллере, но не на каждом resolver, и вложенные резолверы (field resolvers) могут вытягивать связанные данные без проверки.
- **Batching / alias-based DoS**: отсутствие ограничения глубины/сложности запроса (`graphql-depth-limit`, `graphql-query-complexity`) — позволяет одним запросом с алиасами (`a: field, b: field, ...`) обойти rate limit и создать чрезмерную нагрузку на резолверы/базу данных.
- **Error/verbose messages**: GraphQL по умолчанию возвращает подробные stack trace в `extensions` при ошибке — проверь, не утекают ли в production.

**Как проверить динамически**: отправь introspection-запрос и запрос с глубокой вложенностью/алиасами — готовые запросы в `payloads.md`.

## 1d. Prototype Pollution / SSTI (всегда проверять, если есть глубокий merge объектов или шаблоны писем/документов)

- **Prototype Pollution**: `lodash.merge`/`_.merge`/`_.defaultsDeep`/`Object.assign` с глубоким рекурсивным объединением полностью пользовательского JSON-ввода (например, обновление настроек профиля через `merge(defaultSettings, req.body)`). При отсутствии защиты от `__proto__`/`constructor.prototype` ввод может загрязнить `Object.prototype` всего процесса — от DoS до RCE (в редких случаях, через gadget-цепочки в зависимостях).
- **SSTI**: шаблонизаторы для email/PDF/отчётов (Handlebars, EJS, Nunjucks, Pug) — если пользовательский ввод (имя, комментарий, тема письма) вставляется в шаблон до рендера (а не как данные для подстановки), возможна инъекция шаблонных конструкций, вплоть до RCE в зависимости от движка.

Пейлоады и признаки эксплуатации — в `payloads.md` и `references/advanced-vectors.md`.

## 2. Angular (фронтенд)

- **XSS**: `bypassSecurityTrustHtml`/`bypassSecurityTrustScript`/`bypassSecurityTrustUrl`, `innerHTML` с пользовательскими данными без `DOMPurify`. Angular по умолчанию экранирует интерполяцию `{{ }}` и `[innerHTML]`, но `bypassSecurityTrust*` и `DomSanitizer` это отключают.
- **Секреты в бандле**: ищи ключи API, токены, `environment.prod.ts` с секретами (всё, что попадает в сборку, читается клиентом).
- **CSRF**: как хранится токен (localStorage vs cookie), передаётся ли в заголовках.
- **Маршрутизация**: `canActivate`/`RouteGuard` — есть ли guard на защищённых роутах, не проверяется ли роль только на клиенте (клиентский guard не является защитой — проверь, что сервер тоже авторизует).

## 3. Prisma / БД

- `schema.prisma` — чувствительные поля (`password`, `token`, `refreshToken`) не должны возвращаться API напрямую; проверь `select`/`omit` при выборках.
- `$queryRaw`/`$executeRaw` — см. выше (инъекции).
- Связи: `select: { relations }` — не «протекают» ли связанные данные другого пользователя через неверные `where`.

## 4. docker-compose / инфраструктура (быстрая проверка)

- Открытые порты БД наружу (`ports: "5432:5432"`), слабые дефолтные пароли в `docker-compose.yml`, отсутствие отдельной сети.
- `npm audit` — уязвимые зависимости (`npm run security:deps` в проекте).

## Быстрый порядок сканирования кода (grep-набор)

```
grep -rn "\$queryRaw\|\\$executeRaw" apps/
grep -rn "exec(\|execSync(\|spawn(" apps/
grep -rn "bypassSecurityTrust\|innerHTML\|dangerouslySetInnerHTML" apps/
grep -rn "origin: '\*'\|origin: \"\*\"\|origin: true" apps/
grep -rn "rejectUnauthorized" apps/
grep -rn "secret:\s*['\"]" apps/
grep -rn "axios\|fetch(\|http.request" apps/
grep -rn "@UseGuards\|@Public\|@SkipAuth" apps/
grep -rn "__proto__\|prototype\[\|\.merge(\|defaultsDeep\|Object.assign(" apps/
grep -rn "\.render(\|ejs\.\|handlebars\|nunjucks\|pug\." apps/
grep -rn "@WebSocketGateway\|@SubscribeMessage\|handleConnection" apps/
grep -rn "@Resolver(\|introspection\|playground:\s*true" apps/
grep -rn "PassportStrategy\|callbackURL\|redirect_uri" apps/
grep -rn "parseXml\|xml2js\|libxmljs\|DOMParser" apps/
```
