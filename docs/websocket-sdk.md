# WebSocket server SDK

```sh
mise run examples
mise exec -- zig-out/bin/ws-echo-zig 127.0.0.1:8080
# Альтернативы с тем же поведением:
mise exec -- zig-out/bin/ws-echo-c 127.0.0.1:8080
mise exec -- zig-out/bin/ws-echo-cpp 127.0.0.1:8080
```

`mise run build:minimal` устанавливает `libzhttpd_websocket.a` и заголовки
`zhttpd_websocket.h`, `zhttpd_websocket.hpp` в zig-out/lib и zig-out/include.
Сборка примеров использует C/C++ toolchain Zig. Пример внешней компоновки:

```sh
mise exec -- zig cc -I zig-out/include examples/websocket/echo.c \
  zig-out/lib/libzhttpd_websocket.a -o ws-echo
```

Если SDK собран с TLS/HTTP2/HTTP3, при внешней C/C++ компоновке дополнительно
подключите libssl, libcrypto, libnghttp2, libnghttp3 той же сборки. Примеры
в build.zig делают это автоматически.

Для Zig подключите экспортированный build-модуль `websocket_sdk`; API:
`serve("127.0.0.1:8080", .{ .context = context, .on_message = callback })`,
`Peer.send(data, binary)`, `Peer.close(code)`, `stop()`.
Примеры исходного кода находятся в `examples/websocket`.

C ABI использует непрозрачный `zws_peer`, callbacks/context и функции
`zws_server_run`, `zws_send`, `zws_close`, `zws_stop`. C++ добавляет `Peer`,
`std::string_view` и `std::function`. Исключение C++ callback закрывает соединение
с кодом 1011. Код возврата run: 0 после остановки, -1 при ошибке запуска; send:
0 если данные поставлены в очередь, -1 при ошибке/переполнении.

Один активный сервер на процесс; вызов serve блокирующий. Callback выполняется
в потоке event loop. Peer и входные данные действуют только до возврата callback;
send копирует данные. Нельзя сохранять peer для асинхронного использования.
stop вызывается из callback или обработчика сигнала; произвольные вызовы из
других потоков не поддерживаются. Библиотека не устанавливает обработчики
сигналов за приложение; примеры делают это явно. SDK-listener использует обычный
HTTP/1.1; TLS доступен через HTTP runtime с собственной конфигурацией.

RFC 6455: handshake v13, masked client frames, text/binary, fragmentation,
ping/pong, close, проверка UTF-8, контрольных кадров и длин. Максимум сообщения
64 KiB, выходная очередь 128 KiB. Нет permessage-deflate, subprotocol negotiation,
HTTP/2/3 extended CONNECT. Нативный `websocket=true` выбирает echo-обработчик;
свою логику приложения подключают через SDK callbacks.

`tests/websocket_e2e.py` выполняет один общий набор проверок для нативного
сервера и всех трёх собранных примеров: handshake с pipelined первым кадром,
Unicode, binary 64 KiB, пустые/фрагментированные сообщения, ping во время
фрагментации, close, некорректные mask/UTF-8/continuation, параллельные клиенты.
Он входит в `mise run test:e2e`.
