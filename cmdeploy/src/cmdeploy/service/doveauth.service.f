[Unit]
Description=Chatmail dict authentication proxy for dovecot

[Service]
ExecStart={execpath} /home/vmail/run/doveauth/doveauth.socket {config_path}
Restart=always
RestartSec=30
User=vmail
UMask=0077

[Install]
WantedBy=multi-user.target
