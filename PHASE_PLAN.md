# 视频点播安卓客户端 · 分阶段任务书（Flutter）

> 已确认的决策（不再重议）：
> - 技术栈：**Flutter**（仅 Android，暂不做 iOS）
> - 功能范围：**全功能（除 admin 管理）**＝登录/注册/视频广场/搜索/播放/我的/上传/转码进度
> - 分发：**GitHub Releases**（仓库私有，APK 公开下载）
> - 后端：**允许小幅修改**（仅新增 App 长效 token，见 P1 设计）
> - App token 有效期：**30 天**；**需要设备管理**（列出/踢掉设备）
> - GitHub 仓库：**YunYingVOD**，**public**，由 agent 用 PAT 创建
>
> 服务端现状基线：`https://51play.ccwu.cc`（IP 64.90.31.17），后端纯 Python 标准库
> `127.0.0.1:8000` + nginx 反代，SQLite `/opt/siteauth/site.db`，HLS AES-128 加密，
> key URI 为相对路径 `/key/<id>`。详细契约以 P0 产出的 `CLIENT_API_SPEC.md` 为准。

---

## 0. 全局约定（每个阶段都必须遵守）

| 项 | 约定 |
|----|------|
| 本地仓库 | `D:\XiaoYiWork\vod_app\`（Flutter 项目根） |
| 远程仓库 | GitHub 私有仓库（如 `striferxu/vod-app`），main 分支保护，每阶段一个 PR/commit |
| 阶段纪律 | **一次只做一个阶段**；每阶段结束打 tag（`p0`、`p1`…）；禁止顺手做下一阶段的内容 |
| 验收账号 | 用现有 `user` 账号（密码由站长提供）；上传/播放验收不得用 admin 账号 |
| 测试设备 | 一台真机（Android 10+）+ 一个模拟器；验收以**真机**为准 |
| API 基址 | `https://51play.ccwu.cc`，全部 HTTPS；客户端不得硬编码 IP |
| 网络层 | 统一一个 `ApiClient` 类；所有请求手动携带 Cookie（HttpOnly 由客户端自管） |
| 错误处理 | 任何阶段新增的网络调用必须有：超时、401 跳登录、非 2xx 的用户可读错误 |
| 不受 Web 端影响的点 | PC 检测跳转（device-check.js）只作用于网页，**原生 App 不受影响**；CSP 同样不影响；Flutter 的 http 请求默认**不带 Origin 头**，后端 Origin 校验对"无 Origin"放行，**无需处理** |
| 每阶段 DoD | 代码合并 main + 本文档验收清单全勾 + 真机验证记录（截图或日志）归档到 `docs/verify/` |

---

## 阶段总览

| 阶段 | 名称 | 依赖 | 核心风险 |
|------|------|------|---------|
| P0 | API 契约冻结 | 无 | 文档与实况不符（已发生过一次） |
| P1 | 后端小改：App 长效 token | P0 | 动生产服务，需备份+回滚 |
| P2 | Flutter 项目骨架 | P0 | 无（纯脚手架） |
| P3 | 登录与会话 | P1, P2 | Cookie 生命周期管理 |
| P4 | 视频广场 + 我的 | P3 | 封面回退、分页 |
| P5 | 播放器（HLS AES-128） | P3 | **全项目最高风险**：key 请求带 Cookie |
| P6 | 上传与转码进度 | P3 | 2GB 大文件流式上传、300s 代理超时 |
| P7 | 注册（审核制） | P3 | 无 |
| P8 | 打包发布 | P2–P7 | 签名密钥管理、CI |

---

## P0 · API 契约冻结

**目标**：产出客户端唯一可信的接口文档，杜绝"凭印象写"（上次变更文档的归档路径错误就是教训）。

**输入**：
- 服务器 SSH 访问能力（root@64.90.31.17）
- 现有文档 `D:\XiaoYiWork\vod_site\SERVER_CHANGES_FOR_AI_AGENT.md`
- 测试账号 user 的密码（向站长索取）

