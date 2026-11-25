# -*- coding: utf-8 -*-
"""multiuser.py — 多用户扩展模块（注册审核 / 视频归属 / 上传转码 / 进度查询）。

设计目标：
- 与 siteauth_server.py 解耦：本模块只提供 pure 函数 (status, body) 与新接口分发。
- 注册走审核：新用户 status='pending'，管理员审核通过(active)后才能登录。
- 上传：普通用户 POST /api/upload（multipart，video 文件）→ 后台线程 ffmpeg 转 HLS →
  进度写入 upload_jobs 表；GET /api/upload_status/<id> 返回进度与预计完成时间。
- 视频归属：videos.owner_id 标记上传者；GET /api/my_videos 返回当前用户上传的视频。

纯标准库，零第三方依赖（沿用现有系统风格）。
"""
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import time
import uuid

import db

WEBROOT = os.environ.get("SITEAUTH_WEBROOT", "/var/www/html")
BACKUP_ROOT = os.environ.get("SITEAUTH_BACKUP_ROOT", "/root/site-backups")

USERNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{3,32}$")
ALLOWED_VIDEO_EXT = {".mp4", ".mov", ".mkv", ".avi", ".webm", ".flv", ".ts", ".m2ts", ".m4v"}

# 单任务并发上限：避免同时多个 ffmpeg 拖垮服务器
MAX_CONCURRENT_JOBS = 1
_jobs_lock = threading.Lock()
_running_jobs = 0

# 封面图：默认在转码完成后用 ffmpeg 抽帧；若失败则留空
UPLOAD_TMP = os.environ.get("SITEAUTH_UPLOAD_TMP", "/var/www/html/videos/.upload_tmp")


def _connect():
    return db.connect()


# ---------------------------------------------------------------------------
# 注册（审核制）
# ---------------------------------------------------------------------------

def register(body, ip):
    """公开注册：status='pending'，等待管理员审核。返回 (status, body)。"""
    if os.environ.get("SITEAUTH_ALLOW_REGISTER", "1").strip() != "1":
        return 403, {"error": "registration closed"}
    username = (body.get("username") or "").strip()
    password = body.get("password") or ""
    nickname = (body.get("nickname") or "").strip() or username

    if not USERNAME_RE.match(username):
        return 400, {"error": "username 需为 3-32 位字母/数字/下划线/点/横线"}
    if not password:
        return 400, {"error": "password required"}
    if len(password) > 256:
        return 400, {"error": "password too long"}
    if len(nickname) > 64:
        return 400, {"error": "nickname too long"}

    import auth
    conn = _connect()
    try:
        exists = conn.execute("SELECT 1 FROM users WHERE username=? COLLATE NOCASE",
                              (username,)).fetchone()
        if exists:
            return 409, {"error": "username already exists"}
        now = int(time.time())
        cur = conn.execute(
            "INSERT INTO users(username,nickname,password_hash,role,status,created_at) VALUES(?,?,?,?,?,?)",
            (username, nickname, auth.hash_password(password), "user", "pending", now))
        uid = cur.lastrowid
        conn.execute(
            "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
            (now, None, "user.register", str(uid), "username=%s nickname=%s" % (username, nickname), ip))
        conn.commit()
        return 200, {"ok": True, "id": uid, "username": username, "status": "pending",
                     "message": "注册成功，账号待管理员审核后即可登录"}
    except sqlite3.IntegrityError:
        return 409, {"error": "username already exists"}
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 上传转码
# ---------------------------------------------------------------------------

def _next_job_dir():
    for _ in range(20):
        vid = uuid.uuid4().hex[:8]
        p = os.path.join(WEBROOT, "videos", vid)
        if not os.path.exists(p):
            return vid
    raise RuntimeError("cannot allocate video id")


