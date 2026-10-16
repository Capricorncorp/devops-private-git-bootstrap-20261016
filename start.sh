#!/bin/sh
set -eu
umask 077

if [ "$(id -u)" != 0 ]; then
    printf '%s\n' 'The fixture must start as root; Apache CGI runs as daemon.' >&2
    exit 1
fi

# No repository is initialized here. Import the actual private bundle separately.
mkdir -p /srv/git
chown root:daemon /srv/git
chmod 0750 /srv/git

# 32 random bytes, hex encoded. Neither credential is passed in process arguments.
openssl rand -hex 32 > /run/mirror-read-token
chown root:root /run/mirror-read-token
chmod 0600 /run/mirror-read-token
htpasswd -i -B -c /run/mirror-reader.htpasswd fixture-reader \
    < /run/mirror-read-token > /dev/null 2>&1
chown root:daemon /run/mirror-reader.htpasswd
chmod 0640 /run/mirror-reader.htpasswd

# This disposable acceptance credential is valid for one hour at most.
( sleep 3600; : > /run/mirror-reader.htpasswd; rm -f /run/mirror-read-token ) &

exec httpd -DFOREGROUND -f /usr/local/apache2/conf/httpd.conf
