#!/usr/bin/env python3
"""probe_p3.py — P3 会话链路探针（在服务器本机运行）。

为什么必须在服务器本机跑：nginx 有 Origin 白名单和登录限流，从外网跑容易
被 503 干扰；本机直连 127.0.0.1:8000 可以精确验证后端行为。

覆盖 P3 客户端的全部依赖点：
  1. 正确密码登录 -> 200 + Set-Cookie
  2. /api/me 用该 Cookie -> 200
  3. 错误密码 -> 401 Invalid credentials（与用户不存在同文案）
  4. 登录后签发 app token -> 200 + vap_ 前缀
  5. 丢弃 Cookie，仅用 app token 换 session -> 200 + 新 Cookie
  6. 新 Cookie 调 /api/me -> 200（证明换新成功）
  7. 伪造 app token -> 401
  8. 列出设备 -> 能看到刚签发的设备
  9. 踢掉该设备 -> 200
 10. 用已踢的 token 换 session -> 401
 11. 登出（带 {}）-> 200，之后 /api/me -> 401
 12. 无 Cookie 调 /api/me -> 401

用法（服务器上）：
    python3 probe_p3.py [username] [password]

注意：第 3 步会产生 1 次失败登录计数。若账号之前已累计接近 10 次，
请先等锁定窗口过去，否则会拿到 423 而非 401。
"""
import json
import sys
import time
import urllib.request
import urllib.error
import http.cookiejar

BASE = "http://127.0.0.1:8000"
USER = sys.argv[1] if len(sys.argv) > 1 else "user"
PWD = sys.argv[2] if len(sys.argv) > 2 else "123456"

results = []


def rec(name, ok, detail=""):
    results.append((name, ok, detail))
    mark = "PASS" if ok else "FAIL"
    print(f"[{mark}] {name}" + (f"  -> {detail}" if detail else ""))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):
        return None


def make_opener():
    """不带 cookiejar：Cookie 手动管理。

    原因：服务端 Set-Cookie 带 `Secure` 标记，而本探针走 http://127.0.0.1。
    Python 的 http.cookiejar 严格遵守 RFC，不会把 Secure cookie 通过 http 发送，
    导致登录后立刻 401。生产环境是 https，浏览器/Flutter 无此问题。
    """
    return urllib.request.build_opener(NoRedirect())


def extract_session(headers):
    """从响应头 Set-Cookie 里抠出 site_session=<value>。"""
    for raw in headers.get_all("Set-Cookie") or []:
        first = raw.split(";")[0].strip()
        if first.startswith("site_session="):
            val = first[len("site_session="):].strip()
            if val and val != "deleted":
                return first
    return None


def call(opener, method, path, body=None, cookie=None):
    """返回 (status, json_or_text, session_cookie_or_None)。不抛异常。"""
    url = BASE + path
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if cookie:
        headers["Cookie"] = cookie
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with opener.open(req, timeout=15) as r:
            raw = r.read().decode("utf-8", "replace")
            return r.status, raw, extract_session(r.headers)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        return e.code, raw, extract_session(e.headers)


def jload(raw):
    try:
        return json.loads(raw)
    except Exception:
        return {}


