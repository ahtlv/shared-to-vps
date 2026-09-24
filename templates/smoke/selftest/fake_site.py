#!/usr/bin/env python3
"""Подставной сайт для самотеста смоука. Нужен ровно для того, чтобы доказать:
смоук краснеет, когда сайт сломан, и краснеет той проверкой, которая названа.

    fake_site.py HTTP_PORT HTTPS_PORT CERT_DIR STAGE [DEFECT]

STAGE задаёт, в какой момент переезда застали сайт:
  before  до переключения: по http отдаётся сам сайт, как у стека за блоком
          http:// в обратном прокси;
  after   после переключения: http уходит на https, www на основное имя.

DEFECT называет один способ поломки; без него сайт здоров. Все отказы взяты из
двух настоящих переездов, а не придуманы под ожидания смоука.

GET /__leads отвечает числом обращений, прошедших валидацию: так самотест
доказывает, что пробник формы не оставляет обращения.
"""
import json
import os
import secrets
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = 'example.test'

HTTP_PORT = int(sys.argv[1])
HTTPS_PORT = int(sys.argv[2])
CERT_DIR = sys.argv[3]
STAGE = sys.argv[4]
DEFECT = sys.argv[5] if len(sys.argv) > 5 else ''

with open(os.path.join(HERE, 'robots.txt'), 'rb') as handle:
    ROBOTS = handle.read()

LEADS = []
SESSION = 'fakesession'
# Токен формы, который сейчас держит сессия. В режиме token-rotates он
# перевыпускается на каждый рендер страницы с формой, как у CMS, которые так
# защищаются от повторной отправки.
TOKEN = ['tok-7f3a']


def form():
    if DEFECT == 'token-rotates':
        TOKEN[0] = 'tok-' + secrets.token_hex(4)
    return (
        '<form id="lead" method="post" action="/form" data-token="%s">'
        '<input name="name"><input name="phone"></form>' % TOKEN[0]
    )


def page(title, body):
    if DEFECT == 'same-titles':
        title = 'Пример'
    # Одноразовый токен в каждом ответе, как у настоящих CMS: из-за него тела
    # двух выдач одной и той же страницы уже не совпадают побайтово.
    nonce = secrets.token_hex(8)
    # Потерянная кодировка при переносе дампа: кириллица превратилась в
    # вопросы, а коды, разметка и маркер на месте.
    if DEFECT == 'unicode-lost':
        body = ''.join(c if ord(c) < 128 else '?' for c in body)
    return (
        '<!DOCTYPE html><html lang="ru"><head><title>%s</title>'
        '<meta name="generator" content="ExampleCMS 4.2">'
        '<script src="//cdn.example.net/lib.js"></script>'
        '</head><body data-nonce="%s">%s</body></html>' % (title, nonce, body)
    ).encode()


def home():
    body = '<h1>Главная</h1>'
    if DEFECT != 'form-missing':
        body += form()
    # Источник с ведущим слэшем: браузер читает //uploads/ как имя хоста.
    img = '//uploads/hero.webp' if DEFECT == 'media-double-slash' else '/uploads/hero.webp'
    # Адрес сайта взят из имени хоста запроса проверки и осел в кэше: ссылки
    # ведут на внутренний адрес или имя контейнера.
    if DEFECT == 'internal-link':
        img = 'http://127.0.0.1/uploads/hero.webp'
    body += '<img src="%s" alt="">' % img
    if DEFECT == 'container-link':
        body += '<a href="http://example-nginx/about/">О нас</a>'
    result = page('Главная · Пример', body)
    if DEFECT == 'home-no-marker':
        result = result.replace(b'<meta name="generator" content="ExampleCMS 4.2">', b'')
    return result


def about():
    return page('О нас · Пример', '<h1>О нас</h1><p>Работаем с 2005 года.</p>')


def contacts():
    return page('Контакты · Пример', '<h1>Контакты</h1><p>Пишите.</p>' + form())


SITEMAP = (
    b'<?xml version="1.0" encoding="UTF-8"?>\n'
    b'<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    b'<url><loc>https://example.test/</loc></url>'
    b'<url><loc>https://example.test/about/</loc></url>'
    b'</urlset>\n'
)


