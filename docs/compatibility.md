# Адаптеры конфигурации

Адаптеры читают исходные настройки и строят общую HTTP-модель. Они не запускают
nginx/Apache/OpenLiteSpeed/Caddy и не загружают их плагины. Полной совместимости
со всеми директивами этих серверов нет. Apache, OpenLiteSpeed и Caddy отклоняют
неподдерживаемые директивы. nginx сохраняет исторический режим предупреждений;
`--strict` превращает неизвестные/игнорируемые директивы в ошибки.

## nginx

Поддержаны существующие маршрутизация, статические файлы, proxy, access rules,
rewrite, include, HTTP/2, QUIC listeners, TLS. Полный список: `zhttpd --directives`.
`fastcgi_pass HOST:PORT` или имя upstream, `fastcgi_param NAME VALUE [if_not_empty]`,
`fastcgi_index`, `fastcgi_read_timeout`, `fastcgi_intercept_errors` работают через
общий FastCGI-модуль. Unix FastCGI и `fastcgi_split_path_info` оставляют location
с безопасным ответом 502 и предупреждением.

Журналы: `log_format`, `access_log`, `error_log`; наследование http/server/location;
несколько access-файлов, уровни ошибок, `escape=default|json|none`, USR1.
Условные, буферизованные, сжатые и syslog access-журналы отклоняются.

```nginx
error_log stderr warn;
events {}
http {
    log_format api escape=json '{"uri":"$request_uri","status":$status}';
    server {
        listen 8080;
        access_log /dev/stdout api;
        location / { return 200 "nginx adapter\n"; }
    }
}
```

## Apache HTTP Server

Поддержаны ServerRoot, Listen, VirtualHost, ServerName/Alias, DocumentRoot,
DirectoryIndex, ограниченные Directory/Location, Require all/ip, Options Indexes
и FollowSymLinks, AllowOverride None, ограничения тела/keep-alive, SSL и Protocols,
Include/IncludeOptional, ProxyPass с одним HTTP upstream, Alias.
`Directory` принимает `/` или DocumentRoot. `.htaccess`, модули авторизации,
RewriteRule и другие произвольные Apache-модули не исполняются.

Журналы: `LogFormat FORMAT NICKNAME`, `CustomLog FILE FORMAT|NICKNAME`,
`TransferLog FILE`, `ErrorLog FILE`, `LogLevel LEVEL`. Форматы common/combined
доступны без объявления. Поддерживаемые поля пользовательских форматов:
`%a`, `%h`, `%l`, `%u`, `%t`, `%r`, `%s`, `%>s`, `%b`, `%B`, `%m`, `%U`, `%H`,
`%v`, `%V`, `%p`, `%{Header}i`, `%{Header}o`, `%%`.
Условные поля/журналы, pipe, syslog и неизвестные поля отклоняются. DNS lookup
для `%h` не выполняется; `%l`/`%u` — `-` (аутентификация не реализована).
Значения экранируются общим безопасным текстовым форматом zhttpd; это не
побайтовая копия вывода Apache. `%b` и `%B` выводят числовой размер, включая 0.

```apache
Listen 127.0.0.1:8080
DocumentRoot "site"
LogFormat "%h %>s %r" requests
CustomLog /dev/stdout requests
ErrorLog /dev/stderr
LogLevel warn
<Directory "site">
    Require all granted
</Directory>
```

## OpenLiteSpeed

Принимается нативный `httpd_config.conf`: virtualhost/vhRoot/configFile,
listener/address/secure/map и отдельные vhost-файлы. В них поддержаны docRoot,
vhDomain/vhAliases, indexFiles/autoIndex, статические context, vhssl и TLS 1.2/1.3.
Работают `$SERVER_ROOT` и `$VH_ROOT`. Enterprise-конфиги в Apache-синтаксисе
нужно импортировать через режим `apache`.

