# -*- coding: utf-8 -*-
"""probe_p0c.py — P0 第三阶段：错误场景与边界补测。"""
import json
import sys
import time
import urllib.error
import urllib.request
import http.cookiejar

BASE = "https://51play.ccwu.cc"
U = sys.argv[1] if len(sys.argv) > 1 else "user"
P = sys.argv[2] if len(sys.argv) > 2 else ""


def op_new():
    jar = http.cookiejar.CookieJar()
    return jar, urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar), urllib.request.HTTPSHandler())


def rq(opener, method, path, data=None, headers=None, timeout=60):
    hdrs = dict(headers or {})
    r = urllib.request.Request(BASE + path, data=data, headers=hdrs, method=method)
    try:
        with opener.open(r, timeout=timeout) as resp:
            raw = resp.read()
            try:
                return resp.status, json.loads(raw.decode())
            except ValueError:
                return resp.status, raw.decode("utf-8", "replace")[:200]
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw[:200]
    except Exception as e:
        return None, repr(e)


def jp(opener, path, obj, extra=None):
    h = {"Content-Type": "application/json"}
    h.update(extra or {})
    return rq(opener, "POST", path, json.dumps(obj).encode(), h)


def show(t, st, b):
    print("\n" + "-" * 66)
    print("[%s] -> HTTP %s" % (t, st))
    print("   " + (json.dumps(b, ensure_ascii=False) if isinstance(b, (dict, list)) else str(b))[:300])


jar, op = op_new()
print("# P0-C 错误场景补测")

# 1. Origin 白名单
st, b = jp(op, "/api/login", {"username": U, "password": P}, {"Origin": "https://evil.example.com"})
show("1 登录带非法 Origin ← 预期 403", st, b)

st, b = jp(op, "/api/login", {"username": U, "password": P}, {"Origin": BASE})
show("2 登录带合法 Origin ← 预期 200", st, b)

# 2. 上传未登录
jar2, op2 = op_new()
st, b = rq(op2, "POST", "/api/upload", b"x", {"Content-Type": "multipart/form-data; boundary=x"})
show("3 未登录上传 ← 预期 401", st, b)

# 3. 未登录注册
st, b = jp(op2, "/api/register", {"username": "abc123", "password": "x"})
show("4 未登录注册(注册已关闭) ← 预期 403 registration closed", st, b)

# 4. 上传缺 video 字段
st, b = rq(op, "POST", "/api/upload", b"--x--\r\n",
           {"Content-Type": "multipart/form-data; boundary=x", "Origin": BASE})
show("5 上传空 multipart ← 预期 400", st, b)

# 5. 上传非 multipart
st, b = rq(op, "POST", "/api/upload", b'{"a":1}',
           {"Content-Type": "application/json", "Origin": BASE})
show("6 上传用 JSON ← 预期 400/403", st, b)

# 6. 不存在 job 的状态查询
st, b = rq(op, "GET", "/api/upload_status/__nope__")
show("7 查询不存在 job ← 预期 404", st, b)

# 7. 404 路由
st, b = rq(op, "GET", "/api/no_such_endpoint")
show("8 不存在的 API 路由 ← 预期 404", st, b)

# 8. admin 接口用普通用户
st, b = rq(op, "GET", "/api/admin/videos")
show("9 普通用户访问 admin 接口 ← 预期 403", st, b)

# 9. GET 方式打 login
st, b = rq(op, "GET", "/api/login")
show("10 GET /api/login ← 预期 404/405", st, b)

# 10. 423 锁定：连续错误密码（用不存在用户避免锁真实账号）
print("\n[10] 连续 12 次错误密码，观察是否出现 423（用不存在用户名，避免锁真实账号）")
jar3, op3 = op_new()
fake = "__locktest_%d__" % int(time.time())
codes = []
for i in range(12):
    st, b = jp(op3, "/api/login", {"username": fake, "password": "wrong"})
    codes.append(st)
    if st == 423:
        show("10 第%d次出现锁定" % (i + 1), st, b)
        break
print("   连续返回码: %s" % codes)

print("\n# P0-C DONE")
