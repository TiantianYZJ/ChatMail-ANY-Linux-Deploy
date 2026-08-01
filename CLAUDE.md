# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Development setup
```bash
scripts/initenv.sh          # Create venv, install chatmaild + cmdeploy + docs deps
. venv/bin/activate         # Activate the venv
```

### Lint & format (Ruff)
```bash
cmdeploy fmt                # Auto-fix formatting and lint issues
cmdeploy fmt -c             # Check-only (diff mode)
# Or equivalently via tox:
cd chatmaild && tox -e lint
```

### Tests
```bash
# chatmaild offline tests (uses tox, runs in isolated env)
cd chatmaild && tox                     # full test suite
cd chatmaild && tox -- -k test_name     # single test by keyword

# cmdeploy offline tests
pytest --pyargs cmdeploy -n4            # parallel, all tests
pytest --pyargs cmdeploy -k test_name   # single test

# cmdeploy online tests (against a deployed server)
pytest --pyargs cmdeploy.tests.online   # requires CHATMAIL_INI + CHATMAIL_SSH
```

### Deploy & manage
```bash
# Initialize config for a domain
cmdeploy init <domain>

# Deploy to remote server (reads chatmail.ini)
cmdeploy run --ssh-host <host>

# Check DNS records
cmdeploy dns

# Server status
cmdeploy status

# Run benchmarks against online instance
cmdeploy bench
```

### Documentation (Sphinx)
```bash
cd doc && make html          # Build static HTML docs
cd doc && make auto          # Dev server with autoreload on 127.0.0.1:8000
```

### Release process
```bash
git cliff --unreleased --tag <version> --prepend CHANGELOG.md
# Commit with: chore(release): prepare for <version>
git tag --annotate <version>
git push origin <version>
gh release create <version>
```

## Project structure

The repo contains **two Python packages** and supporting files for running chatmail relay servers (MTAs for end-to-end encrypted email, focusing on Delta Chat).

### `chatmaild/` — Core relay services

Python package providing the server-side services:
- **`config.py`** — INI-based configuration, parses chatmail.ini with all tuning knobs (rate limits, mailbox sizes, TLS modes, resource thresholds)
- **`doveauth.py`** — Dovecot authentication (entry point: `doveauth`)
- **`newemail.py`** — CGI script for account creation
- **`expire.py`** — Mail expiration and mailbox quota management (entry points: `chatmail-expire`, `chatmail-quota-expire`)
- **`notifier.py`** — Push notification service for device tokens (Apple/Google/Huawei via `notifications.delta.chat`)
- **`metadata.py`** — Metadata inspection (entry point: `chatmail-metadata`)
- **`user.py`** — User/maildir abstraction
- **`filedict.py`** / **`dictproxy.py`** — Persistent dictionary and proxy helpers
- **`fsreport.py`** — Filesystem reporting (entry point: `chatmail-fsreport`)
- **`syslimits.py`** — System resource checks (load, memory, disk) before accepting new addresses
- **`lastlogin.py`** — Track last login timestamps
- **`migrate_db.py`** — SQLite-to-maildir migration
- **`ini/chatmail.ini.f`** — Template for chatmail.ini configuration file
- **`tests/`** — pytest test suite with `plugin.py` fixtures (provides `make_config`, `gencreds`, `maildata`, `example_config`)

### `cmdeploy/` — Deployment tool

Provisioning tool built on [pyinfra](https://pyinfra.com/) that deploys chatmail services via SSH:
- **`cmdeploy.py`** — CLI entry point with subcommands: `init`, `run`, `dns`, `status`, `test`, `fmt`, `bench`, `webdev`
- **`deployers.py`** — orchestrates all service deployers, builds `chatmaild` wheel
- **`basedeploy.py`** — base `Deployer` class, systemd helpers, policy-rc.d
- **`run.py`** — pyinfra deployment script entry point
- **`sshexec.py`** — SSH/local execution abstraction
- **`dns.py`** — DNS record checking and zone file generation
- **`www.py`** — Static web page builder (renders markdown pages)
- **`genqr.py`** — QR code generation for dclogin URLs
- **Deployers** (one per service, in own directories):
  - `dovecot/deployer.py`, `postfix/deployer.py`, `nginx/deployer.py`
  - `opendkim/deployer.py`, `acmetool/` (Let's Encrypt)
  - `filtermail/deployer.py`, `external/deployer.py`
  - `selfsigned/deployer.py`, `mtail/deployer.py`
- **`remote/`** — remote shell helpers (`rshell.py`, `rdns.py`)
- **`tests/`** — pytest suite with offline unit tests and `tests/online/` for integration tests against deployed servers

### `www/` — Static website

Rendered markdown pages (`index.md`, `info.md`, `privacy.md`) with CSS and JS (QR code, dclogin URL generation).

### `doc/` — Sphinx documentation

Built from `doc/source/` with `make html` or `make auto`.

## Configuration

All server tuning lives in `chatmail.ini` (template at `chatmaild/src/chatmaild/ini/chatmail.ini.f`). Key settings:
- `mail_domain` — the domain (or IPv4 address for no-DNS setups)
- Resource limits: `max_load_1m`, `min_available_memory`, `min_free_disk_space`, `max_imap_connections`, `max_smtp_connections`
- Address policy: `username_min_length`, `username_max_length`, `password_min_length`
- Mail lifecycle: `delete_mails_after`, `delete_large_after`, `delete_inactive_users_after`, `max_mailbox_size`, `max_message_size`
- TLS modes: automatic (self-signed for `_`-prefix domains, ACME otherwise) or `tls_external_cert_and_key` for custom certs
- `iroh_relay` — built-in P2P relay (default) or external

## TLS modes

The config `mail_domain` value determines TLS setup:
1. **Self-signed** — domain starts with `_` or is an IPv4 address
2. **ACME** — default for normal domains, uses built-in acmetool + Let's Encrypt
3. **External** — `tls_external_cert_and_key` set in ini

When self-signed, generated accounts include a `dclogin:` URL with `ic=3` (AcceptInvalidCertificates).

## Commit conventions

[Conventional Commits](https://www.conventionalcommits.org/) — changelog generated with [git-cliff](https://git-cliff.org/). Types used: `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `chore`, `ci`, `revert`. Breaking changes marked with `!` or `BREAKING CHANGE` footer.
