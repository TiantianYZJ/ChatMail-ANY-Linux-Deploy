# Pitfalls — Field-Deployed Issues & Fixes

Every issue encountered while deploying ChatMail Relay on a non-Debian Linux (Alibaba Cloud Linux 3, RHEL 8 based). Each entry: **Symptom → Root cause → Fix**.

## 1. `/new` broken: `python3\r: No such file or directory`

**Symptom**: `POST /new` returns 502 / empty CGI reply. Container log shows:

```
/usr/bin/env: 'python3\r': No such file or directory
```

**Root cause**: Files edited on Windows carry CRLF line endings. The CGI script's shebang became `#!/usr/bin/env python3\r`; the `\r` makes `env` fail to find the interpreter.

**Fix** (after every container rebuild, since the image's entrypoint re-copies the script):

```bash
docker exec chatmail sed -i '1s/\r$//' /usr/lib/cgi-bin/newemail.py
```

**Prevention**: keep `.py` files in LF. The entrypoint `sed` should strip CR and fix the shebang in one step:
`sed -i '1s|#!/usr/local/lib/chatmaild/venv/bin/python3|#!/usr/bin/env python3|; 1s/\r$//'`

## 2. Container can't see host Unix sockets: `/run` tmpfs

**Symptom**: IMAP/SMTP login fails with `Temporary authentication failure`. Inside the container, `/run/doveauth` shows as:

```
tmpfs on /run/doveauth type tmpfs (rw,nosuid,nodev,mode=755)
```

**Root cause**: `/run` is a tmpfs inside containers, and host systemd services manage their runtime dirs via `RuntimeDirectory=`, which Docker bind-mounts can't reliably share. The socket created by the host service never appears inside the container.

**Fix**: move the socket directories from `/run` to `/home/vmail/run` (real disk, bind-mounted `rw`):

- Update the 3 systemd service files (`doveauth`, `chatmail-metadata`, `lastlogin`) — `ExecStart` socket path, and **delete** the `RuntimeDirectory=` line.
- Update dovecot configs (`/etc/dovecot/auth.conf`, `/etc/dovecot/dovecot.conf`) to point at the new paths.
- `systemctl daemon-reload && systemctl restart doveauth chatmail-metadata lastlogin`
- Recreate the container; `/home/vmail` is already mounted `rw`.

## 3. Container nginx bind fails: `Address already in use` on 80/443

**Symptom**: Container restarts in a loop, nginx `bind() to 0.0.0.0:443 failed (98: Address already in use)`.

**Root cause**: the deploy `docker run` mounted `-v /etc/nginx/nginx.conf:/etc/nginx/nginx.conf:ro`. On a host with its own nginx (e.g. BT-Panel), this **overwrote** the container's config with the host's, so the container nginx tried to bind 80/443.

**Fix**: remove that mount. The container image ships its own internal-only nginx config listening on `127.0.0.1:10234`. Host nginx (if any) proxies `/new` etc. to that port.

## 4. Docker build fails: `Temporary failure resolving`

**Symptom**: `apt-get update` inside the image build can't resolve mirrors (`Temporary failure resolving 'mirrors.aliyun.com'`).

**Root cause**: Docker daemon defaults to the host's `/etc/resolv.conf`; if that points at a localhost resolver or an unreachable DNS, builds fail. Also Docker Hub pulls are slow/unreachable in mainland China.

**Fix**: configure `/etc/docker/daemon.json` with public DNS and a registry mirror, then restart Docker:

```json
{
  "dns": ["223.5.5.5", "223.6.6.6", "8.8.8.8"],
  "registry-mirrors": ["https://docker.m.daocloud.io"]
}
```

```bash
systemctl restart docker
```

## 5. Host doveauth crash-loops: `ModuleNotFoundError: chatmaild`

**Symptom**: `doveauth.service` restarts ~every 30s, log shows `ModuleNotFoundError: No module named 'chatmaild'`; restart counter in the thousands.

**Root cause**: chatmaild was installed editable (`pip install -e`). The `.pth` file points at a source path that became invalid (e.g. repo moved/re-cloned), so the venv's python can't import `chatmaild`.

**Fix**: reinstall non-editable:

```bash
/usr/local/lib/chatmaild/venv/bin/pip install --force-reinstall /root/ChatMail/chatmaild
systemctl restart doveauth
```

## 6. `chatmail-metadata` crash-loops: maildir missing

**Symptom**: `chatmail-metadata.service` fails repeatedly; log shows `ERROR:root:vmail dir does not exist: PosixPath('/home/vmail/mail/<domain>')`.

**Root cause**: the metadata service requires the mailboxes base directory to exist before it can start.

**Fix**:

```bash
mkdir -p /home/vmail/mail/<domain>
chown vmail:vmail /home/vmail/mail/<domain>
systemctl restart chatmail-metadata
```

## 7. Cert valid but client still fails: SANs / DNS propagation / security group

**Symptom**: Delta Chat can't connect even though a Let's Encrypt cert was issued. Three possible causes:

**a) Cert missing `imap`/`smtp` SANs.** Delta Chat probes `imap.<domain>` and `smtp.<domain>`; hostname mismatch → refused.

