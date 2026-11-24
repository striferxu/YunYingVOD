# -*- coding: utf-8 -*-
"""admin.py — 管理 API（用户、视频、审计、健康）。纯标准库。

所有函数返回 (status, dict_body) 或 (status, dict_body, headers)。
调用方（siteauth_server.py）负责鉴权 role=='admin'。
"""
import json
import os
import re
import shutil
import time

import db
import auth
import videos as videos_mod
import healthchecks

USERNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{3,32}$")
WEBROOT = os.environ.get("SITEAUTH_WEBROOT", "/var/www/html")
BACKUP_ROOT = os.environ.get("SITEAUTH_BACKUP_ROOT", "/root/site-backups")
DELETED_ROOT = os.path.join(BACKUP_ROOT, "deleted")


# ---------------------------------------------------------------------------
# 用户管理
# ---------------------------------------------------------------------------

def users_list():
    conn = db.connect()
    try:
        rows = conn.execute(
            "SELECT id,username,role,status,created_at,last_login_at,last_login_ip "
            "FROM users ORDER BY id").fetchall()
        return 200, [dict(r) for r in rows]
    finally:
        conn.close()


def user_create(body, actor_id, ip):
    username = (body.get("username") or "").strip()
    password = body.get("password") or ""
    role = body.get("role") or "user"
    if not USERNAME_RE.match(username):
        return 400, {"error": "username must match ^[A-Za-z0-9_.-]{3,32}$"}
    if not password:
        return 400, {"error": "password required"}
    if len(password) > 256:
        return 400, {"error": "password too long"}
    if role not in ("admin", "user"):
        return 400, {"error": "role must be admin or user"}
    conn = db.connect()
    try:
        exists = conn.execute("SELECT 1 FROM users WHERE username=? COLLATE NOCASE",
                              (username,)).fetchone()
        if exists:
            return 409, {"error": "username already exists"}
        now = int(time.time())
        cur = conn.execute(
            "INSERT INTO users(username,password_hash,role,created_at) VALUES(?,?,?,?)",
            (username, auth.hash_password(password), role, now))
        uid = cur.lastrowid
        conn.execute(
            "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
            (now, actor_id, "user.create", str(uid), "username=%s role=%s" % (username, role), ip))
        conn.commit()
        return 200, {"ok": True, "id": uid, "username": username, "role": role}
    finally:
        conn.close()


def user_password(vid, body, actor_id, ip):
    password = body.get("password") or ""
    if not password:
        return 400, {"error": "password required"}
    if len(password) > 256:
        return 400, {"error": "password too long"}
    conn = db.connect()
    try:
        row = conn.execute("SELECT id,username FROM users WHERE id=?", (vid,)).fetchone()
        if not row:
            return 404, {"error": "user not found"}
        now = int(time.time())
        conn.execute("UPDATE users SET password_hash=? WHERE id=?", (auth.hash_password(password), vid))
        # 改密后踢掉该用户全部会话
        conn.execute("DELETE FROM sessions WHERE user_id=?", (vid,))
        conn.execute(
            "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
            (now, actor_id, "user.password", str(vid), "username=%s" % row["username"], ip))
        conn.commit()
        return 200, {"ok": True}
    finally:
        conn.close()


def user_status(vid, body, actor_id, ip):
    status = body.get("status")
    if status not in ("active", "disabled"):
        return 400, {"error": "status must be active or disabled"}
    conn = db.connect()
    try:
        row = conn.execute("SELECT id,username,role,status FROM users WHERE id=?", (vid,)).fetchone()
        if not row:
            return 404, {"error": "user not found"}
        if row["role"] == "admin" and status == "disabled":
            admins = conn.execute("SELECT COUNT(*) AS c FROM users WHERE role='admin' AND status='active'"
                                  ).fetchone()["c"]
            if admins <= 1 and row["status"] == "active":
                return 400, {"error": "cannot disable the last active admin"}
        now = int(time.time())
        conn.execute("UPDATE users SET status=? WHERE id=?", (status, vid))
        if status == "disabled":
            conn.execute("DELETE FROM sessions WHERE user_id=?", (vid,))
        conn.execute(
            "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
            (now, actor_id, "user.status", str(vid),
             "username=%s -> %s" % (row["username"], status), ip))
        conn.commit()
        return 200, {"ok": True}
    finally:
        conn.close()


