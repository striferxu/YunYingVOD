# 视频点播客户端 API 契约（P0 冻结版）

> **文档性质**：本文档是 Flutter 安卓客户端**唯一可信**的接口依据。
> 所有响应样例均为 **2026-11-24 在服务器本机对 `https://51play.ccwu.cc` 实测的真实输出**，
> 非手写推测。实测脚本见同目录 `probe_p0.py` / `probe_p0b.py` / `probe_p0c.py` / `probe_p0d.py`。
>
> 服务端代码快照见 `docs/server_snapshot/`（与线上 md5 一致）。
>
> **客户端若发现实际响应与本文不符，以实测为准并回写本文档。**

---

## 0. 基础信息

| 项 | 值 |
|----|-----|
| Base URL | `https://51play.ccwu.cc`（**仅 HTTPS**，HTTP 会 301） |
| 备用直连 | `https://64.90.31.17`（证书覆盖，但客户端不应硬编码 IP） |
| 会话 Cookie 名 | `site_session` |
| Cookie 属性 | `HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=1800` |
| 会话有效期 | **1800 秒（30 分钟）**，**滑动续期**：任意一次带 Cookie 的 API 调用都会把 expires_at 推后 30 分钟 |
| 时间戳格式 | 全部为 **Unix 秒**（整数），如 `1795535044` |
| 业务时间字段 | `date` 是字符串 `YYYY-MM-DDTHH:MM:SS`（本地时间，无时区后缀） |
| 字符集 | UTF-8，JSON `ensure_ascii=False`（含中文/emoji 原样返回） |
| 当前视频总数 | **33 条 ready**（验收时请实时比对，不要写死） |

### 0.1 鉴权方式

1. **主方式（客户端必须用）**：`POST /api/login` 成功后服务端下发 `site_session` Cookie。
   客户端需自行保存该 Cookie，并在后续**所有**请求中带上：
   ```
   Cookie: site_session=<token>
   ```
   ⚠️ Flutter 的 `dart:io HttpClient` / `dio` **不会**自动持久化 HttpOnly Cookie，
   必须手动从 `Set-Cookie` 响应头提取并存储（建议 `flutter_secure_storage`）。

2. **Origin 校验（关键，容易踩坑）**：
   后端对写接口（POST/DELETE/PUT）做 CSRF 校验：
   - `Content-Type` **必须**是 `application/json`（上传接口例外，见 §5）
   - `Origin` 头**若存在**则必须在白名单 `{https://51play.ccwu.cc, https://64.90.31.17}` 内
   - **Flutter 原生 http 默认不发 Origin 头 → 校验放行**（实测确认）
   - 但如果你手动加了 `Origin: https://xxx` 而域名不在白名单 → **403 `CSRF check failed`**

   > 实测证据：
   > - 带 `Origin: https://evil.example.com` 登录 → `403 {"error":"CSRF check failed"}`
   > - 带 `Origin: https://51play.ccwu.cc` 登录 → `200`
   > - 不带 Origin → `200`

   **结论：客户端不要手动设置 Origin 头，让它是空的即可。**

3. **`POST /api/logout` 必须带 JSON body**（哪怕空对象 `{}`）和
   `Content-Type: application/json`，否则 403。实测：
   - 无 Content-Type → `403 {"error":"CSRF check failed"}`
   - `Content-Type: application/json` + body `{}` → `200 {"ok":true}`

---

## 1. 认证与会话

### 1.1 登录 `POST /api/login`

**请求**
```http
POST /api/login
Content-Type: application/json

{"username": "user", "password": "******"}
```

**成功 200**
```json
{"ok": true, "username": "user", "role": "user"}
```
响应头同时下发：
```
Set-Cookie: site_session=<64字节随机串>; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=1800
```

**失败**

| 场景 | 状态码 | body |
|------|--------|------|
| 密码错误 | 401 | `{"error": "Invalid credentials"}` |
| 用户不存在 | 401 | `{"error": "Invalid credentials"}`（**与密码错误无法区分**，勿做用户枚举提示） |
| 账号 pending（未审核） | 401 | `{"error": "Invalid credentials"}`（同上，无法区分） |
| 连续失败达 10 次 | **423** | `{"error": "Account locked"}` |
| 空 body | 400 | `{"error": "Empty request body"}` |
| 非法 JSON | 400 | `{"error": "Invalid JSON"}` |
| 非法 Origin | 403 | `{"error": "CSRF check failed"}` |
| **nginx 限流** | **503** | HTML `<h1>503 Service Temporarily Unavailable</h1>` |

