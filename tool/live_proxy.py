#!/usr/bin/env python3
"""Loopback-only DeepSeek relay for the browser smoke entry; never ships a key."""
import argparse
import http.server
import json
import os
import urllib.error
import urllib.request

class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def _relay(self):
        routes = {'/__deepseek/models': ('GET', 'https://api.deepseek.com/models'),
                  '/__deepseek/chat/completions': ('POST', 'https://api.deepseek.com/chat/completions')}
        route = routes.get(self.path)
        if route is None or route[0] != self.command:
            self.send_error(404)
            return
        origin = self.headers.get('Origin')
        if origin and origin not in {f'http://127.0.0.1:{self.server.server_port}', f'http://localhost:{self.server.server_port}'}:
            self.send_error(403)
            return
        length = int(self.headers.get('Content-Length', '0'))
        if length > 4 * 1024 * 1024:
            self.send_error(413)
            return
        key = os.environ.get('DEEPSEEK_API_KEY')
        if not key:
            self.send_error(503, 'DEEPSEEK_API_KEY is not configured on the relay host')
            return
        data = self.rfile.read(length) if self.command == 'POST' else None
        request = urllib.request.Request(route[1], data=data, method=self.command, headers={
            'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json',
            'Accept': 'text/event-stream' if data else 'application/json',
            'User-Agent': 'Domovoy-live-demo/1.0'})
        try:
            response = urllib.request.urlopen(request, timeout=90)
        except urllib.error.HTTPError as error:
            response = error
        except Exception:
            self.send_error(502, 'DeepSeek relay connection failed')
            return
        with response:
            self.send_response(response.status)
            self.send_header('Content-Type', response.headers.get('Content-Type', 'application/json'))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.close_connection = True
            try:
                for line in response:
                    self.wfile.write(line)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return

    def do_GET(self):
        if self.path.startswith('/__deepseek/'):
            self._relay()
        else:
            super().do_GET()

    def do_POST(self):
        self._relay()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', default='build/web')
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    from functools import partial
    server = http.server.ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, directory=args.directory))
    print(f'Domovoy live demo: http://127.0.0.1:{args.port}', flush=True)
    server.serve_forever()
