# -*- coding: utf-8 -*-
"""videos.py — 视频列表/详情/兼容层序列化（v2）。纯标准库。

单一真相：SQLite videos 表。videos.json 兼容层只做动态输出。
"""
import time

import db

VALID_STATUS = ("ready", "hidden", "deleted", "broken")


def list_videos(status="ready", q=None, page=None, limit=None):
    """普通用户列表。status 为 None 表示不过滤。返回 (total, items)。"""
    conn = db.connect()
    try:
        where = ["1=1"]
        params = []
        if status:
            where.append("status = ?")
            params.append(status)
        if q:
            where.append("name LIKE ? COLLATE NOCASE")
            params.append("%" + q + "%")
        w = " AND ".join(where)
        total = conn.execute("SELECT COUNT(*) AS c FROM videos WHERE " + w, params).fetchone()["c"]
        sql = ("SELECT id,name,date,cover,duration,size_bytes,status,sort_pin,views,owner_id,created_at "
               "FROM videos WHERE " + w + " ORDER BY sort_pin DESC, date DESC, id")
        if limit:
            offset = ((page or 1) - 1) * limit
            sql += " LIMIT ? OFFSET ?"
            params = params + [limit, offset]
        rows = conn.execute(sql, params).fetchall()
        return total, [dict(r) for r in rows]
    finally:
        conn.close()


def get_video(vid, allow_status=("ready",)):
    """单条。默认只返回 ready。返回 dict 或 None。"""
    conn = db.connect()
    try:
        row = conn.execute(
            "SELECT id,name,date,cover,description,duration,size_bytes,status,sort_pin,views,created_at,updated_at "
            "FROM videos WHERE id=?", (vid,)).fetchone()
        if not row:
            return None
        d = dict(row)
        if allow_status and d.get("status") not in allow_status:
            return None
        return d
    finally:
        conn.close()


def compat_json():
    """兼容层：返回旧格式数组 [{id,name,date,cover}]，date 倒序，只含 ready。"""
    conn = db.connect()
    try:
        rows = conn.execute(
            "SELECT id,name,date,cover FROM videos WHERE status='ready' "
            "ORDER BY sort_pin DESC, date DESC, id").fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def upsert(entry, fix_status_ready=True):
    """UPSERT 一条视频（merge_videos.py 与 admin 共用）。

    entry: dict，至少含 id/name/date；cover 若为 base64 data URL 会落盘到
    /var/www/html/covers/<id>.jpg 并改写为 /covers/<id>.jpg。
    返回 dict {ok, id, total, cover}
    """
    import os
    import base64 as b64mod

    vid = entry.get("id")
    if not vid:
        raise ValueError("id is required")
    name = entry.get("name") or entry.get("title") or vid
    date = entry.get("date") or ""
    cover = entry.get("cover") or ""
    sort_pin = entry.get("sort_pin") or 0
    try:
        sort_pin = int(sort_pin)
    except (TypeError, ValueError):
        sort_pin = 0

    if cover.startswith("data:image/"):
        try:
            _meta, b64data = cover.split(",", 1)
            data = b64mod.b64decode(b64data)
            covers_dir = os.environ.get("SITEAUTH_COVERS_DIR",
                                        "/var/www/html/covers")
            os.makedirs(covers_dir, exist_ok=True)
            with open(os.path.join(covers_dir, vid + ".jpg"), "wb") as f:
                f.write(data)
            cover = "/covers/%s.jpg" % vid
        except Exception as e:
            raise ValueError("cover decode failed: %s" % e)
    elif cover and not cover.startswith("/covers/"):
        # 路径封面（如 auto_upload 的 /videos/<id>/cover.jpg）：同步到统一封面目录
        try:
            webroot = os.environ.get("SITEAUTH_WEBROOT", "/var/www/html")
            src = os.path.join(webroot, cover.lstrip("/"))
            if os.path.isfile(src):
                covers_dir = os.environ.get("SITEAUTH_COVERS_DIR",
                                            "/var/www/html/covers")
                os.makedirs(covers_dir, exist_ok=True)
                with open(src, "rb") as f:
                    data = f.read()
                with open(os.path.join(covers_dir, vid + ".jpg"), "wb") as f:
                    f.write(data)
                cover = "/covers/%s.jpg" % vid
        except Exception:
            pass  # 同步失败保留原路径（兼容 v1 静态目录）

    conn = db.connect()
    # owner_id：多用户升级后 videos.owner_id 必填。entry 带则校验后使用；
    # 不带则 INSERT 默认归 admin(1)，UPDATE 时保留原属主，不覆盖他人视频。
    owner_insert = 1
    owner_update = None
    owner_raw = entry.get("owner_id")
    if owner_raw is not None and owner_raw != "":
        try:
            owner_id = int(owner_raw)
        except (TypeError, ValueError):
            raise ValueError("owner_id must be an integer, got %r" % (owner_raw,))
        if owner_id <= 0:
            raise ValueError("owner_id must be positive, got %r" % (owner_raw,))
        if not conn.execute("SELECT id FROM users WHERE id=?", (owner_id,)).fetchone():
            raise ValueError("owner_id %d does not match any user" % owner_id)
        owner_insert = owner_id
        owner_update = owner_id

    now = int(time.time())
    try:
        row = conn.execute("SELECT id, created_at FROM videos WHERE id=?", (vid,)).fetchone()
        created = row["created_at"] if row else now
        conn.execute(
            "INSERT INTO videos (id,name,date,cover,status,sort_pin,created_at,updated_at,owner_id) "
            "VALUES (?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(id) DO UPDATE SET "
            "  name=excluded.name, date=excluded.date, cover=excluded.cover, "
            "  status=excluded.status, sort_pin=excluded.sort_pin, "
            "  deleted_at=NULL, updated_at=excluded.updated_at, "
            "  owner_id=COALESCE(?, videos.owner_id)",
            (vid, name, date, cover,
             "ready" if fix_status_ready else entry.get("status", "ready"),
             sort_pin, created, now, owner_insert, owner_update))
        conn.commit()
        total = conn.execute("SELECT COUNT(*) AS c FROM videos").fetchone()["c"]
        return {"ok": True, "id": vid, "total": total, "cover": cover}
    finally:
        conn.close()


