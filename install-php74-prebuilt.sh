#!/bin/bash
set -euo pipefail

######################################################################
# PHP 7.4 Pre-built Installer for Amazon Linux 2023
# Downloads pre-compiled PHP 7.4.33, configures FPM + Apache
# No compilation needed - takes about 1 minute
#
# Usage: sudo bash install-php74-prebuilt.sh
######################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run with sudo: sudo bash install-php74-prebuilt.sh${NC}"
    exit 1
fi

echo -e "${GREEN}=== PHP 7.4 Pre-built Installer for Amazon Linux 2023 ===${NC}"
echo ""

########################################
# STEP 1: Download and extract pre-built PHP 7.4
########################################
echo -e "${YELLOW}[1/5] Downloading pre-built PHP 7.4.33...${NC}"
cd /tmp
wget -q --show-progress https://github.com/anirudhatalmale6-alt/install-php74/releases/download/v1.0/php74-al2023-x86_64.tar.gz

echo "Extracting to /opt..."
tar xzf php74-al2023-x86_64.tar.gz -C /opt/

# Register OpenSSL 1.1 libraries
echo "/opt/openssl-1.1/lib" > /etc/ld.so.conf.d/openssl-1.1.conf
ldconfig

echo -e "${GREEN}[1/5] Done.${NC}"

########################################
# STEP 2: Install runtime dependencies
########################################
echo -e "${YELLOW}[2/5] Installing runtime dependencies...${NC}"
dnf install -y libxml2 oniguruma libcurl libpng libjpeg-turbo freetype libzip zlib 2>&1 | tail -3
dnf install -y mariadb105 2>/dev/null || dnf install -y mariadb-connector-c 2>/dev/null || true
echo -e "${GREEN}[2/5] Done.${NC}"

########################################
# STEP 3: Configure PHP-FPM
########################################
echo -e "${YELLOW}[3/5] Configuring PHP 7.4 FPM...${NC}"
mkdir -p /opt/php74/etc/conf.d

# Set up FPM config from defaults
cp /opt/php74/etc/php-fpm.conf.default /opt/php74/etc/php-fpm.conf
cp /opt/php74/etc/php-fpm.d/www.conf.default /opt/php74/etc/php-fpm.d/www.conf

# Use port 9074
sed -i 's|listen = 127.0.0.1:9000|listen = 127.0.0.1:9074|' /opt/php74/etc/php-fpm.d/www.conf
sed -i 's|user = nobody|user = apache|' /opt/php74/etc/php-fpm.d/www.conf
sed -i 's|group = nobody|group = apache|' /opt/php74/etc/php-fpm.d/www.conf

# Create systemd service
cat > /etc/systemd/system/php74-fpm.service <<'UNIT'
[Unit]
Description=PHP 7.4 FastCGI Process Manager
After=network.target

[Service]
Type=simple
ExecStart=/opt/php74/sbin/php-fpm --nodaemonize --fpm-config /opt/php74/etc/php-fpm.conf
ExecReload=/bin/kill -USR2 $MAINPID
PrivateTmp=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable php74-fpm
systemctl start php74-fpm
echo -e "${GREEN}[3/5] Done.${NC}"

########################################
# STEP 4: Configure Apache
########################################
echo -e "${YELLOW}[4/5] Configuring Apache...${NC}"

# Backup existing PHP configs
for f in /etc/httpd/conf.d/php*.conf /etc/httpd/conf.modules.d/*php*.conf; do
    if [ -f "$f" ]; then
        cp "$f" "${f}.bak-$(date +%Y%m%d%H%M%S)"
        echo "  Backed up: $f"
    fi
done

# Disable mod_php
for f in /etc/httpd/conf.modules.d/*php*.conf; do
    if [ -f "$f" ]; then
        mv "$f" "${f}.disabled"
        echo "  Disabled: $f"
    fi
done

# Disable conflicting PHP handler configs
for f in /etc/httpd/conf.d/php*.conf; do
    if [ -f "$f" ] && [ "$(basename $f)" != "php74-fpm.conf" ]; then
        mv "$f" "${f}.disabled"
        echo "  Disabled: $f"
    fi
done

# Create PHP 7.4 FPM handler
cat > /etc/httpd/conf.d/php74-fpm.conf <<'APACHE'
<Directory "/var/www/html">
    <FilesMatch "\.php$">
        SetHandler "proxy:fcgi://127.0.0.1:9074"
    </FilesMatch>
</Directory>
<IfModule dir_module>
    DirectoryIndex index.php index.html
</IfModule>
APACHE

setsebool -P httpd_can_network_connect 1 2>/dev/null || true

httpd -t
systemctl restart httpd
echo -e "${GREEN}[4/5] Done.${NC}"

########################################
# STEP 5: Verify
########################################
echo -e "${YELLOW}[5/5] Verifying...${NC}"
echo ""
echo "========================================="
echo ""
echo "--- PHP 7.4 ---"
/opt/php74/bin/php -v
echo ""
echo "Required modules:"
for mod in mysqli curl json; do
    if /opt/php74/bin/php -m 2>/dev/null | grep -qi "^${mod}$"; then
        echo -e "  ${GREEN}[OK]${NC} $mod"
    else
        echo -e "  ${RED}[MISSING]${NC} $mod"
    fi
done
echo ""
echo "All modules:"
/opt/php74/bin/php -m
echo ""
echo "--- PHP 8.3 (system CLI) ---"
php -v 2>/dev/null || echo "(not in PATH)"
echo ""
echo "--- Services ---"
echo -n "PHP 7.4 FPM: "
systemctl is-active php74-fpm
echo -n "Apache:      "
systemctl is-active httpd
echo ""
echo "--- Site Test ---"
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null || echo "error")
echo "HTTP Status: $HTTP_CODE"
echo ""
echo "========================================="
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
    echo -e "${GREEN}SUCCESS - Site is responding!${NC}"
else
    echo -e "${YELLOW}HTTP $HTTP_CODE - check logs:${NC}"
    echo "  sudo tail -50 /var/log/httpd/error_log"
    echo "  sudo tail -50 /opt/php74/var/log/php-fpm.log"
fi
echo ""
echo -e "${GREEN}Done! PHP 7.4 is handling /var/www/html/${NC}"
