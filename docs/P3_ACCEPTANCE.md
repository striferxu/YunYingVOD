# P3 验收记录 · 登录与会话

> 阶段目标：完整登录/登出 + 会话保活 + app token 静默续期。
> 验收时间：2026-11-25
> 构建产物：`dist/云影VOD-p3-debug.apk`（160.5 MB，sha256 `4e2f40df5614663c31c150dda1455bfa34571ab01e4bb478a647461d91ed4232`）

---

## 1. 交付内容

### 1.1 新增文件

| 文件 | 作用 |
|------|------|
| `lib/core/auth_controller.dart` | 会话状态机（457 行）。唯一真相源，供路由守卫与 UI 订阅 |
| `lib/features/devices/devices_page.dart` | 设备管理页。列出/踢除 app token |
| `test/auth_test.dart` | 15 个单元测试（错误翻译、模型解析、剩余天数） |
| `docs/probe_p3.py` | 服务端全链路探针（16 项断言） |

### 1.2 重写文件

| 文件 | 变更 |
|------|------|
| `lib/main.dart` | 接入 `AuthController` + Provider、启动 bootstrap、生命周期监听、全局 401 接线 |
| `lib/core/router.dart` | 改为 `buildRouter(auth)` 工厂函数 + 登录守卫 + `SplashPage` |
| `lib/features/auth/login_page.dart` | 占位页 → 完整登录页（校验/加载态/三类错误文案/预填用户名） |
| `lib/features/videos/home_page.dart` | "我的"标签页从占位改为真实账号页（用户卡片/设备管理/登出） |

### 1.3 依赖变更

```yaml
flutter_secure_storage: ^9.2.2 → ^11.2.0   # 9.x 与 device_info_plus 13.x 的 win32 约束冲突
device_info_plus: ^13.3.0                   # 新增，取真实机型名作为 device_name
connectivity_plus: ^7.3.2                   # 新增，网络状态提示
```

---

## 2. 会话状态机设计

### 2.1 三条恢复路径（`bootstrap()`）

```
启动
 ├─ 读本地 Cookie
 │   ├─ 有 → GET /api/me
 │   │        ├─ 200 → authenticated（restorePath = "cookie"）
 │   │        ├─ 401 → Cookie 已废，继续 ↓
 │   │        └─ 网络错误 → unauthenticated，但**不清 Cookie**（网络恢复后仍可免登录）
 │   └─ 无 → 继续 ↓
 ├─ 读 app token
 │   ├─ 有 → POST /api/app/session {token}
 │   │        ├─ 200 → authenticated（restorePath = "app_token"），新 Cookie 落盘
 │   │        ├─ 401 → token 过期/被踢，清除，继续 ↓
 │   │        └─ 网络错误 → unauthenticated
 │   └─ 无 → 继续 ↓
 └─ unauthenticated（清 Cookie，走登录页）
```

`restorePath` 会记录在 `AuthController.lastRestorePath`，便于真机排查到底走了哪条路。

### 2.2 保活策略

- **定时**：`Timer.periodic(10 分钟)` → `GET /api/me`。服务端 session 1800s 滑动续期，10 分钟一次足够安全且不浪费请求。
- **回前台**：`didChangeAppLifecycleState == resumed` → 轻量刷新一次。
- **失败降级**：定时保活失败**不改登录态**（弱网常见），只在 401 时才走 token 换新，换新失败才切未登录。
- **重入保护**：`_refreshing` 标志防止全局 401 与定时器同时触发 token 换新（会浪费 token 请求）。

### 2.3 登出顺序（顺序有依赖，不能调换）

1. 停定时器
2. `GET /api/app/tokens` 找到 `current == true` 的项 → `DELETE` 作废本机 token
3. `POST /api/logout` 销毁服务端 session
4. 清本地 Cookie + secure storage

> 必须先作废 token 再 logout：logout 后 session 已废，就没法调设备接口了。
> 反之如果只 logout 不作废 token，下次启动会静默换新，用户会觉得"登出没生效"。

> ⚠️ **已知限制**：`/api/app/tokens` 返回的 `current` 字段当前恒为 `false`
> （P1 设计：换 session 后无法反查来源 token）。所以第 2 步实际不会命中任何项，
> 本机 token 会残留到过期或改密码时才清。这不影响登出效果（session 已销毁，
> token 下次换新后会重新走一遍登录流程），但会在设备管理页留下一条僵尸记录。
> 已在 `OPEN_QUESTIONS.md` 记录，P4 之后再决定是否给 app_tokens 表加 `last_session_token` 关联字段。