class Handler(BaseHTTPRequestHandler):
    scheme = 'http'

    def log_message(self, *args):
        pass

    def send(self, status, body=b'', content_type='text/html; charset=UTF-8', headers=None):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def redirect(self, status, location):
        self.send(status, headers={'Location': location})

    def host(self):
        return self.headers.get('Host', HOST).split(':', 1)[0]

    # Что делает обратный прокси до того, как запрос дойдёт до сайта.
    def front(self):
        if STAGE != 'after':
            return False
        if self.scheme == 'http' and DEFECT != 'http-no-redirect':
            self.redirect(308, 'https://%s%s' % (self.host(), self.path))
            return True
        if self.host() == 'www.' + HOST:
            if DEFECT == 'www-no-redirect':
                return False
            status = 302 if DEFECT == 'www-302' else 301
            self.redirect(status, 'https://%s%s' % (HOST, self.path))
            return True
        return False

    def do_GET(self):
        path = self.path.split('?', 1)[0]

        if path == '/__leads':
            return self.send(200, str(len(LEADS)).encode(), 'text/plain')
        if self.front():
            return

        # Оборванное восстановление: движок жив, а разбор адресов нет, и любой
        # путь рендерит главную с кодом 200.
        if DEFECT == 'every-path-is-home':
            return self.send(200, home())

        if path == '/':
            if DEFECT == 'home-500':
                return self.send(500, b'Internal Server Error')
            if DEFECT == 'home-unrendered':
                return self.send(200, b"{include 'file:templates/home.tpl'}")
            return self.send(200, home(), headers={'Set-Cookie': 'SID=%s; path=/; HttpOnly' % SESSION})

        if path == '/about/':
            if DEFECT == 'page-404':
                return self.send(404, b'Not found')
            if DEFECT == 'page-is-home':
                return self.send(200, home())
            return self.send(200, about())

        if path == '/contacts/':
            # Второй адрес отдаёт тело первого: главная тут ни при чём.
            if DEFECT == 'pages-identical':
                return self.send(200, about())
            return self.send(200, contacts())

        if path == '/sitemap.xml':
            if DEFECT == 'sitemap-500':
                return self.send(500, b'Internal Server Error')
            if DEFECT == 'sitemap-broken':
                return self.send(200, SITEMAP[:-20], 'application/xml')
            if DEFECT == 'sitemap-not-sitemap':
                return self.send(200, b'<?xml version="1.0"?><rss><channel/></rss>', 'application/xml')
            return self.send(200, SITEMAP, 'application/xml')

        if path == '/robots.txt':
            if DEFECT == 'robots-404':
                return self.send(404, b'Not found')
            body = ROBOTS
            if DEFECT == 'robots-stub':
                body = b'User-agent: *\nDisallow: /\n'
            if DEFECT == 'robots-one-byte':
                body = ROBOTS.rstrip(b'\n')
            return self.send(200, body, 'text/plain')

        self.send(404, b'Not found')

    do_HEAD = do_GET

    def do_POST(self):
        if self.front():
            return
        length = int(self.headers.get('Content-Length', 0))
        fields = {}
        for pair in self.rfile.read(length).decode().split('&'):
            if '=' in pair:
                name, value = pair.split('=', 1)
                fields[name] = value
        if self.path.split('?', 1)[0] != '/form':
            return self.send(404, b'Not found')
        if DEFECT == 'form-500':
            return self.send(500, b'Internal Server Error')
        answer = lambda body: self.send(200, json.dumps(body, separators=(',', ':')).encode(), 'application/json')
        # Форма держит свой ключ в сессии: POST без куки главной для неё чужой.
        if 'SID=%s' % SESSION not in self.headers.get('Cookie', ''):
            return answer({'success': False, 'message': 'session expired'})
        if fields.get('token') != TOKEN[0]:
            return answer({'success': False, 'message': 'bad token'})
        missing = {name: 'required' for name in ('name', 'phone') if not fields.get(name)}
        if DEFECT == 'form-accepts-empty':
            missing = {}
        if missing:
            return answer({'success': False, 'errors': missing})
        LEADS.append(fields)
        answer({'success': True})


class HttpsHandler(Handler):
    scheme = 'https'


def serve_https():
    cert = {'cert-wrong-name': 'wrong', 'cert-expiring': 'short'}.get(DEFECT, 'ok')
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(CERT_DIR, cert + '.crt'), os.path.join(CERT_DIR, cert + '.key'))
    server = ThreadingHTTPServer(('127.0.0.1', HTTPS_PORT), HttpsHandler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == '__main__':
    threading.Thread(target=serve_https, daemon=True).start()
    ThreadingHTTPServer(('127.0.0.1', HTTP_PORT), Handler).serve_forever()
