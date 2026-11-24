# P2 · Flutter 项目骨架 验收记录

> 验收日期：2026-11-25
> 主机：E480（Windows 11，用户 strif）
> 工程目录：`D:\XiaoYiWork\vod_app`

---

## 一、环境版本（已固化，写入 README）

| 组件 | 版本 | 安装路径 |
|------|------|----------|
| Flutter | **3.50.1** stable（2026-11-20 发布） | `D:\dev\tools\flutter` |
| Dart | 3.14.0 | 随 Flutter |
| JDK | **21.0.13.1+2** LTS（Adoptium/Temurin） | `D:\dev\tools\jdk\jdk-21.0.13.1+2` |
| Android SDK Platform | android-36（另自动补装 34/35） | `D:\dev\tools\android-sdk` |
| Android Build-Tools | 36.0.0 | 同上 |
| Android NDK | 28.2.13676358 (r28c) | 同上（构建时自动装） |
| CMake | 3.22.1 | 同上（构建时自动装） |
| Gradle | 9.5.0（腾讯云镜像分发） | `%USERPROFILE%\.gradle` |
| AGP | 9.3.1 | — |
| Kotlin | 2.4.20 | — |
| minSdk / targetSdk / compileSdk | 24 / 36 / 36 | — |

### 环境变量（已写入用户级，永久生效）

```
JAVA_HOME                = D:\dev\tools\jdk\jdk-21.0.13.1+2
ANDROID_HOME             = D:\dev\tools\android-sdk
ANDROID_SDK_ROOT         = D:\dev\tools\android-sdk
PUB_HOSTED_URL           = https://pub.flutter-io.cn
FLUTTER_STORAGE_BASE_URL = https://storage.flutter-io.cn
PATH += D:\dev\tools\flutter\bin
PATH += D:\dev\tools\jdk\jdk-21.0.13.1+2\bin
PATH += D:\dev\tools\android-sdk\platform-tools
PATH += D:\dev\tools\android-sdk\cmdline-tools\latest\bin
```

### 镜像配置（国内网络必需）

| 用途 | 镜像 |
|------|------|
| Flutter SDK 下载 | `https://storage.flutter-io.cn` |
| pub 包 | `https://pub.flutter-io.cn` |
| Gradle 分发 | `https://mirrors.cloud.tencent.com/gradle/` |
| Maven (google/public/gradle-plugin) | `https://maven.aliyun.com/repository/*` |

> 实测：本机 Clash 代理 7890 **未开启**，全部走国内镜像直连。
> `flutter doctor` 的 Network resources 项会因访问 github.com 超时报警，**不影响构建**。

---

## 二、验收清单逐项核对

### ✅ 1. `flutter analyze` 零 error

```
Analyzing vod_app...
No issues found! (ran in 25.8s)
```

**零 error、零 warning、零 info。**

> 踩坑记录：Flutter 3.50 起 `package:flutter/material.dart` 被标记 deprecated，
> 要求改用 `package:material_ui/material_ui.dart`（官方新包，pub 上版本 1.11.1）。
> 初版 analyze 报 12 条 `deprecated_member_use` info，全部替换 import 后归零。

### ✅ 2. `flutter test` 全绿

```
00:00 +19: All tests passed!
```

19 个用例，覆盖 5 个模型的解析：

| 模型 | 用例数 | 覆盖点 |
|------|--------|--------|
| `Video` | 7 | 真实响应解析、老数据缺字段、空 cover 归一化、时长格式、体积格式、媒体路径、未知状态回退 |
| `VideoPage` | 3 | 正常分页、空数组、items 缺失 |
| `AppUser` | 2 | `/api/me` 解析、admin 角色识别 |
| `AppDevice` | 2 | P1 实测字段解析、lastUsedAt 为 null |
| `IssuedToken` | 1 | `vap_` 前缀 + ttl_days=30 |
| `UploadJob` | 4 | 0-100 归一化、已是 0-1 不重复除、queued 状态、failed 带 error |

**测试数据全部来自 P0/P1 实测真实响应**，不是手写臆造。

### ✅ 3. `flutter build apk --debug` 成功

```
Running Gradle task 'assembleDebug'...  1395.3s
√ Built build\app\outputs\flutter-apk\app-debug.apk
```

APK 校验：

