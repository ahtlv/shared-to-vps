FROM php:{{PHP_VERSION}}-fpm-alpine

# Образ уже несёт curl, mbstring, dom, xml, json и opcache, поэтому
# доставляются только те расширения, которых в нём нет. Набор общий для
# WordPress и MODX: mysqli нужен первому, pdo_mysql второму (без него xPDO
# не подключается к базе вовсе). Слой адаптера поверх этого образа до
# работающего приложения не доехал бы: контейнер собирается отсюда, поэтому
# драйвер базы любой поддерживаемой CMS живёт здесь.
# fcgi нужен ради cgi-fcgi: им healthcheck пингует сам FPM.
RUN set -eux; \
    apk add --no-cache \
        fcgi \
        freetype \
        icu-libs \
        imagemagick \
        imagemagick-libs \
        libjpeg-turbo \
        libpng \
        libwebp \
        libzip; \
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        freetype-dev \
        icu-dev \
        imagemagick-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libzip-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" exif gd intl mysqli pdo_mysql zip; \
    pecl install imagick; \
    docker-php-ext-enable imagick; \
    pecl clear-cache; \
    apk del .build-deps; \
    php -m

COPY php.ini /usr/local/etc/php/conf.d/99-{{SLUG}}.ini
# Имя длиннее zz-docker.conf официального образа: тот объявляет [www] с
# listen 9000, и наши настройки пула должны читаться после него.
COPY pool.conf /usr/local/etc/php-fpm.d/zzz-{{SLUG}}.conf
COPY placeholder-index.php /usr/local/share/{{SLUG}}-placeholder/index.php
COPY docker-entrypoint.sh /usr/local/bin/{{SLUG}}-entrypoint

RUN chmod 755 /usr/local/bin/{{SLUG}}-entrypoint

ENTRYPOINT ["{{SLUG}}-entrypoint"]
CMD ["php-fpm"]
