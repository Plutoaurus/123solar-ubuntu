#!/bin/bash

# Inverter Support
_AURORA=1
_485SOLAR_GET=1

###############################################################################

# Aurora Power One inverter - Waveshare RS485-to-Ethernet adapter settings
# Adjust these if your adapter IP or port differs
_AURORA_INVERTER_IP=**IP ADDRESS**
_AURORA_INVERTER_PORT=4196          # Waveshare default TCP port
_AURORA_VIRTUAL_PORT=/tmp/ttyV0     # Temp virtual serial port used per-call by wrapper

###############################################################################

_123SOLAR_REPO=https://github.com/jeanmarc77/123solar.git

_485SOLAR_GET_VER=1.000
_485SOLAR_GET_URL=https://github.com/Plutoaurus/123solar-ubuntu/raw/master/485solar-get_1.003-sources.tgz
_AURORA_VER=1.9.4
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

# Remove Apache and any Apache-related packages — they conflict with nginx on port 80.
# libapache2-mod-php* must also be removed as it pulls apache2 back in as a dependency
# when installing PHP packages. The generic 'php' meta-package has the same problem so
# we install php-cli/fpm/cgi individually instead (see apt-get install below).
echo "Removing Apache2 and related packages to avoid conflict with nginx..."
apt-get remove --purge -y \
    apache2 \
    apache2-utils \
    apache2-bin \
    apache2-data \
    'libapache2-mod-php*'
apt-get autoremove -y

# Install Components
# - NOTE: the generic 'php' meta-package is intentionally omitted — on Ubuntu it pulls in
#   libapache2-mod-php which reinstalls Apache and conflicts with nginx on port 80.
#   php-cli, php-fpm and php-cgi provide everything 123solar needs without Apache.
# - socat is used by the aurora-eth wrapper to bridge TCP to a per-call virtual serial port
apt-get -y install \
    nginx \
    apache2-utils \
    git \
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
# nginx.conf is maintained in the repo at https://github.com/Plutoaurus/123solar-ubuntu
# The sed command substitutes the placeholder 'php-fpm' with the actual versioned
# PHP-FPM service name (e.g. php8.3-fpm) detected above.
cp $GIT_PATH/nginx.conf /etc/nginx/sites-available/default
sed -i "s/php-fpm/$PHP_FPM/g" /etc/nginx/sites-available/default

# Ensure the default site symlink is in place
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

# msmtp
cp $GIT_PATH/msmtprc /etc/msmtprc
chmod 600 /etc/msmtprc
chown www-data:root /etc/msmtprc
# Only add sendmail_path if not already present
if ! grep -q "sendmail_path" /etc/php/$PHP_VERSION/fpm/php.ini; then
    sed -i '/;sendmail_path/a sendmail_path = "/usr/bin/msmtp -C /etc/msmtprc -t"' /etc/php/$PHP_VERSION/fpm/php.ini
fi

# 123Solar — clone directly from the GitHub repository to get the latest code
# (the release tarball lags behind the repo)
if [ -d ~/123solar ]; then
    rm -rf ~/123solar