> ⚠️ **登录限流（客户端必须处理）**：nginx `limit_req_zone ... zone=login rate=15r/m`（15 次/分钟），
> `burst=5`。超过后返回 **503 HTML**（不是 JSON）。
> 客户端登录按钮必须：① 请求中禁用防连点；② 收到 503 时提示"操作过于频繁，请稍后再试"。

**423 锁定实测序列**（4.2 秒间隔，避开限流）：
```
第1~10次 -> 401 {"error":"Invalid credentials"}
第11次   -> 423 {"error":"Account locked"}
```
锁定 600 秒（10 分钟），按 **username** 计数（内存态，重启后端即清空）。

### 1.2 登出 `POST /api/logout`

```http
POST /api/logout
Content-Type: application/json
Cookie: site_session=<token>

{}
```
**成功 200**：`{"ok": true}`（同时 `Set-Cookie: site_session=; Max-Age=0` 清 Cookie）

### 1.3 当前会话 `GET /api/me`

```http
GET /api/me
Cookie: site_session=<token>
```
**成功 200**
```json
{"username": "user", "role": "user", "expires_at": 1795535044}
```
**未登录/过期 401**：`{"error": "Unauthorized"}`

> 客户端用途：App 启动时验证本地 Cookie 是否仍有效；也是**滑动续期**最轻量的探针（建议每 10 分钟调一次）。

### 1.4 完整用户信息 `GET /api/me_full`

**成功 200**
```json
{"data": {"id": 6, "username": "user", "nickname": "", "role": "user", "status": "active"}}
```
`nickname` 可能为空串（此时前端显示 username）。

### 1.5 `/api/auth` 说明（**客户端不要调用**）

`GET /api/auth` 直连公网返回 **404**。它在 nginx 中是 `internal` 指令，仅供
`auth_request` 子请求使用（`/videos/`、`/key/`、`/covers/`、`/player.html` 的鉴权靠它）。
客户端无需也不应调用。

---

## 2. 视频列表与详情

### 2.1 列表 `GET /api/videos`

**查询参数**（全部可选）

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `q` | string | 无 | 标题模糊搜索（`LIKE %q%`，**不区分大小写**） |
| `status` | string | `ready` | `ready`/`hidden`/`deleted`/`broken`；非法值**静默回落为 ready** |
| `page` | int | 1 | 页码，`<1` 时按 1 处理 |
| `limit` | int | 100 | 每页条数，**上限 500**（超过按 500 处理），`<1` 按 1 |

**成功 200**（真实输出，截断至首项）
```json
{
  "total": 33,
  "items": [
    {
      "id": "tw_2124946082094260484",
      "name": "经典 A片 - 💖💖💖",
      "date": "2026-11-24T11:13:51",
      "cover": "/covers/tw_2124946082094260484.jpg",
      "duration": null,
      "size_bytes": null,
      "status": "ready",
      "sort_pin": 0,
      "views": 0,
      "owner_id": 1,
      "created_at": 1795490031
    }
  ]
}
```

**字段说明**

| 字段 | 类型 | 可空 | 说明 |
|------|------|------|------|
| `id` | string | 否 | 视频 ID，形如 `tw_<19位数字>`、`8位hex`、`cklou_<32hex>`、`whos_*`。**客户端不要假设格式** |
| `name` | string | 否 | 标题 |
| `date` | string | 否 | `YYYY-MM-DDTHH:MM:SS` |
| `cover` | string | **是** | 形如 `/covers/<id>.jpg`，可能为 `null`/空 |
| `duration` | number | **是** | 秒（浮点）。**实测大量为 null**，客户端需容错 |
| `size_bytes` | int | **是** | 字节，常为 null |
| `status` | string | 否 | `ready`/`hidden`/`deleted`/`broken` |
| `sort_pin` | int | 否 | >0 表示置顶 |
| `views` | int | 否 | 播放数 |
| `owner_id` | int | **是** | 上传者用户 id，可对照 `/api/owners` |
| `created_at` | int | 否 | Unix 秒 |

**排序规则**：`sort_pin DESC, date DESC, id`（置顶优先，然后时间倒序）。

**实测样例**