def start_upload(user_id, filename, title, save_path, ip):
    """创建任务并启动后台转码线程（不阻塞请求）。"""
    import auth  # noqa
    vid = None
    try:
        vid = _next_job_dir()
    except RuntimeError as e:
        return 500, {"error": str(e)}

    job_id = vid
    total = _probe_duration(save_path)  # 可能为 None
    now = int(time.time())
    prog_file = os.path.join(UPLOAD_TMP, job_id + ".prog")
    conn = _connect()
    try:
        conn.execute(
            "INSERT INTO upload_jobs(id,user_id,filename,title,status,progress_file,"
            "total_seconds,created_at) VALUES(?,?,?,?,?,?,?,?)",
            (job_id, user_id, filename, title, "queued", prog_file, total, now))
        conn.commit()
    finally:
        conn.close()

    threading.Thread(target=_run_job, args=(job_id, user_id, title, save_path, ip),
                     daemon=True).start()
    return 202, {"ok": True, "job_id": job_id, "status": "queued",
                 "message": "上传成功，已进入转码队列，请稍候查看进度"}


def _probe_duration(path):
    """用 ffprobe 取时长（秒）。失败返回 None。"""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=30)
        v = out.stdout.strip()
        if not v:
            return None
        return float(v)
    except Exception:
        return None


def _run_job(job_id, user_id, title, src_path, ip):
    global _running_jobs
    # 限定并发
    with _jobs_lock:
        while _running_jobs >= MAX_CONCURRENT_JOBS:
            _jobs_lock.release()
            time.sleep(2)
            _jobs_lock.acquire()
        _running_jobs += 1
    conn = _connect()
    try:
        conn.execute("UPDATE upload_jobs SET status='running', started_at=? WHERE id=?",
                     (int(time.time()), job_id))
        conn.commit()
    finally:
        conn.close()

    dest_dir = os.path.join(WEBROOT, "videos", job_id)
    os.makedirs(dest_dir, exist_ok=True)
    prog_file = os.path.join(UPLOAD_TMP, job_id + ".prog")
    log_file = os.path.join(UPLOAD_TMP, job_id + ".log")
    ffprog = os.path.join(UPLOAD_TMP, job_id + ".ffprog")
    ok = False
    error = ""
    try:
        ok, error = _transcode(src_path, dest_dir, prog_file, ffprog, log_file)
        if ok:
            _finalize(job_id, title, dest_dir, user_id, ip)
    except Exception as e:
        error = str(e)
    finally:
        with _jobs_lock:
            _running_jobs -= 1

    conn = _connect()
    try:
        if ok:
            conn.execute("UPDATE upload_jobs SET status='done', finished_at=? WHERE id=?",
                         (int(time.time()), job_id))
        else:
            conn.execute("UPDATE upload_jobs SET status='failed', finished_at=?, error=? "
                         "WHERE id=?", (int(time.time()), (error or "unknown")[:500], job_id))
        conn.commit()
    finally:
        conn.close()
    # 清理临时文件
    for p in (src_path, prog_file, ffprog, log_file + ".transcode"):
        try:
            if os.path.isfile(p):
                os.remove(p)
        except Exception:
            pass
    if not ok:
        try:
            shutil.rmtree(dest_dir, ignore_errors=True)
        except Exception:
            pass