```
certbot certonly --standalone \
  -d <domain> -d www.<domain> -d mta-sts.<domain> \
  -d imap.<domain> -d smtp.<domain> --email you@example.com --agree-tos
```

**b) DNS not propagated.** Let's Encrypt's validation server resolves through a different DNS path than your local machine.

```bash
dig @8.8.8.8 imap.<domain> +short
```

**c) Security group / firewall.** The cloud's security group is a separate layer from the host's `firewalld`. Verify from *outside*:

```powershell
# Windows PowerShell, from your local machine
Test-NetConnection imap.<domain> -Port 993
```

## 8. Socket path duplicated after repeated sed

**Symptom**: a service fails with `FileNotFoundError`; inspecting `ExecStart` shows a doubled path like `/home/vmail/home/vmail/run/...`.

**Root cause**: running the path-replacement `sed` twice concatenates the prefix.

**Fix**:

```bash
sed -i 's|/home/vmail/home/vmail/run|/home/vmail/run|g' /etc/systemd/system/lastlogin.service
systemctl daemon-reload && systemctl restart lastlogin
```

## 9. Editable venv `python3` is a dangling symlink inside the container

**Symptom**: `docker exec chatmail .../venv/bin/python3` → `no such file or directory`, but `ls` shows it exists.

**Root cause**: the host venv's `python3` is a symlink to `/usr/local/bin/python3` (host path). Inside the container that target doesn't exist.

