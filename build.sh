#!/bin/sh

set -x
set -e

# persistent / runtime deps
export PHPIZE_DEPS="\
        autoconf \
        dpkg-dev dpkg \
        file \
        g++ \
        gcc \
        libc-dev \
        make \
        pcre-dev \
        pkgconf \
        re2c"

apk add --no-cache --virtual .persistent-deps \
        ca-certificates \
        curl \
        tar \
        xz

# ensure www-data user exists
addgroup -g 82 -S www-data
adduser -u 82 -D -S -G www-data www-data

# 82 is the standard uid/gid for "www-data" in Alpine
# http://git.alpinelinux.org/cgit/aports/tree/main/apache2/apache2.pre-install?h=v3.3.2
# http://git.alpinelinux.org/cgit/aports/tree/main/lighttpd/lighttpd.pre-install?h=v3.3.2
# http://git.alpinelinux.org/cgit/aports/tree/main/nginx-initscripts/nginx-initscripts.pre-install?h=v3.3.2

export PHP_INI_DIR=/usr/local/etc/php
mkdir -p $PHP_INI_DIR/conf.d

apk add --update apache2
export APACHE_CONFDIR=/etc/apache2
export APACHE_ENVVARS=$APACHE_CONFDIR/envvars

if [ ! -e "$APACHE_ENVVARS" ]; then
    cat <<EOF > "$APACHE_ENVVARS"
export APACHE_LOCK_DIR=/var/lock/apache2
export APACHE_LOG_DIR=/var/log/apache2
export APACHE_RUN_DIR=/var/run/apache2
export APACHE_RUN_GROUP=www-data
export APACHE_RUN_USER=www-data
EOF
fi

# generically convert lines like
#   export APACHE_RUN_USER=www-data
# into
#   : ${APACHE_RUN_USER:=www-data}
#   export APACHE_RUN_USER
# so that they can be overridden at runtime ("-e APACHE_RUN_USER=...")
sed -ri 's/^export ([^=]+)=(.*)$/: ${\1:=\2}\nexport \1/' "$APACHE_ENVVARS"

# setup directories and permissions
. "$APACHE_ENVVARS"
for dir in \
    "$APACHE_LOCK_DIR" \
    "$APACHE_RUN_DIR" \
    "$APACHE_LOG_DIR" \
    /var/www/html \
; do
    rm -rvf "$dir";
    mkdir -p "$dir";
    chown -R "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$dir";
done

# logs should go to stdout / stderr

ln -sfT /dev/stderr "$APACHE_LOG_DIR/error.log"
ln -sfT /dev/stdout "$APACHE_LOG_DIR/access.log"
ln -sfT /dev/stdout "$APACHE_LOG_DIR/other_vhosts_access.log"

# PHP files should be handled by PHP, and should be preferred over any other file type
{ \
        echo '<FilesMatch \.php$>'; \
        echo '  SetHandler application/x-httpd-php'; \
        echo '</FilesMatch>'; \
        echo; \
        echo 'DirectoryIndex disabled'; \
        echo 'DirectoryIndex index.php index.html'; \
        echo; \
        echo '<Directory /var/www/>'; \
        echo '  Options -Indexes'; \
        echo '  AllowOverride All'; \
        echo '</Directory>'; \
} | tee "$APACHE_CONFDIR/conf.d/docker-php.conf"

export PHP_EXTRA_BUILD_DEPS=apache2-dev
export PHP_EXTRA_CONFIGURE_ARGS=--with-apxs2

# Apply stack smash protection to functions using local buffers and alloca()
# Make PHP's main executable position-independent (improves ASLR security mechanism, and has no performance impact on x86_64)
# Enable optimization (-O2)
# Enable linker optimization (this sorts the hash buckets to improve cache locality, and is non-default)
# Adds GNU HASH segments to generated executables (this is used if present, and is much faster than sysv hash; in this configuration, sysv hash is also generated)
# https://github.com/docker-library/php/issues/272
export PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2"
export PHP_CPPFLAGS="$PHP_CFLAGS"
export PHP_LDFLAGS="-Wl,-O1 -Wl,--hash-style=both -pie"

