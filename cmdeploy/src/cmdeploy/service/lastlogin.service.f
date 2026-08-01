[Unit]
Description=Dict proxy for last-login tracking

[Service]
ExecStart={execpath} /home/vmail/run/chatmail-lastlogin/lastlogin.socket {config_path}
Restart=always
RestartSec=30
User=vmail

[Install]
WantedBy=multi-user.target