| 请求 | 结果 |
|------|------|
| `/api/videos` | `total=33, items=33` |
| `/api/videos?q=IPX` | `total=1`，`["IPX-811"]` |
| `/api/videos?limit=2&page=2` | `total=33`，返回第 3、4 条 |
| `/api/videos?status=deleted` | `total=0, items=[]` |
| `/api/videos?limit=999` | 200，limit 被钳到 500 |
| `/api/videos?page=0` | 200，按 page=1 |

**未登录 401**：`{"error": "Unauthorized"}`（JSON）

### 2.2 详情 `GET /api/videos/<id>`

**成功 200**（真实输出）
```json
{
  "id": "tw_2124946082094260484",
  "name": "经典 A片 - 💖💖💖",
  "date": "2026-11-24T11:13:51",
  "cover": "/covers/tw_2124946082094260484.jpg",
  "description": "",
  "duration": null,
  "size_bytes": null,
  "status": "ready",
  "sort_pin": 0,
  "views": 0,
  "created_at": 1795490031,
  "updated_at": 1795490031
}
```
比列表多 `description`、`updated_at`。

**不存在 404**：`{"error": "video not found"}`
**非 ready 状态**：也返回 404（`get_video` 默认只允许 `ready`）

### 2.3 我的视频 `GET /api/my_videos`

**成功 200**（user 账号上传前）
```json
{"total": 0, "items": []}
```
上传后实测：
```json
{"total": 1, "items": [{"id":"97c4e6fe","name":"P0 探针测试视频（可删除）","date":"2026-11-24T23:21:28","cover":"/covers/97c4e6fe.jpg","duration":3.024,"size_bytes":56936,"status":"ready","views":0,"created_at":1795533688}]}
```
字段：`id,name,date,cover,duration,size_bytes,status,views,created_at`
（**注意：无 `owner_id`、无 `sort_pin`**，与 `/api/videos` 不同）
排序：`created_at DESC, id`

### 2.4 上传者映射 `GET /api/owners`

**成功 200**（真实输出）
```json
{"1": "admin"}
```
键是 `owner_id`（**字符串形式的数字**），值是 `nickname`（空则回落 `username`）。
仅包含有 ready 视频的属主。客户端用 `ownersMap[video.owner_id]` 取，取不到显示"其他用户"。

### 2.5 兼容层 `GET /videos.json`

**成功 200**，返回**数组**（非对象）：
```json
[{"id":"tw_2124946082094260484","name":"经典 A片 - 💖💖💖","date":"2026-11-24T11:13:51","cover":"/covers/tw_2124946082094260484.jpg"}]
```
仅 `id,name,date,cover` 四个字段，只含 ready。
**客户端不推荐使用**（信息不全），保留仅供老网页兼容。

---

## 3. 媒体资源（HLS 播放链路）

### 3.1 三类资源与鉴权

| 资源 | 路径 | 鉴权 |
|------|------|------|
| 播放列表 | `/videos/<id>/output.m3u8` | **需 Cookie**（nginx `auth_request /api/auth`） |
| TS 分段 | `/videos/<id>/output<序号>.ts` 或 `output_<序号>.ts` | **需 Cookie** |
| 解密密钥 | `/key/<id>` | **需 Cookie** |
| 封面 | `/covers/<id>.jpg` | **需 Cookie** |

⚠️ **文件名不统一**：不同视频的分段命名不同，实测见过 `output0.ts`（tw_ 系列）和
`output_000.ts`（早期 8 位 hex 系列）。**必须解析 m3u8 内容拿真实文件名，不要拼规则。**

### 3.2 m3u8 实测内容头部

```
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:3
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-KEY:METHOD=AES-128,URI="/key/tw_2124946082094260484",IV=0x00000000000000000000000000000000
#EXTINF:3.000000,
output0.ts
```

**关键点**：
- `#EXT-X-KEY` 的 `URI` 是**相对路径** `/key/<id>`（**不含域名**）
- `IV` 固定全零 `0x0000...0000`
- 播放器会把相对 URI 基于 m3u8 的 URL 解析成 `https://51play.ccwu.cc/key/<id>` → **同源请求**

### 3.3 实测鉴权行为

| 请求 | 带 Cookie | 不带 Cookie |
|------|-----------|-------------|
| `/videos/<id>/output.m3u8` | **200**，37693 bytes | **401**（nginx HTML 页，非 JSON） |
| `/key/<id>` | **200**，16 bytes（AES-128 密钥） | **401** |
| `/covers/<id>.jpg` | **200**，JPEG（9.7KB） | 401 |
| `/videos/<id>/output0.ts` | **200**，199104 bytes | 401 |

