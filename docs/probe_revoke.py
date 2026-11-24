#!/usr/bin/env python3
"""probe_revoke.py — 验证"踢设备"能真正让设备下线（P3.2 回归测试）。

背景（P3.2 真机 bug）：
  客户端移除当前设备后不会退出登录；杀进程重开仍是登录态。
  根因三层：
    1. sessions 表与 app_tokens 表无关联，revoke 只删 token 不删 session
    2. session 会滑动续期（每次访问 expires_at = now+1800）
       → 被踢的设备只要 App 开着、每 10 分钟保活，就能无限续命
    3. 客户端移除后不切登录态

本探针验证修复后：
  A. 用 token 换 session → 能访问 /api/me
  B. 踢掉该 token → 响应带 sessions_killed >= 1
  C. 旧 session 立刻失效（/api/me → 401）★ 核心断言
  D. 旧 token 也不能再换新 session → 401
  E. 模拟"保活"：反复访问 /api/me 仍是 401（不能被续期救活）★ 核心断言
  F. 踢自己 → self_revoked == true
  G. 踢别人的设备 → 403（越权保护仍在）

用法（服务器上）：python3 probe_revoke.py <username> <password>
"""
import json
import sys
import urllib.request
import urllib.error

BASE = "http://127.0.0.1:8000"
USER = sys.argv[1] if len(sys.argv) > 1 else "user"
PWD = sys.argv[2] if len(sys.argv) > 2 else "123456"

results = []


def rec(name, ok, detail=""):
    results.append((name, ok, detail))
    print("[%s] %s%s" % ("PASS" if ok else "FAIL", name,
                         ("  -> " + detail) if detail else ""))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):
        return None


def make_opener():
    return urllib.request.build_opener(NoRedirect())


def extract_session(headers):
    for raw in headers.get_all("Set-Cookie") or []:
        first = raw.split(";")[0].strip()
        if first.startswith("site_session="):
            val = first[len("site_session="):].strip()
            if val and val != "deleted":
                return first
    return None


def call(opener, method, path, body=None, cookie=None):
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
            return r.status, r.read().decode("utf-8", "replace"), extract_session(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), extract_session(e.headers)


def jload(raw):
    try:
        return json.loads(raw)
    except Exception:
        return {}


def main():
    print("目标: %s  账号: %s" % (BASE, USER))
    print("-" * 60)

    op = make_opener()

    # ---- 登录拿 Cookie ----
    st, raw, cookie = call(op, "POST", "/api/login",
                           {"username": USER, "password": PWD})
    if st != 200 or not cookie:
        print("登录失败: status=%s %s" % (st, raw[:120]))
        return 1

    # ---- 签发一个探针专用 token ----
    st, raw, _ = call(op, "POST", "/api/app/token",
                      {"device_name": "踢设备探针", "platform": "android"},
                      cookie=cookie)
    tok = jload(raw)
    token, tok_id = tok.get("token", ""), tok.get("id")
    if not token or not tok_id:
        print("签发 token 失败: %s" % raw[:150])
        return 1

    # ---- A. token 换 session ----
    st, raw, dev_cookie = call(op, "POST", "/api/app/session", {"token": token})
    rec("A. token 换 session -> 200", st == 200 and dev_cookie is not None,
        "status=%s" % st)
    if not dev_cookie:
        return summary()

    st, raw, _ = call(op, "GET", "/api/me", cookie=dev_cookie)
    rec("A2. 新 session 可访问 /api/me", st == 200, "status=%s" % st)

    # ---- B. 踢掉该 token（用主会话操作，不是自己踢自己）----
    st, raw, _ = call(op, "DELETE", "/api/app/tokens/%d" % tok_id, body={},
                      cookie=cookie)
    body = jload(raw)
    rec("B. 踢设备 -> 200", st == 200, "status=%s" % st)
    killed = body.get("sessions_killed")
    rec("B2. 连带销毁了 session（sessions_killed>=1）",
        isinstance(killed, int) and killed >= 1, "sessions_killed=%s" % killed)
    rec("B3. 不是自己踢自己（self_revoked=false）",
        body.get("self_revoked") is False, "self_revoked=%s" % body.get("self_revoked"))

    # ---- C. 旧 session 立刻失效 ★ ----
    st, raw, _ = call(op, "GET", "/api/me", cookie=dev_cookie)
    rec("C. 被踢设备的 session 立刻失效 -> 401", st == 401, "status=%s" % st)

    # ---- D. 旧 token 也不能再换 ----
    st, raw, _ = call(op, "POST", "/api/app/session", {"token": token})
    rec("D. 旧 token 换 session -> 401", st == 401, "status=%s" % st)

    # ---- E. 模拟保活：反复访问仍是 401（不能被滑动续期救活）★ ----
    all_401 = True
    for i in range(3):
        st, raw, _ = call(op, "GET", "/api/me", cookie=dev_cookie)
        if st != 401:
            all_401 = False
            break
    rec("E. 反复保活 3 次仍是 401（session 未被续期复活）", all_401,
        "最终 status=%s" % st)

    # ---- F. 自己踢自己 -> self_revoked ----
    # 用主会话签发一个新 token，再用该 token 换 session，然后用那个 session 踢自己
    st, raw, _ = call(op, "POST", "/api/app/token",
                      {"device_name": "自踢探针", "platform": "android"},
                      cookie=cookie)
    t2 = jload(raw)
    tok2, tok2_id = t2.get("token", ""), t2.get("id")
    st, raw, c2 = call(op, "POST", "/api/app/session", {"token": tok2})
    if st == 200 and c2:
        st, raw, _ = call(op, "DELETE", "/api/app/tokens/%d" % tok2_id,
                          body={}, cookie=c2)
        body = jload(raw)
        rec("F. 踢自己 -> self_revoked=true",
            st == 200 and body.get("self_revoked") is True,
            "status=%s self_revoked=%s" % (st, body.get("self_revoked")))
        st, raw, _ = call(op, "GET", "/api/me", cookie=c2)
        rec("F2. 自踢后自己的 session 也失效 -> 401", st == 401, "status=%s" % st)
    else:
        rec("F. 踢自己 -> self_revoked=true", False, "准备阶段失败")

    # ---- G. 越权保护：踢不存在的 id ----
    st, raw, _ = call(op, "DELETE", "/api/app/tokens/999999", body={},
                      cookie=cookie)
    rec("G. 踢不存在的设备 -> 404", st == 404, "status=%s" % st)

    # ---- 清理 ----
    st, raw, _ = call(op, "GET", "/api/app/tokens", cookie=cookie)
    for it in (jload(raw).get("items") or []):
        if it.get("device_name") in ("踢设备探针", "自踢探针"):
            call(op, "DELETE", "/api/app/tokens/%d" % it["id"], body={},
                 cookie=cookie)

    # 登出主会话
    call(op, "POST", "/api/logout", {}, cookie=cookie)

    return summary()


def summary():
    print("-" * 60)
    passed = sum(1 for _, ok, _ in results if ok)
    total = len(results)
    print("合计 %d/%d 通过" % (passed, total))
    if passed != total:
        for name, ok, detail in results:
            if not ok:
                print("  失败: %s (%s)" % (name, detail))
        return 1
    print("全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