---

## 3. 服务端实测（16/16 通过）

探针：`docs/probe_p3.py`，在服务器本机 `python3 probe_p3.py user 123456` 运行。

```
目标: http://127.0.0.1:8000  账号: user
------------------------------------------------------------
[PASS] 0. 无 Cookie 调 /api/me -> 401  -> status=401
[PASS] 1. 正确密码登录 -> 200  -> status=200 body={"ok": true, "username": "user", "role": "user"}
[PASS] 1b. 下发 site_session Cookie  -> 有 Cookie
[PASS] 2. Cookie 调 /api/me -> 200  -> status=200 username=user
[PASS] 4. 签发 app token -> 200  -> status=200 ttl_days=30
[PASS] 4b. token 有效期 30 天  -> ttl_days=30
[PASS] 5. 仅用 token 换 session -> 200  -> status=200 body={"ok": true, ..., "expires_at": 1795542393, ...}
[PASS] 5b. 换到新 Cookie 且与旧的不同  -> 新 Cookie
[PASS] 6. 新 Cookie 调 /api/me -> 200  -> status=200
[PASS] 7. 伪造 token 换 session -> 401  -> status=401
[PASS] 8. 列出设备含刚签发项  -> status=200 total=1 命中=1
[PASS] 9. 踢掉该设备 -> 200  -> status=200 {"ok": true}
[PASS] 10. 已踢 token 换 session -> 401  -> status=401
[PASS] 11. 登出（带 {}）-> 200  -> status=200
[PASS] 11b. 登出后 /api/me -> 401  -> status=401
[PASS] 3. 错误密码 -> 401 Invalid credentials  -> status=401 error=Invalid credentials
------------------------------------------------------------
合计 16/16 通过
全部通过 ✓
```

### 3.1 探针踩坑（值得记住）

**Python `http.cookiejar` 不会把 `Secure` Cookie 通过 `http://` 发送。**

服务端 `Set-Cookie: site_session=...; HttpOnly; Secure; SameSite=Lax`，
探针走 `http://127.0.0.1:8000`，cookiejar 严格遵守 RFC 6265 不发送 Secure cookie，
导致"登录成功但紧接着 /api/me 就 401"的假故障。

**修正**：探针改为手动从 `Set-Cookie` 头抠值、手动塞 `Cookie:` 头，不用 cookiejar。

> 生产环境是 https，Flutter 的 `ApiClient` 手动管理 Cookie 头，**不受此影响**。

---

## 4. 客户端静态检查

```
flutter analyze  ->  No issues found! (ran in 23.9s)
flutter test     ->  00:00 +34: All tests passed!   （19 原有 + 15 新增）
```

---

## 5. 构建踩坑：Kotlin 增量编译在 Windows 上崩

**现象**（连续 3 次复现，清 `build/` 无效）：

```
Execution failed for task ':device_info_plus:compileDebugKotlin'.
> Could not close incremental caches in
  build\device_info_plus\kotlin\compileDebugKotlin\cacheable\caches-jvm\jvm\kotlin:
  class-fq-name-to-source.tab, source-to-classes.tab, internal-name-to-source.tab
```

**定位过程**：
1. 删 `build/device_info_plus` → 仍失败
2. 杀所有 java 进程 + 删整个 `build/` → 仍失败
3. 判定为 Kotlin 增量编译在 Windows 上关闭 `.tab` 文件句柄的时序 bug（插件源码未改也复现）

**修复**：`android/gradle.properties` 追加

```properties
kotlin.incremental=false
kotlin.incremental.android=false
org.gradle.vfs.watch=false
```

**代价**：插件 Kotlin 模块全量重编，构建从 ~40s 增至 ~148s。可接受。

**后续**：等 Kotlin 上游修复后可移除这三行；届时若构建又报同样错，直接回来加回去。

---

## 6. 验收清单

