<?php
// Наполнение сайта-фикстуры стенда через API MODX. Запускается в контейнере
// приложения, докрут фикстуры смонтирован по пути старой площадки. Только
// для stand.sh: в стек не копируется.
//
// Что кладётся и зачем:
//   - две страницы на своём шаблоне и одна на базовом: приёмка сравнивает
//     тела с главной и между шаблонами;
//   - картинка через медиа-источник, у которого относительный адрес с
//     ведущим слэшем и абсолютный путь старой площадки в сериализованных
//     свойствах: до правки тело несёт //assets/;
//   - строка site_url со старым адресом: перекрывает адрес, выведенный из
//     имени хоста;
//   - второй пользователь без полного доступа и сессии старой площадки.

$root = $argv[1];
require $root . '/config.core.php';
require MODX_CORE_PATH . 'vendor/autoload.php';
$modx = new \MODX\Revolution\modX();
$modx->initialize('mgr');

function must(bool $ok, string $what): void
{
    if (!$ok) {
        fwrite(STDERR, "фикстура: не удалось $what\n");
        exit(1);
    }
}

function setting(\MODX\Revolution\modX $modx, string $key, string $value): void
{
    $s = $modx->getObject(\MODX\Revolution\modSystemSetting::class, ['key' => $key])
        ?: $modx->newObject(\MODX\Revolution\modSystemSetting::class);
    $s->fromArray(['key' => $key, 'value' => $value, 'xtype' => 'textfield', 'namespace' => 'core', 'area' => 'site'], '', true, true);
    must($s->save(), "настройку $key");
}

setting($modx, 'friendly_urls', '1');
setting($modx, 'use_alias_path', '1');
setting($modx, 'site_url', 'http://old.example.test/');

$prop = static fn (string $name, $value, string $type = 'textfield') => [
    'name' => $name, 'desc' => '', 'type' => $type, 'options' => [], 'value' => $value, 'lexicon' => 'core:source',
];
$source = $modx->newObject(\MODX\Revolution\Sources\modFileMediaSource::class);
$source->fromArray(['name' => 'Images', 'description' => '', 'class_key' => \MODX\Revolution\Sources\modFileMediaSource::class]);
$source->set('properties', [
    'basePath' => $prop('basePath', $root . '/assets/images/'),
    'basePathRelative' => $prop('basePathRelative', false, 'combo-boolean'),
    'baseUrl' => $prop('baseUrl', '/assets/images/'),
    'baseUrlRelative' => $prop('baseUrlRelative', true, 'combo-boolean'),
]);
must($source->save(), 'медиа-источник');

// Адрес картинки собирается как base_url плюс адрес из источника: так
// собирало логотипы расширение настроек в кейсе. С ведущим слэшем в baseUrl
// источника это даёт //assets/..., без него /assets/...
$tpl = $modx->newObject(\MODX\Revolution\modTemplate::class);
$tpl->fromArray(['templatename' => 'Inner', 'content' =>
    "<!doctype html>\n<html><head><title>[[*pagetitle]]</title></head>\n<body><h1>[[*pagetitle]]</h1>\n[[*content]]\n<img src=\"[[++base_url]][[*photo]]\" alt=\"\">\n</body></html>\n"]);
must($tpl->save(), 'шаблон');

$tv = $modx->newObject(\MODX\Revolution\modTemplateVar::class);
$tv->fromArray(['name' => 'photo', 'caption' => 'Photo', 'type' => 'image', 'default_text' => '']);
must($tv->save(), 'дополнительное поле');
$link = $modx->newObject(\MODX\Revolution\modTemplateVarTemplate::class);
$link->fromArray(['tmplvarid' => $tv->get('id'), 'templateid' => $tpl->get('id'), 'rank' => 0], '', true, true);
must($link->save(), 'поле в шаблоне');
$sourceLink = $modx->newObject(\MODX\Revolution\Sources\modMediaSourceElement::class);
$sourceLink->fromArray(['source' => $source->get('id'), 'object_class' => \MODX\Revolution\modTemplateVar::class,
    'object' => $tv->get('id'), 'context_key' => 'web'], '', true, true);
must($sourceLink->save(), 'источник поля');

function page(\MODX\Revolution\modX $modx, array $data): int
{
    $r = $modx->newObject(\MODX\Revolution\modDocument::class);
    $r->fromArray($data + ['published' => 1, 'deleted' => 0, 'parent' => 0, 'isfolder' => 0,
        'class_key' => \MODX\Revolution\modDocument::class, 'content_type' => 1,
        'context_key' => 'web', 'richtext' => 0, 'searchable' => 1, 'cacheable' => 1]);
    must($r->save(), 'страницу ' . $data['alias']);

    return $r->get('id');
}

$katalog = page($modx, ['pagetitle' => 'Katalog', 'alias' => 'katalog', 'uri' => 'katalog/', 'isfolder' => 1,
    'template' => $tpl->get('id'), 'content' => '<p>stand-katalog-body</p>']);
page($modx, ['pagetitle' => 'Item', 'alias' => 'item', 'uri' => 'katalog/item.html', 'parent' => $katalog,
    'template' => $tpl->get('id'), 'content' => '<p>stand-item-body</p>']);
page($modx, ['pagetitle' => 'Kontakty', 'alias' => 'kontakty', 'uri' => 'kontakty.html', 'template' => 1,
    'content' => '<p>stand-kontakty-body</p>']);
$value = $modx->newObject(\MODX\Revolution\modTemplateVarResource::class);
$value->fromArray(['tmplvarid' => $tv->get('id'), 'contentid' => $katalog, 'value' => 'x.png'], '', true, true);
must($value->save(), 'значение поля');

$user = $modx->newObject(\MODX\Revolution\modUser::class);
$user->fromArray(['username' => 'editor', 'active' => 1, 'sudo' => 0]);
$user->set('password', 'stand-editor-pass-1');
$profile = $modx->newObject(\MODX\Revolution\modUserProfile::class);
$profile->fromArray(['email' => 'editor@example.test', 'fullname' => 'Editor']);
$user->addOne($profile);
must($user->save(), 'пользователя');

$modx->exec("INSERT INTO {$modx->getTableName(\MODX\Revolution\modSession::class)} (id, access, data) VALUES ('stolen-manager-session', UNIX_TIMESTAMP(), 'modx.user.contextTokens|a:1:{s:3:\"mgr\";i:1;}')");
$modx->cacheManager->refresh();
echo "фикстура: katalog=$katalog source=", $source->get('id'), " tv=", $tv->get('id'), "\n";
