server {
    listen 80;
    listen [::]:80;
    server_name example.com www.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name example.com www.example.com;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    include snippets/options-ssl-nginx.conf;

    root /var/www/example.com/public;
    index index.html;
    client_max_body_size 20m;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff;

    location / {
        try_files $uri $uri/ @app;
    }

    location @app {
        include proxy_params;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 300s;
        proxy_pass http://app_backend;
    }

    location ^~ /static/ {
        alias /var/www/example.com/static/;
        expires 30d;
        access_log off;
    }

    location ~* \.(?:css|js|png|jpe?g|gif|ico|svg|woff2?)$ {
        expires max;
        log_not_found off;
    }

    location = /healthz {
        access_log off;
        return 200 "ok\n";
    }

    location /admin/ {
        allow 10.0.0.0/8;
        allow 192.168.0.0/16;
        deny all;
        proxy_pass http://127.0.0.1:8000/;
    }

    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
