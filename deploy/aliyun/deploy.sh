#!/bin/bash
set -euo pipefail

# ============================================================
# ChatMail Relay — 阿里云 Linux 一键部署脚本
# ============================================================
# 用法:
#   sudo ./deploy.sh <mail_domain> [--email admin@example.com]
#
# 示例:
#   sudo ./deploy.sh chat.example.com --email admin@example.com
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---- 配置 ----
MAIL_DOMAIN="${1:-}"
ADMIN_EMAIL=""
CHATMAIL_INI="$REPO_DIR/chatmail.ini"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---- 参数解析 ----
if [ -z "$MAIL_DOMAIN" ]; then
    echo "用法: sudo $0 <mail_domain> [--email admin@example.com]"
    echo ""
    echo "  首次部署时，请提供邮件域名:"
    echo "    sudo $0 mychat.example.com --email admin@example.com"
    echo ""
    echo "  如果 chatmail.ini 已存在，只需运行:"
    echo "    sudo $0 mychat.example.com"
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email) ADMIN_EMAIL="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ============================================================
# Step 1: 系统初始化
# ============================================================
step_system_init() {
    info "Step 1/9: 系统初始化"

    # 检测架构
    ARCH="$(uname -m)"
    info "  Architecture: $ARCH"

    # 主机名设置
    hostnamectl set-hostname "$MAIL_DOMAIN" 2>/dev/null || true

    # 安装 EPEL（阿里云 Linux 可能已安装 aliyun 版本的 EPEL）
    if rpm -q epel-aliyuncs-release &>/dev/null; then
        info "  Aliyun EPEL already installed (epel-aliyuncs-release)"
    elif ! rpm -q epel-release &>/dev/null; then
        info "  Installing EPEL..."
        dnf install -y epel-release || {
            warn "  Standard EPEL failed, trying aliyun EPEL..."
            dnf install -y epel-aliyuncs-release 2>/dev/null || true
        }
    else
        info "  EPEL already installed"
    fi

    # 基础包
    info "  Installing system packages..."
    dnf install -y \
        curl rsync wget git \
        python3 python3-devel python3-pip python3-virtualenv \
        gcc \
        bind-utils \
        unbound \
        certbot \
        firewalld \
        device-mapper-persistent-data lvm2

    # 安装 Docker CE
    if ! command -v docker &>/dev/null; then
        info "  Installing Docker CE..."
        dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
        dnf install -y docker-ce docker-ce-cli containerd.io
        systemctl enable docker --now
    else
        info "  Docker already installed"
        systemctl enable docker --now 2>/dev/null || true
    fi

    # 创建 vmail 用户（固定 UID/GID）
    if ! id vmail &>/dev/null; then
        info "  Creating vmail user (UID 7000)..."
        groupadd -g 7000 vmail
        useradd -u 7000 -g 7000 -d /home/vmail -m -s /sbin/nologin vmail
    else
        info "  vmail user already exists"
    fi

    # 创建目录结构
    info "  Creating directory structure..."
    mkdir -p /home/vmail/mail
    chown vmail:vmail /home/vmail/mail

    mkdir -p \
        /usr/local/lib/chatmaild \
        /var/www/html \
        /etc/dkimkeys

    # socket 共享目录（用真实磁盘目录，避免 /run tmpfs 与 Docker 挂载冲突）
    mkdir -p /home/vmail/run/doveauth /home/vmail/run/chatmail-metadata \
        /home/vmail/run/chatmail-lastlogin /home/vmail/run/chatmail-turn
    chown vmail:vmail /home/vmail/run/doveauth /home/vmail/run/chatmail-metadata \
        /home/vmail/run/chatmail-lastlogin /home/vmail/run/chatmail-turn

    # SELinux 配置
    if command -v setenforce &>/dev/null; then
        SELINUX_ENFORCING=$(getenforce 2>/dev/null || echo "Disabled")
        if [ "$SELINUX_ENFORCING" = "Enforcing" ]; then
            warn "  SELinux is Enforcing, setting Permissive mode for Docker volumes"
            setenforce 0 || true
            sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
        fi
    fi

    # 确保宿主机 postfix/sendmail 已停止（容器内的 Postfix 负责端口）
    # 注意：宿主机 nginx 保留不动（由 chatmail-proxy.conf 代理转发）
    for svc in postfix sendmail; do
        if systemctl is-active "$svc" &>/dev/null 2>&1; then
            info "  Stopping host $svc (container handles these ports)..."
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        fi
    done

    # firewalld 放行端口
    info "  Configuring firewalld..."
    systemctl enable firewalld --now 2>/dev/null || true
    for PORT in 25 80 443 143 465 587 993 53; do
        firewall-cmd --permanent --add-port="${PORT}/tcp" 2>/dev/null || true
    done
    firewall-cmd --permanent --add-port=53/udp 2>/dev/null || true
    # iroh-relay 端口
    firewall-cmd --permanent --add-port=3340/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
}

