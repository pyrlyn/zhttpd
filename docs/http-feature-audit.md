# Проверка возможностей HTTP-сервера

Проверка выполнена 12 ноября 2026 года. Исходный checkout: `8be061ba3a891c09eeaeb6d71768385668517d03`.
Реализация выполнена в ветке `codex/server-features`, созданной от обновлённого `origin/main` (`fb3f377cb2a557254f2e3bd84c2efe72a90e9bc9`).
Перед публикацией интегрированы изменения `origin/main` (`44b0fef`), включая пул памяти запросов и исправления HTTP/3.
Статусы относятся к собственному серверу/API; простая пересылка запроса приложению не считается встроенным parser/auth/middleware.

## Результаты по каждому пункту

| Возможность | До проверки | После изменений | Реализация и границы |
| --- | --- | --- | --- |
| Маршрутизация URL | реализована | реализована | [src/server/router.zig:22](../src/server/router.zig#L22). Exact/prefix/regex, вложенные locations и vhosts; сохранена совместимость nginx. |
| Маршрутизация по HTTP-методу | частично | реализована | [src/server/router.zig:28](../src/server/router.zig#L28). Отдельные маршруты для одного URL, проверка пересечений методов и Allow при 405. |
| Заголовки запроса | реализована | реализована | [src/http/request.zig:51](../src/http/request.zig#L51). Регистронезависимый поиск, проверка framing-заголовков и ограничение количества. |
| Заголовки ответа | реализована | реализована | [src/server/handler.zig:674](../src/server/handler.zig#L674). Существующий writer; новый Context.addHeader проверяет значения и защищает framing. |
| GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS | частично | реализована | [src/http_sdk.zig:7](../src/http_sdk.zig#L7). Нативные callbacks и proxy, автоматический HEAD для GET, CORS preflight и OPTIONS *. Статика остаётся GET/HEAD; CONNECT tunnelling и TRACE reflection не входят в реализацию. |
| Статусы 200, 404, 500 и другие | реализована | реализована | [src/http/response.zig:6](../src/http/response.zig#L6). Проверены реальные ответы, HEAD, 204/304; 400/401/403/405/409/413/415/429/503 в новом E2E. |
| JSON request body | отсутствует | реализована | [src/http/body.zig:35](../src/http/body.zig#L35). Проверка Content-Type, разбор в std.json.Value, некорректный JSON → 400. |
| multipart/form-data | отсутствует | реализована | [src/http/body.zig:86](../src/http/body.zig#L86). Границы, quoted parameters, повторные поля, filename, content type и бинарные значения; ограниченные память и число полей. |
| application/x-www-form-urlencoded | отсутствует | реализована | [src/http/body.zig:24](../src/http/body.zig#L24). Декодирование %XX и +; повторные ключи сохраняются. |
| Query-параметры | частично | реализована | [src/http/application.zig:19](../src/http/application.zig#L19). Новый декодирующий API; прежние nginx $args/$arg_* сохраняют своё поведение. |
| Middleware-цепочка | частично | реализована | [src/http/application.zig:66](../src/http/application.zig#L66). Порядок before/after, short-circuit, ошибка повторного next; существующие серверные фазы сохранены. |
| Аутентификация | отсутствует | реализована | [src/http/auth.zig:16](../src/http/auth.zig#L16). JWT HS256 с обязательными exp/iss/aud/sub, nbf, MAC и ротацией secret file. Session store и Basic Auth не добавлялись; выбран JWT. |
| Авторизация | частично | реализована | [src/http/auth.zig:52](../src/http/auth.zig#L52). Требование всех перечисленных scopes, 403 при недостаточных правах; существующие IP ACL сохранены. |
| CORS | частично | реализована | [src/server/policy.zig:23](../src/server/policy.zig#L23). Origin allowlist, preflight methods/headers, credentials, Vary; wildcard с credentials запрещён. |
| Rate limiting | отсутствует | реализована | [src/server/policy.zig:125](../src/server/policy.zig#L125). Token bucket по peer IP и location на worker, bounded state, 429 + Retry-After. Общекластерной квоты нет. |
| Cookie: чтение, установка, удаление | частично | реализована | [src/http/application.zig:32](../src/http/application.zig#L32). Отдельные Set-Cookie, чтение Cookie, удаление Max-Age=0 с тем же path/domain. |
| Cookie: Secure/HttpOnly/SameSite | частично | реализована | [src/http/cookie.zig:2](../src/http/cookie.zig#L2). Безопасные defaults, Strict/Lax/None, проверка __Host-/__Secure- и CRLF. |
| Логирование запросов | реализована | реализована | [src/server/worker.zig:472](../src/server/worker.zig#L472). Существующие форматы, escaping, scoped error logs, USR1 reopening; пройдены logging E2E. |
| Единый формат ошибок | реализована | реализована | [src/server/handler.zig:566](../src/server/handler.zig#L566). Сохранились общий HTML renderer/error_page; добавлен JSON для локальных ошибок и native exceptions. Ответы upstream остаются собственными. |
| HTTPS | реализована | реализована | [src/server/tls.zig:248](../src/server/tls.zig#L248). Существующие TLS/SNI; SDK serveConfig использует тот же runtime. TLS 1.2/1.3 и новые политики по HTTPS проверены. |
| Сжатие gzip | отсутствует | реализована | [src/server/compression.zig:20](../src/server/compression.zig#L20). Локальная статика и memory responses 256 байт..8 МиБ, q=0, HEAD, Vary и weak ETag. Upstream streams не пересжимаются. |
| Кэширование | реализована | реализована | [src/server/handler.zig:487](../src/server/handler.zig#L487). ETag/If-None-Match, Last-Modified, 304, Expires/Cache-Control и open-file cache. Proxy response cache не реализован. |
| Health endpoint | реализована | реализована | [src/app_config.zig:452](../src/app_config.zig#L452). Исходный config.toml уже имел /health. Добавлен health_path: GET/HEAD JSON, no-store, без JWT/rate. Проверяется liveness процесса. |
| Таймауты соединений и чтения | реализована | реализована | [src/server/conn.zig:769](../src/server/conn.zig#L769). Header/body/send/keepalive/upstream-connect/read/send; добавлены native TOML настройки header/body/send. Проверен slow-header timeout. |
| Ограничение размера тела | частично | реализована | [src/server/conn.zig:645](../src/server/conn.zig#L645). Исправлен обход для chunked-тел, которые сервер отбрасывает: счётчик теперь работает независимо от body_store. Проверен 413 для обоих framing-вариантов. |
| Статические файлы | реализована | реализована | [src/server/handler.zig:339](../src/server/handler.zig#L339). Root/alias/index/try_files, MIME, HEAD, ranges, autoindex, sendfile/open-file cache; тесты сохранены. |
| Редиректы | реализована | реализована | [src/server/handler.zig:606](../src/server/handler.zig#L606). 301/302/303/307/308, Location и rewrite; новый Context.redirect. Проверены существующие redirect E2E. |
| Идемпотентность операций | отсутствует | частично | [src/server/application.zig:7](../src/server/application.zig#L7). Добавлен Idempotency-Key для native handlers: replay, 409 на конфликт, bounded cache 128 ответов/5 минут/64 КиБ, 503 при заполнении. Нет атомарности с внешней БД, сохранения после restart и общей дедупликации между workers. |

## Ключевые доказательства исходных пробелов

Номера строк ниже относятся к исходному commit `8be061b`, до правок:

- `src/nginx/directives.zig:194`: auth_basic помечен ignored; :196 — auth_request; :269 — gzip; :308 — limit_req_zone.
- `src/http/request.zig:17`: модель Request содержит head/framing/args, без JSON или multipart decoder; :11 перечисляет методы, но не реализует прикладные операции.
- `src/server/handler.zig:244`: фиксированные access/content фазы; :267 сохраняет тело для proxy; :332 ограничивает статику GET/HEAD.
- `src/server/vars.zig:224`: query lookup без percent/plus decoding; :233 — только чтение cookie.
- `src/server/conn.zig:526`: storeBody возвращает управление до проверки лимита, если body_store=false.
- `config.toml:27`: существующий health route; отдельная функция проверки зависимостей отсутствует.

## Проверки

- Исходная версия: `zig build test` — 57/57.
- После интеграции актуального main: `zig build test` — 74/76, два TLS-теста пропущены в сборке без TLS; та же suite с TLS/HTTP build flags — 76/76.
- `zig build test-features` — 193 HTTP assertions, включая malformed input, expiration/issuer/audience/algorithm rejection, scope denial, CORS, gzip cache validators, chunked body cap и JWT secret rotation.
- `HTTP_FEATURES_TLS=1 ... zig build test-features -Dtls=true ...` — те же 193 проверки; настроенные маршруты запрашиваются по HTTPS.
- `tests/error-pages.py`, `config_e2e.py`, `logging_e2e.py`, `gateway_e2e.py` — PASS.
- `tests/request-storage.py` — PASS: пул памяти, partial/pipelined headers, лимиты, drain и backpressure.
- `tests/tls-io.py` — PASS для TLS 1.2, TLS 1.3 и KeyUpdate.
- `tests/protocols.py` после интеграции `44b0fef` — PASS: HTTP/1.1, HTTP/2, HTTP/3, multiplexing, uploads, proxy, limits, loss/reordering/duplicates, reload и shutdown. Ранее на исходной базе `fb3f377` воспроизводился timeout H3; с исправлениями из актуального main он больше не воспроизводится.

Для локального TLS-прогона использован OpenSSL 3.6.4 из `/opt/homebrew/opt/openssl@3`; nghttp2/nghttp3 собраны из закреплённых в репозитории исходников с проверкой SHA256.

## Интерфейс и ограничения

См. [Native HTTP applications and server policies](http-application.md): настройки TOML, подключение Zig callbacks, lifecycle, размеры буферов и точная семантика replay.
Новые политики включаются явно; старые nginx-директивы auth_basic/auth_request/limit_req/gzip остаются unsupported. Идемпотентность бизнес-транзакции после сбоя требует сохранения ключа в одной транзакции с прикладным изменением.
