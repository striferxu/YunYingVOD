# P7 验收记录 · 注册（审核制）

> 阶段目标（PHASE_PLAN.md P7）：新用户在 App 内注册，与 Web 端注册体验一致。
>
> **结论：全部通过。** 真机（Samsung SM-F9360 / Fold4，Android 16，WiFi）实测
> 五项验收标准全过；服务端接口层另有 8 组边界用例全部通过。

- 验收日期：2026-11-25
- 设备：Samsung SM-F9360（Fold4），Android 16，arm64-v8a，904×2316 @420dpi
- 网络：WiFi（192.168.9.102），服务器 `64.90.31.17`
- 测试账号：`user` / `123456`（正常用户，用于回归）
- 构建：`flutter build apk --debug`，APK 241,862,647 bytes

---

## 1. 验收清单

| # | 验收标准（任务书） | 结果 | 证据 |
|---|---|---|---|
| 1 | 真机提交注册 → 200 返回；Web 管理后台「待审核」出现该用户 | ✅ 通过 | 见 3.1 / 3.2 |
| 2 | 重复用户名返回 409，App 展示后端真实错误 | ✅ 通过 | 见 3.3 |
| 3 | 非法用户名（2 位、含中文）前端拦截，文案与后端 400 一致 | ✅ 通过 | 见 3.4 |
| 4 | 二维码真机可见可放大保存 | ✅ 通过 | 见 3.5 |
| 5 | pending 账号尝试登录：401，App 提示"账号待审核" | ✅ 通过 | 见 3.6 |

附加回归：正常账号 `user` 登录仍成功，P7 改动未影响既有登录链路（见 3.7）。

---

## 2. 实现概要

### 2.1 文件变更

**新增**

| 文件 | 说明 |
|---|---|
| `lib/core/models/register_result.dart` | 注册响应模型（id/username/status/message）+ 用户名规则文案常量 |
| `test/p7_test.dart` | P7 单测 18 条 |

**重写**

| 文件 | 说明 |
|---|---|
| `lib/features/register/register_page.dart` | P2 占位页 → 完整注册页（表单 + 本地校验 + 审核说明 + 二维码 + 成功页 + 全屏二维码查看） |

**修改**

| 文件 | 改动 |
|---|---|
| `lib/core/auth_controller.dart` | 新增 `register()`、`usernamePattern`、`_translateRegisterError()`、`_humanizeRegister400()`；401 登录文案补充"或账号正在等待管理员审核" |
| `lib/features/auth/login_page.dart` | 文档注释同步 P7 文案 |
| `test/auth_test.dart` | 401 文案断言同步 |

### 2.2 关键设计

1. **校验规则双端逐字一致**
   前端 `AuthController.usernamePattern = RegExp(r'^[A-Za-z0-9_.-]{3,32}$')`
   与后端 `multiuser.USERNAME_RE` 完全等价；错误文案
   `用户名需为 3-32 位字母/数字/下划线/点/横线` 与后端 400 的
   `username 需为 3-32 位字母/数字/下划线/点/横线`（去掉前缀）以及 Web 端
   `app.js:140` 三处一致。

2. **校验放在 Controller 而不是只放页面**
   `AuthController.register()` 内部先做一遍校验再发请求。这样即使将来新增
   别的注册入口，规则也不会漏。

3. **密码最小长度按 Web 端约束**
   后端其实只校验非空 + ≤256（`multiuser.register` 里没有最小长度检查），
   但 Web 端强制"至少 6 位"。客户端跟随 Web，保持一致体验。

4. **注册成功不建立会话**
   服务端 200 只建 `pending` 用户，不发 Cookie。所以成功后**不跳首页**，
   而是展示"注册申请已提交"结果页 + 二维码 + 「去登录（审核通过后）」按钮。

5. **401 文案扩展**
   服务端对 `pending` 用户登录返回 `401 {"error":"Invalid credentials"}`，
   与密码错误完全无法区分（刻意防用户枚举）。P7 起文案改为
   `用户名或密码错误，或账号正在等待管理员审核`，让新注册用户知道
   "不是密码错了，可能是还没审核"。

6. **二维码三处保障**
   - 内嵌 104px 缩略图，`Image.network` 直接拉 `https://51play.ccwu.cc/admin_qr.png`
   - 加载失败显示「加载失败 / 点击重试」，点击重建 `Image`（`ValueKey` 换 key）
   - 点击进入全屏 `InteractiveViewer`（0.8×~5×），支持双指缩放，底部提示可截图后用微信从相册识别

---

## 3. 真机验收记录

### 3.1 提交注册 → 200