| 检查项 | 结果 |
|--------|------|
| 文件大小 | 159 MB |
| ZIP 完整性 | `testzip()` 无损坏，156 个条目 |
| package name | `cc.ccwu.vod_app` |
| versionName / Code | `1.0.0` / `1` |
| minSdkVersion | 24（Android 7.0） |
| targetSdkVersion | 36 |
| compileSdkVersion | 36 |
| INTERNET 权限 | ✅ 已声明 |
| 含 `libflutter.so` | ✅ |
| 含 `AndroidManifest.xml` | ✅ |
| 应用显示名 | 云影VOD |

> `libapp.so` 不存在是**正常**的：debug 构建走 JIT，AOT 产物只在 release/profile 生成。

### ⚠️ 4. 真机安装启动 —— 待用户执行

**当前无 Android 真机/模拟器连接**（`adb devices` 为空），我无法代跑。

请你执行（APK 路径已就绪）：

```powershell
# 手机开启 USB 调试并连上后
adb install -r D:\XiaoYiWork\vod_app\build\app\outputs\flutter-apk\app-debug.apk
# 或直接把 APK 传到手机点安装
```

预期：启动后显示深色主题首页「视频广场」，底部两个 Tab（广场 / 我的），
广场页有「上传」浮动按钮，中间是占位说明文字。点击不崩溃即通过。

### ✅ 5. ApiClient 三项能力

| 要求 | 实现 | 位置 |
|------|------|------|
| 超时 15s | `static const Duration defaultTimeout = Duration(seconds: 15)`，所有请求走 `.timeout(timeout)` | `lib/core/api_client.dart` |
| 自动带 Cookie | `_cookies` 内存罐 + `_absorbCookies()` 解析 `Set-Cookie`，每次请求自动拼 `Cookie` 头 | 同上 |
| 401 广播 | `StreamController<void>.broadcast()`，`onUnauthorized` 供页面订阅；`main.dart` 已接线清本地 Cookie | 同上 + `main.dart` |

额外做了三件 P0 踩过的坑：

1. **写接口强制发 `{}`**：`POST`/`DELETE` 即使无 body 也发 `{}` + `Content-Type: application/json`，
   否则服务端 403 `CSRF check failed`（P0 实测坑）。
2. **503 单独处理**：nginx 限流返回 HTML，不尝试 JSON 解析，直接抛"请求过于频繁"。
3. **非 JSON 响应兜底**：截断到 120 字符再抛错，避免把整页 HTML 塞进异常信息刷屏。

### ✅ 6. `pubspec.yaml` 锁定依赖 + `flutter pub deps --json` 归档

依赖清单（全部锁定主版本）：

```yaml
dependencies:
  flutter: sdk
  cupertino_icons: ^1.0.8
  material_ui: ^1.11.1          # Flutter 3.50 起替代 flutter/material.dart
  http: ^1.2.2                  # 不用 dio，保持轻量
  flutter_secure_storage: ^9.2.2 # Cookie/token 加密存储
  go_router: ^14.6.2            # Navigator 2 声明式路由，已定死
  provider: ^6.1.2              # 轻量状态管理
  intl: ^0.20.1                 # 时间格式化
dev_dependencies:
  flutter_test: sdk
  flutter_lints: ^6.0.0
```

依赖树已归档：`docs/verify/pub_deps.json`

### ✅ 7. README 写清环境/构建/目录约定

见工程根 `README.md`。

---

## 三、目录结构（已按任务书固化，后续不重构）

