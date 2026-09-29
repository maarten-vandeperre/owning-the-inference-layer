#!/usr/bin/env python3
"""Live-provider acceptance suite. Creates quotes, never orders. Normal provider charges apply."""
import json, sys, urllib.request
BASE = sys.argv[1].rstrip('/') if len(sys.argv) > 1 else 'http://localhost:8080'
PRICES = {'espresso': 250, 'americano': 300, 'cappuccino': 380, 'latte': 400, 'flat white': 400}
def call(path, body=None):
    req = urllib.request.Request(BASE + path, data=None if body is None else json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=120) as r: return json.load(r)
def line(drink='latte', size='regular', milk='dairy', quantity=1, decaf=False):
    unit = PRICES[drink] + (70 if size == 'large' else 0) + (40 if milk in ('oat', 'soy') else 0)
    return dict(drink=drink, size=size, milk=milk, quantity=quantity, decaf=decaf, unitCents=unit, totalCents=unit*quantity)
def canonical(items): return sorted(items, key=lambda i: (i['drink'], i['size'], i['milk'], i['decaf']))
cases = [
    ('Two large oat lattes, please.', [line(size='large', milk='oat', quantity=2)]),
    ('Two large oat lattes and a cappuccino, please.', [line(size='large', milk='oat', quantity=2), line('cappuccino')]),
    ('One latte and one espresso.', [line(), line('espresso', 'small', 'none')]),
    ('One latte and one decaf soy latte.', [line(), line(milk='soy', decaf=True)]),
    ('A decaf cappuccino.', [line('cappuccino', decaf=True)]),
    ('One small espresso.', [line('espresso', 'small', 'none')]),
    ('Six small espressos.', [line('espresso', 'small', 'none', quantity=6)]),
    ('Coffee, please.', None), ('One champagne.', None),
    ('One latte and one champagne.', None), ('Four lattes and three espressos.', None), ('100 lattes.', None),
]
print('Provider configuration:', json.dumps(call('/api/config')))
failures = 0
for text, items in cases:
    try:
        r = call('/api/interpret', {'text': text}); q = r.get('quote')
        ok = (q is None and bool(r.get('clarification'))) if items is None else (
            q is not None and canonical(q.get('items', [])) == canonical(items)
            and q.get('totalCents') == sum(i['totalCents'] for i in items) and not r.get('clarification'))
        print(('PASS' if ok else 'FAIL'), repr(text), 'elapsedMs=', r.get('elapsedMs'))
        if not ok: print('  Returned:', json.dumps(r)); failures += 1
    except Exception as e: print('FAIL', repr(text), str(e)); failures += 1
print(f'{len(cases)-failures}/{len(cases)} passed. Results apply only to this configured model and request set.')
sys.exit(1 if failures else 0)
