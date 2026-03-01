#!/bin/bash
# Generic Reverse Proxy Installer for any app behind Nginx
# Debian 13 amd64/arm64 with Let's Encrypt dry-run verification
set -e

##############################################
# Global variables
##############################################

# App name, used for filenames
APP_NAME="myapp"

# Public domain for the app
DOMAIN="example.com"

# Local port of the app
APP_PORT=8080

# Certbot webroot
WEBROOT="/var/www/html"

# Email for notification
MSMTP_TO="email@example.com"

##############################################
# Clean existing configs
##############################################
echo "[INFO] Cleaning previous $APP_NAME Nginx and Fail2Ban configs"
rm -f /etc/nginx/sites-enabled/${APP_NAME}*.conf
rm -f /etc/nginx/sites-available/${APP_NAME}*.conf
rm -f /etc/nginx/conf.d/${APP_NAME}-security.conf 2>/dev/null || true
rm -f /etc/fail2ban/filter.d/${APP_NAME}.conf 2>/dev/null || true
rm -f /etc/fail2ban/jail.d/${APP_NAME}.conf 2>/dev/null || true

##############################################
# Clean existing nginx if corrupted
##############################################
if [ ! -f /etc/nginx/nginx.conf ]; then
    echo "[INFO] Main Nginx configuration missing. Purging and reinstalling Nginx..."
    apt-get remove --purge -y nginx nginx-common
    apt-get install -y nginx
fi

##############################################
# Install nginx if needed
##############################################
if ! command -v nginx >/dev/null 2>&1; then
    echo "[INFO] Installing Nginx"
    apt update
    apt install -y nginx
fi
mkdir -p $WEBROOT
ufw allow 80,443/tcp || true

##############################################
# Install certbot if needed
##############################################
if ! command -v certbot >/dev/null 2>&1; then
    echo "[INFO] Installing Certbot + Nginx plugin"
    apt update
    apt install -y certbot python3-certbot-nginx
fi

##############################################
# Nginx security (app-specific)
##############################################
SECURITY_CONF="/etc/nginx/conf.d/${APP_NAME}-security.conf"
if [ ! -f "$SECURITY_CONF" ]; then
cat > "$SECURITY_CONF" <<'EOF'
client_max_body_size 50M;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "no-referrer-when-downgrade" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
EOF
fi

##############################################
# HTTP config (Let’s Encrypt)
##############################################
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
cat > /etc/nginx/sites-available/${APP_NAME}.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # Allow Certbot HTTP challenge
    location /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type "text/plain";
        try_files \$uri =404;
    }

    # Redirect all other HTTP traffic to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
ln -sf /etc/nginx/sites-available/${APP_NAME}.conf /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

##############################################
# Obtain let's encrypt certificate if missing
##############################################
if [ ! -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
    echo "[INFO] Obtaining Let's Encrypt certificate for $DOMAIN"
    certbot certonly --webroot -w $WEBROOT -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email || \
        echo "Certbot issuance failed for $DOMAIN at $(date)" | msmtp $MSMTP_TO
fi

##############################################
# HTTPS config
##############################################
cat > /etc/nginx/sites-available/${APP_NAME}-ssl.conf <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'EECDH+AESGCM:EDH+AESGCM';
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;

    include /etc/nginx/conf.d/${APP_NAME}-security.conf;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
ln -sf /etc/nginx/sites-available/${APP_NAME}-ssl.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

##############################################
# Fail2ban configuration for the app
##############################################
if [ ! -f /etc/fail2ban/filter.d/${APP_NAME}.conf ]; then
    cat > /etc/fail2ban/filter.d/${APP_NAME}.conf <<'EOF'
[Definition]
failregex = .*Login failed for user.*
ignoreregex =
EOF
fi

if [ ! -f /etc/fail2ban/jail.d/${APP_NAME}.conf ]; then
    cat > /etc/fail2ban/jail.d/${APP_NAME}.conf <<EOF
[${APP_NAME}]
enabled = true
filter = ${APP_NAME}
action = iptables[name=${APP_NAME}, port=443, protocol=tcp]
logpath = /var/log/${APP_NAME}.log
maxretry = 3
bantime = 3600
EOF
fi
systemctl restart fail2ban

##############################################
# Crowdsec configuration
##############################################
echo "[INFO] Verifying CrowdSec Nginx bouncer and collection"
if ! cscli bouncers list | grep -q "nginx"; then
    cscli bouncers add nginx
fi
if ! cscli collections list | grep -q "crowdsecurity/nginx"; then
    cscli collections install crowdsecurity/nginx
fi

##############################################
# Certbot auto-renew test (dry-run)
##############################################
echo "[INFO] Testing Certbot auto-renewal (dry-run)"
if certbot renew --dry-run --webroot -w $WEBROOT; then
    echo "Certbot dry-run successful for $DOMAIN at $(date)" | msmtp $MSMTP_TO
else
    echo "Certbot dry-run FAILED for $DOMAIN at $(date)" | msmtp $MSMTP_TO
fi

echo "[INFO] Script completed. $APP_NAME accessible at https://$DOMAIN"