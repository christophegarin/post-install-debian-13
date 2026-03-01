#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

##############################################
# Global variables
##############################################

LOGFILE="/var/log/post-install.log"
SERVER_NAME="SRV-XXX-2601"

# SMTP / mail settings for msmtp (TLS/SSL)
ADMIN_EMAIL="admin@example.com"
SMTP_USER="smtp_user@example.com"
SMTP_PASS="myPasswordHere"
SMTP_SERVER="smtp.example.com"
SMTP_PORT="465"  # 465 possible for SSL

TIMEZONE="Europe/Paris"

NEWUSER="username"
SSH_KEY="ssh-key-here"
SSH_PASSWORD="myPasswordHere"

# SSH allowed IPs/subnets, or ("ALL") for no restriction
SSH_ALLOWED_IPS=("192.168.1.0/24" "X.X.X.X")

# IP whitelist for Fail2Ban & CrowdSec (bypass bans)
WHITELIST_IPS=("192.168.1.0/24" "X.X.X.X")

DISABLE_IPV6="yes"
INSTALL_DOKPLOY="no"
INSTALL_DOCKER="no"

CPU_THRESHOLD=90
CPU_DURATION=10
MEM_THRESHOLD=15
MEM_DURATION=10
CHECK_INTERVAL=60
WATCHDOG_MAX_ALERTS=3

DOCKER_ADMIN_PASS=""

##############################################
# Reconfigure mode detection
##############################################

RECONFIG_MODE="no"
if [[ "${1:-}" == "--reconfigure" ]]; then
    RECONFIG_MODE="yes"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Running in RECONFIGURE mode: only reapplying configuration" | tee -a "$LOGFILE"
fi

##############################################
# Logging
##############################################

mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1
log() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
error_log() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*"; sleep 1; }

send_mail() {
    local SUBJECT="$1"
    local BODY="$2"
    echo -e "$BODY" | msmtp "$ADMIN_EMAIL" || error_log "msmtp failed to send $SUBJECT"
}

##############################################
# Root check
##############################################

if [ "$EUID" -ne 0 ]; then
    error_log "Script must be run as root, attempting to continue..."
fi

log "Starting post-installation for $SERVER_NAME"

##############################################
# System update & packages
##############################################