> 401 响应体是 **nginx 的 HTML**，不是 JSON，客户端解析时不要假设 JSON。

### 3.4 客户端播放实现要点

1. **必须把 Cookie 注入到媒体请求**。Android ExoPlayer 方案：
   ```dart
   VideoPlayerController.networkUrl(
     Uri.parse('https://51play.ccwu.cc/videos/$id/output.m3u8'),
     httpHeaders: {'Cookie': 'site_session=$token'},
   )
   ```
   ExoPlayer 会把 `httpHeaders` 应用到该媒体源的**全部**请求（m3u8、ts、key）。
2. **Referer 白名单**：nginx 对 `/videos/`、`/key/`、`/covers/` 有
   `valid_referers none server_names`。原生播放器默认**不发 Referer** → 命中 `none` → 放行。
   ⚠️ **不要给媒体请求手动加 Referer**，否则会被 403。
3. Cookie 过期（30 分钟）时，正在播放的视频会因 key/ts 401 而中断 → 需在播放页捕获错误并尝试续期后重载。

---

## 4. 上传与转码

### 4.1 上传 `POST /api/upload`

**请求**
```http
POST /api/upload
Cookie: site_session=<token>
Content-Type: multipart/form-data; boundary=----xxx

------xxx
Content-Disposition: form-data; name="video"; filename="clip.mp4"
Content-Type: video/mp4

<二进制>
------xxx
Content-Disposition: form-data; name="title"

视频标题
------xxx--
```

**成功 202**
```json
{"ok": true, "job_id": "97c4e6fe", "status": "queued", "message": "上传成功，已进入转码队列，请稍候查看进度"}
```
- `job_id` 是 8 位 hex，**与最终 video id 相同**（实测 `job_id=97c4e6fe`，`result_id=97c4e6fe`）

**限制**

| 项 | 值 |
|----|-----|
| 单文件上限 | 2GB（`SITEAUTH_UPLOAD_MAX`，默认 2147483648） |
| nginx 请求体上限 | 2200m |
| nginx 代理超时 | `proxy_read_timeout 300s` / `proxy_send_timeout 300s` |
| 允许扩展名 | `.mp4 .mov .mkv .avi .webm .flv .ts .m2ts .m4v` |
| 转码并发 | **1**（多任务排队） |
| 转码参数 | libx264 veryfast crf23 + aac 128k，HLS 2 秒分片，AES-128 |

**错误**

| 场景 | 状态码 | body（实测） |
|------|--------|--------------|
| 未登录 | 401 | `{"error": "Unauthorized"}` |
| 非 multipart | 400 | `{"error": "must be multipart/form-data"}` |
| 缺 video 字段 | 400 | `{"error": "缺少 video 文件"}` |
| 扩展名不支持 | 400 | `{"error": "不支持的文件类型: .txt"}` |
| 文件为空 | 400 | `{"error": "视频文件为空"}` |
| 超限 | 413 | `{"error": "file too large or empty"}` |

> ⚠️ **蜂窝网络注意**：>300 秒的上传会被 nginx 掐断。客户端应提示"建议 WiFi 上传"。

### 4.2 上传进度 `GET /api/upload_status/<job_id>`

**成功 200**（实测，3 秒视频已完成）
```json
{
  "id": "97c4e6fe",
  "status": "done",
  "percent": 0.0,
  "eta_seconds": null,
  "current_seconds": 0.0,
  "total_seconds": 3.024,
  "error": null,
  "result_id": "97c4e6fe"
}
```

**字段**

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | string | `queued` / `running` / `done` / `failed` |
| `percent` | number\|null | 0~100，无总时长时为 null |
| `eta_seconds` | int\|null | 预计剩余秒数 |
| `current_seconds` | number | 已转码秒数 |
| `total_seconds` | number\|null | 源视频总时长 |
| `error` | string\|null | 失败原因 |
| `result_id` | string\|null | 成功后的 video id |

**错误**：不存在 → `404 {"error":"job not found"}`；非本人且非 admin → `403 {"error":"forbidden"}`

**轮询建议**：2 秒间隔；`status` 变为 `done`/`failed` 即停止。
短小视频可能**第一次轮询就 done**（实测 3 秒视频首次即 done）。

---

## 5. 注册

### 5.1 当前状态：**注册已开启**（审核制）

**实测（2026-11-24 23:36，开关开启后）**：
```json
HTTP 200 {"ok": true, "id": 181, "username": "regtest_...", "status": "pending",
          "message": "注册成功，账号待管理员审核后即可登录"}
```