# ============================================================
# Step 2: 生成 chatmail.ini
# ============================================================
step_create_config() {
    info "Step 2/9: 生成 chatmail.ini"

    if [ -f "$CHATMAIL_INI" ]; then
        info "  $CHATMAIL_INI already exists, skipping"
        return
    fi

    cat > "$CHATMAIL_INI" <<INIEOF
[params]

# mail domain (MUST be set to fully qualified chat mail domain)
mail_domain = ${MAIL_DOMAIN}

# email address for Let's Encrypt notifications
$( [ -n "$ADMIN_EMAIL" ] && echo "acme_email = ${ADMIN_EMAIL}" || echo "# acme_email =")

# restrictions on user addresses
username_min_length = 9
username_max_length = 9
password_min_length = 9

# mail lifecycle
max_mailbox_size = 500M
max_message_size = 31457280
delete_mails_after = 20
delete_large_after = 7
delete_inactive_users_after = 90

# rate limits
max_user_send_per_minute = 60
max_user_send_burst_size = 10

# system resource limits
max_load_1m = 5
min_available_memory = 200M
min_free_disk_space = 1G
max_imap_connections = 10000
max_smtp_connections = 1000

# privacy policy contacts (REQUIRED for production)
#privacy_postal = Your Street, City
#privacy_mail = privacy@${MAIL_DOMAIN}

# TLS — ACME mode via certbot
# acme_email must be set above for ACME to work.
INIEOF

    info "  Created $CHATMAIL_INI"
    warn "  !! Please edit $CHATMAIL_INI to set your privacy contacts and other settings"
}

# ============================================================
# Step 3: 构建 Docker 镜像
# ============================================================
step_build_docker() {
    info "Step 3/9: 构建 Docker 镜像"

    export DOCKER_BUILDKIT=1

    # 检查 Docker 是否运行
    if ! docker info &>/dev/null; then
        systemctl start docker
        sleep 2
    fi

    bash "$REPO_DIR/docker/build.sh"
}

# ============================================================
# Step 4: 设置 chatmaild Python 虚拟环境
# ============================================================
step_setup_venv() {
    info "Step 4/9: 设置 Python venv"

    VENV_DIR="/usr/local/lib/chatmaild/venv"
    if [ -d "$VENV_DIR" ]; then
        info "  venv already exists at $VENV_DIR"
    else
        python3 -m venv --upgrade-deps "$VENV_DIR"
    fi

    # 安装 chatmaild
    info "  Installing chatmaild package..."
    "$VENV_DIR/bin/pip" install -e "$REPO_DIR/chatmaild"

    # 复制 chatmail.ini
    cp "$CHATMAIL_INI" /usr/local/lib/chatmaild/chatmail.ini

    # 复制 newemail.py（editable 安装不复制到 site-packages，
    # 容器 entrypoint 会从 /usr/local/lib/chatmaild/ 找到它）
    cp "$REPO_DIR/chatmaild/src/chatmaild/newemail.py" /usr/local/lib/chatmaild/newemail.py
    chmod 755 /usr/local/lib/chatmaild/newemail.py

    # 复制 chatmaild 源码树到挂载目录（容器内 fcgiwrap 用系统 python3，
    # 通过 PYTHONPATH=/usr/local/lib/chatmaild/src 导入 chatmaild 包）
    rm -rf /usr/local/lib/chatmaild/src
    cp -r "$REPO_DIR/chatmaild/src/chatmaild" /usr/local/lib/chatmaild/src

    info "  venv installed at $VENV_DIR"
}

