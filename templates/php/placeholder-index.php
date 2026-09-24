<?php
declare(strict_types=1);

// Трассирующая пуля: доказывает путь обратный прокси → nginx → php-fpm
// целиком. Заголовок ставит PHP, подделать его nginx не может, поэтому
// именно он отличает «ответил PHP» от «ответила статика или страница ошибки
// nginx». Служит до Ф3: после разворачивания сайта страница заменяется
// содержимым площадки.
header('Content-Type: text/plain; charset=utf-8');
header('X-Stack-Tracer: php-fpm');

printf("{{SLUG}} tracer bullet is responding\nPHP %s\n", PHP_VERSION);
