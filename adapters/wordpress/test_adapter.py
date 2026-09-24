"""Юнит-тесты адаптера WordPress без докера и без сети.

    python3 adapters/wordpress/test_adapter.py

Здесь проверяется то, что ломается тихо: распаковка, которая пропустила бы
путь наружу, дамп, найденный не тот, префикс, угаданный по чужой таблице,
старый путь, пропущенный в экранированной форме, конфиг, который меняется от
прогона к прогону. Разворачивание целиком проверяет stand.sh на докере.
"""

from __future__ import annotations

import gzip
import importlib.util
import io
import json
import os
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


helper = load("restore_helper", "restore_helper.py")
security = load("security_check", "security-check.py")


class TempDir(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()


def make_zip(path: Path, entries: dict[str, bytes], symlinks: dict[str, str] | None = None) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
        for name, target in (symlinks or {}).items():
            info = zipfile.ZipInfo(name)
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, target)


class ExtractTest(TempDir):
    def test_zip_is_extracted_with_normal_modes(self) -> None:
        archive = self.tmp / "site.zip"
        make_zip(archive, {"index.php": b"<?php", "wp-content/uploads/a.jpg": b"x"})
        dest = self.tmp / "out"
        dest.mkdir()
        count = helper.safe_extract(archive, dest)
        self.assertEqual(count, 2)
        self.assertEqual((dest / "index.php").read_bytes(), b"<?php")
        self.assertEqual(stat.S_IMODE((dest / "index.php").stat().st_mode), 0o644)

    def test_tar_gz_is_accepted(self) -> None:
        archive = self.tmp / "site-files.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            data = b"<?php"
            info = tarfile.TarInfo("./index.php")
            info.size = len(data)
            info.mode = 0o700
            tar.addfile(info, io.BytesIO(data))
        dest = self.tmp / "out"
        dest.mkdir()
        helper.safe_extract(archive, dest)
        # Режим из архива хостинга не переносится: 0700 давал отказ на всё.
        self.assertEqual(stat.S_IMODE((dest / "index.php").stat().st_mode), 0o644)

    def test_unsafe_paths_are_refused_before_anything_is_written(self) -> None:
        for bad in ("../evil.php", "/etc/evil", "a/../../evil", "a\\b.php", "C:/evil"):
            with self.subTest(bad=bad):
                archive = self.tmp / "bad.zip"
                make_zip(archive, {"index.php": b"ok", bad: b"x"})
                dest = self.tmp / f"out-{abs(hash(bad))}"
                dest.mkdir()
                with self.assertRaises(helper.RestoreError):
                    helper.safe_extract(archive, dest)
                self.assertEqual(list(dest.iterdir()), [], "при отказе ничего не распаковано")

    def test_symlink_in_zip_is_refused(self) -> None:
        archive = self.tmp / "link.zip"
        make_zip(archive, {"index.php": b"ok"}, symlinks={"wp-config.php": "/etc/passwd"})
        dest = self.tmp / "out"
        dest.mkdir()
        with self.assertRaises(helper.RestoreError):
            helper.safe_extract(archive, dest)

    def test_symlink_in_tar_is_refused(self) -> None:
        archive = self.tmp / "link.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            info = tarfile.TarInfo("wp-config.php")
            info.type = tarfile.SYMTYPE
            info.linkname = "/etc/passwd"
            tar.addfile(info)
        dest = self.tmp / "out"
        dest.mkdir()
        with self.assertRaises(helper.RestoreError):
            helper.safe_extract(archive, dest)


class DumpTest(TempDir):
    def test_single_dump_inside_installer_is_found(self) -> None:
        dump = self.tmp / "dup-installer/dup_descriptors_x/db_dumps/20260101-dump.sql"
        dump.parent.mkdir(parents=True)
        dump.write_text("--")
        (self.tmp / "wp-content/plugins/p").mkdir(parents=True)
        # SQL внутри плагина это схема плагина, а не дамп сайта.
        (self.tmp / "wp-content/plugins/p/install.sql").write_text("--")
        self.assertEqual(helper.find_dump(self.tmp), dump)

    def test_two_dumps_are_ambiguous(self) -> None:
        (self.tmp / "dup-installer").mkdir()
        (self.tmp / "dup-installer/a.sql").write_text("--")
        (self.tmp / "dup-installer/b.sql.gz").write_bytes(gzip.compress(b"--"))
        with self.assertRaisesRegex(helper.RestoreError, "--dump"):
            helper.find_dump(self.tmp)

    def test_no_dump_asks_for_explicit_one(self) -> None:
        (self.tmp / "index.php").write_text("<?php")
        with self.assertRaisesRegex(helper.RestoreError, "--dump"):
            helper.find_dump(self.tmp)

    def test_root_dump_without_installer_is_found(self) -> None:
        (self.tmp / "database.sql.gz").write_bytes(gzip.compress(b"--"))
        self.assertEqual(helper.find_dump(self.tmp), self.tmp / "database.sql.gz")


