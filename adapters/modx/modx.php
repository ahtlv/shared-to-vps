<?php
// Правки и проверки MODX изнутри приложения. Запускается из lib.sh:
//
//   modx_php fix OLD_ROOT URL пути старой площадки в настройках, адрес, медиа-источники, сессии
//   modx_php paths            эффективные пути ядра и подключение к базе
//   modx_php media            медиа-источники, адреса которых соберутся с двойным слэшем
//
// Реквизиты базы берутся из конфига сайта, а не из .env стека: если конфиг и
// база разошлись, это видно здесь же, отказом подключения, а не 500 на всём
// сайте после запуска.
//
// Объявления строгих типов здесь нет намеренно: файл уходит в PHP через stdin,
// и так он работает одинаково в любом способе запуска.

$args = array_slice($argv, 1);
$command = $args[0] ?? '';
$root = '/var/www/html';

function fail(string $message): void
{
    fwrite(STDERR, $message . "\n");
    exit(1);
}

require $root . '/config.core.php';
require MODX_CORE_PATH . 'config/' . MODX_CONFIG_KEY . '.inc.php';

try {
    $pdo = new PDO($database_dsn, $database_user, $database_password, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
} catch (PDOException $e) {
    // Текст исключения называет пользователя, но не пароль.
    fail('конфиг сайта не подключается к базе: ' . $e->getMessage());
}
if (!preg_match('/^[A-Za-z0-9_]+$/', $table_prefix)) {
    fail('префикс таблиц не из [A-Za-z0-9_]');
}
$t = static fn (string $name): string => '`' . $table_prefix . $name . '`';

function table_exists(PDO $pdo, string $table): bool
{
    $stmt = $pdo->prepare('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?');
    $stmt->execute([trim($table, '`')]);

    return (int) $stmt->fetchColumn() === 1;
}

// Медиа-источник с относительным адресом, который начинается со слэша. MODX и
// расширения собирают адрес как base_url плюс baseUrl источника: '/' и
// '/assets/...' дают '//assets/...', а браузер читает это как адрес на хосте
// assets. Страница при этом отвечает 200, картинки молча не грузятся.
// Правка настройки не должна менять время её правки. У таблиц настроек
// editedon обновляется сам при любом UPDATE, и два одинаковых
// разворачивания давали бы разные таблицы в зависимости от минуты запуска.
function keep_edited(PDO $pdo, string $table): string
{
    $stmt = $pdo->prepare('SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?');
    $stmt->execute([trim($table, '`'), 'editedon']);

    return (int) $stmt->fetchColumn() === 1 ? ', editedon = editedon' : '';
}

function media_problems(array $properties, string $oldRoot, string $root): array
{
    $problems = [];
    $relative = $properties['baseUrlRelative']['value'] ?? true;
    $baseUrl = $properties['baseUrl']['value'] ?? null;
    if ($relative && is_string($baseUrl) && str_starts_with($baseUrl, '/')) {
        $problems['baseUrl'] = ltrim($baseUrl, '/');
    }
    $basePath = $properties['basePath']['value'] ?? null;
    if ($oldRoot !== '' && is_string($basePath) && str_starts_with($basePath, $oldRoot . '/')) {
        $problems['basePath'] = $root . substr($basePath, strlen($oldRoot));
    }

    return $problems;
}

function media_rows(PDO $pdo, string $table): array
{
    $rows = [];
    foreach ($pdo->query("SELECT id, name, properties FROM $table ORDER BY id") as $row) {
        $properties = $row['properties'] === '' || $row['properties'] === null
            ? [] : @unserialize($row['properties'], ['allowed_classes' => false]);
        if (!is_array($properties)) {
            fail("медиа-источник {$row['id']}: свойства не разбираются, правка вслепую испортила бы их");
        }
        $rows[] = [$row['id'], $row['name'], $properties];
    }

    return $rows;
}

if ($command === 'paths') {
    foreach (['MODX_CORE_PATH', 'MODX_PROCESSORS_PATH', 'MODX_CONNECTORS_PATH', 'MODX_MANAGER_PATH', 'MODX_BASE_PATH', 'MODX_ASSETS_PATH'] as $name) {
        echo $name, '=', defined($name) ? constant($name) : '(нет)', "\n";
    }
    echo "DB=ok\n";
    exit(0);
}

if ($command === 'media') {
    foreach (media_rows($pdo, $t('media_sources')) as [$id, $name, $properties]) {
        foreach (media_problems($properties, '', $root) as $key => $fixed) {
            echo "$id $name $key=", $properties[$key]['value'], "\n";
        }
    }
    exit(0);
}

if ($command === 'fix') {
    $oldRoot = rtrim($args[1] ?? '', '/');
    $url = $args[2] ?? '';
    if (!preg_match('~^https://[^/]+/$~', $url)) {
        fail('fix: адрес сайта вида https://хост/');
    }
    if ($oldRoot === '' || $oldRoot === $root) {
        $oldRoot = '';
    }
    $pdo->beginTransaction();
    if ($oldRoot !== '') {
        // Строковые настройки, не сериализованные: простая замена безопасна.
        foreach (['system_settings', 'context_setting', 'user_settings'] as $name) {
            if (!table_exists($pdo, $t($name))) {
                continue;
            }
            $stmt = $pdo->prepare('UPDATE ' . $t($name) . ' SET value = REPLACE(value, ?, ?)' . keep_edited($pdo, $t($name)) . ' WHERE value LIKE ?');
            $stmt->execute([$oldRoot . '/', $root . '/', '%' . addcslashes($oldRoot, '%_\\') . '/%']);
            echo "настройки $name: путей старой площадки переписано ", $stmt->rowCount(), "\n";
        }
    }
    // Адрес сайта MODX обычно выводит из имени хоста запроса, и строки в
    // настройках нет. Если она есть, она перекрывает вывод и обязана быть новой.
    $stmt = $pdo->prepare('UPDATE ' . $t('system_settings') . ' SET value = ?' . keep_edited($pdo, $t('system_settings')) . " WHERE `key` = 'site_url' AND value <> ?");
    $stmt->execute([$url, $url]);
    echo "адрес сайта в настройках: ", $stmt->rowCount() ? "переписан на $url" : 'не задан или уже верный', "\n";
    // Свойства источника сериализованы: REPLACE по строке испортил бы длины,
    // и PHP молча прочитал бы false вместо настроек. Разбирается и собирается.
    $update = $pdo->prepare('UPDATE ' . $t('media_sources') . ' SET properties = ?' . keep_edited($pdo, $t('media_sources')) . ' WHERE id = ?');
    foreach (media_rows($pdo, $t('media_sources')) as [$id, $name, $properties]) {
        $problems = media_problems($properties, $oldRoot, $root);
        foreach ($problems as $key => $fixed) {
            echo "медиа-источник $id ($name): $key '", $properties[$key]['value'], "' -> '$fixed'\n";
            $properties[$key]['value'] = $fixed;
        }
        if ($problems) {
            $update->execute([serialize($properties), $id]);
        }
    }
    // Сессии старой площадки, включая вход в менеджер: украденная там кука
    // не должна открывать новую.
    if (table_exists($pdo, $t('session'))) {
        $pdo->exec('DELETE FROM ' . $t('session'));
        echo "сессии старой площадки удалены\n";
    }
    $pdo->commit();
    exit(0);
}

fail("неизвестная команда: $command");