Журналы `accesslog PATH { useServer 0; logFormat … }` и
`errorlog PATH { useServer 0; logLevel … }` поддерживаются на уровне сервера и
vhost. В настоящем файле поля разделяются переводами строк, а не `;`.
`useServer 1` сохраняет унаследованные настройки. Поля logFormat совпадают с
поддержанным набором Apache выше. Встроенная ротация, compressArchive, keepDays,
rollingSize и расширенные logHeaders не имитируются и вызывают ошибку.

## Caddy

Принимается Caddyfile: site blocks, http:// / https://, root, file_server
(browse/index), respond, redir, один reverse_proxy, литеральные header, handle
с точным путём или завершающей `*`, import файлов. TLS требует явных cert/key либо совпадения HTTPS-site с `[acme].domains` (или `domain`)
в TOML-обёртке.
Не поддерживаются Caddy JSON, API, placeholders, произвольные matchers/плагины
и автоматический HTTPS самого Caddy. Общий ACME-модуль zhttpd работает во всех
режимах через `[acme]` в TOML, включая Caddyfile и его import.

Журналы: site `log` с `output stdout|stderr|file PATH` и `format json`.
Записи используют **JSON-схему zhttpd**, описанную в configuration.md, а не полную
структуру Caddy. Параметры ротации, фильтры, log_append, форматы console и сетевые
writers отклоняются.

```caddyfile
http://localhost:8080 {
    root * site
    file_server
    log {
        output stdout
        format json
    }
}
```

Справочники исходных форматов:
[Apache logs](https://httpd.apache.org/docs/2.4/mod/mod_log_config.html),
[OpenLiteSpeed logs](https://docs.openlitespeed.org/config/logs/),
[Caddy log](https://caddyserver.com/docs/caddyfile/directives/log).

## Общий автоматический ACME

Для любого адаптера `[acme]` или `[[acme.certificates]]` в `config.toml` включает выпуск и обновление
через Let's Encrypt/lego. HTTP-01 поддерживает несколько доменов, DNS-01 —
также wildcard. Укажите HTTPS listener и имена управляемых доменов в исходном
формате; ручные certificate/key можно опустить. Общий SAN-сертификат либо отдельные SNI-сертификаты назначаются
совпавшим хостам. В одном виртуальном хосте можно использовать несколько
сертификатов; точное имя приоритетнее wildcard. У каждой записи свой DNS-провайдер,
`dns_env_file` и расписание продления. Каждый alias должен покрываться одним из
назначенных сертификатов. Остальные
виртуальные хосты используют свои сертификаты. Примеры и правила приоритета —
в [конфигурации ACME](configuration.md#автоматический-lets-encrypt).

### ACME и reload

Во всех режимах совместимости изменения доменов, SAN и отдельных сертификатов
Let's Encrypt применяются через `SIGHUP` / `-s reload` без перезапуска master.
Обновите TOML и нативные виртуальные хосты совместно. До завершения выпуска новых
сертификатов работает прежняя конфигурация; ошибка сохраняет её целиком.
Удалённые записи перестают участвовать в SNI и продлении, файлы остаются в кеше.
Порядок применения, повторный reload и ограничения HTTP-01 описаны в
[руководстве конфигурации](configuration.md#добавление-и-удаление-через-reload).

### Автоматическое применение изменений

`server.auto_reload` по умолчанию включён: изменения TOML, основного нативного
конфига, nginx/Apache include, OpenLiteSpeed configFile и Caddy import автоматически
запускают безопасный reload. Добавление/удаление glob-совпадений тоже отслеживается.
Прямой запуск нативного файла поддерживается. Ошибка сохраняет рабочую конфигурацию;
исправление конфигурационного файла вызывает следующую попытку.
[Настройки наблюдения](configuration.md#автоматический-reload).

Ручные сертификаты/ключи TLS, все ACME SNI-пары и `dns_env_file` входят в тот же
список наблюдения. Новая пара проверяется перед переключением workers; ошибка
сохраняет действующий HTTPS. Изменение DNS env-файла запускает проверку только
связанных сертификатов, с сохранением сроков остальных записей.
[Ротация TLS и credentials](configuration.md#сертификаты-ключи-и-dns-credentials).