fi
git clone --depth=1 $_123SOLAR_REPO ~/123solar
# Remove any previous install and copy fresh from the repo root
rm -rf /var/www/html/123solar
mkdir -p /var/www/html/123solar
cp -r ~/123solar/* /var/www/html/123solar/
rm -rf ~/123solar
chown -R www-data:www-data /var/www/html/123solar

# Ensure DEBUG mode is off — when DEBUG=true 123solar bypasses systemctl and
# launches php directly, breaking the start/stop buttons in the admin panel.
sed -i "s/\$DEBUG=true/\$DEBUG=false/" /var/www/html/123solar/config/config_main.php

# Download Highcharts locally — code.highcharts.com now returns 403 for CDN
# requests without a license. Files are stored in the repo at highcharts/ and
# copied to the web root. All Highcharts URLs are defined in scripts/links.php.
mkdir -p /var/www/html/123solar/js/highcharts/modules
cp $GIT_PATH/highcharts/highcharts.js /var/www/html/123solar/js/highcharts/
cp $GIT_PATH/highcharts/highcharts-more.js /var/www/html/123solar/js/highcharts/
cp $GIT_PATH/highcharts/modules/drilldown.js /var/www/html/123solar/js/highcharts/modules/
cp $GIT_PATH/highcharts/modules/exporting.js /var/www/html/123solar/js/highcharts/modules/
cp $GIT_PATH/highcharts/modules/annotations.js /var/www/html/123solar/js/highcharts/modules/
chown -R www-data:www-data /var/www/html/123solar/js/highcharts
sed -i 's|https://code.highcharts.com/highcharts.js|/123solar/js/highcharts/highcharts.js|g' /var/www/html/123solar/scripts/links.php
sed -i 's|https://code.highcharts.com/highcharts-more.js|/123solar/js/highcharts/highcharts-more.js|g' /var/www/html/123solar/scripts/links.php
sed -i 's|https://code.highcharts.com/modules/drilldown.js|/123solar/js/highcharts/modules/drilldown.js|g' /var/www/html/123solar/scripts/links.php
sed -i 's|https://code.highcharts.com/modules/exporting.js|/123solar/js/highcharts/modules/exporting.js|g' /var/www/html/123solar/scripts/links.php
sed -i 's|https://code.highcharts.com/modules/annotations.js|/123solar/js/highcharts/modules/annotations.js|g' /var/www/html/123solar/scripts/links.php

# Fix aurora output field index in aurora.php.
# Aurora v1.9.4 outputs 53 fields per line with OK at position 52 (0-indexed).
# The upstream code uses $ok=21 which was designed for an older aurora version
# with shorter output — this causes all readings to be treated as NOK/failed.
sed -i "s/\$ok = 21;/\$ok = 52;/" /var/www/html/123solar/scripts/protocols/aurora.php
sed -i "s/\$ok = 31;/\$ok = 52;/" /var/www/html/123solar/scripts/protocols/aurora.php

# Increase the admin panel start/stop redirect delay from 1s to 4s.
# systemctl stop/start takes a few seconds; without this the page reloads
# before the service state has changed and the button shows the wrong state.
sed -i "s/}, 1000);/}, 4000);/" /var/www/html/123solar/admin/admin.php

# Fix start button bug in admin.php — replace the unreliable ps+PID check
# with a direct systemctl is-active check. The upstream code uses ps to check
# if 123solar is running, but when $PID is empty it matches any 123solar.php
# process (including rogue ones), causing systemctl start to be skipped.
php -r '
$file = "/var/www/html/123solar/admin/admin.php";
$c = file_get_contents($file);
$old = '\''                        exec("$PSCMD | grep $PID | grep 123solar.php", $ret);
                                if (!isset($ret[1])) { // avoid several instances
                                $command = exec("sudo systemctl start 123solar.service");
                                }'\'';
$new = '\''                        $svcstate = exec("systemctl is-active 123solar.service");
                                if ($svcstate != "active") {
                                $command = exec("sudo systemctl start 123solar.service");
                                }'\'';
$c = str_replace($old, $new, $c);
file_put_contents($file, $c);
echo "Done\n";
'
chown www-data:www-data /var/www/html/123solar/admin/admin.php

# Write the 123solar systemd service file directly rather than downloading the
# upstream version, which targets Arch Linux (/srv/http, User=http) and breaks on Ubuntu.
cat > /etc/systemd/system/123solar.service << EOF
[Unit]
Description=123Solar
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/var/www/html/123solar/scripts
ExecStart=/usr/bin/php 123solar.php
ExecStartPost=/bin/sh -c "systemctl show -p MainPID --value 123solar.service > /var/www/html/123solar/scripts/123solar.pid"
ExecStopPost=/usr/bin/rm -f /var/www/html/123solar/scripts/123solar.pid
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Serial port access for www-data
usermod -a -G dialout www-data

# Allow www-data to start/stop the 123solar systemd service without a password.
# This is required for the start/stop buttons in the 123solar web admin panel.
cat > /etc/sudoers.d/123solar << EOF
www-data ALL=(ALL) NOPASSWD: /bin/systemctl start 123solar.service
www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop 123solar.service
EOF
chmod 440 /etc/sudoers.d/123solar

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

    # Rename the real aurora binary so the wrapper can call it explicitly.
    # The wrapper is then symlinked as 'aurora' so 123solar calls it transparently.
    mv /usr/local/bin/aurora /usr/local/bin/aurora-real

    # --- aurora-eth wrapper ---
    # The Waveshare RS485-to-Ethernet adapter uses short-connection mode — it accepts
    # a TCP connection, transfers data, then closes it immediately. A persistent socat
    # bridge therefore doesn't work. Instead this wrapper:
    #   1. Opens a fresh socat TCP->PTY bridge for each aurora call
    #   2. Waits for the virtual port to appear
    #   3. Passes the real /dev/pts path to aurora-real (required because aurora-real
    #      is a setuid root binary that can't follow symlinks in /tmp)
    #   4. Uses flock so parallel 123solar calls queue rather than collide
    #   5. Appends the real port if 123solar omits it (some check calls don't include it)
    cat > /usr/local/bin/aurora-eth << 'WRAPEOF'
#!/bin/bash
ADAPTER_IP=__ADAPTER_IP__
ADAPTER_PORT=__ADAPTER_PORT__
VIRTUAL_PORT=__VIRTUAL_PORT__
LOCKFILE=/tmp/aurora-eth.lock

(
    # Serialise all calls — only one TCP connection to the adapter at a time
    # Exit 0 on timeout so 123solar doesn't treat a queued call as a fatal error
    flock -w 30 200 || exit 0

    rm -f $VIRTUAL_PORT

    # Start socat: fresh TCP connection per call to match adapter's short-connection mode
    socat PTY,link=$VIRTUAL_PORT,b19200,raw,echo=0 TCP:$ADAPTER_IP:$ADAPTER_PORT &
    SOCAT_PID=$!

    # Wait up to 5 seconds for the virtual port symlink to appear
    for i in $(seq 1 10); do
        [ -e "$VIRTUAL_PORT" ] && break
        sleep 0.5
    done

    if [ ! -e "$VIRTUAL_PORT" ]; then
        kill $SOCAT_PID 2>/dev/null
        exit 1
    fi

    REAL_PORT=$(readlink -f $VIRTUAL_PORT)

    # Replace virtual port path with real pts path in args.
    # aurora-real is setuid root and cannot follow symlinks in /tmp,
    # so it must receive the actual /dev/pts/N path directly.
    if echo "$@" | grep -q "$VIRTUAL_PORT"; then
        ARGS="${@/$VIRTUAL_PORT/$REAL_PORT}"
    else
        # Some 123solar check calls (-s, -A) omit the port — append it
        ARGS="$@ $REAL_PORT"
    fi

    aurora-real $ARGS
    RESULT=$?

    kill $SOCAT_PID 2>/dev/null
    wait $SOCAT_PID 2>/dev/null
    rm -f $VIRTUAL_PORT

    # Brief pause to allow adapter to close TCP connection before next call
    sleep 1

    exit $RESULT
) 200>$LOCKFILE
WRAPEOF

    # Substitute real adapter settings into the wrapper
    sed -i "s|__ADAPTER_IP__|${_AURORA_INVERTER_IP}|g" /usr/local/bin/aurora-eth
    sed -i "s|__ADAPTER_PORT__|${_AURORA_INVERTER_PORT}|g" /usr/local/bin/aurora-eth
    sed -i "s|__VIRTUAL_PORT__|${_AURORA_VIRTUAL_PORT}|g" /usr/local/bin/aurora-eth

    chmod +x /usr/local/bin/aurora-eth

    # Symlink aurora -> aurora-eth so 123solar calls the wrapper transparently
    ln -sf /usr/local/bin/aurora-eth /usr/local/bin/aurora

    # Write 123solar inverter config
    # Sets port to $_AURORA_VIRTUAL_PORT and communication options known to work
    # with the Aurora Power One inverter at RS485 address 1 via the Waveshare adapter.
    # -D flag is required because socat PTY devices don't support Unix serial locking.
    SOLAR_CFG_DIR=/var/www/html/123solar/config
    mkdir -p $SOLAR_CFG_DIR
    cat > $SOLAR_CFG_DIR/config_invt1.php << EOF
<?php
// ### GENERAL FOR INVERTER #1
\$INVNAME1="Invertor";
// ### SPECS
\$PLANT_POWER1=4600;
\$PHASE1=false;
\$CORRECTFACTOR1=1;
\$PASSO1=9999999;
\$SR1='no';
// #### PROTOCOL
\$PORT1='${_AURORA_VIRTUAL_PORT}';
\$PROTOCOL1='aurora';
\$ADR1='1';
\$COMOPTION1='-U25 -Y50 -w10 -a1 -d0 -D';
\$SYNC1=true;
\$LOGCOM1=false;
\$SKIPMONITORING1=false;
EOF
    chown www-data:www-data $SOLAR_CFG_DIR/config_invt1.php

    # Create required data directories
    mkdir -p /var/www/html/123solar/data/invt1/infos
    chown -R www-data:www-data /var/www/html/123solar/data

    echo ""
    echo "Aurora wrapper installed:"
    echo "  aurora-real : /usr/local/bin/aurora-real (original binary)"
    echo "  aurora-eth  : /usr/local/bin/aurora-eth  (socat TCP wrapper)"
    echo "  aurora      : /usr/local/bin/aurora -> aurora-eth (symlink)"
    echo "  Adapter     : ${_AURORA_INVERTER_IP}:${_AURORA_INVERTER_PORT}"
    echo "  Virtual port: ${_AURORA_VIRTUAL_PORT}"
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
echo "Next steps:"
echo "  1. Access 123solar at http://$(hostname -I | awk '{print $1}')/123solar"
echo "  2. Log in to the admin panel and verify inverter settings:"
echo "       Port    : ${_AURORA_VIRTUAL_PORT}"
echo "       Protocol: aurora"
echo "       Options : -U25 -Y50 -w10 -a1 -d0 -D"
echo "  3. Configure msmtp email:"
echo "       sudo nano /etc/msmtprc"
echo ""
echo "To verify aurora is communicating with the inverter:"
echo "  sudo -u www-data /usr/local/bin/aurora-eth -U25 -Y50 -w10 -a1 -d0"
