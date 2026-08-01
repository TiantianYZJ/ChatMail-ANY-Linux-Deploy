FROM debian:12-slim

ARG VMAIL_UID=7000
ARG VMAIL_GID=7000

# Try Aliyun mirror first, fall back to official Debian
RUN if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update || ( \
        echo "Aliyun mirror failed, switching to deb.debian.org..." && \
        if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
            sed -i 's|mirrors.aliyun.com|deb.debian.org|g' /etc/apt/sources.list.d/debian.sources; \
        fi && \
        apt-get update \
    )

RUN apt-get install -y --no-install-recommends \
    dovecot-core dovecot-imapd dovecot-lmtpd dovecot-sieve \
    postfix \
    nginx libnginx-mod-stream \
    opendkim opendkim-tools \
    fcgiwrap \
    rsyslog \
    dns-root-data \
    ca-certificates curl \
    python3 python3-iniconfig python3-filelock python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g ${VMAIL_GID} vmail \
    && useradd -u ${VMAIL_UID} -g ${VMAIL_GID} -d /home/vmail -m -s /sbin/nologin vmail

# Install chatmaild into the image so the CGI newemail.py can import it
COPY chatmaild/pyproject.toml /tmp/chatmaild/pyproject.toml
COPY chatmaild/src/chatmaild/ /tmp/chatmaild/src/chatmaild/
RUN /usr/bin/python3 -m pip install --break-system-packages /tmp/chatmaild \
    && rm -rf /tmp/chatmaild

RUN rm -f /etc/nginx/sites-enabled/default
# We no longer need nginx-internal.py (nginx has a fixed internal-only config)
RUN rm -f /opt/nginx-internal.py 2>/dev/null || true

# CGI directory for newemail.py (copied from mounted venv at runtime)
RUN mkdir -p /usr/lib/cgi-bin /var/www/html

# Minimal nginx config: internal HTTP on 10234 only (host nginx handles public 80/443)
RUN rm -f /etc/nginx/nginx.conf && cat > /etc/nginx/nginx.conf <<'NGINX'
worker_processes auto;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log syslog:server=unix:/dev/log,facility=local7;
    sendfile on;
    tcp_nopush on;
    server_tokens off;

    server {
        listen 127.0.0.1:10234;
        root /var/www/html;
        index index.html index.htm;

        location /new {
            fastcgi_pass unix:/run/fcgiwrap.socket;
            include /etc/nginx/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME /usr/lib/cgi-bin/newemail.py;
        }
        location /cgi-bin/ {
            fastcgi_pass unix:/run/fcgiwrap.socket;
            include /etc/nginx/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME /usr/lib/cgi-bin/$fastcgi_script_name;
        }
        location /relay {
            proxy_pass http://127.0.0.1:3340;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }
        location /ping { proxy_pass http://127.0.0.1:3340; proxy_http_version 1.1; }
        location /generate_204 { proxy_pass http://127.0.0.1:3340; proxy_http_version 1.1; }
        location / {
            try_files $uri $uri/ =404;
        }
    }
}
NGINX

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 25 143 465 587 993 80 443

ENTRYPOINT ["/entrypoint.sh"]
