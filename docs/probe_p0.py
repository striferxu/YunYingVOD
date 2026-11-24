# -*- coding: utf-8 -*-
"""probe_p0.py — P0 阶段 API 契约实测脚本（在服务器本机执行）。

用法（服务器上）：
    python3 probe_p0.py <username> <password>

输出：逐接口打印真实请求/响应，供 CLIENT_API_SPEC.md 直接引用。
注意：脚本跑在服务器本机，走 https://51play.ccwu.cc，与客户端同链路。
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import http.cookiejar

BASE = "https://51play.ccwu.cc"
USERNAME = sys.argv[1] if len(sys.argv) > 1 else "user"
PASSWORD = sys.argv[2] if len(sys.argv) > 2 else ""

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(jar),
    urllib.request.HTTPSHandler(),
)


def call(method, path, body=None, headers=None, raw=False, desc=""):
    url = BASE + path if path.startswith("/") else path
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    print("\n" + "=" * 70)
    print("[%s] %s %s" % (desc, method, path))
    try:
        with opener.open(req, timeout=30) as r:
            payload = r.read()
            print("-> HTTP %d %s" % (r.status, r.reason))
            if raw:
                print("-> bytes=%d head=%r" % (len(payload), payload[:80]))
                return r.status, payload
            text = payload.decode("utf-8", "replace")
            try:
                obj = json.loads(text)
                print("-> JSON: " + json.dumps(obj, ensure_ascii=False)[:1200])
                return r.status, obj
            except ValueError:
                print("-> TEXT: " + text[:600])
                return r.status, text
    except urllib.error.HTTPError as e:
        payload = e.read()
        text = payload.decode("utf-8", "replace")
        print("-> HTTP %d %s" % (e.code, e.reason))
        print("-> BODY: " + text[:600])
        return e.code, text
    except Exception as e:
        print("-> EXCEPTION: %r" % (e,))
        return None, None


def cookies():
    return {c.name: c.value for c in jar}


def main():
    print("#" * 70)
    print("# P0 API PROBE  base=%s  user=%s" % (BASE, USERNAME))
    print("#" * 70)

    # ---------- 1. 登录 ----------
    st, obj = call("POST", "/api/login",
                   body={"username": USERNAME, "password": PASSWORD},
                   desc="1 登录(正确密码)")
    print("-> cookies: %s" % json.dumps(cookies()))

    # ---------- 2. me / me_full ----------
    call("GET", "/api/me", desc="2 当前会话")
    call("GET", "/api/me_full", desc="3 完整用户信息")

    # ---------- 3. 视频列表 ----------
    st, vids = call("GET", "/api/videos", desc="4 视频列表(默认)")
    first_id = None
    if isinstance(vids, dict) and vids.get("items"):
        print("-> total=%s items=%d" % (vids["total"], len(vids["items"])))
        print("-> 字段名: %s" % list(vids["items"][0].keys()))
        print("-> 首项: %s" % json.dumps(vids["items"][0], ensure_ascii=False))
        first_id = vids["items"][0]["id"]
    call("GET", "/api/videos?q=IPX", desc="5 搜索 q=IPX")
    call("GET", "/api/videos?limit=2&page=2", desc="6 分页 limit=2 page=2")
    call("GET", "/api/videos?status=deleted", desc="7 状态过滤 deleted")
    call("GET", "/api/videos?limit=999", desc="8 limit 越界(>500)")
    call("GET", "/api/videos?page=0", desc="9 page=0 越界")
    if first_id:
        call("GET", "/api/videos/" + urllib.parse.quote(first_id), desc="10 单条详情")
    call("GET", "/api/videos/__not_exist__", desc="11 不存在的 id")
    call("GET", "/api/my_videos", desc="12 我的视频")
    call("GET", "/api/owners", desc="13 上传者映射")
    st, cj = call("GET", "/videos.json", desc="14 兼容层 videos.json")
    if isinstance(cj, list) and cj:
        print("-> 兼容层字段名: %s" % list(cj[0].keys()))

    # ---------- 4. 媒体链路鉴权 ----------
    if first_id:
        vid = urllib.parse.quote(first_id)
        call("GET", "/videos/%s/output.m3u8" % vid, raw=True, desc="15 m3u8(带Cookie)")
        call("GET", "/key/%s" % vid, raw=True, desc="16 key(带Cookie)")
        call("GET", "/covers/%s.jpg" % vid, raw=True, desc="17 cover(带Cookie)")
        # 取第一个 ts
        st, m3u8 = call("GET", "/videos/%s/output.m3u8" % vid, raw=True, desc="18 m3u8 再取一次")
        if m3u8:
            lines = m3u8.decode("utf-8", "replace").splitlines()
            ts = [l.strip() for l in lines if l.strip() and not l.startswith("#")]
            if ts:
                call("GET", "/videos/%s/%s" % (vid, ts[0]), raw=True, desc="19 ts 分段")

    # ---------- 5. 错误场景 ----------
    print("\n" + "#" * 70)
    print("# 错误场景（用干净 opener，不带 Cookie）")
    print("#" * 70)
    clean = urllib.request.build_opener()
    req = urllib.request.Request(BASE + "/api/videos")
    try:
        with clean.open(req, timeout=30) as r:
            print("20 无Cookie拉列表 -> HTTP %d" % r.status)
    except urllib.error.HTTPError as e:
        print("20 无Cookie拉列表 -> HTTP %d BODY=%s" % (e.code, e.read().decode()[:200]))
    if first_id:
        req = urllib.request.Request(BASE + "/videos/%s/output.m3u8" % urllib.parse.quote(first_id))
        try:
            with clean.open(req, timeout=30) as r:
                print("21 无Cookie拉m3u8 -> HTTP %d" % r.status)
        except urllib.error.HTTPError as e:
            print("21 无Cookie拉m3u8 -> HTTP %d BODY=%s" % (e.code, e.read().decode()[:200]))
        req = urllib.request.Request(BASE + "/key/%s" % urllib.parse.quote(first_id))
        try:
            with clean.open(req, timeout=30) as r:
                print("22 无Cookie拉key -> HTTP %d" % r.status)
        except urllib.error.HTTPError as e:
            print("22 无Cookie拉key -> HTTP %d" % e.code)

    # 错误密码（干净 opener）
    st, obj = call("POST", "/api/login", body={"username": USERNAME, "password": "definitely_wrong_zz"},
                   desc="23 错误密码")
    # 不存在用户
    call("POST", "/api/login", body={"username": "__no_such_user__", "password": "x"}, desc="24 不存在用户")
    # 非法 JSON
    call("POST", "/api/login", body=None, headers={"Content-Type": "application/json"},
         desc="25 空body登录")

    # ---------- 6. 登出 ----------
    call("POST", "/api/logout", desc="26 登出")
    call("GET", "/api/me", desc="27 登出后 me")

    print("\n" + "#" * 70)
    print("# PROBE DONE")
    print("#" * 70)


if __name__ == "__main__":
    main()
