#!/usr/bin/env python3
"""
siteauth_server.py — v2 认证与数据后端（改写版，保留原文件名/systemd ExecStart 不变）
====================================================================================
纯 Python 标准库，零第三方依赖。监听 127.0.0.1:8000，供 nginx auth_request 与 /api/ 代理调用。

API（与方案 §5.4 一致）：
  POST /api/login                无鉴权：username?+password；username 为空走 legacy 单密码
  GET  /api/auth                 供 nginx auth_request；带 X-Auth-User / X-Auth-Role
  POST /api/logout               销毁会话 + 清 Cookie
  GET  /api/me                   {"username","role","expires_at"}
  GET  /api/videos               {"total","items"}，支持 q/page/limit/status
  GET  /api/videos/<id>          单条
  GET  /videos.json              兼容层：旧格式数组 [{id,name,date,cover}]
  GET  /api/admin/users          管理：用户列表
  POST /api/admin/users          管理：建号
  POST /api/admin/users/<id>/password /status
  DELETE /api/admin/users/<id>
  GET/POST /api/admin/videos     管理：完整列表 / 新增更新
  POST /api/admin/videos/<id>/delete /restore
  GET  /api/admin/audit          最近 50 条审计
  GET  /api/admin/health         DB 与磁盘一致性

安全：Cookie site_session HttpOnly;Secure;SameSite=Lax；DB 只存 sha256(token)；
      写接口要求 Content-Type: application/json 且 Origin（若存在）在允许列表；
      登录失败 10 次锁 10 分钟（内存计数）；请求体上限 1MB。
"""
import http.server
import json
import os
import re
import secrets
import threading
import time
import urllib.parse
from http import HTTPStatus

import db
import auth
import videos as videos_mod
import admin as admin_mod
import multiuser  # 多用户扩展（注册审核/上传转码），独立模块不影响旧功能
import app_tokens  # P1：移动端长效令牌

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("SERVER_PORT", "8000"))
MAX_BODY = 1 * 1024 * 1024

SESSION_MAX_AGE = int(os.environ.get("SESSION_MAX_AGE", "600"))
LEGACY_MODE = os.environ.get("SITEAUTH_LEGACY_LOGIN", "on").strip().lower()
SITE_PASSWORD = os.environ.get("SITE_PASSWORD", "")
ALLOWED_ORIGINS = {"https://51play.ccwu.cc", "https://64.90.31.17"}

# 登录失败锁定（内存）
MAX_LOGIN_FAILURES = 10
LOCK_SECONDS = 600
_fail_lock = threading.Lock()
_failures = {}  # key(username 或 "legacy") -> {"count": int, "locked_until": float}


def _now():
    return int(time.time())


def _parse_content_type(ct):
    """解析 'multipart/form-data; boundary=xxx' → (主类型, 参数dict)。"""
    parts = [p.strip() for p in ct.split(";")]
    main = parts[0].lower()
    params = {}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            params[k.strip().lower()] = v.strip().strip('"')
    return main, params


# ---------------------------------------------------------------------------
# 会话（落库）
# ---------------------------------------------------------------------------

def create_session(conn, user_id, ip, ua):
    token = secrets.token_urlsafe(32)
    now = _now()
    conn.execute(
        "INSERT INTO sessions(token_hash,user_id,created_at,last_active,expires_at,ip,ua) "
        "VALUES(?,?,?,?,?,?,?)",
        (auth.token_hash(token), user_id, now, now, now + SESSION_MAX_AGE, ip, ua[:200]))
    return token


def get_session_user(conn, token):
    """校验会话并滑动续期。返回 dict(user_id, username, role, status, expires_at) 或 None。"""
    if not token:
        return None
    th = auth.token_hash(token)
    row = conn.execute(
        "SELECT s.user_id,s.expires_at,u.username,u.role,u.status FROM sessions s "
        "JOIN users u ON u.id=s.user_id WHERE s.token_hash=?", (th,)).fetchone()
    if not row:
        return None
    now = _now()
    if row["expires_at"] <= now:
        conn.execute("DELETE FROM sessions WHERE token_hash=?", (th,))
        conn.commit()
        return None
    if row["status"] != "active":
        conn.execute("DELETE FROM sessions WHERE token_hash=?", (th,))
        conn.commit()
        return None
    conn.execute("UPDATE sessions SET last_active=?, expires_at=? WHERE token_hash=?",
                 (now, now + SESSION_MAX_AGE, th))
    conn.commit()
    return {"user_id": row["user_id"], "username": row["username"],
            "role": row["role"], "status": row["status"], "expires_at": now + SESSION_MAX_AGE}