def _transcode(src_path, dest_dir, prog_file, ffprog, log_file):
    """用 ffmpeg 转 HLS（AES-128 加密，与现有视频一致）。返回 (ok, error)。"""
    import base64
    try:
        # 1) 生成 16 字节 AES key
        key = os.urandom(16)
        key_path = os.path.join(dest_dir, "video.key")
        with open(key_path, "wb") as f:
            f.write(key)

        scheme = "https://51play.ccwu.cc"  # 兼容：key URI 用已配置域名
        dom = os.environ.get("SITEAUTH_PUBLIC", "https://51play.ccwu.cc")
        if dom:
            scheme = dom.rstrip("/")
        key_info = os.path.join(dest_dir, "key.info")
        with open(key_info, "w") as f:
            # ffmpeg key_info_file：第1行URI、第2行key文件路径、第3行IV(hex,空=自动)
            #
            # ⚠️ URI 必须写**相对路径** `/key/<id>`，不要写绝对 URL。
            # 历史视频全部是相对路径，客户端（Android App 的 MediaProxy）
            # 依赖这一点把 key 请求重写到本机代理，从而绕过网络对
            # `SNI=*.ccwu.cc` 的 TLS 阻断（详见 App docs/P5_ACCEPTANCE.md）。
            # 写成绝对 URL 会让播放器直连 51play.ccwu.cc 并被阻断 → 黑屏。
            f.write("/key/%s\n" % os.path.basename(dest_dir))
            f.write(key_path + "\n")
            f.write("00000000000000000000000000000000\n")

        # 2) key/ 符号链接（与现有结构一致），供 nginx /key/ 鉴权读取
        key_link = os.path.join(WEBROOT, "key", os.path.basename(dest_dir))
        if not os.path.lexists(key_link):
            try:
                os.symlink(key_path, key_link)
            except Exception:
                pass

        # 3) ffmpeg 转 HLS
        out_m3u8 = os.path.join(dest_dir, "output.m3u8")
        cmd = [
            "ffmpeg", "-y", "-i", src_path,
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
            "-c:a", "aac", "-b:a", "128k",
            "-hls_time", "2", "-hls_list_size", "0",
            "-hls_key_info_file", key_info,
            "-hls_segment_filename", os.path.join(dest_dir, "output_%03d.ts"),
            "-progress", ffprog, "-nostats",
            out_m3u8,
        ]
        with open(log_file + ".transcode", "w") as lf:
            rc = subprocess.run(cmd, stdout=lf, stderr=lf, timeout=3600).returncode
        if rc != 0:
            return False, "ffmpeg 转码失败(rc=%d)，详见日志" % rc
        # 校验产物
        if not (os.path.isfile(out_m3u8) and os.path.getsize(out_m3u8) > 0):
            return False, "转码产物缺失"
        # 4) 抽取封面
        cover_jpg = os.path.join(dest_dir, "cover.jpg")
        try:
            subprocess.run(
                ["ffmpeg", "-y", "-i", src_path, "-ss", "1", "-frames:v", "1",
                 "-q:v", "3", cover_jpg],
                capture_output=True, timeout=60)
        except Exception:
            pass
        # 5) 同步封面到 covers/<id>.jpg
        if os.path.isfile(cover_jpg):
            try:
                covers = os.path.join(WEBROOT, "covers")
                os.makedirs(covers, exist_ok=True)
                shutil.copy(cover_jpg, os.path.join(covers, os.path.basename(dest_dir) + ".jpg"))
            except Exception:
                pass
        # 6) 重新探测时长（转码后）
        return True, ""
    except Exception as e:
        return False, str(e)


def _finalize(job_id, title, dest_dir, user_id, ip):
    """转码成功后写入 videos 表。"""
    vid = os.path.basename(dest_dir)
    now = int(time.time())
    # 时长：优先用原始源时长（upload_jobs.total_seconds），避免 ffprobe 读 https key 的 m3u8 失败
    duration = None
    conn = _connect()
    try:
        r = conn.execute("SELECT total_seconds FROM upload_jobs WHERE id=?", (job_id,)).fetchone()
        if r and r["total_seconds"]:
            duration = r["total_seconds"]
    finally:
        conn.close()
    if not duration:
        duration = _probe_duration(os.path.join(dest_dir, "output.m3u8"))
    name = title.strip() or vid
    cover = "/covers/%s.jpg" % vid
    size = 0
    for root, _, files in os.walk(dest_dir):
        for fn in files:
            try:
                size += os.path.getsize(os.path.join(root, fn))
            except Exception:
                pass
    conn = _connect()
    try:
        conn.execute(
            "INSERT INTO videos(id,name,date,cover,description,duration,size_bytes,status,"
            "sort_pin,views,created_at,updated_at,owner_id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (vid, name, time.strftime("%Y-%m-%dT%H:%M:%S"), cover, "", duration, size,
             "ready", 0, 0, now, now, user_id))
        conn.execute("UPDATE upload_jobs SET result_id=? WHERE id=?", (vid, job_id))
        conn.execute(
            "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
            (now, user_id, "video.upload", vid, "name=%s size=%d" % (name, size), ip))
        conn.commit()
    finally:
        conn.close()