DUMP = """\
CREATE TABLE `wpx_options` (`option_id` int);
CREATE TABLE `wpx_posts` (`ID` int);
CREATE TABLE `wpx_users` (`ID` int);
CREATE TABLE `wpx_usermeta` (`umeta_id` int);
CREATE TABLE `other_options` (`id` int);
INSERT INTO `wpx_options` VALUES (1,'upload_path','/home/oldhost/public_html/wp-content/uploads','yes');
INSERT INTO `wpx_options` VALUES (2,'cache','a:1:{s:3:\\"dir\\";s:43:\\"/home/oldhost/public_html/wp-content/cache\\";}','yes');
INSERT INTO `wpx_options` VALUES (3,'json','{\\"d\\":\\"\\\\/home\\\\/oldhost\\\\/public_html\\\\/wp-content\\\\/x\\"}','yes');
INSERT INTO `wpx_options` VALUES (4,'home','https://example.test','yes');
INSERT INTO `wpx_posts` VALUES (1,'<img src=\\"https://example.test/wp-content/uploads/a.jpg\\">');
INSERT INTO `wpx_options` VALUES (5,'new','/var/www/html/wp-content/uploads','yes');
"""


class PrefixAndPathsTest(TempDir):
    def write(self, text: str, gz: bool = False) -> Path:
        path = self.tmp / ("dump.sql.gz" if gz else "dump.sql")
        if gz:
            path.write_bytes(gzip.compress(text.encode()))
        else:
            path.write_text(text)
        return path

    def test_prefix_needs_options_posts_and_users(self) -> None:
        # other_options есть, но без posts и users это чужая таблица.
        self.assertEqual(helper.detect_prefix(self.write(DUMP)), "wpx_")

    def test_two_wordpress_prefixes_are_ambiguous(self) -> None:
        text = DUMP + "CREATE TABLE `wp_options` (x int);\nCREATE TABLE `wp_posts` (x int);\nCREATE TABLE `wp_users` (x int);\n"
        with self.assertRaisesRegex(helper.RestoreError, "wp_.*wpx_|wpx_.*wp_"):
            helper.detect_prefix(self.write(text))

    def test_url_path_is_not_a_filesystem_root(self) -> None:
        text = DUMP + (
            "INSERT INTO `wpx_posts` VALUES (2,'<img src=\\\"/blog/wp-content/uploads/a.jpg\\\">');\n"
            "INSERT INTO `wpx_options` VALUES (6,'x','/var/www/site/wp-content/y','yes');\n"
        )
        found = helper.old_paths(self.write(text))
        # Путь адреса с одним сегментом это ссылка, а не корень старой площадки.
        self.assertNotIn("/blog", found)
        self.assertEqual(found, {"/home/oldhost/public_html": 3, "/var/www/site": 1})

    def test_home_is_read_from_dump_before_anything_is_touched(self) -> None:
        self.assertEqual(helper.dump_home(self.write(DUMP), "wpx_"), "https://example.test")
        quoted = 'CREATE TABLE `wp_options` (x int);\nINSERT INTO `wp_options` VALUES ("1","siteurl","http://a.test","yes"),("2","home","http://old.test/","yes");\n'
        self.assertEqual(helper.dump_home(self.write(quoted), "wp_"), "http://old.test")
        # Так пишет mariadb-dump: каждая строка расширенного INSERT на своей строке.
        multiline = ("CREATE TABLE `wp_options` (x int);\nINSERT INTO `wp_options` VALUES (1,'siteurl','http://a.test','on'),\n"
                     "(2,'home','http://multi.test','on'),\n(3,'blogname','x','on');\n"
                     "INSERT INTO `wp_posts` VALUES (1,'home','http://wrong.test');\n")
        self.assertEqual(helper.dump_home(self.write(multiline), "wp_"), "http://multi.test")

    def test_old_paths_found_in_plain_serialized_and_json_forms(self) -> None:
        found = helper.old_paths(self.write(DUMP, gz=True))
        # Адрес сайта с /wp-content/ путём не является, новый путь тоже.
        self.assertEqual(found, {"/home/oldhost/public_html": 3})


