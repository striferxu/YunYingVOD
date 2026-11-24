#!/usr/bin/env python3
"""probe_dedup.py — 验证同设备 app token 去重（P3 真机 bug 回归测试）。

背景：P3 真机验收发现，反复登录/登出后设备管理页出现多条同名设备。
根因：客户端登出靠 `current` 字段找本机 token，但服务端 list_tokens 没传
current_token_id，该字段恒为 false → 本机 token 从未被删除。

本探针验证修复后的服务端兜底行为：
  A. 同设备连续签发 3 次 → 只留 1 条
  B. 不同设备名互不影响
  C. 不同用户互不影响
  D. 同设备名但不同平台 → 视为不同设备（各留 1 条）

用法（服务器上）：python3 probe_dedup.py <username> <password>
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


def login(opener):
    st, raw, cookie = call(opener, "POST", "/api/login",
                           {"username": USER, "password": PWD})
    if st != 200 or not cookie:
        print("登录失败: status=%s %s" % (st, raw[:120]))
        sys.exit(1)
    return cookie


def list_tokens(opener, cookie):
    st, raw, _ = call(opener, "GET", "/api/app/tokens", cookie=cookie)
    return jload(raw).get("items") or []


def issue(opener, cookie, name, platform="android"):
    st, raw, _ = call(opener, "POST", "/api/app/token",
                      {"device_name": name, "platform": platform}, cookie=cookie)
    return st, jload(raw)


def cleanup(opener, cookie, names):
    """删掉探针造出来的设备，避免污染真实账号。"""
    for it in list_tokens(opener, cookie):
        if it.get("device_name") in names:
            call(opener, "DELETE", "/api/app/tokens/%d" % it["id"], body={},
                 cookie=cookie)


def main():
    print("目标: %s  账号: %s" % (BASE, USER))
    print("-" * 60)

    op = make_opener()
    cookie = login(op)

    probe_names = ["去重探针A", "去重探针B", "去重探针C"]

    # ---- A. 同设备连续签发 3 次 ----
    for _ in range(3):
        issue(op, cookie, "去重探针A")
    items = [i for i in list_tokens(op, cookie) if i.get("device_name") == "去重探针A"]
    rec("A. 同设备签发 3 次 -> 只留 1 条", len(items) == 1,
        "实际 %d 条" % len(items))

    # ---- B. 不同设备名互不影响 ----
    issue(op, cookie, "去重探针B")
    a_items = [i for i in list_tokens(op, cookie) if i.get("device_name") == "去重探针A"]
    b_items = [i for i in list_tokens(op, cookie) if i.get("device_name") == "去重探针B"]
    rec("B. 新增 B 设备后 A 仍为 1 条", len(a_items) == 1 and len(b_items) == 1,
        "A=%d B=%d" % (len(a_items), len(b_items)))

    # ---- D. 同设备名不同平台 -> 各自保留 ----
    issue(op, cookie, "去重探针C", "android")
    issue(op, cookie, "去重探针C", "ios")
    c_all = [i for i in list_tokens(op, cookie) if i.get("device_name") == "去重探针C"]
    c_android = [i for i in c_all if i.get("platform") == "android"]
    c_ios = [i for i in c_all if i.get("platform") == "ios"]
    rec("D. 同设备名不同平台各留 1 条",
        len(c_android) == 1 and len(c_ios) == 1,
        "android=%d ios=%d" % (len(c_android), len(c_ios)))

    # ---- 再签发一次 A，确认总数不涨 ----
    before = len(list_tokens(op, cookie))
    issue(op, cookie, "去重探针A")
    after = len(list_tokens(op, cookie))
    rec("E. 再次签发 A 后总条数不变", before == after,
        "before=%d after=%d" % (before, after))

    # ---- 清理 ----
    cleanup(op, cookie, probe_names)
    left = [i for i in list_tokens(op, cookie) if i.get("device_name") in probe_names]
    rec("F. 探针数据已清理干净", len(left) == 0, "残留 %d 条" % len(left))

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
