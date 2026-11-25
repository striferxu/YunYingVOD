# -*- coding: utf-8 -*-
"""probe_p0d.py — 慢速测 423 锁定 + 限流恢复行为。"""
import json
import sys
import time
import urllib.error
import urllib.request

BASE = "https://51play.ccwu.cc"
FAKE = "__locktest_%d__" % int(time.time())


def post(obj):
    r = urllib.request.Request(BASE + "/api/login",
                               data=json.dumps(obj).encode(),
                               headers={"Content-Type": "application/json"},
                               method="POST")
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:120]


print("# 限流: 15r/m burst=5 —— 每秒 1 次不会被限流，测后端 423")
print("# 用户名: %s\n" % FAKE)
codes = []
for i in range(12):
    st, body = post({"username": FAKE, "password": "wrong%d" % i})
    codes.append(st)
    print("  第%2d次 -> HTTP %s  %s" % (i + 1, st, body.strip()[:80]))
    if st == 423:
        print("  >>> 出现 423 锁定")
        break
    time.sleep(4.2)   # 约 14 次/分钟，低于 15r/m
print("\n返回码序列: %s" % codes)