def main():
    print(f"目标: {BASE}  账号: {USER}")
    print("-" * 60)

    op = make_opener()

    # ---- 0. 无 Cookie 访问 /api/me 应 401 ----
    st, raw, _ = call(op, "GET", "/api/me")
    rec("0. 无 Cookie 调 /api/me -> 401", st == 401, f"status={st}")

    # ---- 1. 正确密码登录 ----
    st, raw, cookie = call(op, "POST", "/api/login",
                           {"username": USER, "password": PWD})
    body = jload(raw)
    rec("1. 正确密码登录 -> 200", st == 200 and body.get("ok") is True,
        f"status={st} body={raw[:100]}")
    rec("1b. 下发 site_session Cookie", cookie is not None,
        "有 Cookie" if cookie else "无 Cookie")
    if not cookie:
        print("登录失败，后续步骤无法继续。请确认账号密码正确且账号为 active。")
        return summary()

    # ---- 2. 用 Cookie 调 /api/me ----
    st, raw, _ = call(op, "GET", "/api/me", cookie=cookie)
    body = jload(raw)
    rec("2. Cookie 调 /api/me -> 200", st == 200 and body.get("username") == USER,
        f"status={st} username={body.get('username')}")

    # ---- 4. 签发 app token ----
    st, raw, _ = call(op, "POST", "/api/app/token",
                      {"device_name": "P3探针设备", "platform": "android"},
                      cookie=cookie)
    tok_body = jload(raw)
    token = tok_body.get("token", "")
    tok_id = tok_body.get("id")
    rec("4. 签发 app token -> 200", st == 200 and token.startswith("vap_"),
        f"status={st} ttl_days={tok_body.get('ttl_days')}")
    rec("4b. token 有效期 30 天", tok_body.get("ttl_days") == 30,
        f"ttl_days={tok_body.get('ttl_days')}")

    # ---- 5. 丢弃 Cookie，仅用 app token 换 session ----
    st, raw, cookie2 = call(op, "POST", "/api/app/session", {"token": token})
    rec("5. 仅用 token 换 session -> 200", st == 200 and cookie2 is not None,
        f"status={st} body={raw[:80]}")
    rec("5b. 换到新 Cookie 且与旧的不同",
        cookie2 is not None and cookie2 != cookie,
        "新 Cookie" if cookie2 else "无 Cookie")

    # ---- 6. 新 Cookie 可用 ----
    if cookie2:
        st, raw, _ = call(op, "GET", "/api/me", cookie=cookie2)
        rec("6. 新 Cookie 调 /api/me -> 200", st == 200, f"status={st}")

    # ---- 7. 伪造 token ----
    st, raw, _ = call(op, "POST", "/api/app/session",
                      {"token": "vap_" + "0" * 64})
    rec("7. 伪造 token 换 session -> 401", st == 401, f"status={st}")

    # ---- 8. 列出设备 ----
    st, raw, _ = call(op, "GET", "/api/app/tokens", cookie=cookie)
    body = jload(raw)
    items = body.get("items") or []
    found = [i for i in items if i.get("id") == tok_id]
    rec("8. 列出设备含刚签发项", st == 200 and len(found) == 1,
        f"status={st} total={body.get('total')} 命中={len(found)}")

    # ---- 9. 踢设备 ----
    st, raw, _ = call(op, "DELETE", f"/api/app/tokens/{tok_id}", body={},
                      cookie=cookie)
    rec("9. 踢掉该设备 -> 200", st == 200, f"status={st} {raw[:80]}")

    # ---- 10. 已踢 token 失效 ----
    st, raw, _ = call(op, "POST", "/api/app/session", {"token": token})
    rec("10. 已踢 token 换 session -> 401", st == 401, f"status={st}")

    # ---- 11. 登出 ----
    st, raw, _ = call(op, "POST", "/api/logout", {}, cookie=cookie)
    rec("11. 登出（带 {}）-> 200", st == 200, f"status={st}")
    st, raw, _ = call(op, "GET", "/api/me", cookie=cookie)
    rec("11b. 登出后 /api/me -> 401", st == 401, f"status={st}")

    # ---- 3. 错误密码（放最后，避免影响前面登录计数）----
    st, raw, _ = call(op, "POST", "/api/login",
                      {"username": USER, "password": "__wrong_pwd_probe__"})
    body = jload(raw)
    rec("3. 错误密码 -> 401 Invalid credentials",
        st == 401 and body.get("error") == "Invalid credentials",
        f"status={st} error={body.get('error')}")

    return summary()


def summary():
    print("-" * 60)
    total = len(results)
    passed = sum(1 for _, ok, _ in results if ok)
    print(f"合计 {passed}/{total} 通过")
    if passed != total:
        print("失败项：")
        for name, ok, detail in results:
            if not ok:
                print(f"  - {name}  ({detail})")
        return 1
    print("全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