def get_upload_status(job_id, user_id):
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT id,user_id,status,progress_file,total_seconds,started_at,created_at,error,result_id "
            "FROM upload_jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            return 404, {"error": "job not found"}
        # 权限：仅本人或 admin
        if row["user_id"] != user_id:
            import auth  # noqa
            u = conn.execute("SELECT role FROM users WHERE id=?", (user_id,)).fetchone()
            if not u or u["role"] != "admin":
                return 403, {"error": "forbidden"}
        d = dict(row)
        progress = _read_progress(d.get("progress_file"))
        percent, eta, cur_sec, tot_sec = _compute_progress(progress, d.get("total_seconds"),
                                                          d.get("started_at"))
        resp = {
            "id": d["id"],
            "status": d["status"],
            "percent": percent,
            "eta_seconds": eta,
            "current_seconds": cur_sec,
            "total_seconds": tot_sec,
            "error": d.get("error"),
            "result_id": d.get("result_id"),
        }
        return 200, resp
    finally:
        conn.close()


def _read_progress(prog_file):
    """读 ffmpeg -progress 输出：最后出现的 out_time_us / out_time_ms。"""
    if not prog_file or not os.path.isfile(prog_file):
        return None
    out_us = None
    try:
        with open(prog_file, "r", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if line.startswith("out_time_us="):
                    try:
                        out_us = float(line.split("=", 1)[1])
                    except ValueError:
                        pass
    except Exception:
        return None
    return out_us


def _compute_progress(out_us, total_seconds, started_at):
    """返回 (percent, eta_seconds, current_seconds, total_seconds)。"""
    now = time.time()
    cur = (out_us / 1e6) if out_us is not None else 0.0
    total = total_seconds if total_seconds and total_seconds > 0 else None
    percent = None
    if total:
        percent = max(0.0, min(100.0, cur / total * 100.0))
    eta = None
    if total and cur > 0:
        speed = cur / max(0.1, (now - (started_at or now)))
        if speed > 0:
            eta = max(0, int((total - cur) / speed))
    return percent, eta, cur, total


def my_videos(user_id):
    conn = _connect()
    try:
        rows = conn.execute(
            "SELECT id,name,date,cover,duration,size_bytes,status,views,created_at "
            "FROM videos WHERE owner_id=? AND status='ready' ORDER BY created_at DESC, id",
            (user_id,)).fetchall()
        return 200, {"total": len(rows), "items": [dict(r) for r in rows]}
    finally:
        conn.close()


def me_full(user_id):
    """返回当前用户的完整信息（含 id、昵称）。"""
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT id,username,nickname,role,status FROM users WHERE id=?", (user_id,)).fetchone()
        if not row:
            return 404, {"error": "user not found"}
        return 200, {"data": dict(row)}
    finally:
        conn.close()


def owners_map():
    """返回所有 ready 视频上传者的 id->昵称 映射（供首页展示上传者）。"""
    conn = _connect()
    try:
        rows = conn.execute(
            "SELECT v.owner_id AS oid, COALESCE(NULLIF(u.nickname,''), u.username) AS name "
            "FROM videos v LEFT JOIN users u ON u.id=v.owner_id WHERE v.status='ready' "
            "GROUP BY v.owner_id").fetchall()
        m = {}
        for r in rows:
            if r["oid"] is None:
                continue
            m[r["oid"]] = r["name"] or "匿名用户"
        return 200, m
    finally:
        conn.close()


def pending_registrations():
    """待审核用户列表（供管理后台）。"""
    conn = _connect()
    try:
        rows = conn.execute(
            "SELECT id,username,created_at FROM users WHERE status='pending' "
            "ORDER BY created_at DESC").fetchall()
        return 200, {"total": len(rows), "items": [dict(r) for r in rows]}
    finally:
        conn.close()
