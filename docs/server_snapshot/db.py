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


def init_db():
    """建目录、设 WAL、执行建表 DDL。幂等。"""
    d = os.path.dirname(DB_PATH)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    conn = connect()
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        with open(_SCHEMA, "r", encoding="utf-8") as f:
            conn.executescript(f.read())
        conn.commit()
    finally:
        conn.close()