def user_delete(vid, actor_id, ip):
    vid = int(vid)
    conn = db.connect()
    try:
        row = conn.execute("SELECT id,username,role FROM users WHERE id=?", (vid,)).fetchone()
        if not row:
            return 404, {"error": "user not found"}
        if vid == actor_id:
            return 400, {"error": "cannot delete yourself"}
        if row["role"] == "admin":
            admins = conn.execute("SELECT COUNT(*) AS c FROM users WHERE role='admin'").fetchone()["c"]
            if admins <= 1:
                return 400, {"error": "cannot delete the last admin"}
        now = int(time.time())
        conn.execute("DELETE FROM sessions WHERE user_id=?", (vid,))
        conn.execute("DELETE FROM users WHERE id=?", (vid,))
        conn.execute(
            "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
            (now, actor_id, "user.delete", str(vid), "username=%s" % row["username"], ip))
        conn.commit()
        return 200, {"ok": True}
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 视频管理
# ---------------------------------------------------------------------------

def videos_list():
    conn = db.connect()
    try:
        rows = conn.execute(
            "SELECT id,name,date,cover,description,duration,size_bytes,status,sort_pin,views,"
            "created_at,updated_at,deleted_at FROM videos ORDER BY sort_pin DESC, date DESC, id"
        ).fetchall()
        out = []
        for r in rows:
            d = dict(r)
            d["disk_ok"] = _disk_present(d["id"])
            out.append(d)
        return 200, {"total": len(out), "items": out}
    finally:
        conn.close()


def _disk_present(vid):
    return (os.path.isdir(os.path.join(WEBROOT, "videos", vid))
            and os.path.isfile(os.path.join(WEBROOT, "videos", vid, "output.m3u8")))


def video_upsert(body, actor_id, ip):
    """新建或**部分更新**一条视频（管理后台的 编辑 / 置顶 / 新增-更新 都走这里）。

    部分更新语义（本函数的唯一正确语义）：请求体里没有给的字段，一律保留数据库中的原值。
    历史 bug：admin.js 的编辑与置顶请求体只有 {id,name,date,status[,sort_pin]}，不含 cover；
    旧实现把缺失的 cover 当成空串写库，于是"只改个名字"就把封面冲掉、缩略图消失。
    同源问题：sort_pin 缺失时也不能归零，否则编辑会顺手取消置顶。
    """
    vid = (body.get("id") or "").strip()
    existing = None
    if vid:
        conn = db.connect()
        try:
            row = conn.execute(
                "SELECT name,date,cover,status,sort_pin FROM videos WHERE id=?",
                (vid,)).fetchone()
            existing = dict(row) if row else None
        finally:
            conn.close()
        # 已软删除的记录：磁盘文件已移入备份目录，只改库会让列表冒出点不开的视频
        if existing and existing["status"] == "deleted":
            return 409, {"error": "video is deleted; restore it first"}
    else:
        import uuid
        vid = uuid.uuid4().hex[:8]

    ex = existing or {}

    def _has(key):
        """请求体里是否真的给了这个字段（None 与空串都视为未提供）。"""
        v = body.get(key)
        return v is not None and str(v).strip() != ""

    name = (body.get("name") or "").strip() or (ex.get("name") or "")
    if not name:
        return 400, {"error": "name required"}
    date = ((body.get("date") or "").strip() or (ex.get("date") or "")
            or time.strftime("%Y-%m-%dT%H:%M:%S"))
    cover = (body.get("cover") or "").strip() or (ex.get("cover") or "")
    status = (body.get("status") or "").strip() or (ex.get("status") or "ready")
    if status == "deleted":
        # 删除必须走 /delete：它会一并把 videos/ key/ covers/ 归档，只改库会留下孤儿文件
        return 400, {"error": "use /api/admin/videos/<id>/delete to delete"}
    if status not in ("ready", "hidden", "broken"):
        return 400, {"error": "invalid status"}
    if _has("sort_pin"):
        try:
            sort_pin = int(body["sort_pin"])
        except (TypeError, ValueError):
            return 400, {"error": "invalid sort_pin"}
    else:
        sort_pin = int(ex.get("sort_pin") or 0)

    entry = {
        "id": vid,
        "name": name,
        "date": date,
        "cover": cover,
        "status": status,
        "sort_pin": sort_pin,
    }
    try:
        res = videos_mod.upsert(entry, fix_status_ready=False)
    except ValueError as e:
        return 400, {"error": str(e)}
    now = int(time.time())
    conn = db.connect()
    try:
        conn.execute(
            "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
            (now, actor_id, "video.upsert", vid,
             "name=%s status=%s pin=%s cover=%s" % (
                 name[:80], status, sort_pin, (cover or "-")[:60]), ip))
        conn.commit()
    finally:
        conn.close()
    return 200, {"ok": True, "id": vid, "total": res["total"]}