class EnvAndConfigTest(TempDir):
    def test_env_is_filled_once_and_kept(self) -> None:
        env = self.tmp / ".env"
        env.write_text("OTHER=1\n")
        first = helper.ensure_env(env, "example")
        self.assertEqual(stat.S_IMODE(env.stat().st_mode), 0o600)
        self.assertEqual(first["WP_DB_USER"], "example")
        self.assertGreaterEqual(len(first["WP_DB_PASSWORD"]), 24)
        self.assertIn("OTHER=1", env.read_text())
        second = helper.ensure_env(env, "example")
        self.assertEqual(first, second, "второй прогон не генерирует новых значений")

    def test_wp_config_is_deterministic_and_escapes_values(self) -> None:
        env = self.tmp / ".env"
        env.write_text("WP_DB_PASSWORD=it's\\a\n")
        values = helper.ensure_env(env, "example")
        a = helper.render_wp_config(values, db_name="example", prefix="wpx_", url="https://example.test", wp_cache=False)
        b = helper.render_wp_config(values, db_name="example", prefix="wpx_", url="https://example.test", wp_cache=False)
        self.assertEqual(a, b, "конфиг не меняется от прогона к прогону")
        self.assertIn("define('DB_PASSWORD', 'it\\'s\\\\a');", a)
        self.assertIn("$table_prefix = 'wpx_';", a)
        self.assertIn("define('DB_HOST', 'mariadb');", a)
        self.assertNotIn("WP_CACHE", a)
        with_cache = helper.render_wp_config(values, db_name="example", prefix="wpx_", url="https://example.test", wp_cache=True)
        self.assertIn("define('WP_CACHE', true);", with_cache)

    def test_dropped_defines_are_listed(self) -> None:
        cfg = self.tmp / "wp-config.php"
        cfg.write_text("<?php define( 'DB_NAME', 'x' ); define('WP_MEMORY_LIMIT','256M'); define(\"WPLANG\", 'ru_RU');")
        self.assertEqual(helper.dropped_defines(cfg), ["WPLANG", "WP_MEMORY_LIMIT"])


class RemnantsTest(TempDir):
    def test_installer_and_its_remnants_are_found_only_where_they_live(self) -> None:
        for rel in ("dup-installer/main.installer.php", "installer.php", "20260101_x_installer-backup.php",
                    "wp-content/backups-dup-pro/a.zip", "wp-snapshots/b.zip", "php.ini", ".user.ini",
                    "wp-config.php", "error_log", "wp-content/plugins/p/error_log", "wp-content/debug.log",
                    "index.php", "wp-content/plugins/dup/installer.php"):
            path = self.tmp / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("x")
        found = sorted(p.relative_to(self.tmp).as_posix() for p in helper.remnants(self.tmp))
        self.assertEqual(found, [
            ".user.ini", "20260101_x_installer-backup.php", "dup-installer", "error_log",
            "installer.php", "php.ini", "wp-config.php", "wp-content/backups-dup-pro",
            "wp-content/debug.log", "wp-content/plugins/p/error_log", "wp-snapshots",
        ])


class UploadStubTest(unittest.TestCase):
    def test_silence_is_golden_is_a_stub_and_code_is_not(self) -> None:
        self.assertTrue(helper.is_upload_stub(b"<?php\n// Silence is golden.\n"))
        self.assertTrue(helper.is_upload_stub(b"<?php // Silence is golden"))
        self.assertTrue(helper.is_upload_stub(b"<?php\n"))
        self.assertFalse(helper.is_upload_stub(b"<?php system($_GET[1]); // Silence is golden"))
        self.assertFalse(helper.is_upload_stub(b"<?php // Silence is golden\neval($x);"))
        # ?> закрывает однострочный комментарий, и дальше снова код.
        self.assertFalse(helper.is_upload_stub(b"<?php // x ?><?php system($_GET[1]);"))
        self.assertFalse(helper.is_upload_stub(b"<?php # x ?>code"))


def wp_tree(root: Path, core: dict[str, bytes]) -> None:
    for rel, data in core.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    (root / "wp-content/uploads").mkdir(parents=True, exist_ok=True)


