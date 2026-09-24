"""Юнит-тесты адаптера MODX без докера и без сети.

    python3 adapters/modx/test_adapter.py

Здесь проверяется то, что ломается тихо: генератор редиректов, который
оставил бы бесконечный редирект или повтор ключа, из-за которого веб-сервер
не стартует; распаковка, которая пропустила бы путь наружу; конфиг, в
котором остался старый пароль или старый путь. Разворачивание целиком
проверяет stand.sh на докере.
"""

from __future__ import annotations

import importlib.util
import io
import re
import stat
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


gen = load("htaccess_to_nginx", "htaccess-to-nginx.py")
helper = load("modx_restore_helper", "restore_helper.py")


class TempDir(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()


# Фикстура из плана: два самоперехода, цепочка в два прыжка, повтор ключа,
# обычное правило. Плюс то, что лежит в .htaccess любого сайта на MODX и
# редиректом со старой структуры не является.
HTACCESS = """\
RewriteEngine On
RewriteBase /

# www и https решает обратный прокси
RewriteCond %{HTTP_HOST} ^www\\.(.*)$ [NC]
RewriteRule ^(.*)$ https://%1/$1 [R=301,L]

RewriteRule ^katalog/$ https://example.test/katalog/ [R=301,L]
RewriteRule ^uslugi/$ /uslugi/ [R=301,L]
RewriteRule ^old-blog/post/$ https://example.test/blog/post/ [R=301,L]
RewriteRule ^blog/post/$ /stati/post/ [R=301,L]
RewriteRule ^sklad/$ /katalog/ [R=301,L]
RewriteRule ^sklad/$ /katalog/ [R=301,L]
RewriteRule ^contacts/$ /kontakty/ [R=301,L]

# Friendly URLs
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule ^(.*)$ index.php?q=$1 [L,QSA]
"""


class RedirectGeneratorTest(TempDir):
    def convert(self, text: str, host: str = "example.test") -> gen.Result:
        return gen.convert(text, hosts={host})

    def locations(self, result: gen.Result) -> dict[str, str]:
        """Точные location и их цели из готового конфига."""
        found = {}
        for match in re.finditer(r'location = "([^"]*)" \{ return (\d+) "([^"]*)"; \}', result.config):
            found[match.group(1)] = f"{match.group(2)} {match.group(3)}"
        return found

    def test_plan_fixture(self) -> None:
        result = self.convert(HTACCESS)
        rules = self.locations(result)
        # Самопереходы выброшены: на новом сервере это бесконечный редирект.
        self.assertNotIn("/katalog/", rules)
        self.assertNotIn("/uslugi/", rules)
        self.assertEqual(result.self_loops, ["/katalog/", "/uslugi/"])
        # Цепочка схлопнута в один прыжок.
        self.assertEqual(rules["/old-blog/post/"], "301 https://$host/stati/post/$is_args$args")
        self.assertEqual(rules["/blog/post/"], "301 https://$host/stati/post/$is_args$args")
        self.assertEqual(result.chains, ["/old-blog/post/ -> /blog/post/ -> /stati/post/"])
        # Повтор ключа устранён: второй location с тем же путём не даёт
        # веб-серверу стартовать.
        self.assertEqual(result.config.count('location = "/sklad/"'), 1)
        self.assertEqual(result.duplicates, 1)
        # Обычные правила на месте, ни одно не потеряно.
        self.assertEqual(rules["/sklad/"], "301 https://$host/katalog/$is_args$args")
        self.assertEqual(rules["/contacts/"], "301 https://$host/kontakty/$is_args$args")
        self.assertEqual(result.lost, [])
        self.assertEqual(len(rules), 4)
        # Условное на хост и внутренняя перезапись не редиректы со старой
        # структуры: их не переносят и не считают потерянными.
        self.assertEqual(len(result.proxy_conditional), 1)
        self.assertEqual(result.not_redirects, 1)
        self.assertEqual(result.exit_code, 0)

    def test_config_has_no_duplicate_keys(self) -> None:
        keys = re.findall(r"location (=|\^~|~\*?) (\"[^\"]*\")", self.convert(HTACCESS).config)
        self.assertEqual(len(keys), len(set(keys)))

    def test_cycle_is_unresolvable(self) -> None:
        result = self.convert("RewriteRule ^a/$ /b/ [R=301,L]\nRewriteRule ^b/$ /a/ [R=301,L]\nRewriteRule ^c/$ /d/ [R=301,L]\n")
        self.assertEqual(result.exit_code, 1)
        self.assertEqual(result.cycles, ["/a/ -> /b/ -> /a/", "/b/ -> /a/ -> /b/"])

    def test_first_rule_wins_on_conflicting_duplicate(self) -> None:
        # Apache отвечает первым совпавшим правилом, второе не срабатывало никогда.
        result = self.convert("RewriteRule ^a/$ /first/ [R=301,L]\nRewriteRule ^a/$ /second/ [R=301,L]\n")
        self.assertEqual(self.locations(result)["/a/"], "301 https://$host/first/$is_args$args")
        self.assertEqual(result.conflicts, ["/a/: /first/, повтор /second/ не срабатывал"])
        self.assertEqual(result.exit_code, 0)

    def test_chain_through_self_loop_ends_at_it(self) -> None:
        result = self.convert("RewriteRule ^a/$ /b/ [R=301,L]\nRewriteRule ^b/$ /b/ [R=301,L]\n")
        self.assertEqual(self.locations(result), {"/a/": "301 https://$host/b/$is_args$args"})

    def test_prefix_and_its_own_loop(self) -> None:
        result = self.convert("RewriteRule ^sklad/ /katalog/ [R=301,L]\nRewriteRule ^old /old-new/ [R=301,L]\n")
        self.assertIn('location ^~ "/sklad/" { return 301 "https://$host/katalog/$is_args$args"; }', result.config)
        # Префикс, который ведёт внутрь себя, редиректит бесконечно.
        self.assertEqual(result.self_loops, ["/old"])

    def test_query_and_codes(self) -> None:
        result = self.convert(
            "RewriteRule ^a/$ /b/?x=1 [R=301,L]\n"
            "RewriteRule ^c/$ /d/?x=1 [R=301,QSA,L]\n"
            "RewriteRule ^e/$ /f/ [R,L]\n"
            "RewriteRule ^g/$ https://other.test/h/ [R=301,L]\n"
        )
        rules = self.locations(result)
        self.assertEqual(rules["/a/"], "301 https://$host/b/?x=1")
        self.assertEqual(rules["/c/"], "301 https://$host/d/?x=1&$args")
        self.assertEqual(rules["/e/"], "302 https://$host/f/$is_args$args")
        # Чужой адрес это законный внешний редирект, а не потеря.
        self.assertEqual(rules["/g/"], "301 https://other.test/h/$is_args$args")

    def test_regex_rule_keeps_order_and_backreference(self) -> None:
        result = self.convert("RewriteRule ^product/(.+)/$ /katalog/$1/ [R=301,NC,L]\n")
        self.assertIn('location ~* "^/product/(.+)/$" { return 301 "https://$host/katalog/$1/$is_args$args"; }', result.config)

    def test_escaped_dot_is_literal(self) -> None:
        result = self.convert("RewriteRule ^download/file\\.pdf$ /file.pdf [R=301,L]\n")
        self.assertEqual(self.locations(result), {"/download/file.pdf": "301 https://$host/file.pdf$is_args$args"})

    def test_untranslatable_rule_is_lost_and_fails(self) -> None:
        for line in (
            "RewriteCond %{QUERY_STRING} ^p=12$\nRewriteRule ^$ /page/ [R=301,L]\n",
            "RewriteRule unanchored/ /x/ [R=301,L]\n",
            "RewriteRule ^a$b/$ /x/ [R=301,L]\n",
            "RewriteRule ^a/$ - [R=301,L]\n",
        ):
            with self.subTest(line=line):
                result = self.convert(line)
                self.assertEqual(result.exit_code, 1)
                self.assertEqual(len(result.lost), 1)

    def test_quoted_pattern_and_target(self) -> None:
        # Так пишет шаблоны .htaccess из поставки MODX.
        result = self.convert('RewriteRule "^old/$" "/new/" [R=301,L]\nRewriteRule "^\\.well-known/" - [L]\n')
        self.assertEqual(self.locations(result), {"/old/": "301 https://$host/new/$is_args$args"})
        self.assertEqual(result.not_redirects, 1)

    def test_junk_after_flags_is_not_silently_ignored(self) -> None:
        result = self.convert("RewriteRule ^a/$ /b/ [R=301,L] .\n")
        self.assertEqual(result.not_redirects, 0)
        self.assertEqual(len(result.lost), 1)

    def test_rewrite_base_applies_to_relative_target_not_pattern(self) -> None:
        # Шаблон в .htaccess корня отсчитывается от корня; RewriteBase
        # подставляется только в относительную цель.
        result = self.convert("RewriteBase /shop/\nRewriteRule ^old$ new [R=301,L]\n")
        self.assertEqual(self.locations(result), {"/old": "301 https://$host/shop/new$is_args$args"})

    def test_chain_is_permanent_only_if_every_hop_is(self) -> None:
        result = self.convert("RewriteRule ^a$ /b [R=301,L]\nRewriteRule ^b$ /c [R,L]\n"
                              "RewriteRule ^d$ /e [R=301,L]\nRewriteRule ^e$ /f [R=301,L]\n"
                              "RewriteRule ^g$ /h [R,L]\nRewriteRule ^h$ /i [R=301,L]\n")
        rules = self.locations(result)
        self.assertEqual(rules["/a"], "302 https://$host/c$is_args$args")
        self.assertEqual(rules["/g"], "302 https://$host/i$is_args$args")
        self.assertEqual(rules["/d"], "301 https://$host/f$is_args$args")

    def test_whole_site_redirect_is_proxy_work(self) -> None:
        # location ^~ "/" совпал бы с location / ядра, и веб-сервер не стартовал бы.
        result = self.convert("RewriteRule ^ https://new.example.test/ [R=301,L]\n")
        self.assertEqual(result.exit_code, 1)
        self.assertNotIn('"/"', result.config)

    def test_main_writes_nothing_on_failure(self) -> None:
        src = self.tmp / "htaccess"
        out = self.tmp / "out.conf"
        src.write_text("RewriteRule ^a/$ /b/ [R=301,L]\nRewriteRule ^b/$ /a/ [R=301,L]\n")
        self.assertEqual(gen.main([str(src), str(out), "--host", "example.test"]), 1)
        self.assertFalse(out.exists(), "при отказе веб-сервер не должен получить половину правил")
        src.write_text(HTACCESS)
        self.assertEqual(gen.main([str(src), str(out), "--host", "example.test"]), 0)
        self.assertIn('location = "/sklad/"', out.read_text())

    def test_output_is_deterministic(self) -> None:
        self.assertEqual(self.convert(HTACCESS).config, self.convert(HTACCESS).config)

    def test_empty_htaccess_gives_valid_empty_config(self) -> None:
        result = self.convert("")
        self.assertEqual(result.exit_code, 0)
        self.assertNotIn("location", result.config)


# --- разворачивание -----------------------------------------------------------

CONFIG_INC = """\
<?php
/**
 *  MODX Configuration file
 */
$database_type = 'mysql';
$database_server = 'localhost';
$database_user = 'old_user';
$database_password = 'old\\'pass';
$database_connection_charset = 'utf8';
$dbase = 'old_db';
$table_prefix = 'modx_';
$database_dsn = 'mysql:host=localhost;dbname=old_db;charset=utf8';
$config_options = array (
);
$driver_options = array (
);

$lastInstallTime = 1700000000;

$site_id = 'modx5f0000000000000.00000000';
$site_sessionname = 'SN5f0000000000';
$https_port = '443';
$uuid = '00000000-0000-0000-0000-000000000000';

if (!defined('MODX_CORE_PATH')) {
    $modx_core_path= '/home/oldhost/public_html/core/';
    define('MODX_CORE_PATH', $modx_core_path);
}
if (!defined('MODX_PROCESSORS_PATH')) {
    $modx_processors_path= '/home/oldhost/public_html/core/model/modx/processors/';
    define('MODX_PROCESSORS_PATH', $modx_processors_path);
}
if (!defined('MODX_BASE_PATH')) {
    $modx_base_path= '/home/oldhost/public_html/';
    $modx_base_url= '/';
    define('MODX_BASE_PATH', $modx_base_path);
    define('MODX_BASE_URL', $modx_base_url);
}
if(defined('PHP_SAPI') && (PHP_SAPI == "cli" || PHP_SAPI == "embed")) {
    $isSecureRequest = false;
} else {
    $isSecureRequest = ((isset ($_SERVER['HTTPS']) && strtolower($_SERVER['HTTPS']) == 'on') || $_SERVER['SERVER_PORT'] == $https_port);
}
"""

CONFIG_CORE = "<?php\ndefine('MODX_CORE_PATH', '/home/oldhost/public_html/core/');\ndefine('MODX_CONFIG_KEY', 'config');\n?>"


class SiteTest(TempDir):
    def make_site(self, root: Path, config: str = CONFIG_INC) -> Path:
        (root / "core/config").mkdir(parents=True)
        (root / "core/config/config.inc.php").write_text(config)
        for rel in ("config.core.php", "manager/config.core.php", "connectors/config.core.php"):
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(CONFIG_CORE)
        (root / "index.php").write_text("<?php")
        return root


class FindRootTest(SiteTest):
    def test_docroot_found_below_hosting_prefix(self) -> None:
        site = self.make_site(self.tmp / "data/www/example.test")
        (self.tmp / "data/www/other").mkdir()
        self.assertEqual(helper.find_root(self.tmp), site)

    def test_docroot_at_top(self) -> None:
        self.make_site(self.tmp)
        self.assertEqual(helper.find_root(self.tmp), self.tmp)

    def test_two_sites_are_ambiguous(self) -> None:
        self.make_site(self.tmp / "a")
        self.make_site(self.tmp / "b")
        with self.assertRaisesRegex(helper.RestoreError, "два"):
            helper.find_root(self.tmp)

    def test_core_outside_docroot_is_refused(self) -> None:
        (self.tmp / "public_html").mkdir()
        (self.tmp / "public_html/config.core.php").write_text(CONFIG_CORE)
        (self.tmp / "public_html/index.php").write_text("<?php")
        with self.assertRaisesRegex(helper.RestoreError, "вне докрута"):
            helper.find_root(self.tmp)


class ExtractTest(TempDir):
    def test_tar_gz_with_hosting_modes(self) -> None:
        archive = self.tmp / "site.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            data = b"<?php"
            info = tarfile.TarInfo("data/www/site/index.php")
            info.size = len(data)
            info.mode = 0o700
            tar.addfile(info, io.BytesIO(data))
        dest = self.tmp / "out"
        dest.mkdir()
        self.assertEqual(helper.safe_extract(archive, dest), 1)
        self.assertEqual(stat.S_IMODE((dest / "data/www/site/index.php").stat().st_mode), 0o644)

    def test_unsafe_paths_and_links_are_refused(self) -> None:
        for bad in ("../evil.php", "/etc/evil", "a/../../evil"):
            with self.subTest(bad=bad):
                archive = self.tmp / "bad.zip"
                with zipfile.ZipFile(archive, "w") as z:
                    z.writestr("index.php", b"ok")
                    z.writestr(bad, b"x")
                dest = self.tmp / f"out-{abs(hash(bad))}"
                dest.mkdir()
                with self.assertRaises(helper.RestoreError):
                    helper.safe_extract(archive, dest)
                self.assertEqual(list(dest.iterdir()), [])
        archive = self.tmp / "link.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            info = tarfile.TarInfo("core/config/config.inc.php")
            info.type = tarfile.SYMTYPE
            info.linkname = "/etc/passwd"
            tar.addfile(info)
        dest = self.tmp / "out-link"
        dest.mkdir()
        with self.assertRaises(helper.RestoreError):
            helper.safe_extract(archive, dest)


class DumpTest(SiteTest):
    def test_single_dump_outside_docroot(self) -> None:
        site = self.make_site(self.tmp / "www/site")
        (self.tmp / "db").mkdir()
        (self.tmp / "db/site.sql").write_text("--")
        # SQL схемы компонента это не дамп сайта.
        (site / "core/components/x/schema").mkdir(parents=True)
        (site / "core/components/x/schema/install.sql").write_text("--")
        self.assertEqual(helper.find_dump(self.tmp, site), self.tmp / "db/site.sql")

    def test_no_dump_or_two_dumps_ask_for_explicit_one(self) -> None:
        site = self.make_site(self.tmp / "site")
        with self.assertRaisesRegex(helper.RestoreError, "--dump"):
            helper.find_dump(self.tmp, site)
        (self.tmp / "a.sql").write_text("--")
        (self.tmp / "b.sql.gz").write_bytes(b"x")
        with self.assertRaisesRegex(helper.RestoreError, "--dump"):
            helper.find_dump(self.tmp, site)


class ConfigTest(SiteTest):
    def test_old_root_and_prefix_are_read_from_config(self) -> None:
        site = self.make_site(self.tmp / "site")
        info = helper.read_config(site)
        self.assertEqual(info["old_root"], "/home/oldhost/public_html")
        self.assertEqual(info["prefix"], "modx_")

    def test_config_is_brought_to_new_credentials_and_paths(self) -> None:
        site = self.make_site(self.tmp / "site")
        env = self.tmp / ".env"
        env.write_text("MARIADB_ROOT_PASSWORD=root\n")
        values = helper.ensure_env(env, "site_modx")
        helper.write_config(site, values, db_name="site", old_root="/home/oldhost/public_html")
        text = (site / "core/config/config.inc.php").read_text()
        self.assertIn("$database_server = 'mariadb';", text)
        self.assertIn("$database_user = 'site_modx';", text)
        # Пароль живёт отдельным файлом: бэкап ядра исключает только его, а
        # конфиг с ключами сайта остаётся в наборе, иначе из собственного
        # бэкапа сайт не развернуть.
        self.assertIn("$database_password = require __DIR__ . '/db-password.inc.php';", text)
        self.assertNotIn(values["MODX_DB_PASSWORD"], text)
        secret = site / "core/config/db-password.inc.php"
        self.assertEqual(secret.read_text(), f"<?php\nreturn {helper.php_string(values['MODX_DB_PASSWORD'])};\n")
        self.assertEqual(stat.S_IMODE(secret.stat().st_mode), 0o640)
        self.assertIn("$dbase = 'site';", text)
        self.assertIn("$database_dsn = 'mysql:host=mariadb;dbname=site;charset=utf8mb4';", text)
        self.assertIn("$database_connection_charset = 'utf8mb4';", text)
        self.assertNotIn("old_", text)
        self.assertNotIn("/home/oldhost", text)
        self.assertIn("$modx_core_path= '/var/www/html/core/';", text)
        # Остальное не тронуто: ключи сессии и установки принадлежат сайту.
        self.assertIn("$site_sessionname = 'SN5f0000000000';", text)
        for rel in ("config.core.php", "manager/config.core.php", "connectors/config.core.php"):
            self.assertIn("define('MODX_CORE_PATH', '/var/www/html/core/');", (site / rel).read_text())

    def test_password_is_generated_once_and_kept(self) -> None:
        env = self.tmp / ".env"
        env.write_text("X=1\n")
        first = helper.ensure_env(env, "site_modx")
        second = helper.ensure_env(env, "site_modx")
        self.assertEqual(first, second)
        self.assertGreaterEqual(len(first["MODX_DB_PASSWORD"]), 32)
        self.assertEqual(stat.S_IMODE(env.stat().st_mode), 0o600)

    def test_rewrite_is_idempotent(self) -> None:
        site = self.make_site(self.tmp / "site")
        env = self.tmp / ".env"
        env.write_text("")
        values = helper.ensure_env(env, "u")
        helper.write_config(site, values, db_name="site", old_root="/home/oldhost/public_html")
        once = (site / "core/config/config.inc.php").read_text()
        helper.write_config(site, values, db_name="site", old_root="/var/www/html")
        self.assertEqual((site / "core/config/config.inc.php").read_text(), once)

    def test_config_from_own_backup_without_password_file(self) -> None:
        # Набор бэкапа ядра: конфиг уже в новом виде, файла пароля нет.
        site = self.make_site(self.tmp / "site")
        env = self.tmp / ".env"
        env.write_text("")
        values = helper.ensure_env(env, "u")
        helper.write_config(site, values, db_name="site", old_root="/home/oldhost/public_html")
        once = (site / "core/config/config.inc.php").read_text()
        (site / "core/config/db-password.inc.php").unlink()
        self.assertEqual(helper.read_config(site)["old_root"], "/var/www/html")
        helper.write_config(site, values, db_name="site", old_root="/var/www/html")
        self.assertEqual((site / "core/config/config.inc.php").read_text(), once)
        self.assertTrue((site / "core/config/db-password.inc.php").is_file())

    def test_missing_assignment_refuses(self) -> None:
        site = self.make_site(self.tmp / "site", CONFIG_INC.replace("$dbase = 'old_db';\n", ""))
        env = self.tmp / ".env"
        env.write_text("")
        with self.assertRaisesRegex(helper.RestoreError, r"\$dbase"):
            helper.write_config(site, helper.ensure_env(env, "u"), db_name="site", old_root="/home/oldhost/public_html")

    def test_php_string_escapes_quote_and_backslash(self) -> None:
        self.assertEqual(helper.php_string("a'b\\c"), "'a\\'b\\\\c'")


class RemnantsTest(SiteTest):
    def test_installer_hosting_leftovers_and_cache(self) -> None:
        site = self.make_site(self.tmp / "site")
        for rel in ("setup/index.php", "error_log", "php.ini", ".user.ini", ".ftpquota",
                    "assets/error_log", "core/cache/context_settings/web/context.cache.php"):
            (site / rel).parent.mkdir(parents=True, exist_ok=True)
            (site / rel).write_text("x")
        (site / "assets/images").mkdir(parents=True)
        found = sorted(str(p.relative_to(site)) for p in helper.remnants(site))
        self.assertEqual(found, [".ftpquota", ".user.ini", "assets/error_log",
                                 "core/cache/context_settings", "error_log", "php.ini", "setup"])
        helper.remove(helper.remnants(site))
        self.assertEqual(helper.remnants(site), [])
        # Сам каталог кэша остаётся: MODX ждёт его на месте и пишет туда.
        self.assertTrue((site / "core/cache").is_dir())


if __name__ == "__main__":
    unittest.main()