def destroy_session(conn, token):
    if token:
        conn.execute("DELETE FROM sessions WHERE token_hash=?", (auth.token_hash(token),))
        conn.commit()


def cleanup_sessions():
    """清掉过期会话（启动时 + 每 10 分钟）。"""
    try:
        conn = db.connect()
        try:
            conn.execute("DELETE FROM sessions WHERE expires_at <= ?", (_now(),))
            conn.commit()
        finally:
            conn.close()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# 登录锁定
# ---------------------------------------------------------------------------

def _check_lock(key):
    with _fail_lock:
        f = _failures.get(key)
        if f and f.get("locked_until", 0) > time.time():
            return True
        return False


def _record_failure(key):
    with _fail_lock:
        f = _failures.setdefault(key, {"count": 0, "locked_until": 0})
        f["count"] += 1
        if f["count"] >= MAX_LOGIN_FAILURES:
            f["locked_until"] = time.time() + LOCK_SECONDS
            f["count"] = 0


def _clear_failures(key):
    with _fail_lock:
        _failures.pop(key, None)


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class SiteAuthHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SiteAuth/2.0"

    _debug_log = False

    def log_message(self, fmt, *args):
        if self._debug_log:
            super().log_message(fmt, *args)

    # ---- 基础工具 ----

    def _client_ip(self):
        xff = self.headers.get("X-Forwarded-For", "")
        if xff:
            return xff.split(",")[0].strip()
        return self.client_address[0]

    def _cookie_token(self):
        cookies = {}
        ch = self.headers.get("Cookie", "")
        for item in ch.split(";"):
            item = item.strip()
            if "=" in item:
                k, v = item.split("=", 1)
                cookies[k.strip()] = v.strip()
        return cookies.get("site_session", "")

    def _read_json_body(self):
        cl = self.headers.get("Content-Length")
        try:
            length = int(cl) if cl else 0
        except ValueError:
            return None, (400, {"error": "Bad Content-Length"})
        if length > MAX_BODY:
            # 排空请求体，保持连接可用；超大（>16MB）则直接关闭连接
            if length <= 16 * 1024 * 1024:
                try:
                    self.rfile.read(length)
                except Exception:
                    pass
                return None, (413, {"error": "Request body too large"})
            self.close_connection = True
            return None, (413, {"error": "Request body too large"})
        body = self.rfile.read(length)
        if not body:
            return None, (400, {"error": "Empty request body"})
        try:
            data = json.loads(body.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None, (400, {"error": "Invalid JSON"})
        if not isinstance(data, dict):
            return None, (400, {"error": "JSON body must be an object"})
        return data, None

    def _csrf_ok(self):
        if self.command not in ("POST", "DELETE", "PUT", "PATCH"):
            return True
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        ct = self.headers.get("Content-Type", "")
        # 上传视频走 multipart/form-data，放行；其余写接口仍要求 application/json
        if path == "/api/upload" and "multipart/form-data" in ct.lower():
            origin = self.headers.get("Origin")
            if origin and origin not in ALLOWED_ORIGINS:
                return False
            return True
        # 设备管理：DELETE /api/app/tokens/<id> 允许无请求体（仍校验 Origin）
        if self.command == "DELETE" and re.fullmatch(r"/api/app/tokens/\d+", path):
            origin = self.headers.get("Origin")
            if origin and origin not in ALLOWED_ORIGINS:
                return False
            return True
        if "application/json" not in ct.lower():
            return False
        origin = self.headers.get("Origin")
        if origin and origin not in ALLOWED_ORIGINS:
            return False
        return True

    def _send(self, status, body, extra_headers=None, content_type="application/json"):
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _send_err(self, status, msg):
        self._send(status, {"error": msg})

    def _set_session_cookie(self, token):
        return ("Set-Cookie",
                "site_session=%s; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=%d"
                % (token, SESSION_MAX_AGE))

    def _clear_session_cookie(self):
        return ("Set-Cookie",
                "site_session=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0")

    # ---- 路由 ----

    def do_GET(self):
        self._route()

    def do_POST(self):
        self._route()

    def do_DELETE(self):
        self._route()

    def do_OPTIONS(self):
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        self._route(head=True)

    def _route(self, head=False):
        if not self._csrf_ok():
            self._send_err(403, "CSRF check failed")
            return
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        query = urllib.parse.parse_qs(parsed.query)

        # 公开
        if self.command == "POST" and path == "/api/login":
            self._handle_login()
            return
        if self.command == "POST" and path == "/api/register":
            data, err = self._read_json_body()
            if err:
                status, body = err
                self._send(status, body)
            else:
                status, body = multiuser.register(data, self._client_ip())
                self._send(status, body)
            return

        # ---- P1：移动端长效令牌 ----
        # 用 app token 换 session。此接口不需要 Cookie，必须在会话校验之前。
        if self.command == "POST" and path == "/api/app/session":
            self._handle_app_session()
            return

        # 会话校验（除 login 外全部要求会话）
        conn = db.connect()
        try:
            token = self._cookie_token()
            user = get_session_user(conn, token)
            if not user:
                if path == "/api/auth":
                    self._send_err(401, "Unauthorized")
                else:
                    self._send_err(401, "Unauthorized")
                return

            if path == "/api/auth":
                self._handle_auth(user, query)
                return
            if self.command == "POST" and path == "/api/logout":
                self._handle_logout(conn, token)
                return
            if self.command == "GET" and path == "/api/me":
                self._send(200, {"username": user["username"], "role": user["role"],
                                 "expires_at": user["expires_at"]})
                return
            if self.command == "GET" and path == "/api/me_full":
                status, body = multiuser.me_full(user["user_id"])
                self._send(status, body)
                return

            # ---- P1：app token 签发与设备管理（需已有会话） ----
            if self.command == "POST" and path == "/api/app/token":
                data, err = self._read_json_body()
                if err:
                    self._send(err[0], err[1])
                else:
                    status, body = app_tokens.issue(
                        user["user_id"],
                        data.get("device_name"),
                        data.get("platform"),
                        self._client_ip(),
                        self.headers.get("User-Agent", ""))
                    self._send(status, body)
                return
            if self.command == "GET" and path == "/api/app/tokens":
                status, body = app_tokens.list_tokens(user["user_id"])
                self._send(status, body)
                return
            m_tok = re.fullmatch(r"/api/app/tokens/(\d+)", path)
            if self.command == "DELETE" and m_tok:
                status, body = app_tokens.revoke(user["user_id"], int(m_tok.group(1)))
                self._send(status, body)
                return

            # ---- 多用户扩展 ----
            if self.command == "POST" and path == "/api/upload":
                self._handle_upload(user)
                return
            m_stat = re.fullmatch(r"/api/upload_status/([^/]+)", path)
            if self.command == "GET" and m_stat:
                status, body = multiuser.get_upload_status(
                    urllib.parse.unquote(m_stat.group(1)), user["user_id"])
                self._send(status, body)
                return
            if self.command == "GET" and path == "/api/my_videos":
                status, body = multiuser.my_videos(user["user_id"])
                self._send(status, body)
                return
            if self.command == "GET" and path == "/api/owners":
                status, body = multiuser.owners_map()
                self._send(status, body)
                return

            # 视频（普通用户）
            if self.command == "GET" and path == "/api/videos":
                self._handle_videos(query)
                return
            m = re.fullmatch(r"/api/videos/([^/]+)", path)
            if self.command == "GET" and m:
                v = videos_mod.get_video(urllib.parse.unquote(m.group(1)))
                if not v:
                    self._send_err(404, "video not found")
                else:
                    self._send(200, v)
                return
            if self.command == "GET" and path == "/videos.json":
                self._send(200, videos_mod.compat_json())
                return

            # 管理
            if path.startswith("/api/admin/"):
                if user["role"] != "admin":
                    self._send_err(403, "Forbidden")
                    return
                self._handle_admin(path, conn, user)
                return

            self._send_err(404, "Not Found")
        finally:
            conn.close()

    # ---- 处理器 ----

    def _handle_login(self):
        data, err = self._read_json_body()
        if err:
            status, body = err
            self._send(status, body)
            return
        username = (data.get("username") or "").strip()
        password = data.get("password") or ""
        ip = self._client_ip()
        ua = self.headers.get("User-Agent", "")

        mode = LEGACY_MODE
        conn = db.connect()
        try:
            if mode == "only":
                # 只走 legacy 老密码
                if not password:
                    self._send_err(401, "Password required")
                    return
                user = self._legacy_login(password)
                if not user:
                    _record_failure("legacy")
                    self._send_err(401, "Invalid password")
                    return
                _clear_failures("legacy")
            elif mode == "off":
                if not username:
                    self._send_err(401, "Username required")
                    return
                if _check_lock(username):
                    self._send_err(423, "Account locked")
                    return
                user = self._db_login(conn, username, password, ip)
                if not user:
                    _record_failure(username)
                    self._send_err(401, "Invalid credentials")
                    return
                _clear_failures(username)
            else:  # on（默认）
                if username:
                    if _check_lock(username):
                        self._send_err(423, "Account locked")
                        return
                    user = self._db_login(conn, username, password, ip)
                    if not user:
                        _record_failure(username)
                        self._send_err(401, "Invalid credentials")
                        return
                    _clear_failures(username)
                else:
                    if not password:
                        self._send_err(401, "Password required")
                        return
                    if _check_lock("legacy"):
                        self._send_err(423, "Account locked")
                        return
                    user = self._legacy_login(password)
                    if not user:
                        _record_failure("legacy")
                        self._send_err(401, "Invalid password")
                        return
                    _clear_failures("legacy")

            token = create_session(conn, user["id"], ip, ua)
            conn.execute("UPDATE users SET last_login_at=?, last_login_ip=? WHERE id=?",
                         (_now(), ip, user["id"]))
            now = _now()
            conn.execute(
                "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
                (now, user["id"], "user.login", str(user["id"]), "username=%s via=%s"
                 % (user["username"], "legacy" if not username else "db"), ip))
            conn.commit()
            self._send(200, {"ok": True, "username": user["username"], "role": user["role"]},
                       extra_headers={self._set_session_cookie(token)[0]: self._set_session_cookie(token)[1]})
        finally:
            conn.close()

    def _db_login(self, conn, username, password, ip):
        row = conn.execute("SELECT * FROM users WHERE username=? COLLATE NOCASE", (username,)).fetchone()
        if not row:
            return None
        if not auth.verify_password(password, row["password_hash"]):
            return None
        if row["status"] != "active":
            return None
        return {"id": row["id"], "username": row["username"], "role": row["role"]}

    def _legacy_login(self, password):
        """老单密码兜底：比对 SITE_PASSWORD（常量时间），成功绑定内置 admin 账号。"""
        if not SITE_PASSWORD:
            return None
        if not auth.constant_time_eq(password, SITE_PASSWORD):
            return None
        conn = db.connect()
        try:
            row = conn.execute(
                "SELECT id,username,role,status FROM users WHERE username='admin' "
                "AND role='admin' ORDER BY id LIMIT 1").fetchone()
            if not row:
                return None
            if row["status"] != "active":
                return None
            return {"id": row["id"], "username": row["username"], "role": row["role"]}
        finally:
            conn.close()

    def _handle_auth(self, user, query=None):
        # 供 nginx auth_request；支持 ?role=<role> 做角色级门禁（管理页用）
        if query:
            req_role = (query.get("role") or [None])[0]
            if req_role and user["role"] != req_role:
                self._send_err(403, "Forbidden")
                return
        headers = {"X-Auth-User": user["username"], "X-Auth-Role": user["role"]}
        self._send(200, {"ok": True, "user": user["username"], "role": user["role"]},
                   extra_headers=headers)

    def _handle_logout(self, conn, token):
        destroy_session(conn, token)
        self._send(200, {"ok": True}, extra_headers={self._clear_session_cookie()[0]: self._clear_session_cookie()[1]})

    def _handle_app_session(self):
        """POST /api/app/session — 用 app token 换一个普通 session Cookie。

        请求：{"token": "vap_xxx"}（也可放在 Authorization: Bearer 里）
        成功：200 + Set-Cookie: site_session=...，body 附 expires_at
        失败：401（无效/过期/账号被停用）
        """
        data, err = self._read_json_body()
        if err:
            self._send(err[0], err[1])
            return
        tok = (data.get("token") or "").strip()
        if not tok:
            authz = self.headers.get("Authorization", "")
            if authz.lower().startswith("bearer "):
                tok = authz[7:].strip()
        if not tok:
            self._send_err(400, "token required")
            return
        user, tok_id = app_tokens.resolve(tok)
        if not user:
            self._send_err(401, "invalid or expired token")
            return
        conn = db.connect()
        try:
            ip = self._client_ip()
            ua = self.headers.get("User-Agent", "")
            session_token = create_session(conn, user["user_id"], ip, ua)
            conn.execute("UPDATE users SET last_login_at=?, last_login_ip=? WHERE id=?",
                         (_now(), ip, user["user_id"]))
            conn.commit()
            ck = self._set_session_cookie(session_token)
            self._send(200, {"ok": True, "username": user["username"],
                             "role": user["role"],
                             "expires_at": _now() + SESSION_MAX_AGE,
                             "token_id": tok_id},
                       extra_headers={ck[0]: ck[1]})
        finally:
            conn.close()

    def _handle_videos(self, query):
        q = (query.get("q") or [None])[0]
        status = (query.get("status") or ["ready"])[0]
        if status not in ("ready", "hidden", "deleted", "broken"):
            status = "ready"
        try:
            page = int((query.get("page") or ["1"])[0])
            limit = int((query.get("limit") or ["100"])[0])
        except ValueError:
            page, limit = 1, 100
        page = max(1, page)
        limit = min(500, max(1, limit))
        total, items = videos_mod.list_videos(status=status, q=q, page=page, limit=limit)
        self._send(200, {"total": total, "items": items})

    def _handle_upload(self, user):
        """接收 multipart/form-data 上传的视频，转交 multiuser 后台转码。

        请求体：multipart，含 video(file)、title(text)。
        """
        import cgi
        import io
        import traceback
        try:
            return self._handle_upload_inner(user, cgi, io)
        except Exception:
            import io as _io
            buf = _io.StringIO()
            try:
                traceback.print_exc(file=buf)
            except Exception:
                pass
            self._send(500, {"error": "upload internal error", "detail": buf.getvalue()[-2000:]})
            return

    def _handle_upload_inner(self, user, cgi, io):
        ct = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in ct.lower():
            self._send_err(400, "must be multipart/form-data")
            return
        try:
            ctype, params = _parse_content_type(ct)
            boundary = params.get("boundary", "")
        except Exception:
            self._send_err(400, "bad Content-Type")
            return
        if not boundary:
            self._send_err(400, "missing boundary")
            return

        # 读取请求体（限制单个文件上限）
        cl = self.headers.get("Content-Length")
        try:
            length = int(cl) if cl else 0
        except ValueError:
            length = 0
        UPLOAD_MAX = int(os.environ.get("SITEAUTH_UPLOAD_MAX", "2147483648"))  # 默认 2GB
        if length <= 0 or length > UPLOAD_MAX + (16 << 20):
            self._send_err(413, "file too large or empty")
            return

        body = self.rfile.read(length)
        # cgi.FieldStorage 直接解析 multipart 字节流
        environ = {"REQUEST_METHOD": "POST", "CONTENT_TYPE": "multipart/form-data; boundary=" + boundary,
                   "CONTENT_LENGTH": str(len(body))}
        try:
            form = cgi.FieldStorage(
                fp=io.BytesIO(body),
                environ=environ,
                headers={"content-type": "multipart/form-data; boundary=" + boundary},
                keep_blank_values=True)
        except Exception:
            self._send_err(400, "bad request body")
            return

        video_item = None
        title = ""
        raw_video = form.getvalue("video") if hasattr(form, "getvalue") else None
        # cgi 对文件字段返回 FieldStorage，对缺失字段返回 None
        try:
            if "video" in form:
                video_item = form["video"]
        except Exception:
            video_item = None
        t_item = form.getvalue("title") if hasattr(form, "getvalue") else None
        if isinstance(t_item, str):
            title = t_item.strip()

        if video_item is None:
            self._send_err(400, "缺少 video 文件")
            return
        # 判断是否为真正的文件上传（含 filename）
        has_file = False
        if isinstance(video_item, (list, tuple)):
            video_item = video_item[0] if video_item else None
        if video_item is not None:
            try:
                has_file = bool(getattr(video_item, "filename", None))
            except Exception:
                has_file = False
        if not has_file:
            self._send_err(400, "缺少 video 文件")
            return
        filename = ""
        if hasattr(video_item, "filename"):
            filename = (video_item.filename or "").strip()
        if not filename:
            filename = "video.mp4"
        ext = os.path.splitext(filename)[1].lower()
        if ext not in multiuser.ALLOWED_VIDEO_EXT:
            self._send_err(400, "不支持的文件类型: %s" % (ext or "无扩展名"))
            return

        data = video_item.file.read() if hasattr(video_item, "file") and video_item.file else b""
        if not data:
            self._send_err(400, "视频文件为空")
            return

        # 存到临时目录，再交后台转码（避免占用请求线程）
        os.makedirs(multiuser.UPLOAD_TMP, exist_ok=True)
        tmp_path = os.path.join(multiuser.UPLOAD_TMP, "in_" + secrets.token_hex(8) + ext)
        with open(tmp_path, "wb") as f:
            f.write(data)

        status, body = multiuser.start_upload(user["user_id"], filename, title, tmp_path,
                                              self._client_ip())
        self._send(status, body)

    def _handle_admin(self, path, conn, user):
        actor_id = user["user_id"]
        ip = self._client_ip()
        method = self.command

        if method == "GET" and path == "/api/admin/users":
            status, body = admin_mod.users_list()
        elif method == "GET" and path == "/api/admin/pending":
            status, body = multiuser.pending_registrations()
        elif method == "POST" and path == "/api/admin/users":
            data, err = self._read_json_body()
            if err:
                status, body = err
            else:
                status, body = admin_mod.user_create(data, actor_id, ip)
        elif method == "POST" and re.fullmatch(r"/api/admin/users/(\d+)/password", path):
            data, err = self._read_json_body()
            if err:
                status, body = err
            else:
                status, body = admin_mod.user_password(re.fullmatch(r"/api/admin/users/(\d+)/password", path).group(1),
                                                       data, actor_id, ip)
        elif method == "POST" and re.fullmatch(r"/api/admin/users/(\d+)/status", path):
            data, err = self._read_json_body()
            if err:
                status, body = err
            else:
                status, body = admin_mod.user_status(re.fullmatch(r"/api/admin/users/(\d+)/status", path).group(1),
                                                     data, actor_id, ip)
        elif method == "DELETE" and re.fullmatch(r"/api/admin/users/(\d+)", path):
            status, body = admin_mod.user_delete(re.fullmatch(r"/api/admin/users/(\d+)", path).group(1),
                                                 actor_id, ip)
        elif method == "GET" and path == "/api/admin/videos":
            status, body = admin_mod.videos_list()
        elif method == "POST" and path == "/api/admin/videos":
            data, err = self._read_json_body()
            if err:
                status, body = err
            else:
                status, body = admin_mod.video_upsert(data, actor_id, ip)
        elif method == "POST" and re.fullmatch(r"/api/admin/videos/([^/]+)/delete", path):
            status, body = admin_mod.video_delete(urllib.parse.unquote(
                re.fullmatch(r"/api/admin/videos/([^/]+)/delete", path).group(1)), actor_id, ip)
        elif method == "POST" and re.fullmatch(r"/api/admin/videos/([^/]+)/restore", path):
            status, body = admin_mod.video_restore(urllib.parse.unquote(
                re.fullmatch(r"/api/admin/videos/([^/]+)/restore", path).group(1)), actor_id, ip)
        elif method == "POST" and re.fullmatch(r"/api/admin/videos/([^/]+)/purge", path):
            status, body = admin_mod.video_purge(urllib.parse.unquote(
                re.fullmatch(r"/api/admin/videos/([^/]+)/purge", path).group(1)), actor_id, ip)
        elif method == "GET" and path == "/api/admin/audit":
            status, body = admin_mod.audit_list()
        elif method == "GET" and path == "/api/admin/health":
            status, body = admin_mod.health()
        else:
            status, body = 404, {"error": "Not Found"}
        self._send(status, body)


# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------

def main():
    db.init_db()
    cleanup_sessions()
    # 每 10 分钟清一次过期会话
    def _loop():
        while True:
            time.sleep(600)
            cleanup_sessions()
    threading.Thread(target=_loop, daemon=True).start()

    server = http.server.ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), SiteAuthHandler)
    server.daemon_threads = True
    globals()["server"] = server  # 便于测试/运维脚本关闭
    print("[siteauth] Listening on %s:%d (legacy_mode=%s)" % (LISTEN_HOST, LISTEN_PORT, LEGACY_MODE),
          flush=True)
    if not SITE_PASSWORD and LEGACY_MODE != "off":
        print("[siteauth] WARNING: SITE_PASSWORD not set; legacy login disabled", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[siteauth] Shutting down.", flush=True)
        server.server_close()


if __name__ == "__main__":
    main()
