# -*- coding: utf-8 -*-
"""db.py — SQLite 连接/事务/DDL 初始化（v2）。纯标准库。"""
import os
import sqlite3

DB_PATH = os.environ.get("DB_PATH", "/opt/siteauth/site.db")
_SCHEMA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")


def connect():
    """每请求一个连接；不跨线程共享。"""
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def _columns(conn, table):
    return {r["name"] for r in conn.execute("PRAGMA table_info(%s)" % table).fetchall()}


def _migrate(conn):
    """幂等的列级迁移。CREATE TABLE IF NOT EXISTS 不会给已有表加列，
    所以新增列必须在这里显式 ALTER。"""
    # P3.2：sessions.app_token_id —— 记录 session 由哪个 app_token 换来，
    # 使"踢设备"能连带销毁对应 session（否则 session 滑动续期，踢了也没用）。
    if "app_token_id" not in _columns(conn, "sessions"):
        conn.execute("ALTER TABLE sessions ADD COLUMN app_token_id INTEGER")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_sessions_app_token "
                     "ON sessions(app_token_id)")
        print("[db] migrated: sessions.app_token_id", flush=True)


def init_db():
    """建目录、设 WAL、执行建表 DDL、跑列级迁移。幂等。"""
    d = os.path.dirname(DB_PATH)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    conn = connect()
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        with open(_SCHEMA, "r", encoding="utf-8") as f:
            conn.executescript(f.read())
        conn.commit()
        _migrate(conn)
        conn.commit()
    finally:
        conn.close()