> 历史备注：P0 首轮实测时该接口返回 `403 {"error":"registration closed"}`，
> 原因是 systemd 环境变量 `SITEAUTH_ALLOW_REGISTER=0`。经站长确认后已改为 `1` 并重启，
> 现注册可用。**客户端请按本文契约实现，无需关心开关。**

### 5.2 Web 端界面形态（客户端 UI 需对齐）

站长提供的 Web 注册页截图，客户端注册页应保持一致的信息结构：

```
创建账号
加入云影点播，分享你的视频

用户名 *      [ 3-32位字母/数字/_-. ]
昵称 *        [ 展示昵称 ]
密码 *        [ 至少6位 ]

┌─ 📋 本站采用注册审核机制 ──────────────┐
│ 新注册的账号需要经过管理员审核通过后才能  │
│ 登录，如有疑问，请扫描下方二维码联系管理员。│
│                                        │
│           [ 管理员微信二维码 ]           │
│                                        │
│ 管理员联系方式                          │
│ 扫描二维码联系管理员，备注你的用户名以加速审核。│
└────────────────────────────────────────┘

[ 提交注册申请 ]

已有账号？去登录
```

**客户端要点**
- 三个必填项：用户名、昵称、密码（截图中昵称也标了 `*`，但后端昵称实际可选，见 §5.4）
- 密码提示"至少 6 位"——这是**前端提示**，后端只校验非空和长度 ≤256。客户端建议按 ≥6 位做前端校验以对齐 Web
- 二维码地址：`https://51play.ccwu.cc/admin_qr.png`（实测公开可访问，HTTP 200，129489 bytes）
- 审核提示文案需原样呈现，这是用户理解"为什么注册后不能马上登录"的关键

### 5.3 接口 `POST /api/register`

**请求**
```http
POST /api/register
Content-Type: application/json

{"username": "newuser", "password": "******", "nickname": "昵称（可选）"}
```
> 该接口**公开**，无需 Cookie。但**必须带 `Content-Type: application/json`**（CSRF 校验）。

**成功 200**（实测）
```json
{"ok": true, "id": 181, "username": "regtest_1795534555", "status": "pending",
 "message": "注册成功，账号待管理员审核后即可登录"}
```

### 5.4 错误码（全部实测确认）

| 场景 | 状态码 | body（真实输出） |
|------|--------|------------------|
| 用户名已存在 | 409 | `{"error": "username already exists"}` |
| 用户名 2 位 | 400 | `{"error": "username 需为 3-32 位字母/数字/下划线/点/横线"}` |
| 用户名含中文 | 400 | `{"error": "username 需为 3-32 位字母/数字/下划线/点/横线"}` |
| 用户名 33 位 | 400 | `{"error": "username 需为 3-32 位字母/数字/下划线/点/横线"}` |
| 缺密码 | 400 | `{"error": "password required"}` |
| 密码 >256 | 400 | `{"error": "password too long"}` |
| 昵称 >64 | 400 | `{"error": "nickname too long"}` |
| 注册关闭（当前不会出现） | 403 | `{"error": "registration closed"}` |

**校验规则（以后端为准）**
- 用户名：`^[A-Za-z0-9_.-]{3,32}$`，**不区分大小写查重**
- 密码：非空，长度 ≤256（**后端无最小长度要求**；Web 提示"至少6位"是前端约束）
- 昵称：可选，≤64 字；**为空时后端自动设为 username**（实测：不传 nickname 注册成功）

### 5.5 注册后行为

- 新用户 `status = "pending"`
- **pending 用户登录 → `401 {"error":"Invalid credentials"}`**（实测确认，与密码错误无法区分）
- 管理员在 Web 后台"待审核注册申请"中通过后变为 `active`，才可登录
- 客户端在 pending 用户尝试登录时，建议提示：
  "用户名或密码错误，或账号正在等待管理员审核"

**管理员二维码**：`https://51play.ccwu.cc/admin_qr.png`
✅ **实测公开可访问**（HTTP 200，129489 bytes，无需 Cookie）。客户端可直接 `Image.network` 加载。

---

## 6. 错误码总表

