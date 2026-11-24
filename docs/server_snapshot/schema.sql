-- schema.sql — v2 建表 DDL（与方案 §4 一致）
PRAGMA journal_mode = WAL;      -- 允许读并发；必须持久设置一次
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;     -- 每个连接都要设

CREATE TABLE IF NOT EXISTS users (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  username      TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  password_hash TEXT    NOT NULL,                       -- scrypt$... 或 pbkdf2$...
  role          TEXT    NOT NULL DEFAULT 'user'  CHECK (role IN ('admin','user')),
  status        TEXT    NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
  created_at    INTEGER NOT NULL,
  last_login_at INTEGER,
  last_login_ip TEXT
);

CREATE TABLE IF NOT EXISTS sessions (
  token_hash  TEXT    PRIMARY KEY,                      -- sha256(token) 的 hex，绝不存明文 token
  user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  INTEGER NOT NULL,
  last_active INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL,
  ip          TEXT,
  ua          TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);

CREATE TABLE IF NOT EXISTS videos (
  id          TEXT    PRIMARY KEY,                      -- 沿用现有 id（8位hex 或 tw_<id>），不要重新生成
  name        TEXT    NOT NULL,
  date        TEXT    NOT NULL,                         -- ISO 字符串，排序用（与旧字段同义）
  cover       TEXT,                                     -- URL 路径，如 /covers/<id>.jpg；可为空
  description TEXT    NOT NULL DEFAULT '',
  duration    REAL,
  size_bytes  INTEGER,
  status      TEXT    NOT NULL DEFAULT 'ready' CHECK (status IN ('ready','hidden','deleted','broken')),
  sort_pin    INTEGER NOT NULL DEFAULT 0,               -- >0 手动置顶（v2 可选）
  views       INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  deleted_at  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_videos_list ON videos(status, sort_pin DESC, date DESC);

-- 审计留痕（管理动作与登录失败都可写，纯记录，v2 只写界面显示最近 50 条）
CREATE TABLE IF NOT EXISTS audit_log (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  ts      INTEGER NOT NULL,
  user_id INTEGER,
  action  TEXT    NOT NULL,
  target  TEXT,
  detail  TEXT,
  ip      TEXT
);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts DESC);
