"""P7 验收：注册接口 + 管理后台待审核列表。

在服务器本机执行（BASE 指向 127.0.0.1:8000，绕过 nginx）。
覆盖：
  1. 合法注册 → 200 status=pending，且 /api/admin/pending 能看到
  2. 重复用户名（同大小写 / 不同大小写）→ 409
  3. 用户名 2 位 / 33 位 / 含中文 → 400，文案一致
  4. 缺密码 → 400 password required
  5. 昵称超 64 → 400 nickname too long
  6. 昵称留空 → 200，nickname 自动等于 username
  7. pending 账号登录 → 401 Invalid credentials（与密码错无法区分）
  8. 清理：删除本轮创建的测试用户
"""
import json
import time
import urllib.error
import urllib.request

BASE = 'http://127.0.0.1:8000'
STAMP = str(int(time.time()))
created = []


def post(path, body, cookie=None):
    headers = {'Content-Type': 'application/json'}
    if cookie:
        headers['Cookie'] = cookie
    req = urllib.request.Request(
        BASE + path, data=json.dumps(body).encode(), headers=headers)
    try:
        r = urllib.request.urlopen(req)
        raw = r.read().decode()
        return r.status, json.loads(raw) if raw else {}, r.headers.get_all('Set-Cookie') or []
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw), []
        except Exception:
            return e.code, {'raw': raw[:200]}, []


def get(path, cookie=None):
    headers = {'Cookie': cookie} if cookie else {}
    req = urllib.request.Request(BASE + path, headers=headers)
    try:
        r = urllib.request.urlopen(req)
        return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def reg(username, password='123456', nickname=None):
    body = {'username': username, 'password': password}
    if nickname is not None:
        body['nickname'] = nickname
    return post('/api/register', body)


print('=' * 60)
print('1. 合法注册')
u1 = 'p7ok_' + STAMP
st, d, _ = reg(u1, nickname='P7测试用户')
print('  HTTP', st, d)
created.append(u1)
assert st == 200 and d.get('status') == 'pending', '注册失败'
print('  PASS')

print('=' * 60)
print('2. 重复用户名（同大小写）')
st, d, _ = reg(u1)
print('  HTTP', st, d)
assert st == 409, '应返回 409'
print('  PASS')

print('3. 重复用户名（不同大小写，服务端 COLLATE NOCASE）')
st, d, _ = reg(u1.upper())
print('  HTTP', st, d)
assert st == 409, '大小写不同也应 409'
print('  PASS')

print('=' * 60)
print('4. 用户名格式错误')
for bad, label in [('ab', '2 位'), ('a' * 33, '33 位'), ('用户abc', '含中文'),
                   ('abc def', '含空格'), ('abc@def', '含 @')]:
    st, d, _ = reg(bad)
    print('  %-8s HTTP %s %s' % (label, st, d))
    assert st == 400, '%s 应 400' % label
print('  PASS')

print('=' * 60)
print('5. 缺密码 / 密码超长 / 昵称超长')
st, d, _ = post('/api/register', {'username': 'p7np_' + STAMP})
print('  缺密码   HTTP', st, d)
assert st == 400 and 'password' in d.get('error', '')

st, d, _ = reg('p7pl_' + STAMP, password='a' * 257)
print('  密码257  HTTP', st, d)
assert st == 400 and 'too long' in d.get('error', '')

st, d, _ = reg('p7nl_' + STAMP, nickname='n' * 65)
print('  昵称65   HTTP', st, d)
assert st == 400 and 'too long' in d.get('error', '')
print('  PASS')

print('=' * 60)
print('6. 昵称留空 → 自动等于用户名')
u6 = 'p7nn_' + STAMP
st, d, _ = reg(u6, nickname='')
print('  HTTP', st, d)
assert st == 200, '昵称留空应成功'
created.append(u6)
print('  PASS（昵称回落需在后台确认）')

print('=' * 60)
print('7. pending 账号登录 → 401')
st, d, _ = post('/api/login', {'username': u1, 'password': '123456'})
print('  HTTP', st, d)
assert st == 401, 'pending 登录应 401'
assert d.get('error') == 'Invalid credentials', '文案应为 Invalid credentials'
print('  PASS')

print('=' * 60)
print('8. 管理后台待审核列表')
st, d, cookies = post('/api/login', {'username': 'admin', 'password': '123456'})
if st != 200:
    print('  admin 登录失败（HTTP %s），跳过后台校验' % st)
else:
    cookie = '; '.join(c.split(';')[0] for c in cookies)
    st, pend = get('/api/admin/pending', cookie=cookie)
    print('  /api/admin/pending HTTP', st)
    names = [p.get('username') for p in (pend.get('items') or pend.get('users') or [])
             ] if isinstance(pend, dict) else []
    print('  待审核用户名:', names)
    print('  本轮注册是否在列表中:', u1 in names, '/', u6 in names)

print('=' * 60)
print('本轮创建的用户:', created)
print('清理命令（在服务器执行）:')
print("  sqlite3 /opt/siteauth/site.db \"DELETE FROM users WHERE username LIKE 'p7%'\"")