| 码 | 含义 | body 形态 | 客户端处理 |
|----|------|-----------|------------|
| 200/202 | 成功 | JSON | 正常 |
| 400 | 参数错误 | JSON `{"error": "..."}` | 展示 `error` 文案 |
| 401 | 未登录/会话过期/密码错 | JSON（`/api/*`）或 **HTML**（nginx 媒体路径） | API → 跳登录；媒体 → 尝试续期后重载 |
| 403 | CSRF 失败 / 无权限 / 注册关闭 | JSON | 展示 `error` |
| 404 | 资源不存在 | JSON 或 HTML | 展示"内容不存在" |
| 409 | 冲突（用户名已存在 / 视频已删除） | JSON | 展示 `error` |
| 413 | 请求体过大 | JSON | 提示文件过大 |
| 423 | 账号锁定 | JSON `{"error":"Account locked"}` | 提示"账号已锁定，请 10 分钟后重试" |
| 503 | **nginx 登录限流** | **HTML** | 提示"操作过于频繁，请稍后再试" |

---

## 7. 客户端实现硬性清单

- [ ] Cookie 手动持久化（secure storage），每次请求手动加 `Cookie` 头
- [ ] **不要**手动设置 `Origin` 头（Flutter 默认不带 → 恰好放行）
- [ ] **不要**给媒体请求设置 `Referer` 头
- [ ] `POST` 一律带 `Content-Type: application/json`（上传除外）
- [ ] 登出必须发 `{}` 空 JSON body
- [ ] 登录按钮防连点 + 处理 503 限流
- [ ] 401 统一拦截：先尝试 token 续期（P1 实现后），失败才跳登录
- [ ] `duration` / `size_bytes` / `cover` / `owner_id` 均可能为 null，全部容错
- [ ] 视频 id 格式不可假设，一律当不透明字符串，URL 编码后使用
- [ ] ts 文件名从 m3u8 解析，不拼规则
- [ ] 播放器 httpHeaders 必须带 Cookie
- [ ] 上传用流式（禁止整文件读进内存），2GB 上限
- [ ] 建议 WiFi 上传提示（>300s 会被服务端超时）

---

## 8. 待验证项（P0 遗留，需在对应阶段补测）

| # | 事项 | 影响阶段 | 备注 |
|---|------|----------|------|
| 1 | ~~`admin_qr.png` 是否需要登录~~ | P7 | ✅ **已实测：公开可访问 200，无需 Cookie** |
| 2 | ~~注册开关是否开启~~ | P7 | ✅ **已开启**（`SITEAUTH_ALLOW_REGISTER=1`），注册全流程已实测通过 |
| 3 | 大文件（>500MB）上传真实表现 | P6 | 只测过 79KB 小文件 |
| 4 | 并发上传（第 2 个任务 queued 表现） | P6 | 需两个大文件 |
| 5 | 30 分钟会话过期中途播放的中断表现 | P5 | 需长时间播放验证 |

---

## 9. 实测环境记录

```
实测时间：2026-11-24 23:13 ~ 23:40 (UTC+8)
实测主机：64.90.31.17（服务器本机，与客户端同链路）
实测账号：user（role=user, id=6）
服务端代码 md5：
  multiuser.py      41864d0ada7668e2f49d6f5dfc5f1cb6
  siteauth_server.py 1f7eb03db99e8f2ee540a5c9c4df0384
  videos.py         8fb35e26de94911346919499e6b82470
  admin.py          7f56fa253afbad16c0cf3b10d91ba37e
systemd 关键环境变量：
  SITEAUTH_LEGACY_LOGIN=off     ← 注意：legacy 单密码登录已关闭
  SITEAUTH_ALLOW_REGISTER=1     ← 注册已开启（23:36 由 0 改为 1）
  SESSION_MAX_AGE=1800
  DB_PATH=/opt/siteauth/site.db
nginx 登录限流：limit_req_zone $binary_remote_addr zone=login:10m rate=15r/m; burst=5
```

### 9.1 P0 期间对生产环境的变更记录

| 时间 | 变更 | 原因 | 备份 |
|------|------|------|------|
| 23:36 | `SITEAUTH_ALLOW_REGISTER` 0 → 1，重启 siteauth | Web 前端有完整注册表单但后端开关关闭，导致网页注册必失败（真实线上故障） | `/root/site-backups/env.conf.bak_*` |

测试产生的探针视频、注册用户、上传任务均已清理，环境已复原（33 条 ready、仅 admin/user 两账号）。

> **重要变更提示**：`SITEAUTH_LEGACY_LOGIN=off` 表示**旧的单密码登录方式已停用**，
> 必须用数据库账号（如 user）登录。任何依赖 legacy 登录的脚本都会失效。
