#!/bin/bash

MAIL_DOMAIN="${MAIL_DOMAIN:-yzjtiantian.cn}"

# Socket shared directories live under /home/vmail/run (bind-mounted from host).
# They must already exist on the host; ensure they're present inside the container too.
mkdir -p /home/vmail/run/doveauth /home/vmail/run/chatmail-metadata \
    /home/vmail/run/chatmail-lastlogin /home/vmail/run/chatmail-turn
chown vmail:vmail /home/vmail/run/doveauth /home/vmail/run/chatmail-metadata \
    /home/vmail/run/chatmail-lastlogin /home/vmail/run/chatmail-turn 2>/dev/null || true

mkdir -p /var/spool/postfix/private
chown postfix:postfix /var/spool/postfix/private 2>/dev/null || true

mkdir -p /run/opendkim /var/spool/postfix/opendkim
chown opendkim:opendkim /run/opendkim /var/spool/postfix/opendkim 2>/dev/null || true

# Start rsyslog once
if command -v rsyslogd &>/dev/null; then
    if [ ! -f /run/rsyslogd.pid ] || ! kill -0 "$(cat /run/rsyslogd.pid 2>/dev/null)" 2>/dev/null; then
        rsyslogd -i /run/rsyslogd.pid 2>/dev/null || rsyslogd 2>/dev/null || true
    fi
fi

# --- TLS Certificate Setup ---
CERT_FILE=""
for f in \
    /etc/letsencrypt/live/${MAIL_DOMAIN}/fullchain.pem \
    /var/lib/acme/live/${MAIL_DOMAIN}/fullchain \
    /etc/ssl/certs/mailserver.pem; do
    if [ -f "$f" ]; then
        CERT_FILE="$f"
        echo "Using TLS certificate: $f"
        break
    fi
done

if [ -z "$CERT_FILE" ]; then
    echo "No TLS certificate found, generating self-signed cert..."
    KEY_FILE="/etc/ssl/private/mailserver.key"
    CERT_FILE="/etc/ssl/certs/mailserver.pem"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
        -days 3650 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -subj "/CN=${MAIL_DOMAIN}" \
        -addext "subjectAltName=DNS:${MAIL_DOMAIN},DNS:www.${MAIL_DOMAIN},DNS:mta-sts.${MAIL_DOMAIN}" \
        2>&1
    if [ -f "$CERT_FILE" ]; then
        echo "Self-signed cert generated: $CERT_FILE"
    else
        echo "ERROR: Failed to generate self-signed certificate!"
    fi
fi

if [ ! -f /var/lib/acme/live/${MAIL_DOMAIN}/fullchain ]; then
    mkdir -p /var/lib/acme/live/${MAIL_DOMAIN}
    if [ -f /etc/letsencrypt/live/${MAIL_DOMAIN}/fullchain.pem ]; then
        ln -sf /etc/letsencrypt/live/${MAIL_DOMAIN}/fullchain.pem /var/lib/acme/live/${MAIL_DOMAIN}/fullchain 2>/dev/null || true
        ln -sf /etc/letsencrypt/live/${MAIL_DOMAIN}/privkey.pem /var/lib/acme/live/${MAIL_DOMAIN}/privkey 2>/dev/null || true
    elif [ -f /etc/ssl/certs/mailserver.pem ]; then
        ln -sf /etc/ssl/certs/mailserver.pem /var/lib/acme/live/${MAIL_DOMAIN}/fullchain 2>/dev/null || true
        ln -sf /etc/ssl/private/mailserver.key /var/lib/acme/live/${MAIL_DOMAIN}/privkey 2>/dev/null || true
    fi
fi

# --- Install newemail.py into CGI dir (chatmaild is installed in the image) ---
NEWEMAIL_SRC="$(/usr/bin/python3 -c "import chatmaild.newemail as n; print(n.__file__)" 2>/dev/null)"
if [ -n "$NEWEMAIL_SRC" ] && [ -f "$NEWEMAIL_SRC" ]; then
    cp "$NEWEMAIL_SRC" /usr/lib/cgi-bin/newemail.py
    # Fix shebang: use container's own python3 (host venv path is broken in container).
    # Also strip any trailing CR from line 1 (CRLF source files break env shebangs).
    sed -i '1s|#!/usr/local/lib/chatmaild/venv/bin/python3|#!/usr/bin/env python3|; 1s/\r$//' /usr/lib/cgi-bin/newemail.py
    chmod 755 /usr/lib/cgi-bin/newemail.py
    echo "Installed newemail.py from $NEWEMAIL_SRC"
else
    echo "WARNING: newemail.py not found, /new will fail"
fi

# --- Start Services ---
opendkim -x /etc/opendkim.conf 2>/dev/null || echo "WARNING: OpenDKIM failed to start"
dovecot 2>/dev/null || echo "WARNING: Dovecot failed to start"

for i in $(seq 1 15); do
    if [ -S /var/spool/postfix/private/auth ]; then break; fi
    sleep 1
done

postfix start 2>/dev/null || echo "WARNING: Postfix failed to start"

# Start fcgiwrap
if command -v fcgiwrap &>/dev/null; then
    rm -f /run/fcgiwrap.socket
    fcgiwrap -s unix:/run/fcgiwrap.socket 2>/dev/null &
    sleep 2
    chmod 777 /run/fcgiwrap.socket 2>/dev/null || true
    echo "fcgiwrap started on /run/fcgiwrap.socket"
fi

# Start nginx on internal 127.0.0.1:10234 (host nginx proxies to this)
nginx 2>/dev/null || echo "WARNING: Nginx failed to start"

# Keep container alive
exec tail -f /dev/null