```
lib/
├── main.dart                      入口：主题 + 路由 + 401 广播接线
├── core/
│   ├── api_client.dart            单例 HTTP 出口：15s 超时 / Cookie 罐 / 401 广播 / 二进制下载
│   ├── session_store.dart         secure storage：Cookie、app token、deviceId
│   ├── router.dart                go_router 路由表（9 条路由已定死）
│   ├── theme.dart                 深色主题 + 设计常量（颜色/间距/圆角）
│   ├── models/
│   │   ├── video.dart             Video / VideoPage / VideoStatus
│   │   ├── user.dart              AppUser / AppDevice / IssuedToken / UserRole
│   │   └── upload_job.dart        UploadJob / UploadStatus
│   └── widgets/
│       ├── state_views.dart       LoadingView / ErrorView / EmptyView
│       └── cover_image.dart       带 Cookie 的封面图 + 占位回退
└── features/
    ├── auth/login_page.dart       P3 填
    ├── videos/home_page.dart      广场 + 我的 Tab 容器（占位）
    ├── videos/my_page.dart        P4 填
    ├── videos/video_detail_page.dart  P4 填
    ├── player/player_page.dart    P5 填（HLS AES-128，最高风险）
    ├── upload/upload_page.dart    P6 填
    └── register/register_page.dart P7 填
test/
└── models_test.dart               19 个用例，全绿
docs/
├── CLIENT_API_SPEC.md             P0 产出
├── OPEN_QUESTIONS.md              P0 决策记录
├── P1_APP_TOKEN_SPEC.md           P1 产出
├── P2_ACCEPTANCE.md               本文件
├── probe_p0{,b,c,d,e}.py          P0 探针
├── probe_p1.py                    P1 探针
├── server_snapshot/               线上代码快照
└── verify/                        验收证据（pub_deps.json、apk 元信息等）
```

---

## 四、路由表（已定死，P3-P8 不再改）

| 路径 | 页面 | 阶段 |
|------|------|------|
| `/` | 首页（= 广场） | P2 占位 |
| `/login` | 登录 | P3 |
| `/videos` | 视频广场 | P4 |
| `/videos/:id` | 视频详情 | P4 |
| `/player/:id` | 播放 | P5 |
| `/upload` | 上传 | P6 |
| `/register` | 注册 | P7 |
| `/me` | 我的 | P4 |
| 其他 | 404 页（带回首页按钮） | — |

---

## 五、踩坑与决策记录

### 1. Flutter 3.50 的 `material.dart` 废弃

**现象**：`flutter analyze` 报 12 条 `deprecated_member_use`，
"Use package:material_ui/material_ui.dart instead"。

**决策**：直接迁移到 `material_ui`，而不是压掉 lint。
理由：`flutter create` 生成的模板本身也 import 这个包，说明是官方方向；
现在迁移成本最低（只改 import 行），等到 P4-P7 写完再迁就贵了。

**结果**：迁移后 `analyze` 归零，19 个测试全过，APK 构建成功。

### 2. Gradle 分发下载失败

**现象**：`java.net.SocketException: 连接重置`，卡在 wrapper 下载 `gradle-9.5.0-all.zip`。

**修复**：改 `gradle-wrapper.properties` 的 `distributionUrl` 指向腾讯云镜像
（实测 `mirrors.cloud.tencent.com/gradle/` 返回 206，支持断点续传）。

### 3. Maven 依赖慢

**修复**：`settings.gradle.kts` 和 `build.gradle.kts` 的 `repositories` 前置阿里云镜像，
保留 `google()` / `mavenCentral()` 作回落。

### 4. Windows 符号链接需开发者模式

**现象**：`flutter pub get` 报 "Building with plugins requires symlink support"。

**影响**：**仅影响 Windows 桌面构建**。Android 构建不需要符号链接。

**处理**：删除 `windows/` 平台目录（本项目只做 Android），
并 `flutter config --no-enable-windows-desktop`。
尝试通过注册表开启开发者模式需要管理员权限，当前会话没有，**已放弃**。

> 如果将来要做 Windows 桌面版，需要管理员执行：
> `reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1`

### 5. 首次构建耗时 23 分钟

**原因**：Gradle 自动补装了 NDK r28c（约 1GB）、SDK Platform 34/35、CMake 3.22.1。
**第二次起增量构建**：约 1-2 分钟。

---

## 六、P2 明确没做的事（遵守任务书"禁止做"）

- ❌ 没有任何业务页面（全部是占位 `EmptyView`）
- ❌ 不接真实接口（`ApiClient` 已就绪但没有页面调用）
- ❌ 没写登录表单、没写列表、没写播放器

---

## 七、下一步（P3）输入就绪情况

| P3 需要 | 状态 |
|---------|------|
| P2 骨架 | ✅ 完成 |
| P1 的 app token 接口 | ✅ 已上线并实测 25/25 |
| `P1_APP_TOKEN_SPEC.md` | ✅ 已写 |
| `ApiClient` / `SessionStore` | ✅ 已实现 |
| user 账号密码 | ⚠️ 仍是 `123456`，你说会改 |

**P3 可以直接开工。**
