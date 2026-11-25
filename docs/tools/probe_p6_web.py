import json, urllib.request, urllib.error

BASE = 'http://127.0.0.1:8000'

req = urllib.request.Request(
    BASE + '/api/login',
    data=json.dumps({'username': 'user', 'password': '123456'}).encode(),
    headers={'Content-Type': 'application/json'})
r = urllib.request.urlopen(req)
raw = r.headers.get_all('Set-Cookie') or []
cookie = '; '.join(c.split(';')[0] for c in raw)


def get(path):
    req = urllib.request.Request(BASE + path, headers={'Cookie': cookie})
    try:
        resp = urllib.request.urlopen(req)
        return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


print('=== /api/my_videos（App「我的视频」数据源）===')
st, d = get('/api/my_videos')
print('HTTP', st, 'total =', d.get('total'))
for it in d.get('items', [])[:3]:
    print('  ', it.get('id'), '|', it.get('name'), '| owner_id 字段:',
          'owner_id' in it)

print('\n=== /api/videos（Web 广场数据源）===')
st, d = get('/api/videos?status=ready&limit=500')
print('HTTP', st, 'total =', d.get('total'))
for it in d.get('items', [])[:3]:
    print('  ', it.get('id'), '|', it.get('name'), '| owner_id =',
          it.get('owner_id'))

print('\n=== /api/owners（owner_id -> 昵称）===')
st, d = get('/api/owners')
print('HTTP', st, d)

print('\n=== 新视频详情 ===')
st, d = get('/api/videos/9c8532f8')
print('HTTP', st)
print('  name:', d.get('name'))
print('  owner_id:', d.get('owner_id'), '-> 昵称:',
      json.loads(json.dumps(d)) and None)