def video_delete(vid, actor_id, ip):
    conn = db.connect()
    try:
        row = conn.execute("SELECT id,name,status FROM videos WHERE id=?", (vid,)).fetchone()
        if not row:
            return 404, {"error": "video not found"}
        if row["status"] == "deleted":
            return 400, {"error": "already deleted"}
        now = int(time.time())
        ts = time.strftime("%Y%m%d-%H%M%S")
        dest = os.path.join(DELETED_ROOT, "%s_%s" % (ts, vid))
        # 备份结构（避免 videos/<id> 与 key/<id> 同名冲突）：
        #   dest/videos/       <- videos/<id>/ 整个目录
        #   dest/key_<id>      <- key/<id> 符号链接或文件
        #   dest/cover_<id>.jpg<- covers/<id>.jpg
        os.makedirs(dest, exist_ok=True)
        moved = []
        src_dir = os.path.join(WEBROOT, "videos", vid)
        if os.path.isdir(src_dir):
            shutil.move(src_dir, os.path.join(dest, "videos"))
            moved.append("videos/%s" % vid)
        src_key = os.path.join(WEBROOT, "key", vid)
        if os.path.lexists(src_key):
            shutil.move(src_key, os.path.join(dest, "key_%s" % vid))
            moved.append("key/%s" % vid)
        src_cover = os.path.join(WEBROOT, "covers", vid + ".jpg")
        if os.path.lexists(src_cover):
            shutil.move(src_cover, os.path.join(dest, "cover_%s.jpg" % vid))
            moved.append("covers/%s.jpg" % vid)
        conn.execute("UPDATE videos SET status='deleted', deleted_at=?, updated_at=? WHERE id=?",
                     (now, now, vid))
        conn.execute(
            "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
            (now, actor_id, "video.delete", vid,
             "backup=%s moved=%s" % (dest, ",".join(moved)), ip))
        conn.commit()
        return 200, {"ok": True, "backup": dest}
    finally:
        conn.close()