**产出**：`docs/CLIENT_API_SPEC.md`，覆盖客户端会用到的全部接口：
- `POST /api/login`、`POST /api/logout`、`GET /api/me`、`GET /api/me_full`
- `GET /api/videos`（含 q/page/limit/status 参数）、`GET /api/videos/<id>`
- `GET /api/my_videos`、`GET /api/owners`
- `POST /api/upload`（multipart：video + title）、`GET /api/upload_status/<id>`
- `POST /api/register`
- 媒体路径：`/videos/<id>/output.m3u8`、`/videos/<id>/output_%03d.ts`、`/key/<id>`、`/covers/<id>.jpg`
- 每条接口记录：方法、路径、请求头（Cookie）、请求体示例、**实测响应 JSON 样例**、错误码（400/401/403/404/409/413/423）

**验收标准**：
- [ ] 每条接口都在服务器上用 curl 实测过，文档中的响应样例是**真实拷贝**而非手写
- [ ] 实测登录→拉列表→拉 m3u8→拉 key 全链路（带 Cookie），4 个请求全部 200
- [ ] 实测 3 种错误场景并记录真实响应体：错误密码（401）、无 Cookie 拉视频（401）、上传非视频扩展名（400）
- [ ] 文档明确记录：session Cookie 名 `site_session`、Max-Age 1800 秒、**滑动续期**（任意 API 调用刷新）
- [ ] 文档明确记录：上传体积上限 2GB（nginx `client_max_body_size 2200m`）、代理超时 300s、转码单并发

**禁止做**：不改任何服务器代码/配置。

---

## P1 · 后端小改：App 长效 token

**目标**：解决"session 30 分钟过期，App 每次要重输密码"的问题。设计原则：**媒体请求链路（/videos/ /key/ /covers/ 的 nginx auth_request 走 Cookie）一行不动**，token 只用于静默换取新 session。

**设计**（实现时严格照此，不得发挥）：
1. 新表 `app_tokens`：
   ```sql
   CREATE TABLE app_tokens (
     id            INTEGER PRIMARY KEY AUTOINCREMENT,
     token_hash    TEXT PRIMARY KEY,          -- sha256(token) hex，绝不存明文
     user_id       INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
     device        TEXT,                      -- 设备名，如 "Pixel 7 / Android 14"
     created_at    INTEGER NOT NULL,
     last_used_at  INTEGER,
     last_used_ip  TEXT,
     expires_at    INTEGER NOT NULL           -- created_at + 30 天
   );
   CREATE INDEX idx_app_tokens_user ON app_tokens(user_id);
   ```
2. `POST /api/app/token`（需有效 session Cookie，JSON body `{"device":"Pixel 7 / Android 14"}`）
   → 返回 `{"ok":true,"token":"<明文仅此一次>","expires_at":<30天后>}`；库中只存 sha256
3. `POST /api/app/session`（无 Cookie，请求头 `X-App-Token: <token>`）
   → 校验 token 未过期 → 创建新 session 并 Set-Cookie
   → 同时刷新 `last_used_at` / `last_used_ip`
4. `GET /api/app/tokens`（需 session Cookie）→ 列出**当前用户**已授权设备：
   `{"items":[{"id":1,"device":"Pixel 7","created_at":...,"last_used_at":...,"last_used_ip":"...","expires_at":...,"current":true}]}`
   （`current=true` 标记当前会话对应的那台设备）
5. `DELETE /api/app/tokens/<id>`（需 session Cookie）→ 作废指定设备 token
   （只能删自己的；返回 `{"ok":true}`）
6. **改密码时**：`admin.user_password()` 中追加 `DELETE FROM app_tokens WHERE user_id=?`，
   使该用户全部设备重新登录
7. nginx：`/api/` 前缀已统一反代，`X-App-Token` 头默认透传，**nginx 零改动**
8. 新接口加入 `siteauth_server.py` 路由；审计日志 action：`app.token_issue` / `app.token_login` / `app.token_revoke`

**输入**：P0 的契约文档；服务器现有代码 `/opt/siteauth/siteauth_server.py`、`db.py`、`schema.sql`