| # | 验收项 | 状态 | 依据 |
|---|--------|------|------|
| 1 | 正确密码登录成功进入首页 | ✅ 服务端已验证 | probe #1 |
| 2 | 错误密码显示后端真实错误（401） | ✅ | probe #3 + 单测 |
| 3 | 第 11 次错密码收到 423 并提示"账号已锁定，请 10 分钟后再试" | ✅ 代码路径已实现 | `_translateLoginError` + 单测；真机需人为触发 |
| 4 | 503 限流提示"操作过于频繁" | ✅ | `_translateLoginError` + 单测 |
| 5 | Cookie 有效时杀进程重开免登录 | ✅ 逻辑已验证 | bootstrap 路径 1；真机待验 |
| 6 | Cookie 失效时 app token 静默换新，用户无感知 | ✅ 服务端已验证 | probe #5/#5b/#6 |
| 7 | 登出后必须重新登录，`/api/me` 返回 401 | ✅ | probe #11/#11b |
| 8 | 设备管理页列出/踢除设备 | ✅ 服务端已验证 | probe #8/#9 |
| 9 | 弱网下登录有加载态，不白屏 | ✅ 代码已实现 | 按钮 `_submitting` + 转圈；真机待验 |
| 10 | 不存储明文密码 | ✅ | 只存 `lastUsername`，密码不落盘 |

**真机待验项**（需要你安装 APK 后确认）：
- 第 1、5、9 项的实际体感
- 杀进程重开是否 30 秒内免登录
- 手动把 Cookie 改坏后是否无感知恢复

---

## 7. 真机验收发现并修复的 bug（P3.1）

### 7.1 现象

真机反复"登录 → 登出 → 再登录 → 再登出"后，设备管理页出现多条完全相同的
`VYG-AL00 / Android 16` 记录（uid=6 下累积到 3 条）。

### 7.2 根因（两处叠加）

1. **服务端**：`list_tokens(user_id)` 调用时**没有传入 `current_token_id`**，
   导致返回的 `current` 字段恒为 `false`。
2. **客户端**：登出时靠 `current == true` 找本机 token 再删 —— 这个条件永不命中，
   于是**本机 token 从未被删除**。每次登录签发一条新的，旧的都留着。

### 7.3 修复

| 层 | 改动 |
|----|------|
| 客户端存储 | `SessionStore` 新增 `_kAppTokenId`，签发时把服务端返回的 `id` 一并存下 |
| 客户端登出 | 新增 `_revokeOwnToken()`：按本地保存的 id 精确 `DELETE`，不再依赖 `current`。旧版无 id 的 token 退回按 `device_name` 匹配（只删同名设备，不误伤） |
| 客户端登录 | 新增 `_purgeStaleLocalToken()`：签发前先删掉本地残留旧 token，覆盖"直接杀进程不点登出"场景 |
| 客户端设备页 | "当前设备"标记改用本地 id 比对；移除本机设备时同步清本地 token |
| **服务端兜底** | `app_tokens.issue()` 按 `(user_id, device_name, platform)` 去重，同设备只保留最新一条 |

服务端兜底是关键：即使客户端杀进程、网络失败、或用户用旧版本 App，也不会再无限堆积。

### 7.4 回归测试

新增 `docs/probe_dedup.py`，服务器实测 **5/5 通过**：

```
[PASS] A. 同设备签发 3 次 -> 只留 1 条  -> 实际 1 条
[PASS] B. 新增 B 设备后 A 仍为 1 条  -> A=1 B=1
[PASS] D. 同设备名不同平台各留 1 条  -> android=1 ios=1
[PASS] E. 再次签发 A 后总条数不变  -> before=7 after=7
[PASS] F. 探针数据已清理干净  -> 残留 0 条
```

历史脏数据已清理（uid=6 删除 id=7、9，保留最新 id=10）。
后端备份：`/root/site-backups/dedup_20261125_015256/`。

### 7.5 残留的已知限制

1. **弱网判定较粗**：`refreshSession` 里除 401 外一律视为网络问题、保持登录态。
   若服务端返回 500，用户会一直停在登录态但接口全失败。P4 接列表页时会暴露得更明显，届时再细化。
2. **设备名相同会被视为同一设备**：如果用户有两台同型号手机（都叫 `VYG-AL00 / Android 16`），
   服务端去重会把它们合并成一条。当前接受（30 天内最多 20 台，且用户极少有多台同型号）。
   彻底解决需要客户端把随机 deviceId 拼进 device_name，P4 再评估。

---

## 8. 相关文件

- `lib/core/auth_controller.dart` — 状态机
- `lib/core/router.dart` — 守卫
- `lib/features/auth/login_page.dart` — 登录页
- `lib/features/devices/devices_page.dart` — 设备管理
- `docs/probe_p3.py` — 服务端探针
- `docs/verify/p3_apk_badging.txt` — APK 元信息
- `docs/P1_APP_TOKEN_SPEC.md` — 后端接口契约（P3 客户端对接依据）