**Fix**: don't rely on the host venv's interpreter inside the container. Install `chatmaild` into the image (Dockerfile `pip install --break-system-packages /tmp/chatmaild`) and fix the CGI shebang to `#!/usr/bin/env python3` (see #1).

## 10. EPEL conflict on Alibaba Cloud: `epel-aliyuncs-release` vs `epel-release`

**Symptom**: `dnf install epel-release` fails with a conflict:

```
package epel-aliyuncs-release-8-15.1.al8.noarch conflicts with epel-release provided by epel-release-8-22.el8
```

**Root cause**: Alibaba Cloud Linux ships its own EPEL variant (`epel-aliyuncs-release`) in the base repos. Installing standard `epel-release` collides with it.

**Fix**: detect the preinstalled variant before installing:

```bash
if rpm -q epel-aliyuncs-release &>/dev/null; then
    echo "Aliyun EPEL already present"
elif ! rpm -q epel-release &>/dev/null; then
    dnf install -y epel-release
fi
```

## 11. China network: custom Dovecot `.deb` downloads fail

**Symptom**: `docker/build.sh` can't download `dovecot-core_2.3.21+dfsg1-3_amd64.deb` from `download.delta.chat` or GitHub — connection timeouts.

**Root cause**: upstream hosts are slow/blocked from mainland China. The project's custom Dovecot `.deb` is also built for Debian Bookworm, which adds friction.

**Fix**: use the standard `dovecot-core dovecot-imapd dovecot-lmtpd` packages from Debian's own repo (via the Aliyun mirror) instead of the custom `.deb`. Functionally equivalent for this deployment.

## 12. `certbot` issues a second cert dir: `your-domain.com-0001`

**Symptom**: after re-issuing, the cert is saved to `/etc/letsencrypt/live/your-domain.com-0001/` instead of `.../your-domain.com/`.

**Root cause**: an existing cert already occupies `live/your-domain.com`; certbot creates a suffixed dir rather than overwriting.

**Fix**: point the symlinks at the actual live dir:

```bash
ls /etc/letsencrypt/live/                        # find the real dir
ln -sf /etc/letsencrypt/live/your-domain.com-0001/fullchain.pem /var/lib/acme/live/your-domain.com/fullchain
ln -sf /etc/letsencrypt/live/your-domain.com-0001/privkey.pem /var/lib/acme/live/your-domain.com/privkey
```

## 13. Cert path inside the container becomes a directory

**Symptom**: Dovecot fails with `ssl_cert: read(...) failed: Is a directory`, even though `ls` shows a symlink.

**Root cause**: repeated `ln -sf` operations and stale mount/link state turned the cert path into a directory. If the path (or its parent, e.g. `/etc/letsencrypt/live/your-domain.com`) is itself a symlink and also a Docker bind-mount source, Docker can mount it as an empty directory.

**Fix**: clean the bad entries inside the container and relink:

```bash
docker exec chatmail rm -rf /var/lib/acme/live/<domain>/fullchain /var/lib/acme/live/<domain>/privkey
docker exec chatmail ln -sf /etc/letsencrypt/live/<domain>/fullchain.pem /var/lib/acme/live/<domain>/fullchain
docker exec chatmail ln -sf /etc/letsencrypt/live/<domain>/privkey.pem /var/lib/acme/live/<domain>/privkey
docker exec chatmail dovecot
```

## 14. `docker restart` reverts container-internal fixes

**Symptom**: `/new` works, then after `docker restart chatmail` it breaks again with the same CRLF / missing-file error.

**Root cause**: the container image's `entrypoint.sh` re-copies `newemail.py` and re-applies the (old) shebang on every start. Manual in-container fixes are ephemeral.

**Fix**: fix the **image** (`entrypoint.sh` + source files in LF), then rebuild with `--no-cache`; otherwise re-apply the fix after every restart:

```bash
docker exec chatmail sed -i '1s/\r$//' /usr/lib/cgi-bin/newemail.py
```

## 15. BT-Panel (宝塔) environment specifics

- BT-Panel installs its **own nginx** (occupies 80/443), postfix (occupies 25), and other services. These collide with the container's ports.
- **Fix**: stop host `postfix`/`sendmail` (container handles 25); keep host nginx for the website and proxy ChatMail paths to `127.0.0.1:10234` via [chatmail-proxy.conf](../chatmail-proxy.conf).
- BT-Panel's site config also has **two layers of port control**: its own nginx `listen` + the OS firewall. Don't forget either.
- The `.well-known/acme-challenge` root in BT config may differ from `/var/www/html`; align it with the site `root` when using webroot mode.

## 16. Double firewall: cloud security group vs host `firewalld`

**Symptom**: everything works from the server itself (`curl 127.0.0.1:993`), but external clients time out.

**Root cause**: Alibaba Cloud's **security group** is a separate layer from the host's `firewalld`. Ports opened in one may not be open in the other.

**Fix**: open the same ports in BOTH the security group (ECS console → security group → inbound rules) and `firewalld`. Verify from *outside*:

```powershell
Test-NetConnection imap.your-domain.com -Port 993
```

## 17. `/etc/resolv.conf` locked with `chattr +i`

**Symptom**: deploying unbound fails: `echo > /etc/resolv.conf` → `Operation not permitted`, even as root.

**Root cause**: a previous deploy step set the immutable flag (`chattr +i`) to prevent `systemd-resolved`/`NetworkManager` from overwriting the file.

**Fix**:

```bash
chattr -i /etc/resolv.conf   # unlock before writing
echo "nameserver 127.0.0.1" > /etc/resolv.conf
chattr +i /etc/resolv.conf   # re-lock if desired
```

## 18. Image vs running container drift after code edits

**Symptom**: you fix a `Dockerfile`/`entrypoint.sh`, `docker restart chatmail`, but the container still behaves like the old version.

**Root cause**: **restarting a container does not rebuild it.** Docker reuses the old image unless you rebuild — and even `docker build` may serve cached layers for unchanged `RUN` steps.

**Fix**: when changing image content, force a clean rebuild:

```bash
docker rm -f chatmail
docker rmi chatmail/relay:latest 2>/dev/null
cd docker && bash build.sh          # uses --no-cache or fresh context
```

Verify what's actually inside the image before running it:

```bash
docker run --rm --entrypoint cat chatmail/relay:latest /etc/nginx/nginx.conf | grep listen
```

## 19. New-account creation fails: autoconfig not published

**Symptom**: Delta Chat reports "Cannot create account" / "Relay could not be added" when using `dcaccount:<domain>` or `add_transport_from_qr`, even though `/new` returns valid credentials.

**Root cause**: Delta Chat core does **not** hard-code IMAP/SMTP servers. `add_transport_from_qr("dcaccount:your-domain.com")` fetches an **autoconfig XML** to learn the servers/ports/encryption:

```
https://autoconfig.your-domain.com/config-v1.1.xml   ← core prefers this
https://your-domain.com/.well-known/autoconfig/mail/config-v1.1.xml
```

If neither is reachable, account setup fails. The XML itself is generated by `genconfig.py` into `/var/www/html/.well-known/autoconfig/mail/config-v1.1.xml`, but two things commonly break:

1. **`autoconfig.<domain>` subdomain has no DNS A record and no nginx server block** (the path core tries first).
2. The host nginx proxies `/.well-known/autoconfig/` to the container, whose nginx has no matching `location` (falls through to `try_files` → 404).

**Fix**:

```bash
# 1. DNS: add an A record
#    autoconfig  A  <server-ip>

# 2. Verify the XML exists on the host
ls /var/www/html/.well-known/autoconfig/mail/config-v1.1.xml

# 3. In host nginx, serve the static XML directly (NOT via container proxy):
#    location /.well-known/autoconfig/ { root /var/www/html; }
#    and add a top-level server block for autoconfig.<domain> (see
#    deploy/aliyun/chatmail-proxy.conf PART 2).

# 4. Test both URLs:
curl -s https://autoconfig.your-domain.com/config-v1.1.xml | head
curl -s https://your-domain.com/.well-known/autoconfig/mail/config-v1.1.xml | head
```

The XML template (`cmdeploy/src/cmdeploy/nginx/autoconfig.xml.j2`) advertises the main domain as the IMAP/SMTP host, so make sure the cert covers that host (see #7) — and keep `autoconfig.` out of the cert requirements (it does not need its own cert if you serve it over HTTP, or reuse the main-domain cert for HTTPS).

## 20. Nginx regex location shadows `.well-known` prefix locations

**Symptom**: the autoconfig / ACME / MTA-STS files exist under `/var/www/html/.well-known/...` and `location /.well-known/autoconfig/ { root /var/www/html; }` is present, yet requests return 404.

**Root cause**: nginx **regex locations** (`location ~ ...`) take priority over **prefix locations** (`location /...`). A catch-all like:

```nginx
location ~ \.well-known {
    allow all;
}
```

matches `.well-known` requests first and inherits the site's default `root` (e.g. `/www/wwwroot/<domain>`), so it looks for the files in the wrong directory → 404.

**Fix**: use the `^~` modifier on the prefix location to bypass regex matching (nginx: `^~` wins over regex):

```nginx
location ^~ /.well-known/autoconfig/ {
    root /var/www/html;
}
location ^~ /.well-known/mta-sts.txt {
    root /var/www/html;
}
```

Verify: `curl -s -o /dev/null -w "%{http_code}" https://<domain>/.well-known/autoconfig/mail/config-v1.1.xml` → 200.

## 21. Container Postfix won't start: host postfix holds port 25

**Symptom**: `docker logs chatmail` shows `WARNING: Postfix failed to start`; inside the container, `postfix start` reports:

```
postfix/master: fatal: bind 0.0.0.0 port 25: Address already in use
```

**Root cause**: a host-level postfix (from BT-Panel, an earlier install, or a leftover `master -w`) is still bound to port 25. The container's postfix can't grab it. `postfix check` passes (it only validates config), so this is easy to miss.

**Fix**: kill the stale host master and prevent it from auto-starting:

```bash
# find what holds 25
ss -tlnp | grep :25
# kill it (it's the leftover host master, NOT the container's)
kill <pid>
systemctl disable postfix 2>/dev/null; systemctl stop postfix 2>/dev/null
# then start the container's postfix
docker exec chatmail postfix start
```

**Prevention**: if you keep a host postfix/sendmail, disable it before starting the container (`systemctl disable --now postfix sendmail`). The container owns 25.

## 22. Outbound port 25 is hard-blocked by the cloud vendor (cannot be unblocked)

**Symptom**: external mail (to Gmail/163/QQ) stays `deferred` in the queue with:

```
connect to <mx>.google.com[IP]:25: Connection timed out
```

A raw TCP test to any remote port 25 hangs/returns nothing:

```bash
timeout 8 bash -c 'cat < /dev/null > /dev/tcp/126mx01.mxmail.netease.com/25 && echo OPEN || echo BLOCKED'
```

**Root cause**: Alibaba Cloud ECS (and most mainland-China vendors) **block outbound TCP 25 at the network layer by default** to fight spam. Their support explicitly states **nobody can unblock it** — it is not a security-group rule, and there is no escalation path (not even for enterprise accounts).

**Fix**: you cannot deliver external mail by direct MTA→MTA over 25. Use an SMTP relay that listens on 465/587/80 — e.g. **Aliyun DirectMail** (`smtpdm.aliyun.com`). See PITFALLS #23-#26 for the full relay setup. In-domain delivery (between two `@your-domain.com` accounts) is unaffected because it goes through local Dovecot LMTP, not port 25.

## 23. DirectMail relay: 465 implicit TLS drops after handshake — use port 80 STARTTLS

**Symptom**: `relayhost = [smtpdm.aliyun.com]:465` gives:

```
lost connection with smtpdm.aliyun.com[IP] while receiving the initial server greeting
```

even though `openssl s_client -connect smtpdm.aliyun.com:465` connects fine and the cert validates.

**Root cause**: DirectMail's implicit-TLS on 465 is unreliable for Postfix's client (it connects, but the server closes before sending the SMTP greeting). Their docs list ports **25 / 80 / 465**; port 80 + STARTTLS is the stable path (and 25 is blocked anyway, see #22).

**Fix**: use port 80 with STARTTLS, and drop the legacy `smtp_use_tls` (it conflicts with `smtp_tls_security_level`):

```bash
# in /etc/postfix/main.cf (host side, container reads it via ro mount)
postconf -e "relayhost = [smtpdm.aliyun.com]:80"
postconf -e "smtp_tls_security_level = encrypt"
# make sure there is NO active smtp_use_tls line
grep -v '^smtp_use_tls' /etc/postfix/main.cf > /tmp/mc && mv /tmp/mc /etc/postfix/main.cf
docker exec chatmail postfix reload
```

Verify by hand that port 80 speaks SMTP before blaming Postfix:

```bash
timeout 15 bash -c 'exec 3<>/dev/tcp/smtpdm.aliyun.com/80; echo -e "EHLO test\r\nQUIT\r" >&3; cat <&3' | head
# → 220 smtpdm.aliyun.com DirectMail Smtpd Server
```

## 24. `no mechanism available`: missing SASL plugins + Postfix chroot

**Symptom**: relay AUTH fails with:

```
SASL authentication failed; cannot authenticate to server smtpdm.aliyun.com: no mechanism available
```

even with correct `sasl_passwd` and `smtp_sasl_auth_enable = yes`.

**Root cause**: two things compound:

1. The container image ships only `libsasldb` in `/usr/lib/*/sasl2/` — no `libplain.so` / `liblogin.so`. So the Cyrus SASL client has nothing to offer.
2. Even after installing them, Postfix's `smtp` service runs **chrooted** (`smtp unix - - y - - smtp` in master.cf), so the plugins under `/usr/lib` are invisible inside the chroot.

**Fix**: install the plugins AND disable chroot for the smtp client service:

```bash
# 1. install plugins (inside container)
docker exec chatmail apt-get update -qq && docker exec chatmail apt-get install -y -qq libsasl2-modules

# 2. disable chroot for the smtp unix service (host /etc/postfix/master.cf)
sed -i 's|^smtp      unix  -       -       y|smtp      unix  -       -       n|' /etc/postfix/master.cf

# 3. allow PLAIN (STARTTLS protects it)
postconf -e "smtp_sasl_security_options = noanonymous"

docker exec chatmail postfix reload
```

**Note**: both the `apt-get` install and the `master.cf` edit are **ephemeral** — a container rebuild reverts them (see #18). Bake `libsasl2-modules` into the Dockerfile and ship the chroot-off `master.cf` if you want this to survive.

## 25. `smtp_generic_maps` must be `regexp:`, not `hash:`

**Symptom**: you add a rewrite rule with a regex key, but the sender is never rewritten and the relay still rejects it:

```bash
# /etc/postfix/generic
/^.+@your-domain\.cn$/ noreply@your-domain.cn
```

with `smtp_generic_maps = hash:/etc/postfix/generic` — `postmap -q "root@your-domain.cn"` returns nothing, and outbound mail keeps the original sender.

**Root cause**: a `hash:` table does **exact-key** lookups. The regex text `/^.+@your-domain\.cn$/` is treated as a literal key, never matched. Generic maps support regexes, but the table **type must be `regexp:`** (no `postmap` needed).

**Fix**:

```bash
postconf -e "smtp_generic_maps = regexp:/etc/postfix/generic"
docker exec chatmail postfix reload
```

## 26. Relay rejects with 436 "MAIL FROM" doesn't conform with authentication

**Symptom**: AUTH now succeeds, but the relay answers:

```
436 "MAIL FROM" doesn't conform with authentication [@sm060104]
(Auth Account:noreply@your-domain.cn|Mail Account:root@your-domain.cn)
```

**Root cause**: DirectMail only accepts messages whose **envelope sender (MAIL FROM) equals the authenticated account**. Your users send as `user@your-domain.cn`, which differs from the relay account → 436.

**Fix**: rewrite every outbound external sender to the relay account with a `regexp:` generic map (see #25):

```bash
# /etc/postfix/generic
/^.+@your-domain\.cn$/ noreply@your-domain.cn

postconf -e "smtp_generic_maps = regexp:/etc/postfix/generic"
docker exec chatmail postfix reload
```

Verify a full relay send now succeeds (`status=sent (250 Data Ok...)` in the log) and that the recipient's From header shows `noreply@your-domain.cn`. In-domain mail keeps its real sender (generic maps only apply to the smtp/relay transport).