操作路径：登录页 →「申请注册」→ 填写三个字段 →「提交注册申请」。

填写内容：

```
用户名  p7app_1795619147
昵称    P7AppTest
密码    abc123456
```

结果页（截图 `shots/p7_ok.png` / `p7_ok.xml`）：

```
注册申请已提交

注册成功，账号待管理员审核
注册成功，账号待管理员审核后即可登录

你的账号信息
p7app_1795619147
[待审核]

┌ 📋 本站采用注册审核机制 ──────────────┐
│ 新注册的账号需要经过管理员审核通过后才能登录。│
│ 如有疑问，请扫描下方二维码联系管理员。      │
│  [二维码]  管理员联系方式                │
└────────────────────────────────────────┘

[ 去登录（审核通过后） ]
再注册一个账号
```

### 3.2 服务端与 Web 后台确认

`users` 表（服务器本机查询）：

```
(186, 'p7app_1795619147', 'P7AppTest', 'user', 'pending', '2026-11-25 15:06:02')
```

`status='pending'`，`nickname` 为用户填写的 `P7AppTest`。

管理后台数据源 `/api/admin/pending`（`multiuser.pending_registrations()`）：

```
id | username | nickname | role | status | created
186 | p7app_1795619147 | P7AppTest | user | pending | 2026-11-25 15:06:02
185 | p7nn_1795590077  | p7nn_1795590077 | user | pending | 2026-11-25 15:01:17
184 | p7ok_1795590077  | P7测试用户 | user | pending | 2026-11-25 15:01:17
```

> id=184/185 是接口层探针脚本创建的，用于验证「昵称留空自动回落用户名」
> （185 的 nickname 等于 username，符合后端
> `nickname = (body.get("nickname") or "").strip() or username`）。

**Web 管理后台「待审核注册申请」列表能看到该用户**（同一数据源）。

### 3.3 重复用户名 → 409

在成功页点「再注册一个账号」，用**完全相同的用户名**再次提交。

结果（截图 `shots/p7_dup.png` / `p7_dup.xml`）：

```
[ 该用户名已被占用，请换一个 ]      ← 红色错误条，位于密码框下方
```

- 三个输入框内容**全部保留**（不用重填），便于直接改名重试
- 服务端返回 `409 {"error":"username already exists"}`
- 客户端翻译为中文可读文案（不直接暴露英文原文）

大小写不敏感也验证过（服务端 `COLLATE NOCASE`）：
`p7ok_...` 与 `P7OK_...` 均返回 409。

### 3.4 非法用户名前端拦截

输入 `ab`（2 位）+ 密码 `123`（3 位），点提交，**未发出任何网络请求**：

```
用户名框下方：用户名需为 3-32 位字母/数字/下划线/点/横线
密码框下方：  密码至少 6 位
```

截图 `shots/p7_val1.png` / `p7_val1.xml`。

**与后端文案逐字对比**（服务端实测，`docs/probe_p7.py` 第 4 节）：

| 输入 | 后端返回 |
|---|---|
| `ab`（2 位） | `400 {"error":"username 需为 3-32 位字母/数字/下划线/点/横线"}` |
| 33 位 | 同上 |
| `用户abc`（含中文） | 同上 |
| `abc def`（含空格） | 同上 |
| `abc@def`（含 @） | 同上 |

前端文案 = 后端文案去掉 `username ` 前缀，与 Web `app.js:140` 完全一致。

### 3.5 二维码可见可放大

**内嵌可见**：注册页审核说明框内，104×104 白底二维码正常渲染
（`shots/p7_reg.png` 中 `[108,1410][381,1683]` 为 `android.widget.ImageView`）。

**服务端 access log 佐证**（请求确实来自 App，非 WebView）：

```
112.25.137.237 - - [25/Nov/2026:15:04:08 +0800] "GET /admin_qr.png HTTP/1.1" 200 129489 "-" "Dart/3.14 (dart:io)"
```

- 状态码 200，129489 字节（与契约 §5.2 实测一致）
- UA 为 `Dart/3.14 (dart:io)`，证明是 Flutter 原生 `Image.network`
- 无 Referer，符合契约要求

**点击放大**：点缩略图进入全屏页（截图 `shots/p7_qr_full.png` / `p7_qr_full.xml`）：

```
AppBar: 管理员二维码
主体:   白底二维码，InteractiveViewer 支持 0.8×~5× 双指缩放
底部:   双指缩放查看 · 截图后可在微信「扫一扫」从相册识别
```

缩放后截图 `shots/p7_qr_zoom.png`（639,842 bytes，可见二维码放大且清晰）。

