# -*- coding: utf-8 -*-
"""app_tokens.py — 移动端长效令牌（P1）。纯标准库。

设计要点
--------
* 令牌明文只在签发时返回一次，DB 只存 sha256(token)（与 sessions 表同一思路）。
* 令牌前缀 ``vap_`` 便于在日志/审计里识别，且不与 session cookie 混淆。
* 有效期默认 30 天（``SITEAUTH_APP_TOKEN_TTL_DAYS``），固定到期，不滑动。
  每次用令牌换 session 时更新 ``last_used_at``，供「设备管理」显示活跃情况。
* 换 session 时不延长令牌有效期 —— 到期必须重新登录，避免令牌无限续命。
* 改密码 / 停用账号 / 删除账号时批量作废该用户全部令牌。
"""
import os
import time

import auth
import db

TOKEN_PREFIX = "vap_"
DEFAULT_TTL_DAYS = 30
MAX_DEVICES_PER_USER = 20          # 单用户最多同时持有的令牌数（防滥用）
MAX_DEVICE_NAME = 64


def _ttl_seconds():
    try:
        days = int(os.environ.get("SITEAUTH_APP_TOKEN_TTL_DAYS", DEFAULT_TTL_DAYS))
    except (TypeError, ValueError):
        days = DEFAULT_TTL_DAYS
    if days < 1:
        days = DEFAULT_TTL_DAYS
    if days > 365:
        days = 365
    return days * 86400


def _clean_name(s, fallback):
    s = (s or "").strip()
    if not s:
        return fallback
    return s[:MAX_DEVICE_NAME]


def issue(user_id, device_name, platform, ip, ua):
    """签发一个 app token。返回 (status, body)。

    成功 body: {"ok":True,"token":"vap_xxx","expires_at":<ts>,"id":<int>,
                "device_name":...,"platform":...,"ttl_days":N}
    """
    conn = db.connect()
    try:
        now = int(time.time())
        # 限制单用户令牌数量：超出则作废最久未使用的那批
        rows = conn.execute(
            "SELECT id FROM app_tokens WHERE user_id=? ORDER BY COALESCE(last_used_at,created_at) ASC",
            (user_id,)).fetchall()
        if len(rows) >= MAX_DEVICES_PER_USER:
            drop = [r["id"] for r in rows[:len(rows) - MAX_DEVICES_PER_USER + 1]]
            conn.executemany("DELETE FROM app_tokens WHERE id=?",
                             [(i,) for i in drop])

        token = TOKEN_PREFIX + auth.new_session_token()
        expires_at = now + _ttl_seconds()
        device_name = _clean_name(device_name, "未命名设备")
        platform = _clean_name(platform, "unknown")
        cur = conn.execute(
            "INSERT INTO app_tokens(token_hash,user_id,device_name,platform,created_at,"
            "last_used_at,expires_at,ip,ua) VALUES(?,?,?,?,?,?,?,?,?)",
            (auth.token_hash(token), user_id, device_name, platform,
             now, None, expires_at, ip, (ua or "")[:200]))
        tid = cur.lastrowid
        conn.execute(
            "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
            (now, user_id, "app.token.issue", str(tid),
             "device=%s platform=%s" % (device_name, platform), ip))
        conn.commit()
        return 200, {"ok": True, "id": tid, "token": token,
                     "expires_at": expires_at,
                     "ttl_days": _ttl_seconds() // 86400,
                     "device_name": device_name, "platform": platform}
    finally:
        conn.close()


def resolve(token):
    """校验 app token。返回 (user_dict, token_row_id) 或 (None, None)。

    校验项：存在、未过期、用户存在且 active。
    顺带更新 last_used_at。
    """
    if not token or not token.startswith(TOKEN_PREFIX):
        return None, None
    conn = db.connect()
    try:
        th = auth.token_hash(token)
        row = conn.execute(
            "SELECT t.id,t.user_id,t.expires_at,u.username,u.role,u.status "
            "FROM app_tokens t JOIN users u ON u.id=t.user_id "
            "WHERE t.token_hash=?", (th,)).fetchone()
        if not row:
            return None, None
        now = int(time.time())
        if row["expires_at"] <= now:
            conn.execute("DELETE FROM app_tokens WHERE id=?", (row["id"],))
            conn.commit()
            return None, None
        if row["status"] != "active":
            return None, None
        conn.execute("UPDATE app_tokens SET last_used_at=? WHERE id=?", (now, row["id"]))
        conn.commit()
        return ({"user_id": row["user_id"], "username": row["username"],
                 "role": row["role"], "status": row["status"]}, row["id"])
    finally:
        conn.close()


def list_tokens(user_id, current_token_id=None):
    """列出该用户全部有效令牌（设备管理）。返回 (status, body)。"""
    conn = db.connect()
    try:
        now = int(time.time())
        conn.execute("DELETE FROM app_tokens WHERE expires_at<=?", (now,))
        conn.commit()
        rows = conn.execute(
            "SELECT id,device_name,platform,created_at,last_used_at,expires_at,ip "
            "FROM app_tokens WHERE user_id=? AND expires_at>? "
            "ORDER BY COALESCE(last_used_at,created_at) DESC",
            (user_id, now)).fetchall()
        items = []
        for r in rows:
            items.append({
                "id": r["id"],
                "device_name": r["device_name"],
                "platform": r["platform"],
                "created_at": r["created_at"],
                "last_used_at": r["last_used_at"],
                "expires_at": r["expires_at"],
                "ip": r["ip"],
                "current": bool(current_token_id and r["id"] == current_token_id),
            })
        return 200, {"total": len(items), "items": items}
    finally:
        conn.close()


def revoke(user_id, token_id):
    """踢掉指定设备。只能删自己的。返回 (status, body)。"""
    conn = db.connect()
    try:
        row = conn.execute("SELECT id,user_id,device_name FROM app_tokens WHERE id=?",
                           (token_id,)).fetchone()
        if not row:
            return 404, {"error": "token not found"}
        if row["user_id"] != user_id:
            return 403, {"error": "forbidden"}
        conn.execute("DELETE FROM app_tokens WHERE id=?", (token_id,))
        now = int(time.time())
        conn.execute(
            "INSERT INTO audit_log(ts,user_id,action,target,detail,ip) VALUES(?,?,?,?,?,?)",
            (now, user_id, "app.token.revoke", str(token_id),
             "device=%s" % row["device_name"], None))
        conn.commit()
        return 200, {"ok": True}
    finally:
        conn.close()


def revoke_all_for_user(conn, user_id, reason=""):
    """批量作废某用户全部令牌（改密/停用时调用）。传入已有 conn 以便同事务。"""
    cur = conn.execute("DELETE FROM app_tokens WHERE user_id=?", (user_id,))
    return cur.rowcount


def revoke_by_token(token):
    """按明文令牌作废（登出时可选）。"""
    if not token:
        return 0
    conn = db.connect()
    try:
        cur = conn.execute("DELETE FROM app_tokens WHERE token_hash=?",
                           (auth.token_hash(token),))
        conn.commit()
        return cur.rowcount
    finally:
        conn.close()