def video_restore(vid, actor_id, ip):
    conn = db.connect()
    try:
        row = conn.execute("SELECT id,name,status FROM videos WHERE id=?", (vid,)).fetchone()
        if not row:
            return 404, {"error": "video not found"}
        now = int(time.time())
        # 找到最近一次删除时的备份目录
        audit = conn.execute(
            "SELECT detail FROM audit_log WHERE action='video.delete' AND target=? "
            "ORDER BY ts DESC LIMIT 1", (vid,)).fetchone()
        backup = None
        if audit and audit["detail"]:
            try:
                detail = audit["detail"]
                if detail.startswith("backup="):
                    backup = detail.split(" moved=")[0][len("backup="):]
                else:
                    backup = detail
            except Exception:
                backup = None
        restored = []
        if backup and os.path.isdir(backup):
            # dest/videos/ -> webroot/videos/<id>/
            src_dir = os.path.join(backup, "videos")
            if os.path.isdir(src_dir):
                dst = os.path.join(WEBROOT, "videos", vid)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                if os.path.lexists(dst):
                    shutil.move(dst, dst + ".dup-%d" % now)
                shutil.move(src_dir, dst)
                restored.append("videos/%s" % vid)
            # dest/key_<id> -> webroot/key/<id>
            src_key = os.path.join(backup, "key_%s" % vid)
            if os.path.lexists(src_key):
                dst = os.path.join(WEBROOT, "key", vid)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                if os.path.lexists(dst):
                    os.remove(dst)
                shutil.move(src_key, dst)
                restored.append("key/%s" % vid)
            # dest/cover_<id>.jpg -> webroot/covers/<id>.jpg
            src_cover = os.path.join(backup, "cover_%s.jpg" % vid)
            if os.path.lexists(src_cover):
                dst = os.path.join(WEBROOT, "covers", vid + ".jpg")
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                if os.path.lexists(dst):
                    os.remove(dst)
                shutil.move(src_cover, dst)
                restored.append("covers/%s.jpg" % vid)
        conn.execute("UPDATE videos SET status='ready', deleted_at=NULL, updated_at=? WHERE id=?",
                     (now, vid))
        conn.execute(
            "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
            (now, actor_id, "video.restore", vid,
             "restored=%s" % (",".join(restored) or "none"), ip))
        conn.commit()
        return 200, {"ok": True, "restored": restored}
    finally:
        conn.close()


def video_purge(vid, actor_id, ip):
    """彻底删除：仅对 status='deleted' 的视频执行。删 DB 记录 + 删除备份目录。"""
    conn = db.connect()
    try:
        row = conn.execute("SELECT id,name,status FROM videos WHERE id=?", (vid,)).fetchone()
        if not row:
            return 404, {"error": "video not found"}
        if row["status"] != "deleted":
            return 400, {"error": "only deleted videos can be purged; use delete first"}
        now = int(time.time())
        audit = conn.execute(
            "SELECT detail FROM audit_log WHERE action='video.delete' AND target=? "
            "ORDER BY ts DESC LIMIT 1", (vid,)).fetchone()
        backup = None
        if audit and audit["detail"]:
            try:
                detail = audit["detail"]
                if detail.startswith("backup="):
                    backup = detail.split(" moved=")[0][len("backup="):]
            except Exception:
                backup = None
        removed = []
        if backup and os.path.isdir(backup):
            shutil.rmtree(backup, ignore_errors=True)
            removed.append(backup)
        for p in [os.path.join(WEBROOT, "videos", vid),
                  os.path.join(WEBROOT, "key", vid),
                  os.path.join(WEBROOT, "covers", vid + ".jpg")]:
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
                removed.append(p)
            elif os.path.lexists(p):
                os.remove(p)
                removed.append(p)
        conn.execute("DELETE FROM videos WHERE id=?", (vid,))
        conn.execute(
            "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
            (now, actor_id, "video.purge", vid,
             "name=%s removed=%s" % (row["name"], ",".join(removed) or "none"), ip))
        conn.commit()
        return 200, {"ok": True, "removed": removed}
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 审计 / 健康
# ---------------------------------------------------------------------------

def audit_list():
    conn = db.connect()
    try:
        rows = conn.execute(
            "SELECT id,ts,user_id,action,target,detail,ip FROM audit_log "
            "ORDER BY id DESC LIMIT 50").fetchall()
        return 200, [dict(r) for r in rows]
    finally:
        conn.close()


def health():
    results = healthchecks.check_a() + healthchecks.check_b()
    ok = sum(1 for _, o, _ in results if o)
    return 200, {
        "ok": ok == len(results),
        "passed": ok,
        "total": len(results),
        "checks": [{"name": n, "ok": o, "detail": d} for n, o, d in results],
    }
