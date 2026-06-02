#!/bin/bash
set -euo pipefail

######################################################################
# PHP 7.4 Installation Script for Amazon Linux 2023
# Installs PHP 7.4 alongside PHP 8.3, configures Apache to use 7.4
# for /var/www/html/ via PHP-FPM
#
# Usage: sudo bash install-php74.sh
######################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run with sudo: sudo bash install-php74.sh${NC}"
    exit 1
fi

echo -e "${GREEN}=== PHP 7.4 Installation for Amazon Linux 2023 ===${NC}"
echo ""

# Show current state
echo -e "${YELLOW}Current environment:${NC}"
echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
echo "Apache: $(httpd -v 2>/dev/null | head -1 || echo 'not found')"
echo "PHP: $(php -v 2>/dev/null | head -1 || echo 'not found')"
echo ""

########################################
# STEP 1: Install build dependencies
########################################
echo -e "${YELLOW}[1/8] Installing build dependencies...${NC}"
dnf groupinstall -y "Development Tools" 2>&1 | tail -1
dnf install -y \
    libxml2-devel \
    sqlite-devel \
    libcurl-devel \
    oniguruma-devel \
    libpng-devel \
    libjpeg-turbo-devel \
    freetype-devel \
    libzip-devel \
    systemd-devel \
    zlib-devel \
    wget \
    tar \
    2>&1 | tail -3

# MariaDB/MySQL dev - try multiple package names
dnf install -y mariadb105-devel 2>/dev/null || \
dnf install -y mariadb-connector-c-devel 2>/dev/null || \
dnf install -y mysql-devel 2>/dev/null || \
echo -e "${YELLOW}Warning: MariaDB/MySQL dev package not found. Will try mysqli anyway.${NC}"

echo -e "${GREEN}[1/8] Done.${NC}"

########################################
# STEP 2: Compile OpenSSL 1.1.1
# (PHP 7.4 is incompatible with OpenSSL 3.x shipped in AL2023)
########################################
echo -e "${YELLOW}[2/8] Compiling OpenSSL 1.1.1w...${NC}"
cd /tmp

if [ -f /opt/openssl-1.1/lib/libssl.so ]; then
    echo "OpenSSL 1.1.1 already installed, skipping."
else
    if [ ! -f openssl-1.1.1w.tar.gz ]; then
        wget -q --show-progress https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz
    fi
    tar xzf openssl-1.1.1w.tar.gz
    cd openssl-1.1.1w
    ./config --prefix=/opt/openssl-1.1 --openssldir=/opt/openssl-1.1 shared zlib 2>&1 | tail -3
    make -j$(nproc) 2>&1 | tail -3
    make install_sw 2>&1 | tail -3
    echo "/opt/openssl-1.1/lib" > /etc/ld.so.conf.d/openssl-1.1.conf
    ldconfig
fi

echo -e "${GREEN}[2/8] Done.${NC}"

########################################
# STEP 3: Download PHP 7.4.33
########################################
echo -e "${YELLOW}[3/8] Downloading PHP 7.4.33...${NC}"
cd /tmp

if [ ! -d php-7.4.33 ]; then
    if [ ! -f php-7.4.33.tar.gz ]; then
        wget -q --show-progress https://www.php.net/distributions/php-7.4.33.tar.gz
    fi
    tar xzf php-7.4.33.tar.gz
fi

echo -e "${GREEN}[3/8] Done.${NC}"

########################################
# STEP 4: Compile PHP 7.4.33
########################################
echo -e "${YELLOW}[4/8] Compiling PHP 7.4.33 — this takes 5-10 minutes...${NC}"
cd /tmp/php-7.4.33

# Detect mysql_config location
MYSQL_CONFIG=""
for mc in /usr/bin/mariadb_config /usr/bin/mysql_config /usr/bin/mysql_config-64; do
    if [ -x "$mc" ]; then
        MYSQL_CONFIG="$mc"
        break
    fi
done

CONFIGURE_ARGS=(
    --prefix=/opt/php74
    --with-config-file-path=/opt/php74/etc
    --with-config-file-scan-dir=/opt/php74/etc/conf.d
    --enable-fpm
    --with-fpm-user=apache
    --with-fpm-group=apache
    --with-openssl=/opt/openssl-1.1
    --with-zlib
    --with-curl
    --with-mysqli
    --with-pdo-mysql
    --enable-mbstring
    --enable-opcache
    --enable-session
    --enable-tokenizer
    --enable-ctype
    --enable-fileinfo
    --enable-bcmath
    --enable-json
    --enable-xml
    --enable-simplexml
    --enable-dom
    --with-libxml
)

# Add GD if dev libraries exist
if pkg-config --exists freetype2 2>/dev/null; then
    CONFIGURE_ARGS+=(--enable-gd --with-jpeg --with-freetype)
fi

# Add libzip if available
if pkg-config --exists libzip 2>/dev/null; then
    CONFIGURE_ARGS+=(--with-zip)
fi

PKG_CONFIG_PATH=/opt/openssl-1.1/lib/pkgconfig ./configure "${CONFIGURE_ARGS[@]}" 2>&1 | tail -10

