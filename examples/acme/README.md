# ACME во всех режимах

Выберите `self.toml`, `nginx.toml`, `apache.toml`, `litespeed.toml` или
`caddy.toml`. Замените `example.com` и email в выбранном TOML и соответствующем
исходном конфиге своим доменом/контактом. Для OpenLiteSpeed домен указан в
`httpd_config.conf` в строке map.

Примеры используют Let's Encrypt **staging** и `accept_terms=false`, чтобы
запуск без настройки не выпускал сертификаты. После настройки явно задайте
`accept_terms=true`; для доверенного публичного сертификата удалите staging
`directory`. Домен должен разрешаться на этот сервер; TCP 80 нужен для HTTP-01,
TCP 443 — для HTTPS. Порт 80 зарезервирован для lego.

```sh
mise run build
mise exec -- zig-out/bin/zhttpd -t -c examples/acme/nginx.toml
mise exec -- zig-out/bin/zhttpd -c examples/acme/nginx.toml
```

Все примеры слушают один порт: запускайте один за раз. Сертификаты каждого
примера сохраняются в отдельном `.acme-MODE`. Соседние виртуальные хосты могут
использовать собственные ручные сертификаты; ACME управляет совпавшими хостами.

## Несколько доменов и wildcard через DNS-01

В `dns01/` находятся отдельные `self.toml`, `nginx.toml`, `apache.toml`,
`litespeed.toml`, `caddy.toml` с массивом `domains` и соответствующими нативными
конфигами. Каждый выпускает один сертификат для `example.com`, `*.example.com`
и `other.net`. Замените все имена, email и `dns_provider` своими значениями,
задайте `accept_terms=true`. Staging оставлен включённым.

Для Cloudflare передайте через окружение `CF_DNS_API_TOKEN_FILE` — абсолютный
путь к файлу токена с DNS:Edit и Zone:Read для обеих зон. Имена переменных
других провайдеров показывает `mise exec -- lego dnshelp --code PROVIDER`.
Секреты не записывайте в TOML репозитория.

```sh
mise exec -- zig-out/bin/zhttpd -t -c examples/acme/dns01/nginx.toml
mise exec -- zig-out/bin/zhttpd -c examples/acme/dns01/nginx.toml
```

DNS-01 не требует входящего TCP 80. Wildcard покрывает один уровень:
`www.example.com`, но не apex и не `a.b.example.com`. Apex включён в примеры
отдельно. Поля и правила выбора виртуальных хостов описаны в
[документации](../../docs/configuration.md#wildcard-и-dns-01).


## Отдельные сертификаты с разными DNS-провайдерами

В [sni/](sni/README.md) — пять полных примеров `[[acme.certificates]]`:
Cloudflare для первого SAN-набора, Route 53 для второго, отдельные env-файлы,
общий listener и выбор сертификата через SNI. Старые примеры выше продолжают
использовать один SAN-сертификат.