**产出**：
- 本地 `D:\XiaoYiWork\vod_site\server\` 更新（siteauth_server.py + schema.sql + 迁移片段）
- 部署到服务器并重启 siteauth
- `docs/APP_TOKEN_SPEC.md`（接口说明 + curl 实测样例）

**验收标准**：
- [ ] 部署前备份：`/root/site-backups/apptoken_<时间>/`（含被改文件 + site.db）
- [ ] curl 实测：登录 → 换 token → 清 Cookie → 用 token 换新 session → 新 session 拉列表 200
- [ ] 错误 token 换 session 返回 401；过期 token 返回 401
- [ ] **回归**：Web 端登录/上传/播放全流程不受影响（浏览器实测）
- [ ] `GET /api/app/tokens` 能列出该用户全部设备，`current` 标记正确
- [ ] `DELETE /api/app/tokens/<id>` 后该 token 换 session 返回 401
- [ ] 用户 A 无法删除用户 B 的 token（越权返回 403/404）
- [ ] 改密码后旧 token 全部失效（实测）
- [ ] 服务重启后 `systemctl is-active siteauth` = active，且原有 18 条视频可播放

**禁止做**：不引入任何第三方依赖；不改 nginx；不动媒体路径鉴权。

---

## P2 · Flutter 项目骨架

**目标**：可编译、可安装的空壳，搭好目录结构与基础设施，后续阶段只往里填功能。

**输入**：P0 契约文档；Flutter stable SDK（本机安装，版本写入文档）

**产出**（目录结构固定，后续阶段不重构）：
```
lib/
  main.dart              # 入口 + 路由表（go_router 或 Navigator 2，二选一定死）
  core/
    api_client.dart      # 单例：基址、Cookie 管理、超时、401 广播
    session_store.dart   # Cookie + app token 持久化（flutter_secure_storage）
    models/              # JSON 模型（video.dart, user.dart, upload_job.dart…）
    widgets/             # 通用组件（错误页、加载态、封面图组件）
  features/
    auth/  videos/  player/  upload/  register/
docs/
  CLIENT_API_SPEC.md     # P0 产出放这里
  verify/                # 验收记录
