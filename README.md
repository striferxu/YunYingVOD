# 云影 VOD · 安卓客户端

云影视频点播网站（https://51play.ccwu.cc）的 Flutter 安卓客户端。

服务端为纯 Python 标准库实现（`http.server` + SQLite + nginx 反代），
客户端通过 Cookie 会话 + 长效 app token 访问。

---

## 当前进度

| 阶段 | 内容 | 状态 |
|------|------|------|
| P0 | API 契约冻结（全部实测） | ✅ |
| P1 | 后端 app_tokens 四接口 | ✅ 已上线，25/25 实测通过 |
| **P2** | **Flutter 项目骨架** | **✅ analyze 零问题 / 19 测试全绿 / APK 构建成功** |
| P3 | 登录与会话 | 待开始 |
| P4 | 视频广场 + 我的 | — |
| P5 | 播放器（HLS AES-128） | — |
| P6 | 上传与转码进度 | — |
| P7 | 注册（审核制） | — |
| P8 | 打包发布 | — |

详见 `PHASE_PLAN.md`。

---

## 环境要求

已在 Windows 11 上验证的版本组合：

| 组件 | 版本 |
|------|------|
| Flutter | 3.50.1 (stable) |
| Dart | 3.14.0 |
| JDK | 21 (Adoptium/Temurin 21.0.13.1+2) |
| Android SDK Platform | 36 |
| Android Build-Tools | 36.0.0 |
| Gradle | 9.5.0 |
| AGP | 9.3.1 |
| Kotlin | 2.4.20 |
| minSdk / targetSdk | 24 / 36 |

### 环境变量

```powershell
JAVA_HOME                = <jdk21 路径>
ANDROID_HOME             = <android-sdk 路径>
ANDROID_SDK_ROOT         = <android-sdk 路径>
PUB_HOSTED_URL           = https://pub.flutter-io.cn
FLUTTER_STORAGE_BASE_URL = https://storage.flutter-io.cn
```

### 国内网络镜像（必需）

| 用途 | 配置位置 |
|------|----------|
| Flutter SDK / 引擎产物 | 环境变量 `FLUTTER_STORAGE_BASE_URL` |
| pub 包 | 环境变量 `PUB_HOSTED_URL` |
| Gradle 分发 | `android/gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl` |
| Maven 依赖 | `android/settings.gradle.kts` + `android/build.gradle.kts` 的 `repositories` |

---

## 构建命令

```powershell
# 拉依赖
flutter pub get

# 静态检查（必须零问题）
flutter analyze

# 单元测试
flutter test

# 构建 debug APK
flutter build apk --debug
# 产物：build\app\outputs\flutter-apk\app-debug.apk

# 构建 release APK（P8 配置签名后可用）
flutter build apk --release --split-per-abi
```

### 安装到真机

```powershell
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

---

## 目录约定

```
lib/
├── main.dart              入口：主题、路由、401 广播接线
├── core/                  跨 feature 的基础设施
│   ├── api_client.dart    唯一 HTTP 出口（15s 超时 / Cookie 罐 / 401 广播）
│   ├── session_store.dart Cookie 与 app token 的安全存储
│   ├── router.dart        go_router 路由表（路径已定死，后续不重构）
│   ├── theme.dart         深色主题与设计常量
│   ├── models/            JSON 模型（video / user / upload_job）
│   └── widgets/           通用组件（加载/错误/空态、带鉴权封面图）
└── features/              按业务域分目录，一个目录一个阶段
    ├── auth/              P3 登录
    ├── videos/            P4 广场、我的、详情
    ├── player/            P5 播放（HLS AES-128）
    ├── upload/            P6 上传
    └── register/          P7 注册

test/                      单元测试
docs/                      契约、验收记录、探针脚本
```

**约定**：

1. `core/` 里不许 import `features/`。
2. 每个 feature 目录只放自己的页面与局部组件，跨 feature 复用的提到 `core/widgets/`。
3. 所有网络请求必须走 `ApiClient()`，不许直接 `http.get`。
4. 路由路径只在 `core/router.dart` 定义，页面里用 `AppRoutes.xxx` 引用。

---

## 关键服务端约束（写代码前必读）

这些是 P0/P1 实测出来的真实行为，不是文档推测：

1. **写接口必须发 JSON 且至少 `{}`**
   `POST` / `DELETE` / `PUT` 若不带 `Content-Type: application/json`，
   或 body 为空，服务端返回 **403 `CSRF check failed`**。
   连 `POST /api/logout` 也必须带 `{}`。

2. **会话 Cookie**
   名称 `site_session`，`HttpOnly; Secure; SameSite=Lax`，`Max-Age=1800`（30 分钟），
   **滑动续期**——任意 API 调用都会刷新过期时间。

3. **app token 是 30 天固定有效期，不滑动**
   只用于 `POST /api/app/session` 换新 session，不直接用于业务请求。

4. **媒体链路需鉴权**
   `/videos/`、`/key/`、`/covers/` 都走 nginx `auth_request`，**必须带 Cookie**。
   所以封面图不能用裸 `Image.network`，要用 `CoverImage` 组件。

5. **HLS 是 AES-128 加密**
   m3u8 里的 key URI 是相对路径 `/key/<id>`；ts 文件名不统一
   （`output0.ts` vs `output_000.ts`），不要硬编码。

6. **错误码约定**

   | 码 | 含义 | 客户端处理 |
   |----|------|-----------|
   | 400 | 参数错误 | 展示后端 `error` 字段 |
   | 401 | 未授权 / 密码错 | 跳登录 |
   | 403 | CSRF 或权限不足 | 检查请求头 |
   | 404 | 资源不存在 | 展示空态 |
   | 409 | 冲突（用户名已存在） | 提示换一个 |
   | 413 | 请求体过大 | 提示文件太大 |
   | 423 | 账号锁定（第 11 次错密码，锁 600s） | 提示"10 分钟后再试" |
   | 503 | nginx 限流（登录 15r/m burst=5） | 提示"请求过于频繁" |

7. **上传限制**
   单文件 2GB（nginx `client_max_body_size 2200m`），代理超时 300s
   → 蜂窝网络传大文件会断，必须提示"建议 WiFi 上传"。
   转码单并发，status 会先出现 `queued`。

---

## 相关文档

| 文档 | 内容 |
|------|------|
| `PHASE_PLAN.md` | P0-P8 分阶段任务书 |
| `docs/CLIENT_API_SPEC.md` | **客户端唯一接口契约**（全部实测） |
| `docs/P1_APP_TOKEN_SPEC.md` | app token 设计与接口 |
| `docs/P2_ACCEPTANCE.md` | P2 验收记录与环境踩坑 |
| `docs/OPEN_QUESTIONS.md` | P0 决策记录 |
| `docs/probe_p0*.py` / `probe_p1.py` | 可复跑的接口探针 |
| `docs/server_snapshot/` | 线上服务端代码快照 |
| `docs/verify/` | 验收证据（analyze/test 输出、依赖树、APK 元信息） |

---

## 服务端仓库

本客户端配套的服务端改动在 `D:\XiaoYiWork\vod_site\server\`：

改动文件：`schema.sql`、`app_tokens.py`（新增）、`siteauth_server.py`、`admin.py`。