make -j$(nproc) 2>&1 | tail -5
make install 2>&1 | tail -5

echo -e "${GREEN}[4/8] Done. PHP 7.4 installed to /opt/php74${NC}"

########################################
# STEP 5: Configure PHP 7.4
########################################
echo -e "${YELLOW}[5/8] Configuring PHP 7.4...${NC}"
mkdir -p /opt/php74/etc/conf.d
cp /tmp/php-7.4.33/php.ini-production /opt/php74/etc/php.ini

# PHP-FPM config
cp /opt/php74/etc/php-fpm.conf.default /opt/php74/etc/php-fpm.conf
cp /opt/php74/etc/php-fpm.d/www.conf.default /opt/php74/etc/php-fpm.d/www.conf

# Use port 9074 so it doesn't conflict with anything
sed -i 's|listen = 127.0.0.1:9000|listen = 127.0.0.1:9074|' /opt/php74/etc/php-fpm.d/www.conf
sed -i 's|user = nobody|user = apache|' /opt/php74/etc/php-fpm.d/www.conf
sed -i 's|group = nobody|group = apache|' /opt/php74/etc/php-fpm.d/www.conf

echo -e "${GREEN}[5/8] Done.${NC}"

########################################
# STEP 6: Create systemd service
########################################
echo -e "${YELLOW}[6/8] Creating PHP 7.4 FPM systemd service...${NC}"

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

echo -e "${GREEN}[6/8] PHP 7.4 FPM service started.${NC}"

########################################
# STEP 7: Configure Apache
########################################
echo -e "${YELLOW}[7/8] Configuring Apache...${NC}"

# Backup all existing PHP-related Apache configs
echo "Backing up existing PHP configs..."
for f in /etc/httpd/conf.d/php*.conf /etc/httpd/conf.modules.d/*php*.conf; do
    if [ -f "$f" ]; then
        cp "$f" "${f}.bak-$(date +%Y%m%d%H%M%S)"
        echo "  Backed up: $f"
    fi
done

# Disable mod_php (rename .conf -> .disabled so Apache ignores them)
for f in /etc/httpd/conf.modules.d/*php*.conf; do
    if [ -f "$f" ]; then
        mv "$f" "${f}.disabled"
        echo "  Disabled: $f"
    fi
done

# Disable PHP handler configs that might conflict
for f in /etc/httpd/conf.d/php*.conf; do
    if [ -f "$f" ] && [ "$(basename $f)" != "php74-fpm.conf" ]; then
        mv "$f" "${f}.disabled"
        echo "  Disabled: $f"
    fi
done

# Create PHP 7.4 FPM handler for Apache
cat > /etc/httpd/conf.d/php74-fpm.conf <<'APACHE'
# Route all .php files in /var/www/html/ to PHP 7.4 FPM on port 9074
<Directory "/var/www/html">
    <FilesMatch "\.php$">
        SetHandler "proxy:fcgi://127.0.0.1:9074"
    </FilesMatch>
</Directory>

# Ensure PHP index files are recognized
<IfModule dir_module>
    DirectoryIndex index.php index.html
</IfModule>
APACHE

# Allow Apache to connect to FPM backend (in case SELinux is enforcing)
setsebool -P httpd_can_network_connect 1 2>/dev/null || true

# Test and restart Apache
echo "Testing Apache configuration..."
httpd -t
systemctl restart httpd

echo -e "${GREEN}[7/8] Apache configured and restarted.${NC}"

########################################
# STEP 8: Verify everything
########################################
echo -e "${YELLOW}[8/8] Verifying installation...${NC}"
echo ""
echo "========================================="
echo ""

echo "--- PHP 7.4 ---"
/opt/php74/bin/php -v
echo ""

echo "Required modules check:"
for mod in mysqli curl json; do
    if /opt/php74/bin/php -m 2>/dev/null | grep -qi "^${mod}$"; then
        echo -e "  ${GREEN}[OK]${NC} $mod"
    else
        echo -e "  ${RED}[MISSING]${NC} $mod"
    fi
done
echo ""

echo "All PHP 7.4 modules:"
/opt/php74/bin/php -m
echo ""

echo "--- PHP 8.3 (system CLI, unchanged) ---"
php -v 2>/dev/null || echo "(not in PATH or removed)"
echo ""

echo "--- Service Status ---"
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
    echo -e "${GREEN}SUCCESS — Site is responding normally!${NC}"
else
    echo -e "${YELLOW}Site returned HTTP $HTTP_CODE${NC}"
    echo "If not 200/302, check the error log:"
    echo "  sudo tail -50 /var/log/httpd/error_log"
    echo ""
    echo "Also check PHP-FPM log:"
    echo "  sudo tail -50 /opt/php74/var/log/php-fpm.log"
fi
echo ""
echo "PHP 7.4 binary:     /opt/php74/bin/php"
echo "PHP 7.4 FPM config: /opt/php74/etc/php-fpm.d/www.conf"
echo "Apache PHP config:  /etc/httpd/conf.d/php74-fpm.conf"
echo ""
echo -e "${GREEN}Done! PHP 7.4 is now handling /var/www/html/${NC}"
