# P1 · 后端 app_tokens 实现说明

> 部署日期：2026-11-25
> 服务器：root@64.90.31.17（RainYun-pHZMnvOv）
> 备份目录：`/root/site-backups/p1_20261125_000335/`

---

## 1. 为什么需要这一层

session Cookie 的 `SESSION_MAX_AGE=1800`（30 分钟），滑动续期。App 若只靠 Cookie，
用户关掉 App 超过 30 分钟就要重输密码，体验不可接受。

方案：**新增长效令牌，令牌只用于"静默换 session"**，媒体链路
（`/videos/`、`/key/`、`/covers/` 的 nginx `auth_request` 走 Cookie）**一行不动**。
这样把改动面压到最小，不影响已验证的播放/封面鉴权链路。

---

## 2. 数据库变更

新增表 `app_tokens`（`schema.sql` 末尾追加，`CREATE TABLE IF NOT EXISTS`，幂等）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | INTEGER PK AUTOINCREMENT | 设备记录 id，用于踢设备 |
| `token_hash` | TEXT NOT NULL UNIQUE | `sha256(vap_xxx)` 的 hex，**绝不存明文** |
| `user_id` | INTEGER NOT NULL → users(id) ON DELETE CASCADE | 属主 |
| `device_name` | TEXT NOT NULL DEFAULT '' | 用户可读设备名，最长 64 字符 |
| `platform` | TEXT NOT NULL DEFAULT 'unknown' | android / ios / unknown |
| `created_at` | INTEGER NOT NULL | 签发时间 |
| `last_used_at` | INTEGER | 最近一次换 session 的时间，可为 NULL |
| `expires_at` | INTEGER NOT NULL | 固定到期时间，**不滑动** |
| `ip` | TEXT | 签发时的客户端 IP |
| `ua` | TEXT | 签发时的 User-Agent，截断 200 字符 |

索引：`idx_app_tokens_user (user_id, expires_at)`

### 关键设计取舍

1. **有效期 30 天固定，不滑动续期。** 每次换 session 只更新 `last_used_at`，
   不延长 `expires_at`。理由：令牌一旦泄露，攻击窗口有硬上限；30 天后必须重新输密码。
2. **单用户最多 20 个令牌。** 超出时自动作废"最久未使用"的那批（`ORDER BY COALESCE(last_used_at, created_at) ASC`）。
   防止恶意刷接口把表撑爆。
3. **令牌前缀 `vap_`。** 便于日志/审计识别，也避免与 session token 混淆。

---

## 3. 接口清单（4 个）

### 3.1 `POST /api/app/token` — 签发令牌

需**有效 session Cookie**。签发后明文只返回这一次。

请求：
```http
POST /api/app/token HTTP/1.1
Content-Type: application/json
Cookie: site_session=<session>

{"device_name": "Pixel 8", "platform": "android"}
```

响应 200：
```json
{
  "ok": true,
  "id": 3,
  "token": "vap_TOkv9XqaEEym...",
  "expires_at": 1798128317,
  "ttl_days": 30,
  "device_name": "Pixel 8",
  "platform": "android"
}
```

`device_name` / `platform` 均可省略，省略时回落为 `"未命名设备"` / `"unknown"`。

---

### 3.2 `POST /api/app/session` — 用令牌换 session

**不需要 Cookie**（这是它存在的意义）。在路由表里排在会话校验**之前**。

请求（两种方式等价）：
```http
POST /api/app/session HTTP/1.1
Content-Type: application/json

{"token": "vap_xxx"}
```
```http
POST /api/app/session HTTP/1.1
Content-Type: application/json
Authorization: Bearer vap_xxx

{}
```

响应 200（同时下发 `Set-Cookie: site_session=...`）：
```json
{
  "ok": true,
  "username": "user",
  "role": "user",
  "expires_at": 1795538118,
  "token_id": 3
}
```

错误：
- `400 {"error":"token required"}` — 两个位置都没给 token
- `401 {"error":"invalid or expired token"}` — 不存在 / 已过期 / 账号被停用

---

### 3.3 `GET /api/app/tokens` — 设备列表

需 session Cookie。只返回**当前用户**的、**未过期**的令牌（查询时顺手清理过期行）。

响应 200：
```json
{
  "total": 2,
  "items": [
    {
      "id": 3,
      "device_name": "Pixel 8",
      "platform": "android",
      "created_at": 1795000000,
      "last_used_at": 1795100000,
      "expires_at": 1797592000,
      "ip": "1.2.3.4",
      "current": true
    }
  ]
}
```

`current` 目前恒为 `false`（换 session 后无法从 Cookie 反查来源令牌，
除非把 `token_id` 塞进 session 表）。**这是已知限制，P3 若需要可在 session 表加一列。**

---

### 3.4 `DELETE /api/app/tokens/<id>` — 踢设备