# ============================================================
# Step 5: 下载静态二进制文件
# ============================================================
step_download_binaries() {
    info "Step 5/9: 下载静态二进制文件"

    # filtermail
    if [ ! -f /usr/local/bin/filtermail ]; then
        info "  Downloading filtermail..."
        curl -fSL "https://github.com/chatmail/filtermail/releases/download/v0.7.4/filtermail-${ARCH}" \
            -o /usr/local/bin/filtermail
        chmod +x /usr/local/bin/filtermail
    else
        info "  filtermail already installed"
    fi

    # iroh-relay
    if [ ! -f /usr/local/bin/iroh-relay ]; then
        info "  Downloading iroh-relay..."
        IROH_URL="https://github.com/n0-computer/iroh/releases/download/v0.35.0"
        if [ "$ARCH" = "x86_64" ]; then
            curl -fSL "${IROH_URL}/iroh-relay-v0.35.0-x86_64-unknown-linux-musl.tar.gz" \
                -o /tmp/iroh-relay.tar.gz
        else
            curl -fSL "${IROH_URL}/iroh-relay-v0.35.0-aarch64-unknown-linux-musl.tar.gz" \
                -o /tmp/iroh-relay.tar.gz
        fi
        tar xzf /tmp/iroh-relay.tar.gz -C /tmp/ ./iroh-relay
        mv /tmp/iroh-relay /usr/local/bin/iroh-relay
        chmod +x /usr/local/bin/iroh-relay
        rm -f /tmp/iroh-relay.tar.gz
    else
        info "  iroh-relay already installed"
    fi

    # chatmail-turn
    if [ ! -f /usr/local/bin/chatmail-turn ]; then
        info "  Downloading chatmail-turn..."
        TURN_URL="https://github.com/chatmail/chatmail-turn/releases/download/v0.4"
        if [ "$ARCH" = "x86_64" ]; then
            curl -fSL "${TURN_URL}/chatmail-turn-x86_64-linux" -o /usr/local/bin/chatmail-turn
        else
            curl -fSL "${TURN_URL}/chatmail-turn-aarch64-linux" -o /usr/local/bin/chatmail-turn
        fi
        chmod +x /usr/local/bin/chatmail-turn
    else
        info "  chatmail-turn already installed"
    fi

    # mtail
    if [ ! -f /usr/local/bin/mtail ]; then
        info "  Downloading mtail..."
        if [ "$ARCH" = "x86_64" ]; then
            curl -fSL "https://github.com/google/mtail/releases/download/v3.0.8/mtail_3.0.8_linux_amd64.tar.gz" \
                -o /tmp/mtail.tar.gz
        else
            curl -fSL "https://github.com/google/mtail/releases/download/v3.0.8/mtail_3.0.8_linux_arm64.tar.gz" \
                -o /tmp/mtail.tar.gz
        fi
        gunzip -c /tmp/mtail.tar.gz | tar -xf - -C /tmp/ mtail
        mv /tmp/mtail /usr/local/bin/mtail
        chmod +x /usr/local/bin/mtail
        rm -f /tmp/mtail.tar.gz
    else
        info "  mtail already installed"
    fi
}

# ============================================================
# Step 6: 生成所有服务配置
# ============================================================
step_generate_configs() {
    info "Step 6/9: 生成服务配置文件"

    # 确保 Python 依赖（使用 chatmaild venv）
    /usr/local/lib/chatmaild/venv/bin/pip install jinja2 2>/dev/null || \
        pip3 install jinja2

    python3 "$SCRIPT_DIR/genconfig.py" "$CHATMAIL_INI" "$REPO_DIR/cmdeploy/src/cmdeploy"
}

