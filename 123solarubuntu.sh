#!/bin/bash

# Inverter Support
_AURORA=1
_485SOLAR_GET=1

###############################################################################

_123SOLAR_VER=1.8.4.5
_123SOLAR_URL=https://github.com/jeanmarc77/123solar/releases/download/1.8.4.5/123solar1.8.4.5.tar.gz
_123SOLAR_URL=$(curl -s https://123solar.org/latest_version.php | awk '/"LINK":/ {print substr($2,2,length($2)-3)}')

_123SOLAR_SVC=https://github.com/jeanmarc77/123solar/blob/main/misc/examples/123solar.service
_485SOLAR_GET_VER=1.000
_485SOLAR_GET_URL=http://downloads.sourceforge.net/project/solarget/485solar-get-$_485SOLAR_GET_VER-sources.tgz
_AURORA_VER=1.9.3
_AURORA_URL=http://www.curtronics.com/Solar/ftp/aurora-$_AURORA_VER.tar.gz
_YASDI_VER=1.8.1build9
_YASDI_URL=http://files.sma.de/dl/11705/yasdi-$_YASDI_VER-src.zip

###############################################################################

GIT_PATH="$(dirname $(readlink -f $0))"

if [[ $(id -u) -ne 0 ]] ; then
    echo "This script must be executed as 'root' (hint: use the 'sudo' command)."
    exit 1
fi

# Confirm Ubuntu
if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    echo "Warning: This script is intended for Ubuntu Server. Proceed with caution."
    read -p "Continue anyway? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 1
fi

apt-get update
apt-get -y upgrade

# Install Components
# - Added build-essential, unzip, wget (not always present on minimal Ubuntu)
# - Added php-xml, php-mbstring (commonly required by web apps)
# - libgcc-s1 replaces the Pi-specific libgcc1 on modern Ubuntu
apt-get -y install \
    nginx \
    php php-fpm php-cgi php-curl php-xml php-mbstring \
    msmtp \
    build-essential \
    wget \
    unzip \
    cmake

# Get the installed PHP version
PHP_VERSION=$(php -r "echo PHP_VERSION;" | awk -F "." '{printf("%s.%s\n",$1,$2)}')
PHP_FPM="php${PHP_VERSION}-fpm"

echo "Detected PHP version: $PHP_VERSION (service: $PHP_FPM)"

# nginx/PHP
cp $GIT_PATH/nginx.conf /etc/nginx/sites-available/default
sed -i "s/php-fpm/$PHP_FPM/g" /etc/nginx/sites-available/default

# Remove the default nginx enabled site if it conflicts
if [ -f /etc/nginx/sites-enabled/default ]; then
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
fi

# msmtp
cp $GIT_PATH/msmtprc /etc/msmtprc
chmod 600 /etc/msmtprc
chown www-data:root /etc/msmtprc
# Only add sendmail_path if not already present
if ! grep -q "sendmail_path" /etc/php/$PHP_VERSION/fpm/php.ini; then
    sed -i '/;sendmail_path/a sendmail_path = "/usr/bin/msmtp -C /etc/msmtprc -t"' /etc/php/$PHP_VERSION/fpm/php.ini
fi

# 123Solar
wget -P ~ $_123SOLAR_URL
tar -xzvf ~/123solar*.tar.gz -C /var/www/html
rm ~/123solar*.tar.gz
chown -R www-data:www-data /var/www/html/123solar
wget -P /etc/systemd/system $_123SOLAR_SVC
sed -i "s/php-fpm/$PHP_FPM/g" /etc/systemd/system/123solar.service

# Serial port access
# On Ubuntu, the group is 'dialout' same as Pi — no change needed
usermod -a -G dialout www-data

# aurora
if [ $_AURORA -eq 1 ]; then
    wget -P ~ $_AURORA_URL
    tar -xzvf ~/aurora*.tar.gz -C ~

    AURORA_DIR="$(find ~ -maxdepth 1 -name 'aurora*' -type d | head -1)"
    if [ -z "$AURORA_DIR" ]; then
        echo "ERROR: aurora source directory not found after extraction."
        exit 1
    fi

    cd "$AURORA_DIR"
    make
    make install
    cd ~
    rm -fr ~/aurora*
fi

# 485solar-get (cmake already installed above)
if [ $_485SOLAR_GET -eq 1 ]; then
    # YASDI
    wget -P ~ $_YASDI_URL
    unzip ~/yasdi*.zip -d ~/yasdi
    rm ~/yasdi*.zip
    cd ~/yasdi/projects/generic-cmake
    cmake .
    make
    make install

    # Update shared library cache
    echo "/usr/local/lib" > /etc/ld.so.conf.d/local.conf
    ldconfig

    cp $GIT_PATH/yasdi.ini /etc/yasdi.ini

    # 485solar-get
    wget -P ~ $_485SOLAR_GET_URL
    tar -xzvf ~/485solar-get*.tgz -C ~/yasdi
    rm ~/485solar-get*.tgz

    SOLARGET_DIR="$(find ~/yasdi -maxdepth 1 -name '485solar-get*' -type d | head -1)"
    cd "$SOLARGET_DIR"
    ./make.sh
    cd ~
    rm -fr ~/yasdi
fi

# Enable and start services
systemctl daemon-reload
systemctl restart nginx $PHP_FPM
systemctl enable 123solar
systemctl start 123solar

echo ""
echo "Installation complete!"
echo "Don't forget to configure msmtp, using the following command:"
echo "  sudo nano /etc/msmtprc"
