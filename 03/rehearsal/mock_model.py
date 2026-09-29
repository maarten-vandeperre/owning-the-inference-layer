#!/usr/bin/env python3
"""Fixed conference rehearsal fixtures. NOT an AI model."""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def item(drink='latte', size='regular', milk='dairy', quantity=1, decaf=False):
    return dict(drink=drink, size=size, milk=milk, quantity=quantity, decaf=decaf)
def cart(*items): return dict(items=list(items), clarification='')
def question(text): return dict(items=[], clarification=text)
FIXTURES = {
    'two large oat lattes, please.': cart(item(size='large', milk='oat', quantity=2)),
    'two large oat lattes and a cappuccino, please.': cart(item(size='large', milk='oat', quantity=2), item('cappuccino')),
    'one latte and one espresso.': cart(item(), item('espresso', 'small', 'none')),
    'one latte and one decaf soy latte.': cart(item(), item(milk='soy', decaf=True)),
    'a decaf cappuccino.': cart(item('cappuccino', decaf=True)),
    'one small espresso.': cart(item('espresso', 'small', 'none')),
    'six small espressos.': cart(item('espresso', 'small', 'none', quantity=6)),
    'coffee, please.': question('Which drink would you like?'),
    'one champagne.': question('We only serve coffee. Which drink would you like?'),
    'one latte and one champagne.': question('We cannot serve champagne. What should accompany your latte?'),
    'four lattes and three espressos.': question('An order can contain at most six cups in total. Which six would you like?'),
    '100 lattes.': question('You can order at most six cups. How many would you like?'),
}
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def send_json(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == '/health': self.send_json({'status': 'UP', 'mode': 'fixture, not a model'})
        else: self.send_error(404)
    def do_POST(self):
        if not self.path.endswith('/chat/completions'):
            self.send_error(404); return
        try:
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            text = body['messages'][-1]['content'].strip().lower()
            result = FIXTURES.get(text, question('Rehearsal fixture only: use one of the documented sample orders.'))
            self.send_json({'model': 'rehearsal-fixtures', 'choices': [{'finish_reason': 'stop', 'message': {'role': 'assistant', 'content': json.dumps(result)}}]})
        except Exception:
            self.send_error(400, 'Invalid rehearsal request')
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8099)
    args = parser.parse_args()
    print(f'REHEARSAL MOCK (NO MODEL) http://{args.host}:{args.port}/v1/chat/completions', flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