export GPG_KEYS="A917B1ECDA84AEC2B568FED6F50ABC807BD5DCD0 528995BFEDFBA7191D46839EF9BA0ADA31CBD89E"

export PHP_VERSION=7.1.7
export PHP_URL="https://secure.php.net/get/php-7.1.7.tar.xz/from/this/mirror" PHP_ASC_URL="https://secure.php.net/get/php-7.1.7.tar.xz.asc/from/this/mirror"
export PHP_SHA256="0d42089729be7b2bb0308cbe189c2782f9cb4b07078c8a235495be5874fff729" PHP_MD5=""

apk add --no-cache --virtual .fetch-deps \
    gnupg \
    openssl

mkdir -p /usr/src
cd /usr/src

wget -O php.tar.xz "$PHP_URL"

if [ -n "$PHP_SHA256" ]; then
    echo "$PHP_SHA256 *php.tar.xz" | sha256sum -c -;
fi

if [ -n "$PHP_MD5" ]; then
    echo "$PHP_MD5 *php.tar.xz" | md5sum -c -;
fi

if [ -n "$PHP_ASC_URL" ]; then
    wget -O php.tar.xz.asc "$PHP_ASC_URL";
    export GNUPGHOME="$(mktemp -d)"
    for key in $GPG_KEYS; do
        set +e;
        # ha.pool.sks-keyservers.net 
        gpg --keyserver pgp.mit.edu --recv-keys "$key";
        set -e;
    done
    gpg --batch --verify php.tar.xz.asc php.tar.xz;
    rm -rf "$GNUPGHOME"
fi

apk del .fetch-deps

apk add --no-cache --virtual .build-deps \
    $PHPIZE_DEPS \
    apache2-dev \
    coreutils \
    curl-dev \
    icu-dev \
    libedit-dev \
    libxml2-dev \
    openssl-dev \
    sqlite-dev

export CFLAGS="$PHP_CFLAGS" \
    CPPFLAGS="$PHP_CPPFLAGS" \
    LDFLAGS="$PHP_LDFLAGS"

docker-php-source extract

cd /usr/src/php

gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"

./configure \
    --build="$gnuArch" \
    --with-config-file-path="$PHP_INI_DIR" \
    --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
    --disable-cgi \
    --enable-ftp \
    --enable-mbstring \
    --enable-mysqlnd \
    --enable-intl \
    \
    --with-curl \
    --with-libedit \
    --with-openssl \
    --with-zlib \
    --with-pcre-regex=/usr \
    \
    $PHP_EXTRA_CONFIGURE_ARGS

make -j "$(nproc)"
make install
find /usr/local/bin /usr/local/sbin -type f -perm +0111 -exec strip --strip-all '{}' + || true;
sed -i 's|lib/apache2/libphp7.so|modules/libphp7.so|' /etc/apache2/httpd.conf
sed -i 's|Listen 80|Listen 8000|' /etc/apache2/httpd.conf
sed -i 's|PidFile "/run/apache2/httpd.pid"|PidFile "/var/run/apache2/httpd.pid"|' /etc/apache2/conf.d/mpm.conf

make clean
cd /
docker-php-source delete

runDeps="$( \
    scanelf --needed --nobanner --recursive /usr/local \
        | awk '{ gsub(/,/, "\nso:", $2); print "so:" $2 }' \
        | sort -u \
        | xargs -r apk info --installed \
        | sort -u \
)"

apk add --no-cache --virtual .php-rundeps $runDeps
apk del .build-deps

# https://github.com/docker-library/php/issues/443
pecl update-channels
rm -rf /tmp/pear ~/.pearrc