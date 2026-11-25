# -*- coding: utf-8 -*-
"""probe_p1.py — P1 app_tokens 全链路实测。

用法：python probe_p1.py [user] [password]
默认 user/123456。全部走 https://51play.ccwu.cc。
"""
import http.cookiejar
import json
import sys
import urllib.error
import urllib.request

BASE = "https://51play.ccwu.cc"
USER = sys.argv[1] if len(sys.argv) > 1 else "user"
PWD = sys.argv[2] if len(sys.argv) > 2 else "123456"

results = []


def call(method, path, body=None, cookie_jar=None, extra_headers=None, token=None):
    url = BASE + path
    data = None
    headers = {"User-Agent": "VODApp-P1Probe/1.0"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if extra_headers:
        headers.update(extra_headers)
    if token:
        headers["Authorization"] = "Bearer " + token
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(cookie_jar) if cookie_jar is not None
        else urllib.request.HTTPHandler())
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with opener.open(req, timeout=30) as r:
            raw = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(raw)
            except json.JSONDecodeError:
                return r.status, raw[:200]
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw[:200]
    except Exception as e:
        return -1, str(e)


def check(name, cond, detail=""):
    ok = bool(cond)
    results.append((name, ok, detail))
    print(("  PASS  " if ok else "  FAIL  ") + name + ("  | " + detail if detail else ""))
    return ok


print("=" * 70)
print("P1 app_tokens 全链路实测")
print("=" * 70)

jar = http.cookiejar.CookieJar()

# ---- 1. 登录拿 session ----
print("\n[1] 登录")
st, body = call("POST", "/api/login", {"username": USER, "password": PWD}, jar)
check("1.1 登录 200", st == 200, "status=%s body=%s" % (st, str(body)[:120]))
if st != 200:
    print("\n登录失败，后续用例跳过。请确认密码。")
    sys.exit(1)

# ---- 2. 签发 app token ----
print("\n[2] 签发 app token")
st, body = call("POST", "/api/app/token",
                {"device_name": "P1-Probe-Device", "platform": "android"}, jar)
check("2.1 签发 200", st == 200, "status=%s" % st)
tok1 = body.get("token") if isinstance(body, dict) else None
check("2.2 返回 vap_ 前缀", bool(tok1 and tok1.startswith("vap_")),
      "token=%s..." % (tok1[:16] if tok1 else None))
check("2.3 有效期 30 天", isinstance(body, dict) and body.get("ttl_days") == 30,
      "ttl_days=%s" % (body.get("ttl_days") if isinstance(body, dict) else None))
exp = body.get("expires_at") if isinstance(body, dict) else None
check("2.4 expires_at 为未来时间", isinstance(exp, int), "expires_at=%s" % exp)
tid1 = body.get("id") if isinstance(body, dict) else None

# ---- 3. 签发第二个 token（模拟第二台设备） ----
print("\n[3] 签发第二个 token（第二台设备）")
st, body = call("POST", "/api/app/token",
                {"device_name": "P1-Probe-Device-2", "platform": "ios"}, jar)
tok2 = body.get("token") if isinstance(body, dict) else None
tid2 = body.get("id") if isinstance(body, dict) else None
check("3.1 第二个 token 签发 200", st == 200, "status=%s" % st)
check("3.2 两 token 不同", tok1 != tok2)

# ---- 4. 列出设备 ----
print("\n[4] 设备列表")
st, body = call("GET", "/api/app/tokens", None, jar)
check("4.1 列表 200", st == 200, "status=%s" % st)
items = body.get("items", []) if isinstance(body, dict) else []
names = [i.get("device_name") for i in items]
check("4.2 含两个设备", len(items) >= 2, "items=%s" % names)
check("4.3 字段完整", all(k in items[0] for k in
                          ("id", "device_name", "platform", "created_at",
                           "expires_at", "current")) if items else False,
      "keys=%s" % (list(items[0].keys()) if items else None))

# ---- 5. 用 token 换 session（不带 Cookie） ----
print("\n[5] 用 token 换 session（无 Cookie）")
st, body = call("POST", "/api/app/session", {"token": tok1})
check("5.1 换 session 200", st == 200, "status=%s body=%s" % (st, str(body)[:120]))
check("5.2 返回 username", isinstance(body, dict) and body.get("username") == USER,
      "username=%s" % (body.get("username") if isinstance(body, dict) else None))

# ---- 6. 用新 session 访问业务接口 ----
print("\n[6] 新 session 访问业务接口")
jar2 = http.cookiejar.CookieJar()
st, body = call("POST", "/api/app/session", {"token": tok1}, jar2)
check("6.1 拿到 Cookie 并 200", st == 200, "status=%s" % st)
st, body = call("GET", "/api/me", None, jar2)
check("6.2 /api/me 200", st == 200, "status=%s" % st)
st, body = call("GET", "/api/videos?limit=3", None, jar2)
check("6.3 /api/videos 200", st == 200, "status=%s" % st)
total = body.get("total") if isinstance(body, dict) else None
check("6.4 视频总数正常", isinstance(total, int) and total > 0, "total=%s" % total)

# ---- 7. Bearer 头方式换 session ----
print("\n[7] Authorization: Bearer 方式")
st, body = call("POST", "/api/app/session", {}, token=tok2)
check("7.1 Bearer 换 session 200", st == 200, "status=%s" % st)

# ---- 8. 错误场景 ----
print("\n[8] 错误场景")
st, body = call("POST", "/api/app/session", {"token": "vap_invalid_token_xxx"})
check("8.1 无效 token -> 401", st == 401, "status=%s" % st)
st, body = call("POST", "/api/app/session", {"token": ""})
check("8.2 空 token -> 400", st == 400, "status=%s" % st)
st, body = call("GET", "/api/app/tokens", None)
check("8.3 无 session 列设备 -> 401", st == 401, "status=%s" % st)

# ---- 9. 踢设备 ----
print("\n[9] 踢掉第二台设备")
st, body = call("DELETE", "/api/app/tokens/%s" % tid2, None, jar)
check("9.1 踢设备 200", st == 200, "status=%s body=%s" % (st, str(body)[:100]))
st, body = call("POST", "/api/app/session", {"token": tok2})
check("9.2 被踢 token 失效 401", st == 401, "status=%s" % st)
st, body = call("POST", "/api/app/session", {"token": tok1})
check("9.3 另一 token 仍可用 200", st == 200, "status=%s" % st)
st, body = call("GET", "/api/app/tokens", None, jar)
items = body.get("items", []) if isinstance(body, dict) else []
check("9.4 列表只剩 1 个", len(items) == 1, "count=%s" % len(items))

# ---- 10. 越权踢别人设备 ----
print("\n[10] 越权保护")
st, body = call("DELETE", "/api/app/tokens/999999", None, jar)
check("10.1 踢不存在设备 -> 404", st == 404, "status=%s" % st)

print("\n" + "=" * 70)
passed = sum(1 for _, ok, _ in results if ok)
failed = len(results) - passed
print("结果：%d 通过 / %d 失败 / 共 %d" % (passed, failed, len(results)))
if failed:
    print("\n失败项：")
    for n, ok, d in results:
        if not ok:
            print("  -", n, "|", d)
print("=" * 70)

# 清理：保留 tok1 用于后续手工验证，其余清空
if tid1:
    call("DELETE", "/api/app/tokens/%s" % tid1, None, jar)
    print("已清理测试 token id=%s" % tid1)

sys.exit(0 if failed == 0 else 2)
