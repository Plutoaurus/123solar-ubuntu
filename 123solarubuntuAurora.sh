#!/bin/bash

# Inverter Support
_AURORA=1
_485SOLAR_GET=1

###############################################################################

# Aurora Power One inverter - RS485 to Ethernet adapter settings
# Adapter IP and port (adjust _AURORA_INVERTER_PORT if your adapter differs)
_AURORA_INVERTER_IP=**IP ADDRESS**
_AURORA_INVERTER_PORT=4196          # RS485-to-Ethernet adapter port
_AURORA_VIRTUAL_PORT=/dev/ttyV0     # Virtual serial port created by socat

###############################################################################

_123SOLAR_VER=1.8.4.5
_123SOLAR_URL=https://github.com/jeanmarc77/123solar/releases/download/1.8.4.5/123solar1.8.4.5.tar.gz


_123SOLAR_SVC=https://github.com/jeanmarc77/123solar/raw/main/misc/examples/123solar.service
_485SOLAR_GET_VER=1.000
_485SOLAR_GET_URL=https://github.com/Plutoaurus/123solar-ubuntu/raw/master/485solar-get_1.003-sources.tgz
_AURORA_VER=1.9.3
_AURORA_URL=https://github.com/Plutoaurus/123solar-ubuntu/raw/master/aurora-1.9.4.tar.gz
_YASDI_VER=1.8.1build9
_YASDI_URL=https://github.com/Plutoaurus/123solar-ubuntu/raw/master/yasdi-1.8.1build9-src.zip

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

# Remove Apache and any Apache-related packages — they conflict with nginx on port 80
# libapache2-mod-php* is also removed as it pulls apache2 back in as a dependency
echo "Removing Apache2 and related packages to avoid conflict with nginx..."
apt-get remove --purge -y \
    apache2 \
    apache2-utils \
    apache2-bin \
    apache2-data \
    'libapache2-mod-php*'
apt-get autoremove -y

# Install Components
# - Added build-essential, unzip, wget (not always present on minimal Ubuntu)
# - Added php-xml, php-mbstring (commonly required by web apps)
# - socat creates a virtual serial port tunnelled over TCP to the RS485-Ethernet adapter
# - NOTE: the generic 'php' meta-package is intentionally omitted — on Ubuntu it pulls in
#   libapache2-mod-php which reinstalls Apache and conflicts with nginx on port 80.
#   php-cli, php-fpm and php-cgi provide everything 123solar needs without Apache.
apt-get -y install \
    nginx \
    php-cli php-fpm php-cgi php-curl php-xml php-mbstring \
    msmtp \
    build-essential \
    wget \
    unzip \
    cmake \
    socat

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
# www-data needs dialout for the socat virtual port as well as any real serial ports
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

    # --- RS485-to-Ethernet virtual serial port via socat ---
    # socat bridges the TCP connection to the adapter and presents it as a
    # standard serial device at $_AURORA_VIRTUAL_PORT so that the aurora
    # binary and 123solar can treat it like a locally attached RS485 port.
    cat > /etc/systemd/system/aurora-socat.service << EOF
[Unit]
Description=socat virtual serial port for Aurora RS485-Ethernet adapter (${_AURORA_INVERTER_IP}:${_AURORA_INVERTER_PORT})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# PTY link= creates a stable symlink at $_AURORA_VIRTUAL_PORT
# waitslave keeps the PTY open even when nothing has the port open yet
# b19200 matches the default Aurora RS485 baud rate — adjust if needed
ExecStart=/usr/bin/socat \
    PTY,link=${_AURORA_VIRTUAL_PORT},b19200,raw,echo=0,waitslave \
    TCP:${_AURORA_INVERTER_IP}:${_AURORA_INVERTER_PORT},retry,interval=5,forever
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Make sure 123solar waits for the virtual port to be ready
    mkdir -p /etc/systemd/system/123solar.service.d
    cat > /etc/systemd/system/123solar.service.d/after-socat.conf << EOF
[Unit]
After=aurora-socat.service
Requires=aurora-socat.service
EOF

    # Configure 123solar to use the virtual serial port for the aurora driver.
    # 123solar stores inverter connection settings in config.php; the key
    # parameter is 'AURORA_PORT' (or equivalent in your installed version).
    # We write a small post-install config snippet into the 123solar config
    # directory that sets the port to the socat virtual device.
    SOLAR_CFG=/var/www/html/123solar/config/config.php
    if [ -f "$SOLAR_CFG" ]; then
        # Update existing port setting if present
        if grep -q "AURORA_PORT\|aurora_port\|rs485port" "$SOLAR_CFG"; then
            sed -i "s|['\"]\/dev\/tty[^'\"]*['\"]|'${_AURORA_VIRTUAL_PORT}'|g" "$SOLAR_CFG"
            echo "Updated aurora serial port to ${_AURORA_VIRTUAL_PORT} in $SOLAR_CFG"
        else
            echo "Note: Could not auto-detect port setting in $SOLAR_CFG."
            echo "      Manually set the aurora serial port to: ${_AURORA_VIRTUAL_PORT}"
        fi
    else
        echo "Note: 123solar config.php not found at expected path."
        echo "      When configuring 123solar via the web UI, set the inverter"
        echo "      serial port to: ${_AURORA_VIRTUAL_PORT}"
    fi

    systemctl enable aurora-socat
    systemctl start aurora-socat

    echo ""
    echo "Aurora socat bridge started: TCP ${_AURORA_INVERTER_IP}:${_AURORA_INVERTER_PORT} -> ${_AURORA_VIRTUAL_PORT}"
    echo "If you ever need to change the TCP port, edit _AURORA_INVERTER_PORT at the top of this script"
    echo "and update /etc/systemd/system/aurora-socat.service, then run: systemctl restart aurora-socat"
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
echo ""
echo "Aurora inverter connection summary:"
echo "  Adapter address : ${_AURORA_INVERTER_IP}:${_AURORA_INVERTER_PORT}"
echo "  Virtual port    : ${_AURORA_VIRTUAL_PORT}"
echo "  socat service   : aurora-socat.service"
echo ""
echo "To verify the socat bridge is running:"
echo "  systemctl status aurora-socat"
echo "  ls -la ${_AURORA_VIRTUAL_PORT}"
echo ""
echo "Don't forget to configure msmtp, using the following command:"
echo "  sudo nano /etc/msmtprc"