# ============================================================
# Step 7: 配置 TLS 证书 (certbot)
# ============================================================
step_setup_certbot() {
    info "Step 7/9: 配置 TLS 证书"

    if [ -z "$ADMIN_EMAIL" ]; then
        warn "  No --email provided, skipping certbot setup"
        warn "  You can run it later: certbot certonly --webroot -w /var/www/html -d ${MAIL_DOMAIN} -d www.${MAIL_DOMAIN} -d mta-sts.${MAIL_DOMAIN}"
        return
    fi

    # 检查是否有现有证书
    if [ -d "/etc/letsencrypt/live/${MAIL_DOMAIN}" ]; then
        info "  Certificate already exists for ${MAIL_DOMAIN}"
    else
        info "  Obtaining Let's Encrypt certificate..."

        # 先启动 nginx 以响应 ACME 挑战
        # （如果容器未运行，临时启动 nginx）
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q chatmail; then
            warn "  Docker container not running, starting temporary nginx for certbot..."
            # 使用 host 的 nginx 或 python 临时 serve
            mkdir -p /var/www/html/.well-known/acme-challenge
        fi

        # 先停止容器 nginx 释放 80 端口（certbot standalone 需要）
        warn "  Freeing port 80 for certbot..."
        fuser -k 80/tcp 2>/dev/null || true
        sleep 2

        certbot certonly --standalone \
            -d "$MAIL_DOMAIN" \
            -d "www.${MAIL_DOMAIN}" \
            --email "$ADMIN_EMAIL" \
            --agree-tos \
            --non-interactive || {
            warn "  certbot failed (expected if DNS not configured yet)."
            warn "  You can run it manually after DNS is set up:"
            warn "    docker exec chatmail nginx -s stop 2>/dev/null"
            warn "    certbot certonly --standalone -d ${MAIL_DOMAIN} -d www.${MAIL_DOMAIN} --email ${ADMIN_EMAIL} --agree-tos"
        }

        # 重启容器 nginx
        docker exec chatmail nginx 2>/dev/null || true
    fi

    # 创建符号链接，使 config.py 中的 acmetool 路径指向 certbot 证书
    if [ -d "/etc/letsencrypt/live/${MAIL_DOMAIN}" ]; then
        mkdir -p /var/lib/acme/live
        ln -sf "/etc/letsencrypt/live/${MAIL_DOMAIN}/fullchain.pem" \
            "/var/lib/acme/live/${MAIL_DOMAIN}/fullchain" 2>/dev/null || true
        ln -sf "/etc/letsencrypt/live/${MAIL_DOMAIN}/privkey.pem" \
            "/var/lib/acme/live/${MAIL_DOMAIN}/privkey" 2>/dev/null || true
        info "  Certificate symlinks created"
    fi

    # 创建续期 hook
    mkdir -p /etc/letsencrypt/renewal-hooks/post
    cat > /etc/letsencrypt/renewal-hooks/post/chatmail-reload.sh <<'HOOK'
#!/bin/sh
/usr/bin/docker exec chatmail doveadm reload 2>/dev/null || true
/usr/bin/docker exec chatmail postfix reload 2>/dev/null || true
/usr/bin/docker exec chatmail nginx -s reload 2>/dev/null || true
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/post/chatmail-reload.sh

    # 设置自动续期 timer
    cat > /etc/systemd/system/certbot-renew.service <<'UNIT'
[Unit]
Description=Renew Let's Encrypt certificates

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --non-interactive
UNIT

    cat > /etc/systemd/system/certbot-renew.timer <<'UNIT'
[Unit]
Description=Daily renewal of Let's Encrypt certificates

[Timer]
OnCalendar=daily
RandomizedDelaySec=43200

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload
    systemctl enable certbot-renew.timer --now
    info "  certbot auto-renewal timer enabled"
}

# ============================================================
# Step 8: 配置 unbound DNS 解析器
# ============================================================
step_setup_unbound() {
    info "Step 8/9: 配置 unbound DNS 解析器"

    # 配置 unbound
    mkdir -p /etc/unbound/unbound.conf.d

    cat > /etc/unbound/unbound.conf.d/chatmail.conf <<'EOF'
# Managed by chatmail deploy
server:
  interface: 127.0.0.1
  do-ip6: no
  cache-max-negative-ttl: 0
  # Use Quad9 as fallback
  forward-zone:
    name: "."
    forward-addr: 9.9.9.9
EOF

    chattr -i /etc/resolv.conf 2>/dev/null || true
    # 配置系统使用本地 unbound
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    echo "nameserver 9.9.9.9" >> /etc/resolv.conf

    # 停止并屏蔽 systemd-resolved（如果存在）
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl mask systemd-resolved 2>/dev/null || true

    # 设置 /etc/resolv.conf 不可变防止被覆盖
    chattr +i /etc/resolv.conf 2>/dev/null || true

    systemctl enable unbound --now
    info "  unbound DNS resolver started"
}

