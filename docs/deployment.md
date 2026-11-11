# Deployment

[Documentation index](../README.md#documentation)

## Build and run the container

The repository Dockerfile builds a ReleaseFast binary on Debian and runs plain
HTTP on container port 8080. TLS is disabled in this image.

```bash
docker build -t zhttpd:local .
docker run --rm --name zhttpd-local -p 127.0.0.1:8080:8080 zhttpd:local
```

In another terminal:

```bash
curl -i http://127.0.0.1:8080/
docker exec zhttpd-local zhttpd -t -c /etc/zhttpd/nginx.conf
docker stop zhttpd-local
```

The image includes:

| Path | Contents |
| --- | --- |
| `/usr/local/bin/zhttpd` | Server executable |
| `/etc/zhttpd/nginx.conf` | Configuration copied from `deploy/nginx.conf` |
| `/var/www/zhttpd/index.html` | Default landing page |
| `/var/lib/zhttpd/logs/` | Access/error logs and PID file |

The default config falls back to `/index.html` for missing paths. To serve real
404s and the branded error page, change its location to:

```nginx
location / {
    try_files $uri $uri/ =404;
}
```

## Supply your own config and content

Prepare an existing local `site.conf` and `public/` directory, then mount them:

```bash
docker run --rm --name zhttpd-local \
  -p 127.0.0.1:8080:8080 \
  -v "$PWD/site.conf:/etc/zhttpd/nginx.conf:ro" \
  -v "$PWD/public:/var/www/zhttpd:ro" \
  zhttpd:local
```

Use `listen 8080` and `root /var/www/zhttpd` in that config. Binding the server
inside the container only to `127.0.0.1` prevents the published port from reaching
it. The host-side port mapping above restricts access to local clients.

The bundled config writes logs into the container filesystem. Mount a writable
volume at `/var/lib/zhttpd/logs` when those logs must survive container removal.
For HTTPS, terminate TLS at an external proxy or build and configure a separate
[TLS-enabled zhttpd binary](getting-started.md#build-with-tls).

## Native process supervision

Run zhttpd in the foreground under your service manager. Supply absolute config
and prefix paths, create writable log/PID directories, and run as the intended
OS account: the nginx `user` directive does not switch users in this version.
Use the [signal commands](getting-started.md#process-lifecycle) for reload,
log reopening, and shutdown.

## Repository image publishing convention

The repository's deployment convention uses `ghcr.io/pyrlyn/zhttpd` and a
**manual** Coolify deployment: pull the branch, build the Dockerfile, push the
image, then deploy it. This repository has no GitHub Actions image-build workflow
and a Git push alone does not deploy an image.

| Source selected for deployment | Image tags |
| --- | --- |
| `dev` | `dev`, `dev-<short-sha>` |
| `main` | `prod`, `latest` |
| Release `vX.Y.Z` on main | `prod-X.Y.Z`, with `prod` and `latest` refreshed |

Development uses `dev` or a pinned `dev-<sha>`; production pins
`prod-<version>`. These are publishing conventions, not evidence that a
particular tag has already been published. The image source label points to
`https://github.com/pyrlyn/zhttpd`.