if [[ "$RECONFIG_MODE" != "yes" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || error_log "apt-get update failed"
    apt-get upgrade -y || error_log "apt-get upgrade failed"
    apt-get autoremove -y || error_log "apt-get autoremove failed"
    apt-get install -y \
        curl sudo ufw fail2ban sysstat \
        unattended-upgrades apt-listchanges \
        rkhunter chkrootkit auditd cron openssl \
        locales console-setup keyboard-configuration \
        ca-certificates lsb-release gnupg || error_log "Package installation failed"
else
    log "Reconfigure mode: skipping package installation"
fi

##############################################
# Log rotation
##############################################

cat <<EOF > /etc/logrotate.d/post-install
$LOGFILE {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 640 root root
}
EOF

##############################################
# Unattended upgrades
##############################################

cat <<EOF > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins {
        "\${distro_id}:\${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

dpkg-reconfigure -f noninteractive unattended-upgrades || error_log "Unattended upgrades reconfigure failed"

##############################################
# Rootkit scan cron
##############################################

cat <<'EOF' > /etc/cron.daily/rootkit-scan
#!/usr/bin/env bash
ADMIN_EMAIL=$ADMIN_EMAIL
HOSTNAME="$(hostname -f)"
TMPFILE=$(mktemp)

rkhunter --cronjob --report-warnings-only >> "$TMPFILE" 2>&1
chkrootkit >> "$TMPFILE" 2>&1

if grep -Ei "Warning|INFECTED|Possible" "$TMPFILE" >/dev/null; then
    (
        echo "Subject: Rootkit Alert on $HOSTNAME"
        cat "$TMPFILE"
    ) | msmtp "$ADMIN_EMAIL"
fi

rm -f "$TMPFILE"
EOF
chmod +x /etc/cron.daily/rootkit-scan || error_log "chmod rootkit-scan failed"

##############################################
# CPU & Memory watchdog
##############################################

cat <<EOF > /usr/local/sbin/cpu-mem-watchdog.sh
#!/usr/bin/env bash
CPU_THRESHOLD=$CPU_THRESHOLD
MEM_THRESHOLD=$MEM_THRESHOLD
CHECK_INTERVAL=$CHECK_INTERVAL
MAX_ALERTS=$WATCHDOG_MAX_ALERTS
ADMIN_EMAIL="$ADMIN_EMAIL"
SERVER_NAME="$SERVER_NAME"

command -v mpstat >/dev/null 2>&1 || { echo "mpstat not found, exiting watchdog"; exit 1; }

cpu_alerts=0
mem_alerts=0

while true; do
    CPU_LOAD=\$(mpstat 1 1 | awk '/Average/ {print 100 - \$12}')
    CPU_INT=\${CPU_LOAD%.*}
    MEM_FREE=\$(free | awk '/Mem:/ {printf "%.0f", \$7/\$2 * 100}')

    if [ "\$CPU_INT" -ge "\$CPU_THRESHOLD" ]; then
        cpu_alerts=\$((cpu_alerts+1))
    else
        cpu_alerts=0
    fi

    if [ "\$MEM_FREE" -le "\$MEM_THRESHOLD" ]; then
        mem_alerts=\$((mem_alerts+1))
    else
        mem_alerts=0
    fi

    if [ "\$cpu_alerts" -ge "\$MAX_ALERTS" ] || [ "\$mem_alerts" -ge "\$MAX_ALERTS" ]; then
        echo "Preventive reboot triggered on \$SERVER_NAME" | msmtp "\$ADMIN_EMAIL"
        shutdown -r now
    fi

    sleep "\$CHECK_INTERVAL"
done
EOF
chmod +x /usr/local/sbin/cpu-mem-watchdog.sh || error_log "chmod watchdog failed"

cat <<EOF > /etc/systemd/system/cpu-mem-watchdog.service
[Unit]
Description=CPU and Memory Watchdog
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/cpu-mem-watchdog.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload || error_log "systemd daemon-reload failed"
systemctl enable --now cpu-mem-watchdog.service || error_log "watchdog enable/start failed"

##############################################
# Locale configuration
##############################################

log "Configuring system locale (English)"
apt-get install -y locales || error_log "locales install failed"
grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen en_US.UTF-8 || error_log "locale-gen failed"
locale -a | grep -q "en_US.utf8" && update-locale LANG=en_US.UTF-8 || error_log "Locale not found after generation"
unset LC_ALL LANGUAGE
export LANG=en_US.UTF-8

##############################################
# Keyboard configuration (French AZERTY)
##############################################

apt-get install -y console-setup keyboard-configuration || error_log "keyboard install failed"
cat <<EOF > /etc/default/keyboard
XKBMODEL="pc105"
XKBLAYOUT="fr"
XKBVARIANT=""
XKBOPTIONS=""
EOF
dpkg-reconfigure --frontend=noninteractive keyboard-configuration || error_log "keyboard reconfigure failed"
setupcon || error_log "setupcon failed"

##############################################
# User & SSH configuration
##############################################

getent group adm-users >/dev/null || addgroup --system adm-users || error_log "group adm-users creation failed"

if ! id -u "$NEWUSER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$NEWUSER" || error_log "adduser failed"
fi
usermod -aG sudo,adm-users "$NEWUSER" || error_log "adduser to groups failed"

if [ -n "$SSH_PASSWORD" ]; then
    echo "$NEWUSER:$SSH_PASSWORD" | chpasswd || error_log "set local password failed"
fi

if [ -n "$SSH_KEY" ]; then
    mkdir -p /home/$NEWUSER/.ssh
    echo "$SSH_KEY" > /home/$NEWUSER/.ssh/authorized_keys
    chmod 700 /home/$NEWUSER/.ssh
    chmod 600 /home/$NEWUSER/.ssh/authorized_keys
    chown -R $NEWUSER:$NEWUSER /home/$NEWUSER/.ssh
fi

SSHD_CONFIG="/etc/ssh/sshd_config"
cp $SSHD_CONFIG ${SSHD_CONFIG}.bak_$(date +%s) || error_log "backup sshd_config failed"

sed -i 's/^#*PermitRootLogin .*/PermitRootLogin no/' $SSHD_CONFIG || error_log "PermitRootLogin failed"
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' $SSHD_CONFIG || error_log "PasswordAuthentication failed"
sed -i 's/^#*MaxAuthTries .*/MaxAuthTries 3/' $SSHD_CONFIG || error_log "MaxAuthTries failed"

grep -q "^Protocol 2" $SSHD_CONFIG || echo "Protocol 2" >> $SSHD_CONFIG
grep -q "^AllowGroups adm-users" $SSHD_CONFIG || echo "AllowGroups adm-users" >> $SSHD_CONFIG
grep -q "^AllowAgentForwarding no" $SSHD_CONFIG || echo "AllowAgentForwarding no" >> $SSHD_CONFIG
grep -q "^Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com" $SSHD_CONFIG || echo "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com" >> $SSHD_CONFIG
grep -q "^MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com" $SSHD_CONFIG || echo "MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com" >> $SSHD_CONFIG
grep -q "^KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256" $SSHD_CONFIG || echo "KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256" >> $SSHD_CONFIG
grep -q "^AuthorizedKeysFile .ssh/authorized_keys" $SSHD_CONFIG || echo "AuthorizedKeysFile .ssh/authorized_keys" >> $SSHD_CONFIG

systemctl restart sshd || error_log "restart sshd failed"
log "SSH hardened and user added to adm-users"

##############################################
# IPv6
##############################################

if [[ "$DISABLE_IPV6" =~ ^([Yy]|[Yy]es)$ ]]; then
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 || error_log "disable ipv6 all failed"
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 || error_log "disable ipv6 default failed"
    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.d/99-disable-ipv6.conf
    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.d/99-disable-ipv6.conf
    sysctl --system || error_log "sysctl --system failed"
    log "IPv6 disabled"
fi

##############################################
# Firewall
##############################################

ufw default deny incoming
ufw default allow outgoing

if [[ "${SSH_ALLOWED_IPS[0]}" == "ALL" ]]; then
    ufw allow 22
else
    for ip in "${SSH_ALLOWED_IPS[@]}"; do
        ufw status | grep -qw "$ip" || ufw allow from "$ip" to any port 22 || error_log "ufw allow $ip failed"
    done
fi

ufw --force enable || error_log "ufw enable failed"
log "Firewall configured"

##############################################
# Fail2Ban configuration with whitelist
##############################################

log "Configuring Fail2Ban with whitelist: ${WHITELIST_IPS[*]}"

systemctl enable --now fail2ban || error_log "fail2ban enable/start failed"

cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
destemail = $ADMIN_EMAIL
sender = $SMTP_USER
mta = mail
ignoreip = ${WHITELIST_IPS[*]}

[sshd]
enabled = true
port = 22
logpath = /var/log/auth.log
backend = systemd
EOF

systemctl restart fail2ban || error_log "fail2ban restart failed"
log "Fail2Ban configured and running"

##############################################
# CrowdSec Installation & Remediation
##############################################

log "Installing and configuring CrowdSec with automatic firewall remediation and whitelist"

# Install CrowdSec if missing
if ! command -v crowdsec >/dev/null 2>&1; then
    log "Installing CrowdSec agent"
    curl -s https://install.crowdsec.net | sh || error_log "CrowdSec bootstrap failed"
    apt-get update || error_log "apt-get update after CrowdSec failed"
    apt-get install -y crowdsec crowdsec-firewall-bouncer-iptables || error_log "CrowdSec install failed"

    # Install essential collections and scenarios
    cscli collections install crowdsecurity/linux || error_log "CrowdSec linux collection failed"
    cscli collections install crowdsecurity/sshd || error_log "CrowdSec sshd collection failed"
    cscli scenarios install crowdsecurity/ssh-bf || error_log "CrowdSec ssh-bf scenario failed"
fi

# Enable firewall bouncer for automatic remediation
if ! cscli bouncers list | grep -q "iptables"; then
    log "Configuring CrowdSec firewall bouncer (iptables)"
    cscli bouncers add crowdsec-firewall-bouncer-iptables --iptables || error_log "CrowdSec iptables bouncer add failed"
fi

# Apply whitelist to CrowdSec
for ip in "${WHITELIST_IPS[@]}"; do
    cscli decisions add --ip "$ip" --type whitelist || log "$ip already whitelisted in CrowdSec"
done

# Check CrowdSec agent and bouncer
if systemctl is-active --quiet crowdsec; then
    log "CrowdSec agent running"
else
    error_log "CrowdSec agent service not active"
    systemctl restart crowdsec || error_log "CrowdSec restart failed"
fi

if systemctl is-active --quiet crowdsec-firewall-bouncer; then
    log "CrowdSec firewall bouncer active"
else
    error_log "CrowdSec firewall bouncer not active"
    systemctl restart crowdsec-firewall-bouncer || error_log "CrowdSec bouncer restart failed"
fi

log "CrowdSec configured with automatic SSH brute-force remediation and whitelist: ${WHITELIST_IPS[*]}"

##############################################
# Dokploy / Docker installation
##############################################

if [[ "$INSTALL_DOKPLOY" =~ ^([Yy]|[Yy]es)$ ]]; then
    if ! command -v dokploy >/dev/null 2>&1; then
        curl -s https://get.dokploy.com | bash || error_log "Dokploy installation failed"
    else
        log "Dokploy already installed"
    fi
elif [[ "$INSTALL_DOCKER" =~ ^([Yy]|[Yy]es)$ ]]; then
    if ! id -u docker-admin >/dev/null 2>&1; then
        DOCKER_ADMIN_PASS=$(openssl rand -base64 16)
        useradd -m -s /bin/bash docker-admin || error_log "docker-admin creation failed"
        echo "docker-admin:$DOCKER_ADMIN_PASS" | chpasswd || error_log "docker-admin password failed"
        usermod -aG sudo docker-admin || error_log "docker-admin sudo group failed"
        sudo -u docker-admin -i bash -c "curl -fsSL https://get.docker.com/rootless | sh" || error_log "Docker rootless installation failed"
    else
        log "Docker rootless user docker-admin already exists"
    fi
fi

##############################################
# msmtp installation
##############################################

log "Installing msmtp"

export DEBIAN_FRONTEND=noninteractive
echo "msmtp msmtp/apparmor boolean true" | debconf-set-selections
apt-get install -y msmtp msmtp-mta || error_log "msmtp install failed"

##############################################
# msmtp configuration
##############################################

cat <<EOF > /etc/msmtprc
defaults
auth           on
tls            on
tls_starttls   off
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log
timeout        60

account        default
host           ${SMTP_SERVER}
port           ${SMTP_PORT}
from           ${SMTP_USER}
user           ${SMTP_USER}
password       ${SMTP_PASS}
EOF

chmod 600 /etc/msmtprc

##############################################
# SMTP connectivity test
##############################################

log "Testing SMTP connectivity"

if timeout 60 bash -c "echo 'Server notification test' | msmtp ${ADMIN_EMAIL}"; then
    log "SMTP test succeeded"
else
    error_log "SMTP test failed"
    echo "===== msmtp debug ====="
    msmtp --debug --account=default ${ADMIN_EMAIL} < <(echo "debug test")
    echo "======================="
fi

##############################################
# Summary
##############################################

SUMMARY=$(cat <<EOF
Post-installation summary for $SERVER_NAME

User: $NEWUSER
SSH key configured: ${SSH_KEY:+yes}
Local password set: ${SSH_PASSWORD:+yes}
SSH access via group: adm-users
SSH allowed IPs/subnets: ${SSH_ALLOWED_IPS[*]}
IPv6 disabled: $DISABLE_IPV6
CPU threshold: $CPU_THRESHOLD% for $CPU_DURATION checks
Memory threshold: $MEM_THRESHOLD% for $MEM_DURATION checks
Watchdog interval: $CHECK_INTERVAL seconds
CrowdSec installed: $(command -v crowdsec >/dev/null 2>&1 && echo yes || echo no)
Dokploy installed: $INSTALL_DOKPLOY
Docker installed: $INSTALL_DOCKER
Docker rootless user: ${DOCKER_ADMIN_PASS:+docker-admin}
EOF
)

log "$SUMMARY"
send_mail "Post-installation Summary" "$SUMMARY"

log "Post-installation completed for $SERVER_NAME"