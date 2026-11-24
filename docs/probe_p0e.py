# -*- coding: utf-8 -*-
"""probe_p0e.py — 注册开启后的完整实测。"""
import json
import sys
import time
import urllib.error
import urllib.request
import http.cookiejar

BASE = "https://51play.ccwu.cc"
STAMP = int(time.time())


def op_new():
    jar = http.cookiejar.CookieJar()
    return jar, urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar), urllib.request.HTTPSHandler())


def rq(opener, method, path, data=None, headers=None):
    h = dict(headers or {})
    r = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        with opener.open(r, timeout=30) as resp:
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


def jp(opener, path, obj):
    return rq(opener, "POST", path, json.dumps(obj).encode(),
              {"Content-Type": "application/json"})


def show(t, st, b):
    print("\n" + "-" * 64)
    print("[%s] -> HTTP %s" % (t, st))
    print("   " + (json.dumps(b, ensure_ascii=False) if isinstance(b, (dict, list)) else str(b))[:260])


jar, op = op_new()
print("# 注册接口实测（开关已开启）")

name = "regtest_%d" % STAMP
st, b = jp(op, "/api/register", {"username": name, "password": "test123456", "nickname": "注册探针"})
show("1 正常注册 ← 预期 200 pending", st, b)

st, b = jp(op, "/api/register", {"username": name, "password": "test123456"})
show("2 重复用户名 ← 预期 409", st, b)

st, b = jp(op, "/api/register", {"username": "ab", "password": "test123456"})
show("3 用户名 2 位 ← 预期 400", st, b)

st, b = jp(op, "/api/register", {"username": "中文用户名", "password": "test123456"})
show("4 中文用户名 ← 预期 400", st, b)

st, b = jp(op, "/api/register", {"username": "nopass_%d" % STAMP})
show("5 无密码 ← 预期 400", st, b)

st, b = jp(op, "/api/register", {"username": "x" * 33, "password": "test123456"})
show("6 用户名 33 位 ← 预期 400", st, b)

st, b = jp(op, "/api/register", {"username": "okname_%d" % STAMP, "password": "test123456",
                                 "nickname": "n" * 65})
show("7 昵称 65 字 ← 预期 400", st, b)

st, b = jp(op, "/api/register", {"username": "ok2_%d" % STAMP, "password": "test123456"})
show("8 无昵称（可选） ← 预期 200，nickname 默认=username", st, b)

# pending 用户登录
jar2, op2 = op_new()
st, b = jp(op2, "/api/login", {"username": name, "password": "test123456"})
show("9 pending 用户登录 ← 预期 401", st, b)

print("\n# 待清理用户: %s, okname_%s, ok2_%s" % (name, STAMP, STAMP))