# ============================================================
# Step 9: 启动所有服务
# ============================================================
step_start_services() {
    info "Step 9/9: 启动所有服务"

    local VENV_BIN="/usr/local/lib/chatmaild/venv/bin"

    # 1. 设置 chatmaild systemd 服务
    info "  Enabling chatmaild services..."
    for svc in doveauth chatmail-metadata lastlogin; do
        systemctl enable "$svc" --now 2>/dev/null || warn "  Failed to start $svc (may need manual setup)"
    done

    # 启动定时任务（expire/timer 不能带 --now）
    for svc in chatmail-expire.timer chatmail-fsreport.timer; do
        systemctl enable "$svc" 2>/dev/null || true
        systemctl start "$svc" 2>/dev/null || true
    done

    # 2. 启动 Docker 容器
    info "  Starting Docker container..."
    # 如果容器已存在，删除重建
    docker rm -f chatmail 2>/dev/null || true

    # 检查是否已有证书
    TLS_CERT_DIR="/etc/letsencrypt/live/${MAIL_DOMAIN}"
    if [ -d "$TLS_CERT_DIR" ]; then
        CERT_VOLUME="-v ${TLS_CERT_DIR}/fullchain.pem:${TLS_CERT_DIR}/fullchain.pem:ro"
        CERT_VOLUME="$CERT_VOLUME -v ${TLS_CERT_DIR}/privkey.pem:${TLS_CERT_DIR}/privkey.pem:ro"
        CERT_VOLUME="$CERT_VOLUME -v /etc/letsencrypt:/etc/letsencrypt:ro"
    else
        # 自签名证书路径（容器会自行生成）
        CERT_VOLUME=""
    fi

    # 注意：不能挂载 /etc/nginx/nginx.conf，否则会覆盖镜像内的内部配置。
    # socket 通过 /home/vmail/run 共享（/home/vmail 挂载为 rw），
    # 容器内 dovecot 直接读写该目录下的 socket。
    docker run -d \
        --name chatmail \
        --restart always \
        --network host \
        -e MAIL_DOMAIN="${MAIL_DOMAIN}" \
        -v /home/vmail:/home/vmail \
        -v /etc/dovecot:/etc/dovecot:ro \
        -v /etc/postfix:/etc/postfix:ro \
        -v /etc/opendkim.conf:/etc/opendkim.conf:ro \
        -v /etc/dkimkeys:/etc/dkimkeys:ro \
        -v /var/www/html:/var/www/html \
        -v /usr/local/lib/chatmaild:/usr/local/lib/chatmaild:ro \
        -v /var/spool/postfix/private:/var/spool/postfix/private \
        $CERT_VOLUME \
        -v /etc/mailname:/etc/mailname:ro \
        chatmail/relay:latest

    info "  Docker container started"

    # 3. 启动 iroh-relay
    info "  Setting up iroh-relay..."
    cp "$REPO_DIR/cmdeploy/src/cmdeploy/iroh-relay.toml" /etc/iroh-relay.toml

    cat > /etc/systemd/system/iroh-relay.service <<'UNIT'
[Unit]
Description=Iroh relay
After=docker.service

[Service]
ExecStart=/usr/local/bin/iroh-relay --config-path /etc/iroh-relay.toml
Restart=on-failure
RestartSec=5s
User=iroh
Group=iroh

[Install]
WantedBy=multi-user.target
UNIT

    # 创建 iroh 用户并启动
    id iroh &>/dev/null || useradd -r -s /sbin/nologin iroh
    systemctl enable iroh-relay --now 2>/dev/null || warn "  iroh-relay may need manual config"

    # 4. 设置 filtermail 服务
    info "  Setting up filtermail services..."

    FILTERMAIL_BIN="/usr/local/bin/filtermail"
    FILTERMAIL_CONFIG="/usr/local/lib/chatmaild/chatmail.ini"

    # outgoing
    cat > /etc/systemd/system/filtermail.service <<UNIT
[Unit]
Description=Chatmail outgoing Postfix before queue filter

[Service]
ExecStart=$FILTERMAIL_BIN $FILTERMAIL_CONFIG outgoing
Restart=always
RestartSec=30
User=vmail

[Install]
WantedBy=multi-user.target
UNIT

    # incoming
    cat > /etc/systemd/system/filtermail-incoming.service <<UNIT
[Unit]
Description=Chatmail incoming Postfix before queue filter

[Service]
ExecStart=$FILTERMAIL_BIN $FILTERMAIL_CONFIG incoming
Restart=always
RestartSec=30
User=vmail

[Install]
WantedBy=multi-user.target
UNIT

    # transport
    cat > /etc/systemd/system/filtermail-transport.service <<UNIT
[Unit]
Description=Chatmail transport service

[Service]
ExecStart=$FILTERMAIL_BIN $FILTERMAIL_CONFIG transport
Restart=always
RestartSec=30
User=vmail
LimitNOFILE=524288

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload

    # 验证服务状态
    info ""
    info "=== 服务状态 ==="
    docker ps --filter name=chatmail --format "  Docker: {{.Image}} {{.Status}}"
    systemctl is-active unbound --quiet && echo "  unbound: running" || echo "  unbound: NOT running"
    systemctl is-active docker --quiet && echo "  docker:  running" || echo "  docker:  NOT running"
}

