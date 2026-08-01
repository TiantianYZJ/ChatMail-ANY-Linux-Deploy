[Unit]
Description=Chatmail dict proxy for IMAP METADATA

[Service]
ExecStart={execpath} /home/vmail/run/chatmail-metadata/metadata.socket {config_path}
Restart=always
RestartSec=5
User=vmail
UMask=0077

[Install]
WantedBy=multi-user.target
