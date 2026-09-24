#!/bin/sh
set -eu

# Том намеренно долгоживущий: Ф3 заменит эту одну страницу проверенным
# снимком сайта. Заполненный том не перезаписывается никогда, иначе повторный
# запуск стека затёр бы уже развёрнутый сайт заглушкой.
if [ -z "$(find /var/www/html -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    cp -a /usr/local/share/{{SLUG}}-placeholder/. /var/www/html/
    chown -R www-data:www-data /var/www/html
fi

exec docker-php-entrypoint "$@"
