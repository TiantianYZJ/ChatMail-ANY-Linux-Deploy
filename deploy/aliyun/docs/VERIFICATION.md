# Deployment Verification Checklist

Step-by-step checks to confirm a ChatMail relay is fully working after deployment. Run in order; each step isolates one layer.

## 1. Services running

```bash
# Docker container up
docker ps --filter name=chatmail --format "{{.Status}}"

# Host services (should be active (running), not auto-restart)
systemctl status doveauth chatmail-metadata lastlogin unbound --no-pager | grep -E "●|Active"

# No crash-loop restart counters in the thousands
systemctl show doveauth -p NRestarts
systemctl show chatmail-metadata -p NRestarts
systemctl show lastlogin -p NRestarts
```

> `NRestarts` climbing every few seconds = crash-loop (see PITFALLS #5, #6).

## 2. Host Unix sockets present (authentication bridge)

```bash
ls -la /home/vmail/run/doveauth/doveauth.socket
ls -la /home/vmail/run/chatmail-metadata/metadata.socket
ls -la /home/vmail/run/chatmail-lastlogin/lastlogin.socket
```

All three must exist as socket files (`srwx------`).

## 3. Container can see the sockets

```bash
docker exec chatmail ls -la /home/vmail/run/doveauth/ \
  /home/vmail/run/chatmail-metadata/ /home/vmail/run/chatmail-lastlogin/
```

> Empty output = sockets not shared (see PITFALLS #2).

## 4. Ports listening

```bash
ss -tln | grep -E ":(25|143|465|587|993)\b"
```

All five must appear (both `0.0.0.0` and `[::]`).

## 5. Container Nginx internal port

```bash
curl -X POST http://127.0.0.1:10234/new
```

Should return JSON: `{"email":"xxx@your-domain.com","password":"..."}`.

> `python3\r` or empty reply = CRLF shebang (see PITFALLS #1, #14).

## 6. TLS cert used by services

```bash
# What cert does Dovecot present?
docker exec chatmail openssl s_client -connect 127.0.0.1:993 2>/dev/null \
  | grep -E "subject=|issuer="

# Should show CN=your-domain.com and issuer=Let's Encrypt (not self-signed)
# SANs must include imap/smtp:
openssl x509 -in /etc/letsencrypt/live/your-domain.com/fullchain.pem -noout -text \
  | grep -A1 "Subject Alternative Name"
```

## 7. External reachability (from your machine, not the server)

```powershell
# Windows PowerShell
Test-NetConnection imap.your-domain.com -Port 993
Test-NetConnection smtp.your-domain.com -Port 465
Test-NetConnection your-domain.com -Port 25
```

> `TcpTestSucceeded: True` = network + security group + firewalld all open.
> Failure while localhost works = security group (see PITFALLS #16).

## 8. DNS from the internet

```bash
dig @8.8.8.8 your-domain.com +short        # A
dig @8.8.8.8 imap.your-domain.com +short   # A
dig @8.8.8.8 your-domain.com MX +short     # MX
```

## 9. Real login test (the ultimate check)

Create an account, then log in with Delta Chat ("I have an account already"):

| Field | Value |
|---|---|
| Email | `<username>@your-domain.com` |
| Password | from `/new` response |
| IMAP server | `imap.your-domain.com` |
| SMTP server | `smtp.your-domain.com` |

If login fails with `Temporary authentication failure`:

```bash
# doveauth should log the authentication attempt
journalctl -u doveauth --no-pager | tail -20
```

## 10. Send/receive a message

1. In Delta Chat, create a 1:1 chat with a friend (or a second test account).
2. Send a message — confirm it arrives.
3. Check server-side delivery:

```bash
# Mail queue should be empty (messages delivered)
docker exec chatmail postqueue -p
```

---

## Quick one-shot health check

```bash
echo "=== container ==="; docker ps --filter name=chatmail --format "{{.Status}}"
echo "=== sockets (host) ==="; ls /home/vmail/run/doveauth/ /home/vmail/run/chatmail-metadata/ /home/vmail/run/chatmail-lastlogin/ 2>/dev/null
echo "=== sockets (container) ==="; docker exec chatmail ls /home/vmail/run/doveauth/ 2>/dev/null
echo "=== ports ==="; for p in 25 143 465 587 993; do ss -tln "sport = :$p" | grep -q . && echo "  $p OK" || echo "  $p MISSING"; done
echo "=== /new ==="; curl -s -X POST http://127.0.0.1:10234/new
echo; echo "=== services ==="; systemctl is-active doveauth chatmail-metadata lastlogin unbound docker
```
