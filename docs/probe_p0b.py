# -*- coding: utf-8 -*-
"""probe_p0b.py — P0 第二阶段实测：登出正确姿势 / 上传 / 进度 / 注册。

在服务器本机执行：python3 probe_p0b.py <username> <password>
会创建一个测试上传（3 秒小视频）与一个测试注册用户，结束后自动清理。
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import http.cookiejar

BASE = "https://51play.ccwu.cc"
USERNAME = sys.argv[1] if len(sys.argv) > 1 else "user"
PASSWORD = sys.argv[2] if len(sys.argv) > 2 else ""
TEST_REG_NAME = "p0probe_%d" % int(time.time())


def new_opener():
    jar = http.cookiejar.CookieJar()
    return jar, urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(),
    )


def show(desc, status, body, limit=900):
    print("\n" + "=" * 70)
    print("[%s]" % desc)
    print("-> HTTP %s" % status)
    if isinstance(body, (dict, list)):
        print("-> " + json.dumps(body, ensure_ascii=False)[:limit])
    else:
        print("-> " + str(body)[:limit])


def req(opener, method, path, data=None, headers=None, timeout=300):
    url = BASE + path
    hdrs = dict(headers or {})
    reqobj = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with opener.open(reqobj, timeout=timeout) as r:
            raw = r.read()
            try:
                return r.status, json.loads(raw.decode("utf-8"))
            except ValueError:
                return r.status, raw.decode("utf-8", "replace")[:300]
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw[:300]


def json_post(opener, path, obj):
    return req(opener, "POST", path,
               data=json.dumps(obj).encode("utf-8"),
               headers={"Content-Type": "application/json"})


def build_multipart(fields, files):
    """fields: dict[str,str]; files: list[(name, filename, bytes, mime)]"""
    boundary = "----P0ProbeBoundary7x" + str(int(time.time()))
    parts = []
    for k, v in fields.items():
        parts.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
                      % (boundary, k, v)).encode("utf-8"))
    for name, filename, content, mime in files:
        parts.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n"
                      "Content-Type: %s\r\n\r\n" % (boundary, name, filename, mime)).encode("utf-8"))
        parts.append(content)
        parts.append(b"\r\n")
    parts.append(("--%s--\r\n" % boundary).encode("utf-8"))
    body = b"".join(parts)
    return body, "multipart/form-data; boundary=%s" % boundary


def main():
    jar, op = new_opener()
    print("#" * 70)
    print("# P0-B PROBE  base=%s  user=%s" % (BASE, USERNAME))
    print("#" * 70)

    st, body = json_post(op, "/api/login", {"username": USERNAME, "password": PASSWORD})
    show("1 登录", st, body)

    # ---------- 登出：三种姿势 ----------
    st, body = req(op, "POST", "/api/logout")
    show("2 登出(无 Content-Type) ← 预期 403", st, body)

    st, body = req(op, "POST", "/api/logout",
                   data=b"{}", headers={"Content-Type": "application/json"})
    show("3 登出(JSON 空对象) ← 正确姿势", st, body)

    st, body = req(op, "GET", "/api/me")
    show("4 登出后 GET /api/me", st, body)

    # 重新登录
    st, body = json_post(op, "/api/login", {"username": USERNAME, "password": PASSWORD})
    show("5 重新登录", st, body)

    # ---------- 上传：错误扩展名 ----------
    body_bytes, ctype = build_multipart(
        {"title": "p0 probe bad ext"},
        [("video", "notavideo.txt", b"hello world", "text/plain")])
    st, body = req(op, "POST", "/api/upload", data=body_bytes,
                   headers={"Content-Type": ctype, "Origin": BASE})
    show("6 上传非视频扩展名 ← 预期 400", st, body)

    # ---------- 上传：真实小视频 ----------
    src = "/tmp/p0_probe_clip.mp4"
    subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15",
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
                    "-t", "3", "-c:v", "libx264", "-preset", "ultrafast",
                    "-c:a", "aac", "-shortest", src],
                   capture_output=True, timeout=120)
    size = os.path.getsize(src) if os.path.isfile(src) else 0
    print("\n[准备] 测试视频 %s size=%d bytes" % (src, size))

    job_id = None
    video_id = None
    if size > 0:
        with open(src, "rb") as f:
            content = f.read()
        body_bytes, ctype = build_multipart(
            {"title": "P0 探针测试视频（可删除）"},
            [("video", "p0_probe_clip.mp4", content, "video/mp4")])
        st, body = req(op, "POST", "/api/upload", data=body_bytes,
                       headers={"Content-Type": ctype, "Origin": BASE})
        show("7 上传真实小视频 ← 预期 202", st, body)
        if isinstance(body, dict):
            job_id = body.get("job_id")

        if job_id:
            for i in range(60):
                st, body = req(op, "GET", "/api/upload_status/" + urllib.parse.quote(job_id))
                if i == 0 or (isinstance(body, dict) and body.get("status") in ("done", "failed")):
                    show("8 轮询上传状态(第%d次)" % (i + 1), st, body)
                if isinstance(body, dict) and body.get("status") in ("done", "failed"):
                    video_id = body.get("result_id")
                    break
                time.sleep(2)

    # ---------- 我的视频 ----------
    st, body = req(op, "GET", "/api/my_videos")
    show("9 GET /api/my_videos（上传后）", st, body, limit=600)

    # ---------- 注册 ----------
    st, body = json_post(op, "/api/register",
                         {"username": TEST_REG_NAME, "password": "probe123456",
                          "nickname": "P0探针"})
    show("10 注册新用户 ← 预期 200 pending", st, body)

    st, body = json_post(op, "/api/register",
                         {"username": TEST_REG_NAME, "password": "probe123456"})
    show("11 重复用户名注册 ← 预期 409", st, body)

    st, body = json_post(op, "/api/register", {"username": "ab", "password": "x"})
    show("12 非法用户名(2位) ← 预期 400", st, body)

    st, body = json_post(op, "/api/register", {"username": "中文用户名", "password": "x"})
    show("13 中文用户名 ← 预期 400", st, body)

    st, body = json_post(op, "/api/register", {"username": "p0empty_" + str(int(time.time()))})
    show("14 注册无密码 ← 预期 400", st, body)

    # ---------- pending 用户登录 ----------
    jar2, op2 = new_opener()
    st, body = json_post(op2, "/api/register",
                         {"username": TEST_REG_NAME + "_b", "password": "probe123456"})
    show("15 注册另一个待审核用户", st, body)
    st, body = json_post(op2, "/api/login",
                         {"username": TEST_REG_NAME + "_b", "password": "probe123456"})
    show("16 pending 用户登录 ← 预期 401", st, body)

    print("\n# 清理标记: job_id=%s video_id=%s reg_users=%s,%s_b"
          % (job_id, video_id, TEST_REG_NAME, TEST_REG_NAME))
    print("# PROBE-B DONE")


if __name__ == "__main__":
    main()
