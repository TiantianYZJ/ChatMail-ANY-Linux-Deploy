#!/usr/bin/env python3
"""
Generate all service config files from Jinja2 templates.
Usage: python3 genconfig.py /path/to/chatmail.ini /path/to/cmdeploy/src/cmdeploy
"""

import os
import sys
import shutil
from pathlib import Path

# Ensure chatmaild is importable
sys.path.insert(0, str(Path(__file__).resolve().parent / "chatmaild" / "src"))

from chatmaild.config import read_config, Config
from jinja2 import Environment, FileSystemLoader, BaseLoader


def ensure_dir(path):
    Path(path).mkdir(parents=True, exist_ok=True)


def render_file(env, template_name, dest_path, **kwargs):
    """Render a Jinja2 template and write to destination."""
    print(f"  Generating {dest_path}")
    template = env.get_template(template_name)
    content = template.render(**kwargs)
    ensure_dir(os.path.dirname(dest_path))
    with open(dest_path, "w") as f:
        f.write(content)


def render_binary(src_path, dest_path):
    """Copy a static file (not a template)."""
    ensure_dir(os.path.dirname(dest_path))
    shutil.copy2(src_path, dest_path)
    print(f"  Copying {dest_path}")


def main():
    if len(sys.argv) < 2:
        print("Usage: genconfig.py <chatmail.ini> [cmdeploy_src_dir]")
        sys.exit(1)

    inipath = Path(sys.argv[1])
    if not inipath.exists():
        print(f"Error: {inipath} not found")
        sys.exit(1)

    # cmdeploy source templates directory
    cmdeploy_src = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("cmdeploy/src/cmdeploy")
    if not cmdeploy_src.exists():
        print(f"Error: cmdeploy source dir {cmdeploy_src} not found")
        sys.exit(1)

    config = read_config(inipath)
    mail_domain = config.mail_domain_bare

    # Setup Jinja2 environment
    env = Environment(
        loader=FileSystemLoader(str(cmdeploy_src)),
        autoescape=False,
    )

    # =============================================
    # Dovecot config
    # =============================================
    print("[1/6] Generating Dovecot config...")
    dovecot_dest = "/etc/dovecot"
    ensure_dir(dovecot_dest)

    render_file(env, "dovecot/dovecot.conf.j2",
                f"{dovecot_dest}/dovecot.conf",
                config=config, debug=False,
                disable_ipv6=config.disable_ipv6)

    render_binary(
        str(cmdeploy_src / "dovecot/auth.conf"),
        f"{dovecot_dest}/auth.conf"
    )
    render_binary(
        str(cmdeploy_src / "dovecot/push_notification.lua"),
        f"{dovecot_dest}/push_notification.lua"
    )

    # Create systemd override directory
    ensure_dir("/etc/systemd/system/dovecot.service.d")
    with open("/etc/systemd/system/dovecot.service.d/10_restart.conf", "w") as f:
        f.write("[Service]\nRestart=always\nRestartSec=30\n")

    # =============================================
    # Postfix config
    # =============================================
    print("[2/6] Generating Postfix config...")
    postfix_dest = "/etc/postfix"
    ensure_dir(postfix_dest)

    render_file(env, "postfix/main.cf.j2",
                f"{postfix_dest}/main.cf",
                config=config, disable_ipv6=config.disable_ipv6)

    render_file(env, "postfix/master.cf.j2",
                f"{postfix_dest}/master.cf",
                debug=False, config=config)

    for fname in ["submission_header_cleanup", "lmtp_header_cleanup",
                  "smtp_tls_policy_map", "login_map"]:
        render_binary(
            str(cmdeploy_src / "postfix" / fname),
            f"{postfix_dest}/{fname}"
        )

    # Compile postmap
    os.system("postmap /etc/postfix/smtp_tls_policy_map 2>/dev/null")

    # Create systemd override
    ensure_dir("/etc/systemd/system/postfix@.service.d")
    with open("/etc/systemd/system/postfix@.service.d/10_restart.conf", "w") as f:
        f.write("[Service]\nRestart=always\nRestartSec=30\n")

    # =============================================
    # Nginx config
    # =============================================
    print("[3/6] Generating Nginx config...")
    render_file(env, "nginx/nginx.conf.j2",
                "/etc/nginx/nginx.conf",
                config=config, disable_ipv6=config.disable_ipv6)

    render_file(env, "nginx/autoconfig.xml.j2",
                "/var/www/html/.well-known/autoconfig/mail/config-v1.1.xml",
                config=config)

    render_file(env, "nginx/mta-sts.txt.j2",
                "/var/www/html/.well-known/mta-sts.txt",
                config=config)

    # =============================================
    # OpenDKIM config
    # =============================================
    print("[4/6] Generating OpenDKIM config...")
    dkim_selector = "opendkim"

    render_file(env, "opendkim/opendkim.conf",
                "/etc/opendkim.conf",
                config={"domain_name": mail_domain,
                        "opendkim_selector": dkim_selector})

    extra_templates = {
        "opendkim/KeyTable": "/etc/dkimkeys/KeyTable",
        "opendkim/SigningTable": "/etc/dkimkeys/SigningTable",
    }
    for src, dest in extra_templates.items():
        render_file(env, src, dest,
                    config={"domain_name": mail_domain,
                            "opendkim_selector": dkim_selector})

    # Create DKIM directory
    ensure_dir("/etc/dkimkeys")

    # =============================================
    # chatmaild systemd services
    # =============================================
    print("[5/6] Generating chatmaild systemd units...")
    remote_venv_dir = "/usr/local/lib/chatmaild/venv"
    remote_chatmail_inipath = "/usr/local/lib/chatmaild/chatmail.ini"

    for unit_name in [
        "doveauth",
        "chatmail-metadata",
        "lastlogin",
        "chatmail-expire",
        "chatmail-expire.timer",
        "chatmail-fsreport",
        "chatmail-fsreport.timer",
    ]:
        src_name = unit_name if "." in unit_name else f"{unit_name}.service"
        src_path = cmdeploy_src / "service" / f"{src_name}.f"
        if not src_path.exists():
            print(f"  WARNING: template not found: {src_path}")
            continue

        content = src_path.read_text().format(
            execpath=f"{remote_venv_dir}/bin/{unit_name.split('.')[0]}",
            config_path=remote_chatmail_inipath,
            remote_venv_dir=remote_venv_dir,
            mail_domain=mail_domain,
        )

        dest_name = unit_name if "." in unit_name else f"{unit_name}.service"
        dest_path = f"/etc/systemd/system/{dest_name}"
        with open(dest_path, "w") as f:
            f.write(content)
        print(f"  Generating {dest_path}")

    # =============================================
    # /etc/mailname
    # =============================================
    print("[6/6] Setting up /etc/mailname...")
    with open("/etc/mailname", "w") as f:
        f.write(f"{mail_domain}\n")

    # Create chatmaild config directory
    ensure_dir("/usr/local/lib/chatmaild")
    shutil.copy2(str(inipath), "/usr/local/lib/chatmaild/chatmail.ini")

    print()
    print("All config files generated successfully.")


if __name__ == "__main__":
    main()