# ============================================================
# Step 10: DNS 验证提示
# ============================================================
step_dns_info() {
    info ""
    info "=== DNS 配置指南 ==="
    info ""
    info "请在你的 DNS 管理面板中添加以下记录（将 ${MAIL_DOMAIN} 替换为你的域名）:"
    info ""
    info "  必需记录:"
    info "  ${MAIL_DOMAIN}.    A       <服务器公网 IP>"
    info "  ${MAIL_DOMAIN}.    MX 10   ${MAIL_DOMAIN}."
    info "  www.${MAIL_DOMAIN}. CNAME   ${MAIL_DOMAIN}."
    if [ -n "$ADMIN_EMAIL" ]; then
        info "  mta-sts.${MAIL_DOMAIN}. CNAME   ${MAIL_DOMAIN}."
    fi
    info ""
    info "  推荐记录:"
    info "  ${MAIL_DOMAIN}.    TXT     \"v=spf1 a ~all\""
    info "  _dmarc.${MAIL_DOMAIN}. TXT  \"v=DMARC1;p=reject;adkim=s;aspf=s\""
    info "  _submissions._tcp.${MAIL_DOMAIN}. SRV 0 1 465 ${MAIL_DOMAIN}."
    info "  _imaps._tcp.${MAIL_DOMAIN}. SRV 0 1 993 ${MAIL_DOMAIN}."
    info ""
    info "  测试命令:"
    info "  dig A ${MAIL_DOMAIN} +short"
    info "  dig MX ${MAIL_DOMAIN} +short"
    info "  dig TXT _dmarc.${MAIL_DOMAIN} +short"
    info ""
    info "部署完成！请配置 DNS 后测试邮件收发。"
}

# ============================================================
# Main
# ============================================================
info "=========================================="
info "ChatMail Relay 部署到阿里云 Linux"
info "域名: ${MAIL_DOMAIN}"
info "=========================================="
info ""

step_system_init
step_create_config
step_build_docker
step_setup_venv
step_download_binaries
step_generate_configs
step_setup_certbot
step_setup_unbound
step_start_services
step_dns_info

info ""
info "部署完成！"
info ""
info ""
info "=== 宿主机 Nginx 代理配置 ==="
info "由于你使用宿主机 nginx 处理 80/443 端口，需要将以下配置"
info "添加到你的 nginx 网站配置中："
info ""
info "  配置文件位置: $SCRIPT_DIR/chatmail-proxy.conf"
info "  宝塔面板: 网站 → 设置 → 配置文件，粘贴文件内容"
info "  手动 nginx: 复制文件到 /etc/nginx/conf.d/chatmail-proxy.conf"
info "  然后执行: nginx -t && nginx -s reload"
info ""

info "后续步骤:"
info "  1. 编辑 ${CHATMAIL_INI} 完善配置"
info "  2. 配置 DNS 记录"
info "  3. 使用 Delta Chat 客户端测试"
info ""
