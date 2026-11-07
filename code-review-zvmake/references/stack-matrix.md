# Матрица стек-специфичных конструкций для код-ревью

Справочник для сопоставления универсальных пунктов чек-листа `SKILL.md` с конструкциями конкретного языка и фреймворка. Стек определяется на Шаге 1 по манифестам (`package.json`, `pyproject.toml` / `requirements.txt`, `pom.xml` / `build.gradle(.kts)`, `*.csproj` / `*.sln`, `go.mod`, `Cargo.toml`, `composer.json`, `Gemfile`) и расширениям изменённых файлов.

Перечни ниже — типовые примеры, а не исчерпывающие списки. Если проект использует иной инструмент (линтер, тестовый фреймворк, DI-контейнер) — определи его по конфигурациям и манифестам и применяй тот же принцип проверки.

---

## 1. Директивы подавления (компилятор / тайпчекер / линтер / покрытие / форматтер)

Изменение такой директивы — **изменение поведения инструментов проверки**, а не «просто комментарий». Исключение `comment-only` на них не распространяется; каждое новое подавление требует обоснования в коде или в требованиях.

| Экосистема | Примеры директив |
|---|---|
| JavaScript / TypeScript | `@ts-ignore`, `@ts-expect-error`, `@ts-nocheck`, `eslint-disable*`, `biome-ignore`, `istanbul ignore`, `c8 ignore`, `v8 ignore`, `prettier-ignore` |
| Python | `# type: ignore`, `# pyright: ignore`, `# noqa`, `# pylint: disable=...`, `# pragma: no cover`, `# fmt: off` / `# fmt: skip` |
| Java / Kotlin | `@SuppressWarnings(...)`, `@Suppress(...)`, `// NOSONAR`, аннотации `@Generated` (исключение из покрытия JaCoCo) |
| .NET (C#) | `#pragma warning disable`, `#nullable disable`, `[SuppressMessage(...)]`, `[ExcludeFromCodeCoverage]` |
| Go | `//nolint`, `//lint:ignore` |
| Rust | `#[allow(...)]`, `#[expect(...)]`, `#[rustfmt::skip]` |
| PHP | `@phpstan-ignore*`, `@psalm-suppress`, `@codeCoverageIgnore*`, `phpcs:ignore` / `phpcs:disable`, оператор подавления ошибок `@` |
| Ruby | `# rubocop:disable ...`, `# :nocov:`, Sorbet-сигилы `# typed: ...` |

## 2. Семантические комментарии (комментарии, влияющие на сборку или выполнение)

Изменение в этих конструкциях не считается `comment-only`:

| Экосистема | Конструкции |
|---|---|
| JavaScript / TypeScript | JSDoc-типы в `.js` при включённом `checkJs`; triple-slash директивы `/// <reference ... />`; магические комментарии сборщиков (например, `/* webpackChunkName: ... */`) |
| Python | type-комментарии (`# type: List[int]`); `doctest`-примеры в docstring, если в проекте запускается `doctest`; объявление кодировки `# -*- coding: ... -*-` |
| Java / Kotlin | Javadoc-тег `@deprecated` (учитывается компилятором Java); теги, обрабатываемые кодогенераторами проекта |
| .NET (C#) | XML-doc при включённых `GenerateDocumentationFile` и `TreatWarningsAsErrors` (ошибки в нём ломают сборку); директивы препроцессора `#if` / `#define` — не комментарии, а изменение компиляции |
| Go | `//go:build`, `//go:generate`, `//go:embed`, `//go:linkname`, `// Output:` в `Example*`-функциях (проверяется `go test`) |
| Rust | примеры кода в `///` и `//!` компилируются и выполняются как doc-тесты (`cargo test`) |
| PHP | docblock-аннотации, читаемые в рантайме или инструментами (Doctrine `@ORM\...`, `@Route`, PHPStan/Psalm-типы `@var`, `@param`, `@return`) |
| Ruby | магические комментарии `# frozen_string_literal: true`, `# encoding: ...` |

## 3. Конвенции тестовых файлов (для исключения `test-only`)

| Экосистема | Типовые расположения и имена |
|---|---|
| JavaScript / TypeScript | `*.spec.*`, `*.test.*`, `*.e2e-spec.*`, `*.e2e.*`, `*.cy.*`, `__tests__/`, `__mocks__/`, `__snapshots__/`, каталоги фикстур |
| Python | `test_*.py`, `*_test.py`, `tests/`, `conftest.py` |
| Java / Kotlin | `src/test/**`, `src/testFixtures/**`, `*Test`, `*Tests`, `*IT` |
| .NET (C#) | тестовые проекты `*.Tests` / `*.UnitTests` / `*.IntegrationTests`, `*Tests.cs` |
| Go | `*_test.go`, `testdata/` |
| Rust | `tests/`, `benches/`; **внимание:** модули `#[cfg(test)] mod tests` встроены в продуктовые файлы — правка такого файла не делает его тестовым, проверяй, что изменён только тестовый модуль |
| PHP | `tests/`, `*Test.php` |
| Ruby | `spec/**/*_spec.rb`, `test/**/*_test.rb`, `spec/factories/`, `spec/support/` |

Общие оговорки: тестовые хелперы, фикстуры и конфигурация тестового раннера, которые подключаются в продуктовую сборку или влияют на CI-гейты (пороги покрытия, исключения из прогона), к `test-only` не относятся.

## 4. Обходы системы типов и небезопасные конструкции

| Экосистема | Что искать |
|---|---|
| JavaScript / TypeScript | `any`, `as unknown as T`, двойные/необоснованные `as`, non-null assertion `!`, непроверенный доступ по индексу без `noUncheckedIndexedAccess`, `JSON.parse` без валидации схемы |
| Python | `Any`, `typing.cast(...)`, `# type: ignore`, доступ к атрибутам через `getattr` со строкой, голый `except:` |
| Java | raw types, непроверенные приведения `(T) obj`, `Optional.get()` без проверки, `@SuppressWarnings("unchecked")` |
| Kotlin | `!!`, небезопасный `as` (вместо `as?`), `lateinit` без гарантии инициализации, `@Suppress("UNCHECKED_CAST")` |
| .NET (C#) | null-forgiving `!`, `dynamic`, явные приведения `(T)obj` без проверки, блоки `unsafe` |
| Go | игнорирование ошибок (`_ = f()`, `v, _ := f()`), утверждение типа `v.(T)` без `ok`, `any` / `interface{}` в публичном API, `unsafe.Pointer` |
| Rust | `.unwrap()` / `.expect()` на данных, которые могут отсутствовать, блоки `unsafe`, усечение при `as`-приведении чисел, `mem::transmute` |
| PHP | `mixed`, нестрогое сравнение `==`, отсутствие `declare(strict_types=1)` там, где принято в проекте, оператор `@` |
| Ruby | `send` / `public_send` с внешним вводом, `instance_variable_set`, Sorbet `T.unsafe` / `T.must` без обоснования |

## 5. Документирующие комментарии

| Экосистема | Формат | Что проверять при изменении сущности |
|---|---|---|
| JavaScript / TypeScript | JSDoc / TSDoc (`/** ... */`) | `@param`, `@returns`, `@throws`, `@deprecated`; комментарий над самой экспортируемой сущностью |
| Python | docstrings (PEP 257; стили Google / NumPy / reST) | `Args`, `Returns`, `Raises`; docstring внутри функции/класса, а не комментарий над ним |
| Java / Kotlin | Javadoc / KDoc | `@param`, `@return`, `@throws` / `@exception` |
| .NET (C#) | XML-doc (`///`) | `<summary>`, `<param>`, `<returns>`, `<exception>` |
| Go | GoDoc (комментарий над объявлением, начинается с имени сущности) | соответствие имени и поведения |
| Rust | rustdoc (`///`, `//!`) | секции `# Errors`, `# Panics`, `# Safety`; работоспособность doc-тестов |
| PHP | PHPDoc (`/** ... */`) | `@param`, `@return`, `@throws` и их соответствие нативным типам |
| Ruby | YARD / RDoc | `@param`, `@return`, `@raise` |

## 6. Гарантированное освобождение ресурсов

| Экосистема | Идиома | Типичные ошибки |
|---|---|---|
| JavaScript / TypeScript | `try/finally`, `using` / `await using` (явное управление ресурсами), `AbortController` | незакрытые клиенты пула, `setTimeout`/`setInterval` без `clearTimeout`/`clearInterval`, подписки без отписки, слушатели событий без удаления |
| Python | `with` / `async with`, `contextlib`, `try/finally` | открытие файлов/соединений без контекстного менеджера, незакрытые сессии HTTP-клиентов |
| Java / Kotlin | try-with-resources, `finally`; Kotlin `use { }` | `Connection` / `Stream` / `ResultSet` вне try-with-resources |
| .NET (C#) | `using` / `await using`, `IDisposable` / `IAsyncDisposable` | неосвобождённые `DbConnection`, `Stream`, `CancellationTokenSource`; создание `HttpClient` на каждый запрос |
| Go | `defer x.Close()`, `defer cancel()` для `context.WithTimeout` / `WithCancel` | незакрытые `rows` / `resp.Body`, утечка горутин без отмены контекста |
| Rust | RAII / `Drop` | удержание `MutexGuard` или транзакции через `.await`, утечка через `mem::forget` |
| PHP | `try/finally` | незакрытые файловые дескрипторы и курсоры в долгоживущих воркерах |
| Ruby | `ensure`, блочные формы (`File.open { }`, `transaction { }`) | ресурсы, открытые без блока и без `ensure` |

## 7. Публичные экспорты и регистрация зависимостей (blast radius)

| Экосистема | Где проверять швы |
|---|---|
| JavaScript / TypeScript | barrel-файлы (`index.ts`), поле `exports` в `package.json`, регистрация провайдеров в DI-модулях фреймворка (например, `providers` / `exports` / `imports` модулей), алиасы путей в `tsconfig` |
| Python | `__init__.py`, `__all__`, entry points в `pyproject.toml`, регистрация приложений/зависимостей фреймворка (например, `INSTALLED_APPS`, `Depends(...)`) |
| Java / Kotlin | стереотипы и конфигурации контейнера (`@Component`, `@Service`, `@Bean`, `@Configuration`), `module-info.java`, `META-INF/services` |
| .NET (C#) | регистрация в `IServiceCollection` (`AddScoped` / `AddSingleton` / `AddTransient`), модификаторы `public` / `internal`, `InternalsVisibleTo` |
| Go | экспортируемые идентификаторы (с заглавной буквы), пакеты `internal/`, провайдеры DI-библиотек при их использовании |
| Rust | `pub` / `pub(crate)`, реэкспорты в `lib.rs` / `mod.rs`, Cargo features |
| PHP | сервис-провайдеры и конфигурация контейнера фреймворка, autoload PSR-4 в `composer.json` |
| Ruby | соглашения автозагрузки (имя файла ↔ константа), initializers, `require` |

## 8. Схемы и валидация контрактов

| Экосистема | Типовые средства |
|---|---|
| JavaScript / TypeScript | `zod`, `class-validator`, `joi`, `yup`, `valibot`, JSON Schema (`ajv`) |
| Python | Pydantic, сериализаторы и формы фреймворков, `marshmallow`, `attrs` / `dataclasses` с валидаторами |
| Java / Kotlin | Jakarta Bean Validation (`@Valid`, `@NotNull`, `@Size`) |
| .NET (C#) | DataAnnotations, FluentValidation |
| Go | `go-playground/validator`, теги структур, ручные проверки в конструкторах |
| Rust | `serde` (`deny_unknown_fields`), `validator`, `garde` |
| PHP | валидаторы форм/запросов фреймворка, Symfony Validator |
| Ruby | валидации моделей, Strong Parameters, `dry-validation` |
| Межъязыковые контракты | OpenAPI / Swagger, GraphQL SDL, Protobuf / gRPC, JSON Schema, AsyncAPI, Avro |

## 9. Слабые и неразличающие ассерты

| Экосистема | Примеры, требующие замены на проверку точного значения/контракта |
|---|---|
| JavaScript / TypeScript | `toBeDefined()`, `toBeTruthy()`, `expect.anything()`, `toHaveBeenCalled()` без проверки аргументов, снапшот вместо явной проверки ключевых полей |
| Python | `assert result`, `assert x is not None`, `mock.assert_called()` без аргументов |
| Java / Kotlin | `assertNotNull(...)`, `assertTrue(x != null)`, `verify(mock).call(any())` |
| .NET (C#) | `Assert.NotNull(...)`, `Assert.True(true)`, проверка вызова с `Arg.Any<T>()` / `It.IsAny<T>()` там, где важен аргумент |
| Go | `assert.NotNil(t, res)`, проверка только `err == nil` без проверки результата |
| Rust | `assert!(res.is_ok())`, `assert!(!v.is_empty())` |
| PHP | `assertNotNull(...)`, `assertTrue($x)` вместо `assertSame` |
| Ruby | `be_truthy`, `not_to be_nil`, `be_present` |

## 10. Детерминизм времени в тестах

| Экосистема | Средства |
|---|---|
| JavaScript / TypeScript | фейковые таймеры тестового раннера (`jest.useFakeTimers()`, `vi.useFakeTimers()`), `@sinonjs/fake-timers`, внедрение часов |
| Python | `freezegun`, `time-machine`, внедрение часов |
| Java / Kotlin | внедрение `java.time.Clock` (`Clock.fixed(...)`), `kotlinx-coroutines-test` для корутин |
| .NET (C#) | `TimeProvider` и `FakeTimeProvider` |
| Go | внедрение интерфейса часов вместо прямого `time.Now()` |
| Rust | `tokio::time::pause()` для асинхронного кода, внедрение часов |
| PHP | `Carbon::setTestNow()`, `MockClock` компонента Symfony Clock |
| Ruby | `travel_to` (ActiveSupport), `Timecop` |

## 11. Числа: деньги, точность и переполнение

| Экосистема | Точные десятичные типы | Пределы и ловушки целых чисел |
|---|---|---|
| JavaScript / TypeScript | нет встроенного decimal: целые минимальные единицы, `BigInt`, библиотеки (`decimal.js`, `big.js`) | `Number.MAX_SAFE_INTEGER` = 2^53−1: 64-битные идентификаторы (`BIGINT`) из БД/JSON теряют точность — передавать строкой или `BigInt` |
| Python | `decimal.Decimal` | целые произвольной точности, но переполнение возможно на границе с БД/внешними форматами |
| Java / Kotlin | `BigDecimal` (сравнение через `compareTo`, а не `equals`) | `int` 32-битный, переполнение молча; `Math.addExact` и аналоги для контроля |
| .NET (C#) | `decimal` | переполнение по умолчанию не проверяется (`unchecked`); `checked` для контроля |
| Go | целые минимальные единицы, сторонние decimal-библиотеки | размер `int` зависит от платформы; переполнение молча |
| Rust | `rust_decimal` и аналоги | в debug-сборке переполнение вызывает панику, в release — молча оборачивается; `checked_*` / `saturating_*` для контроля |
| PHP | `bcmath`, библиотеки денег | переполнение `int` превращает значение во `float` |
| Ruby | `BigDecimal` | целые произвольной точности; ловушки — на границе с БД |

## 12. Хранилища данных: блокировки, пакетные выборки, точность времени

### Ошибки взаимоблокировки (для проверки ретраев и порядка блокировок)
| СУБД | Код |
|---|---|
| PostgreSQL | SQLSTATE `40P01` (`deadlock_detected`); `40001` — ошибка сериализации |
| MySQL / MariaDB (InnoDB) | ошибка `1213` (`ER_LOCK_DEADLOCK`, SQLSTATE `40001`) |
| Microsoft SQL Server | ошибка `1205` |
| Oracle | `ORA-00060` |

### Пакетные выборки вместо `N+1`
- `WHERE id IN (...)` с учётом лимита числа параметров драйвера/СУБД (при больших списках — разбиение на батчи или передача массива).
- Передача массива одним параметром там, где СУБД это поддерживает (например, PostgreSQL `WHERE id = ANY($1)`).
- Механизмы ORM для жадной загрузки связей (eager loading / `include` / `select_related` / `prefetch_related` / `JOIN FETCH` / `Include` и аналоги).

### Keyset-пагинация
- Сортировка по стабильному набору полей с уникальным разрешающим полем (`ORDER BY created_at, id`) и курсор по тому же набору (`(created_at, id) > (:c, :id)`).
- Курсор не должен строиться по полю, которое обновляется внутри обхода.

### Точность временных меток (источник потерь при построении курсоров и сравнении)
| Сторона | Точность |
|---|---|
| PostgreSQL `timestamp` / `timestamptz` | микросекунды |
| MySQL `DATETIME(fsp)` / `TIMESTAMP(fsp)` | до микросекунд; по умолчанию `fsp = 0` (секунды) |
| SQL Server `datetime2` / `datetime` | 100 нс / ~3,33 мс |
| JavaScript `Date` | миллисекунды |
| Python `datetime` | микросекунды |
| Java `Instant` / .NET `DateTime` / Go `time.Time` | наносекунды / 100 нс (тики) / наносекунды |