test/                    # 模型解析与 ApiClient 的单元测试
```

**验收标准**：
- [ ] `flutter analyze` 零 error；`flutter test` 全绿（至少覆盖 1 个模型解析）
- [ ] `flutter build apk --debug` 成功；真机安装启动显示占位首页不崩溃
- [ ] `ApiClient` 具备：超时 15s、自动带 Cookie、401 时通过流广播事件（页面可订阅）
- [ ] `pubspec.yaml` 锁定依赖版本（`flutter pub deps --json` 归档到 docs）
- [ ] README 写清：环境版本、构建命令、目录约定

**禁止做**：不做任何业务页面；不接真实接口（用写死的 mock 数据）。

---

## P3 · 登录与会话

**目标**：完整登录/登出 + 会话保活 + token 静默续期。

**输入**：P2 骨架；P1 的 `APP_TOKEN_SPEC.md`

**产出**：
- 登录页（用户名+密码；提示文案与 Web 端一致）
- 会话管理：启动时若有存留 Cookie → `GET /api/me` 验证；失效但有 app token → `POST /api/app/session` 静默换新；都失效 → 登录页
- 登录成功后调 `POST /api/app/token` 存入 secure storage（device 名取 `Platform.localHostname` 或机型）
- 前台保活：App 回到前台 + 每 10 分钟定时调一次 `/api/me`（滑动续期）
- 登出：`POST /api/logout` + 清 Cookie + **作废 app token**（后端 P1 若未提供作废接口，记录到文档，此阶段先只清本地）

**验收标准**：
- [ ] 真机：user 账号登录成功进入首页；错误密码显示后端真实错误信息（401）
- [ ] 杀进程重开：30 秒内免登录直接进首页（Cookie 仍有效路径）
- [ ] 模拟过期：手动把本地 Cookie 改坏 → 重开 App 走 token 静默换新成功，用户无感知
- [ ] 连续 10 次错密码，第 11 次收到 423 并向用户展示"账号已锁定，请 10 分钟后再试"
- [ ] 登出后再进 App 必须重新登录；`/api/me` 返回 401
- [ ] 弱网（模拟器限速）下登录有加载态，不白屏

**禁止做**：不做注册页（P7）；不做"记住密码"明文存储。

---

## P4 · 视频广场 + 我的

**目标**：两个列表页，数据与 Web 端一致。

**输入**：P3 会话；契约中 `/api/videos`、`/api/my_videos`、`/api/owners`

**产出**：
- 视频广场页：网格/列表双布局切换（沿用 Web 端交互：列表模式显示上传者/时长/播放数/上传时间）、标题搜索（前端过滤或 `?q=`）、下拉刷新
- 我的页：`/api/my_videos`，空态文案"暂无视频，快去上传第一个吧"
- 封面组件：`/covers/<id>.jpg` 失败回退 `/videos/<id>/cover.jpg` 再回退占位图（与 Web 端 `handleCoverFallback` 同逻辑）
- 点击卡片 → 播放页占位（P5 实现，本阶段先 `Scaffold` 占位 + 传 videoId）

**验收标准**：
- [ ] 广场条数 = Web 端条数（当前 18 条 ready），字段逐一对得上
- [ ] 网格/列表切换即时生效且重启 App 记住选择（本地持久化，键名记录到文档）
- [ ] 搜索"IPX"等真实关键词结果与 Web 端一致
- [ ] 断网进入广场：显示可重试的错误页，不崩溃；恢复网络点重试能恢复
- [ ] 封面三段回退逻辑用一张不存在封面的视频实测（可临时改库造数据，测完还原）
- [ ] 我的页与 Web 端"我的"列表一致（user 账号当前为空则显示空态）

**禁止做**：不做播放（P5）；不做上传入口跳转的真实功能（P6）。

---

## P5 · 播放器（HLS AES-128）—— 全项目最高风险阶段

**目标**：真机流畅播放加密 HLS。**成败关键：m3u8、ts 分段、/key/<id> 三类请求都必须带 Cookie**。

**输入**：P4 的播放页占位；契约中媒体路径与鉴权说明

**技术方案（定死，失败才允许换）**：
- `video_player` + `VideoPlayerController.networkUrl(url, httpHeaders: {'Cookie': 'site_session=<token>'})`
- Android 底层 ExoPlayer 会把 httpHeaders 应用到该媒体源的**全部**请求（含 key）
- 播放地址：`/videos/<id>/output.m3u8`（相对 key URI 由播放器基于 m3u8 URL 解析为同源绝对路径）

**产出**：
- 播放页：加载态/错误态/鉴权失效态三态；播放/暂停/进度条/seek；全屏切换（横屏）
- 播放前 `GET /api/videos/<id>` 拿元数据（标题、时长）展示
- 401（Cookie 过期且 token 换新失败）→ 引导去登录

**验收标准**：
- [ ] **真机播放现有 18 条中至少 3 条不同来源的视频**（含一条 `tw_` 前缀、一条 8 位 hex id），全部出画有声
- [ ] 抓包或服务端日志确认 `/key/<id>` 请求返回 200 且携带 Cookie（这是硬性验收，不能只看"能播"）
- [ ] seek 到任意位置正常；横竖屏切换不中断播放（或可控重建）
- [ ] 飞行模式中途断网：显示错误态 + 重试按钮，恢复后重试成功
- [ ] 后台切换 App 再回来：恢复播放或显示可恢复状态，不崩溃
- [ ] 若 `video_player` 无法带 Cookie 拉 key（黑屏/403）：备选方案 `media_kit`，切换决策记录到文档，**不得静默换库**

**禁止做**：不做倍速/字幕/下载缓存（明确不做，避免范围膨胀）。

---

## P6 · 上传与转码进度

**目标**：选视频 → 上传 → 转码进度（百分比+ETA）→ 完成出现在"我的"。

**输入**：P3 会话；契约中 `/api/upload`、`/api/upload_status/<id>`

**产出**：
- 上传页：系统文件选择器（`file_picker`，限定视频类型）+ 标题输入
- 上传实现：**流式** multipart（dio 的 `MultipartFile.fromStream`，禁止 `readAsBytes` 整读进内存）；显示上传进度
- 上传成功（202 返回 job_id）→ 轮询 `/api/upload_status/<job_id>`（2 秒间隔），展示 percent + eta_seconds（文案格式与 Web 端一致："约 X 分钟"）
- 状态机：queued → running → done（提示成功并可跳"我的"）/ failed（展示后端 error 字段）
- 转码期间可离开页面，回到页面恢复轮询（job_id 持久化到本地）

**验收标准**：
- [ ] 真机（WiFi）上传 ~100MB mp4 全流程走通：进度条到 100% → 转码进度推进 → done → "我的"出现新视频 → 可播放（走 P5）
- [ ] 上传中杀 App 重开：能从"我的/上传记录"恢复查看该任务进度（后端任务不丢）
- [ ] 选非视频文件被拒绝（前端过滤 + 后端 400 双保险，400 的真实错误文案展示）
- [ ] 转码排队（若服务器正忙）时状态显示 queued 而非卡死
- [ ] 上传中断网：明确报错，不残留假进度
- [ ] 上传后 Web 端也能看到该视频（owner 归属正确，显示 user 的昵称）

**风险预告**：移动网络上传 >300s 会被 nginx 掐断（`proxy_read_timeout 300s`），本阶段验收只要求 WiFi 下 2GB 内可靠；蜂窝网络大文件列为已知限制写入文档，**不在本阶段解决**。

**禁止做**：不做断点续传/分片（后端不支持，明确不做）。

---

## P7 · 注册（审核制）

**目标**：新用户在 App 内注册，与 Web 端注册体验一致。

**输入**：P3 会话；契约中 `POST /api/register`（§5）；二维码 URL `https://51play.ccwu.cc/admin_qr.png`（已实测公开可访问 200）；Web 端注册页截图（UI 对齐）

