# Выборка опубликованных страниц для смоука и приёмки. Подключается точкой
# после lib.sh.
#
# sample_pages PREFIX N: до N строк «путь<TAB>id», страницы HTML, не главная,
# по одной на шаблон: копия одного шаблона не должна пройти за два разных
# адреса. Путь такой, каким его видит посетитель: с дружественными адресами
# из uri ресурса, без них через index.php?id=.
sample_pages() {
    p=$1
    start=$(sql "$db_name" -e "SELECT value FROM \`${p}system_settings\` WHERE \`key\` = 'site_start'" 2>/dev/null)
    furls=$(sql "$db_name" -e "SELECT value FROM \`${p}system_settings\` WHERE \`key\` = 'friendly_urls'" 2>/dev/null)
    sql "$db_name" -e "SELECT c.id, c.uri FROM \`${p}site_content\` c JOIN (
            SELECT MIN(id) AS id FROM \`${p}site_content\`
            WHERE published = 1 AND deleted = 0 AND class_key LIKE '%modDocument' AND id <> '${start:-1}' AND uri <> ''
              AND content_type IN (SELECT id FROM \`${p}content_type\` WHERE mime_type = 'text/html')
            GROUP BY template) m ON m.id = c.id
        ORDER BY c.id LIMIT $2" \
        | while IFS="$(printf '\t')" read -r id uri; do
            if [ "$furls" = 1 ]; then printf '/%s\t%s\n' "$uri" "$id"
            else printf '/index.php?id=%s\t%s\n' "$id" "$id"; fi
        done
}