class SignatureTest(unittest.TestCase):
    def test_html_apostrophe_does_not_hide_code(self) -> None:
        self.assertEqual(security.signature_hits("<p>Don't</p><?php eval($_POST['x']); ?>"), ["eval("])

    def test_attribute_is_not_a_comment(self) -> None:
        self.assertEqual(security.signature_hits("<?php #[Attr] eval($_POST['x']);"), ["eval("])

    def test_html_outside_php_is_not_code(self) -> None:
        self.assertEqual(security.signature_hits("<p>use eval( carefully</p><?php echo 1; ?>system( in html"), [])

    def test_comment_ends_at_close_tag(self) -> None:
        self.assertEqual(security.signature_hits("<?php // note ?><?php eval($x);"), ["eval("])


class UsersFromDumpTest(unittest.TestCase):
    def test_double_quoted_dump_is_parsed_like_single_quoted(self) -> None:
        single = ("INSERT INTO `wp_users` VALUES (1,'admin','$P$x','admin','a@x','','2026-01-01','',0,'admin');\n"
                  "INSERT INTO `wp_usermeta` VALUES (1,1,'wp_capabilities','a:1:{s:13:\\\"administrator\\\";b:1;}');\n")
        double = ('INSERT IGNORE INTO `wp_users` VALUES ("1","admin","$P$x","admin","a@x","","2026-01-01","","0","admin");\n'
                  'INSERT IGNORE INTO `wp_usermeta` VALUES ("1","1","wp_capabilities","a:1:{s:13:\\\"administrator\\\";b:1;}");\n')
        expected = {"admin": ["administrator"]}
        self.assertEqual(security.users_from_sql(single, "wp_"), expected)
        self.assertEqual(security.users_from_sql(double, "wp_"), expected)