> 注：注册开关已由站长确认开启（`SITEAUTH_ALLOW_REGISTER=1`），接口全流程已实测通过。

**产出**：
- 注册页：用户名/昵称/密码；提交前本地校验用户名规则 `^[A-Za-z0-9_.-]{3,32}$`（与后端一致，错误提示同文案）
- 提交成功（200, status=pending）：展示"注册成功，账号待管理员审核后即可登录"+ 管理员微信二维码（`Image.network` 拉取上述 URL，失败可重试）
- 登录页加"没有账号？去注册"入口

**验收标准**：
- [ ] 真机提交注册 → 200 返回；Web 管理后台"待审核"出现该用户
- [ ] 重复用户名返回 409，App 展示后端真实错误
- [ ] 非法用户名（如 2 位、含中文）前端拦截，文案与后端 400 一致
- [ ] 二维码真机可见可放大保存（或至少清晰展示）
- [ ] 用 pending 账号尝试登录：401，App 提示"账号待审核"（若后端对 pending 返回的也是 401 Invalid credentials，则文案统一为"用户名或密码错误，或账号待审核"，**以后端实测为准记录到文档**）

**禁止做**：不做审核操作（admin 功能留在 Web 端）。

---

## P8 · 打包发布（GitHub Releases）

**目标**：一条 push 自动出签名 APK 并发布。

**输入**：P2–P7 全部完成；GitHub 账号（striferxu）

**产出**：
- 签名：本地生成 keystore（`vodapp.jks`，口令由站长保管，**不入库**）；`key.properties` 进 `.gitignore`；CI 用 GitHub Secrets 注入
- `.github/workflows/release.yml`：tag push（`v*`）触发 → `flutter build apk --release` → 签名 → 创建 GitHub Release 并附 APK
- 版本管理：`pubspec.yaml` 版本与 tag 一致；Release Notes 模板（变更点 + 已知限制）
- `docs/RELEASE.md`：keystore 丢失=无法升级安装的警告、备份要求、发版步骤

**验收标准**：
- [ ] 打 `v0.1.0` tag → CI 全绿 → Releases 页出现 APK
- [ ] **干净设备**（无开发环境）浏览器下载 APK 直接安装成功
- [ ] 覆盖安装（旧版本在、装新版本）成功且登录态保留（secure storage 未丢）
- [ ] APK 为 release 签名（`apksigner verify` 通过），minSdk 与真机验收记录一致
- [ ] 仓库中无 keystore、无密码、无 API 基址以外的敏感信息（自查 + `git log -p` 抽查）

**禁止做**：不上传 keystore 到任何远程；不做 Play Store 上架。

---

## 附：跨阶段已知限制（写进 App 的"关于"页与 Release Notes）

1. 蜂窝网络上传大文件（>300s）可能被服务端超时中断 —— 仅建议 WiFi 上传
2. 转码服务器单并发，多人同时上传需排队
3. admin 管理功能（用户审核/视频管理）请使用 Web 端
4. App 长效 token 有效期 90 天，改密码后所有设备需重新登录

## 附：验收所需资源清单（站长提供）

- [ ] user 账号密码（P0/P3 起全程需要）
- [ ] 一台 Android 10+ 真机（开 USB 调试）
- [ ] GitHub 仓库创建权限 + Actions 开启
- [ ] keystore 口令保管人确认（P8）