需 session Cookie。只能删自己的（否则 403）。

- `200 {"ok": true}` — 成功
- `404 {"error":"token not found"}` — id 不存在
- `403 {"error":"forbidden"}` — 是别人的令牌

**CSRF 例外**：`DELETE /api/app/tokens/<数字>` 允许**无请求体**，
只校验 Origin（若存在）。其他写接口仍必须 `Content-Type: application/json` + 至少 `{}`。

---

## 4. 令牌作废策略（三条自动触发）

| 触发动作 | 位置 | 行为 |
|---------|------|------|
| 管理员改密码 | `admin.py: user_password()` | `DELETE FROM app_tokens WHERE user_id=?`，响应附 `tokens_revoked` 数量 |
| 管理员停用账号 | `admin.py: user_status()` | 同上，同时清 sessions |
| 删除账号 | 外键 `ON DELETE CASCADE` | 自动级联删除 |

**改密码即强制下线所有设备**——这是安全默认值，不需要额外开关。

---

## 5. 改动文件清单

| 文件 | 改动 |
|------|------|
| `schema.sql` | 末尾追加 `app_tokens` 表 + 索引 |
| `app_tokens.py` | **新增**，250 行，纯标准库，含 `issue`/`resolve`/`list_tokens`/`revoke`/`revoke_all_for_user`/`revoke_by_token` |
| `siteauth_server.py` | ① `import app_tokens` ② 路由：`/api/app/session`（会话校验前）、`/api/app/token`、`/api/app/tokens`、`DELETE /api/app/tokens/<id>` ③ 新增 `_handle_app_session()` ④ `_csrf_ok()` 放行无 body 的 DELETE |
| `admin.py` | `user_password()` 增加批量作废 + 返回 `tokens_revoked`；`user_status()` 停用时增加批量作废 |

---

## 6. 部署步骤（可复现）

```bash
# 1. 备份
TS=$(date +%Y%m%d_%H%M%S)
mkdir -p /root/site-backups/p1_$TS
cp -a /opt/siteauth/{site.db,schema.sql,siteauth_server.py,admin.py} /root/site-backups/p1_$TS/

# 2. 上传 4 个文件到 /opt/siteauth/

# 3. 迁移 DB（幂等）
cd /opt/siteauth && python3 -c "import db; db.init_db()"

# 4. 重启
systemctl restart siteauth && systemctl is-active siteauth
```

**回滚**：把备份目录的 4 个文件拷回 `/opt/siteauth/`，重启服务。
`app_tokens` 表留着无害（无代码引用），也可 `DROP TABLE app_tokens`。

---

## 7. 实测结果

探针脚本：`docs/tools/probe_p1.py`（需在**服务器本机**跑，因为本机到 51play.ccwu.cc 的连接会被重置）

### 主链路 25/25 通过

```
[1] 登录                                    PASS
[2] 签发 app token                          PASS ×4（vap_ 前缀 / ttl_days=30 / expires_at 未来）
[3] 签发第二个 token                        PASS ×2
[4] 设备列表                                PASS ×3（含 8 个字段完整）
[5] 用 token 换 session（无 Cookie）        PASS ×2
[6] 新 session 访问业务接口                 PASS ×4（/api/me、/api/videos total=33）
[7] Authorization: Bearer 方式              PASS
[8] 错误场景                                PASS ×3（401/400/401）
[9] 踢设备                                  PASS ×4（踢后失效、另一台仍可用、列表减一）
[10] 越权保护                               PASS（404）
```

### 改密/停用作废链路

```
1. 签发 token id=3 vap_rAdoWYZYHUk7...      PASS
2. token 可解析                             PASS
3. admin 改密 -> tokens_revoked = 1         PASS
4. 旧 token 解析结果 None（已作废）          PASS
5. 停用账号                                 PASS
6. 停用后 token 已作废                       PASS
7. 恢复 active                              PASS
8. app_tokens 表剩余 0 行（环境已复原）      PASS
9. user 状态 active                         PASS
```

---

## 8. 客户端对接要点（P3 用）

1. 登录成功 → `POST /api/app/token`，把 `token` + `expires_at` 存 secure storage。
   `device_name` 建议用 `"${机型} / Android ${版本}"`。
2. App 启动：先读 Cookie 调 `GET /api/me`；401 则用存的 token 调
   `POST /api/app/session`，成功即拿到新 Cookie，用户无感。
3. 前台保活：每 10 分钟调一次 `/api/me`（滑动续期 30 分钟窗口）。
4. 登出：`POST /api/logout`（**必须带 `{}` JSON body**）+ 清 Cookie +
   可选 `DELETE /api/app/tokens/<自己的 id>`。
5. 设备管理页：`GET /api/app/tokens` 列出，`DELETE /api/app/tokens/<id>` 踢掉。