class SecurityCheckTest(TempDir):
    CORE = {
        "index.php": b"<?php require 'wp-blog-header.php';",
        "wp-includes/version.php": b"<?php\n$wp_version = '6.6';\n",
        "wp-admin/admin.php": b"<?php // admin",
    }

    def setUp(self) -> None:
        super().setUp()
        self.root = self.tmp / "site"
        wp_tree(self.root, self.CORE)
        import hashlib
        self.manifest = self.tmp / "manifest.json"
        self.manifest.write_text(json.dumps({rel: hashlib.md5(data).hexdigest() for rel, data in self.CORE.items()}))
        self.dump = self.tmp / "dump.sql"
        self.dump.write_text(
            "CREATE TABLE `wp_options` (x int);\nCREATE TABLE `wp_posts` (x int);\nCREATE TABLE `wp_users` (x int);\n"
            "INSERT INTO `wp_users` VALUES (1,'admin','$P$x','admin','a@example.test','','2026-01-01',"
            "'',0,'admin'),(2,'editor','$P$y','editor','e@example.test','','2026-01-01','',0,'editor');\n"
            "INSERT INTO `wp_usermeta` VALUES (1,1,'wp_capabilities','a:1:{s:13:\\\"administrator\\\";b:1;}'),"
            "(2,2,'wp_capabilities','a:1:{s:6:\\\"editor\\\";b:1;}');\n"
        )

    def run_check(self, *extra: str) -> tuple[int, dict]:
        out = io.StringIO()
        argv = ["--source", "dir", str(self.root), "--dump", str(self.dump),
                "--core-manifest", str(self.manifest), "--json", *extra]
        code = security.main(argv, stdout=out)
        return code, json.loads(out.getvalue())

    def test_clean_tree_with_expected_users_passes(self) -> None:
        code, report = self.run_check("--user", "admin:administrator", "--user", "editor:editor")
        self.assertEqual(report["findings"], [])
        self.assertEqual(code, 0)

    def test_changed_core_file_is_a_finding(self) -> None:
        (self.root / "wp-admin/admin.php").write_bytes(b"<?php eval($_POST[1]);")
        code, report = self.run_check("--user", "admin:administrator", "--user", "editor:editor")
        self.assertEqual(code, 1)
        self.assertTrue(any("wp-admin/admin.php" in f for f in report["findings"]))

    def test_extra_php_in_core_dir_is_a_finding(self) -> None:
        (self.root / "wp-includes/x7.php").write_text("<?php")
        code, report = self.run_check("--user", "admin:administrator", "--user", "editor:editor")
        self.assertEqual(code, 1)
        self.assertTrue(any("wp-includes/x7.php" in f for f in report["findings"]))

    def test_unexpected_user_is_a_finding(self) -> None:
        code, report = self.run_check("--user", "admin:administrator")
        self.assertEqual(code, 1)
        self.assertTrue(any("editor" in f for f in report["findings"]))

    def test_without_expected_users_it_does_not_pass_silently(self) -> None:
        code, report = self.run_check()
        self.assertEqual(code, 1)
        self.assertTrue(any("--user" in f for f in report["findings"]))

    def test_code_in_uploads_is_a_finding_stub_is_not(self) -> None:
        (self.root / "wp-content/uploads/forms").mkdir()
        (self.root / "wp-content/uploads/forms/index.php").write_text("<?php // Silence is golden.")
        code, _ = self.run_check("--user", "admin:administrator", "--user", "editor:editor")
        self.assertEqual(code, 0)
        (self.root / "wp-content/uploads/2026").mkdir()
        (self.root / "wp-content/uploads/2026/img.php").write_text("<?php echo 1;")
        code, report = self.run_check("--user", "admin:administrator", "--user", "editor:editor")
        self.assertEqual(code, 1)
        self.assertTrue(any("uploads/2026/img.php" in f for f in report["findings"]))

    def test_signature_in_plugin_is_a_finding_unless_allowed(self) -> None:
        plugin = self.root / "wp-content/plugins/lib/x.php"
        plugin.parent.mkdir(parents=True)
        plugin.write_text("<?php\n// eval( in a comment is not code\n$a = 'eval(';\n")
        code, _ = self.run_check("--user", "admin:administrator", "--user", "editor:editor")
        self.assertEqual(code, 0, "комментарий и строка не находка")
        plugin.write_text("<?php eval($x);")
        code, report = self.run_check("--user", "admin:administrator", "--user", "editor:editor")
        self.assertEqual(code, 1)
        allow = self.tmp / "allow.conf"
        allow.write_text("# проверено глазами\nbenign=wp-content/plugins/lib/x.php|eval(\n")
        code, _ = self.run_check("--user", "admin:administrator", "--user", "editor:editor", "--site-conf", str(allow))
        self.assertEqual(code, 0)

    def test_unknown_root_dir_with_error_log_is_still_reported(self) -> None:
        (self.root / "wp-xyz").mkdir()
        (self.root / "wp-xyz/sh.php").write_text("<?php eval($_POST[1]);")
        (self.root / "wp-xyz/error_log").write_text("x")
        code, report = self.run_check("--user", "admin:administrator", "--user", "editor:editor")
        self.assertEqual(code, 1)
        self.assertTrue(any("wp-xyz" in f and "каталоги" in f for f in report["findings"]))

    def test_dropin_in_wp_content_is_scanned(self) -> None:
        (self.root / "wp-content/db.php").write_text("<?php eval($_POST[1]);")
        code, report = self.run_check("--user", "admin:administrator", "--user", "editor:editor")
        self.assertEqual(code, 1)
        self.assertTrue(any("wp-content/db.php" in f for f in report["findings"]))

    def test_dangerous_string_in_dump_is_a_finding(self) -> None:
        with self.dump.open("a") as fh:
            fh.write("INSERT INTO `wp_options` VALUES (9,'x','<?php eval(base64_decode(\"aaa\"));','yes');\n")
        code, report = self.run_check("--user", "admin:administrator", "--user", "editor:editor")
        self.assertEqual(code, 1)
        self.assertTrue(any("дамп" in f for f in report["findings"]))

    def test_installer_in_archive_is_noted_and_in_volume_is_a_finding(self) -> None:
        (self.root / "dup-installer").mkdir()
        (self.root / "dup-installer/main.installer.php").write_text("<?php")
        out = io.StringIO()
        base = [str(self.root), "--dump", str(self.dump), "--core-manifest", str(self.manifest), "--json",
                "--user", "admin:administrator", "--user", "editor:editor"]
        self.assertEqual(security.main(["--source", "dir", *base], stdout=out), 0,
                         "в архиве установщик это устройство архива, а не взлом")
        out = io.StringIO()
        self.assertEqual(security.main(["--source", "dir", "--deployed", *base], stdout=out), 1,
                         "в развёрнутом докруте установщик это находка")

    def test_archive_source_is_extracted_safely(self) -> None:
        archive = self.tmp / "site.zip"
        entries = {rel: data for rel, data in self.CORE.items()}
        entries["dup-installer/db_dumps/dump.sql"] = self.dump.read_bytes()
        make_zip(archive, entries)
        out = io.StringIO()
        code = security.main(["--source", "archive", str(archive), "--core-manifest", str(self.manifest), "--json",
                              "--user", "admin:administrator", "--user", "editor:editor"], stdout=out)
        report = json.loads(out.getvalue())
        self.assertEqual(report["findings"], [])
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