### 3.6 pending 账号登录 → 401 + 待审核提示

用刚注册的 `p7app_1795619147` / `abc123456` 在登录页登录。

结果（截图 `shots/p7_pending_login.png` / `p7_pending_login.xml`）：

```
[ 用户名或密码错误，或账号正在等待管理员审核 ]     ← 红色错误条
```

服务端实测确认返回的是 `401 {"error":"Invalid credentials"}`
（`docs/probe_p7.py` 第 7 节），与密码错误无法区分。

> **与任务书的偏差说明**：任务书允许两种处理——
> 「若后端对 pending 返回的也是 401 Invalid credentials，则文案统一为
> 『用户名或密码错误，或账号待审核』」。实测正是这种情况，故采用统一文案。
> 已记录于此。

### 3.7 回归：正常账号登录不受影响

用 `user` / `123456` 登录 → 成功进入视频广场，可见 34 条视频，
含 P6 上传的 `4P6test100MB`（截图 `shots/p7_relogin.png` / `p7_relogin.xml`）。

---

## 4. 服务端接口层验收（`docs/probe_p7.py`）

在服务器本机（`127.0.0.1:8000`，绕过 nginx）执行，8 组用例全部 PASS：

| # | 场景 | 结果 |
|---|---|---|
| 1 | 合法注册（带昵称） | 200 `status=pending`，id=184 |
| 2 | 重复用户名（同大小写） | 409 `username already exists` |
| 3 | 重复用户名（不同大小写） | 409（`COLLATE NOCASE` 生效） |
| 4 | 用户名 2/33 位、含中文、含空格、含 `@` | 全部 400，文案一致 |
| 5 | 缺密码 / 密码 257 位 / 昵称 65 字 | 400 `password required` / `password too long` / `nickname too long` |
| 6 | 昵称留空 | 200，nickname 自动等于 username（id=185） |
| 7 | pending 账号登录 | 401 `Invalid credentials` |
| 8 | 后台待审核列表 | 见 3.2（通过 DB 直查确认） |

---

## 5. 自动化测试

```
flutter analyze  → No issues found!
flutter test     → All tests passed! (103 条)
```

新增 `test/p7_test.dart` 18 条：

| 分组 | 条数 | 覆盖点 |
|---|---|---|
| 用户名规则 | 7 | 3/32 位边界、2/33 位越界、中文、空格、`@`、`/`、`+`、空串、文案一致性 |
| RegisterResult 解析 | 3 | 完整响应、缺字段兜底、status 非 pending |
| 注册错误文案 | 4 | 409 / 400 / 503 / 403 |
| 登录 401 文案 | 1 | 含"待审核"提示 |
| 前端校验边界 | 3 | 密码 6 位下限、256 上限、昵称 64 上限 |

同步修改 `test/auth_test.dart` 的 401 文案断言。

---

## 6. 已知限制

1. **注册成功后无法在 App 内查看审核进度**
   App 只展示"待审核"，实际审核在 Web 管理后台完成。任务书明确
   「不做审核操作（admin 功能留在 Web 端）」。

2. **二维码依赖外网可达**
   `https://51play.ccwu.cc/admin_qr.png` 走域名。若真机网络对该域名的
   TLS 握手有阻断（P5 已查明的 SNI 阻断问题），二维码会加载失败并显示
   「加载失败 / 点击重试」。实测本机网络下正常（200 / 129489 字节）。

   > 说明：P5 的阻断只针对 ExoPlayer 的 Conscrypt ClientHello 特征；
   > Flutter 的 Dart BoringSSL ClientHello 特征不同，未被阻断，
   > 所以 `Image.network` 正常。

3. **昵称非强制**
   Web 端标了 `*` 但后端允许为空（自动回落用户名）。客户端跟随此行为：
   留空不报错，helper 文案提示"留空则与用户名相同"。

4. **密码强度无校验**
   后端只要求非空 + ≤256，客户端跟随 Web 的"≥6 位"。不做复杂度校验。

---

## 7. 测试数据清理

| 项 | 处理 |
|---|---|
| `p7ok_1795590077`（id=184） | 已删除 |
| `p7nn_1795590077`（id=185） | 已删除 |
| `p7app_1795619147`（id=186，真机创建） | 已删除 |
| 对应 `audit_log` 记录 | 已删除 |
| `/tmp/probe_p7.py` | 保留在服务器 `/tmp`，可随时清理 |

清理后确认：

```
剩余 pending: 0
剩余 p7 用户: 0
```

**注意**：清理后 `p7app_1795619147` 已不存在，App 端当前处于 `user` 登录态。
