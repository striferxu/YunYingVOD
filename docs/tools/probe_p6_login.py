import json, urllib.request, io

BASE = 'http://127.0.0.1:8000'
req = urllib.request.Request(
    BASE + '/api/login',
    data=json.dumps({'username': 'user', 'password': '123456'}).encode(),
    headers={'Content-Type': 'application/json'})
r = urllib.request.urlopen(req)
raw = r.headers.get_all('Set-Cookie') or []
cookie = '; '.join(c.split(';')[0] for c in raw)
print(cookie.split('=')[0], '=', cookie.split('=', 1)[1][:20] + '...')
open('/tmp/p6_cookie.txt', 'w').write(cookie)
