# 云影 VOD 安卓客户端 · 项目总览（P0–P8）

> 本文件是各阶段验收文档的**汇总入口**。细节以对应阶段文档为准，
> 本文件只记录：每阶段做了什么、验收结论、踩过什么坑、当前线上/仓库状态。
>
> - 仓库：`striferxu/YunYingVOD`（public）
> - 服务端：`https://51play.ccwu.cc`（IP `64.90.31.17`，nginx 反代 → `siteauth` `127.0.0.1:8000`）
> - 首个正式版本：`v0.1.0`；当前版本：`v0.1.1`（versionName `0.1.1`）
> - 汇总更新：2026-11-25

---

## 0. 阶段总览表

| 阶段 | 内容 | 结论 | Tag | 关键产出 |
|---|---|---|---|---|
| P0 | API 契约冻结 | ✅ 全部实测冻结 | `p1-p2-done`（含 P0） | `docs/CLIENT_API_SPEC.md`、`docs/OPEN_QUESTIONS.md` |
| P1 | 后端 app token（4 接口） | ✅ 已上线，25/25 + 9/9 实测 | 同上 | `docs/P1_APP_TOKEN_SPEC.md` |
| P2 | Flutter 项目骨架 | ✅ analyze 0 / 19 测试 / APK 成功 | `p1-p2-done` | `docs/P2_ACCEPTANCE.md` |
| P3 | 登录与会话 | ✅ 16/16 探针 + 真机；修 2 个真机 bug（P3.1/P3.2） | `p3-done` | `docs/P3_ACCEPTANCE.md` |
| P4 | 视频广场 + 我的 | ✅ 真机全过（33 条 ready） | `p4-done` | `docs/P4_ACCEPTANCE.md` |
| P5 | 播放器（HLS AES-128） | ✅ 真机全过（经本地媒体代理绕过 SNI 阻断） | `p5-done` | `docs/P5_ACCEPTANCE.md` |
| P6 | 上传与转码进度 | ✅ 真机全过（99.5MB 全流程）；修 key URI 缺陷 | `p6-done` | `docs/P6_ACCEPTANCE.md` |
| P7 | 注册（审核制） | ✅ 真机全过 + 服务端 8 组边界全过 | `p7-done` | `docs/P7_ACCEPTANCE.md` |
| P8 | 打包发布（GitHub Releases） | ✅ CI 17 步全绿，Release 已发布 | `p8-done` / `v0.1.0` | `docs/P8_ACCEPTANCE.md`、`docs/RELEASE.md` |

**总状态：P0–P8 全部完成并验收通过。** 代码位于 `main`，当前提交见 `git log`。

---

## 1. 各阶段要点

### P0 · API 契约冻结

- 产出 `docs/CLIENT_API_SPEC.md`：客户端**唯一可信**接口依据，所有响应样例均为服务器实测真实输出。
- 覆盖：登录/登出/`/api/me`/`/api/me_full`、视频列表与详情、`my_videos`、`owners`、上传与状态、注册、媒体路径（`/videos/<id>/output.m3u8`、`/key/<id>`、`/covers/<id>.jpg`）。
- 关键基线：Cookie 名 `site_session`，Max-Age 1800s，**滑动续期**；上传上限 2GB，代理超时 300s，转码单并发。
- 决策留痕 `docs/OPEN_QUESTIONS.md`：Q1 注册（审核制，且当时线上注册开关实际是关的，已开启）、Q2 app token 30 天 + 设备管理、Q3 仓库名、Q4 已知限制接受。

### P1 · 后端 app token

- 新增 `app_tokens` 表与 4 个接口：签发 / 换 session / 列设备 / 踢设备。
- 令牌 `vap_` 前缀，30 天固定有效期，DB 只存 sha256；`MAX_DEVICES_PER_USER=20`。
- 作废策略三条：改密码、停用账号、用户手动踢除。
- 实测：主链路 25/25、改密/停用作废链路 9/9。

### P2 · Flutter 骨架

- 环境固化：Flutter 3.50.1 / Dart 3.14.0 / JDK 21 / Android SDK 36 / Gradle 9.5.0 / AGP 9.3.1 / Kotlin 2.4.20，minSdk 24、targetSdk 36。
- `flutter analyze` 零问题、19 个单测全绿、debug APK 构建成功。
- 踩坑：Flutter 3.50 起 `package:flutter/material.dart` 废弃 → 统一 `package:material_ui/material_ui.dart`；Gradle/Maven 需国内镜像；Windows 首次构建 23 分钟。

### P3 · 登录与会话

- `AuthController`（会话状态机，唯一真相源）：Cookie → `/api/me` → app token 交换；10 分钟保活；401 广播；本机 token 被踢 → 登出。
- 服务端探针 16/16。
- **P3.1 真机 bug**：设备管理页累积重复设备。根因：服务端 `list_tokens` 未传 `current_token_id`（`current` 恒 false）→ 客户端登出时找不到本机 token 从不删除。修复：本地存 token id 精确删除 + 服务端按 `(user_id, device_name, platform)` 去重（`probe_dedup.py` 5/5）。
- **P3.2 真机 bug**：移除设备后不退出登录（三层根因）。修复后行为：本机立即掉线，其他设备最多 10 分钟（下次保活）感知。

### P4 · 视频广场 + 我的

- 广场列表（33 条 ready）、搜索、布局切换（键名 `home_layout`，与 Web localStorage 同名）、封面三段回退、我的视频空态、播放页占位。
- **与任务书 2 处偏差**（按实际代码实现）：封面回退顺序以 `vod_site/web/app.js` 为准；广场条数以实测 33 条为准。
- 测试 56 条（P2 19 + P3 15 + P4 22）。

### P5 · 播放器（全项目最高风险）

- 技术方案未换库（仍是 `video_player`/ExoPlayer），改用 **App 内本地媒体代理** `lib/core/media_proxy.dart`：ExoPlayer 只连 `http://127.0.0.1:<port>`，上游 HTTPS 由 Dart（BoringSSL，大 ClientHello）完成并注入 Cookie。
- 根因取证：网络侧按 TLS ClientHello 的 **SNI + 包长**阻断 `*.ccwu.cc`；Android Conscrypt ClientHello 小（~465–517B）被 RST，Dart BoringSSL 大（~1473B）通过。
- 备选方案 A（IP SAN 证书）失败：Let's Encrypt 拒绝为裸 IP 签发。
- 附带修复：错误态重试按钮"画得出来点不到"（布局溢出 → 紧凑布局 + `SingleChildScrollView`）。
- 硬性验收：`/key/<id>` 请求 200 且带 Cookie；三条不同来源视频（`tw_`、`cklou_`、8 位 hex）出画有声。

### P6 · 上传与转码进度

- dio 流式 multipart（禁 `readAsBytes`）、2 秒轮询、queued→running→done/failed、job 本地持久化可恢复。
- 真机：99.5MB 视频上传 7.5 分钟 → 转码 23s → 出现在"我的"并可播放；杀进程重开可恢复；非视频文件前后端双拦；排队显示 queued。
- **修真实缺陷**：服务端转码产物把 key URI 写成**绝对 URL**，导致 MediaProxy 无法改写、播放器直连被 SNI 阻断 → 黑屏。改为相对 `/key/<id>`，并让客户端 `rewritePlaylist` 兼容本站绝对 URL。
- 附带修复："我的视频"上传者显示"其他用户"（`/api/my_videos` 不返回 `owner_id` → `ownerFallback`）。
- 测试增至 85 条。

### P7 · 注册（审核制）

- 注册页：用户名/昵称/密码，本地校验 `^[A-Za-z0-9_.-]{3,32}$`（与后端 `USERNAME_RE` 逐字一致）。
- 成功 200 `status=pending` + 管理员二维码（可放大）；409 重复用户名；400 格式错误；pending 登录 401 统一文案"用户名或密码错误，或账号正在等待管理员审核"。
- 服务端接口层 8 组边界全过（`docs/tools/probe_p7.py`）。

### P8 · 打包发布

- 签名：`android/vodapp.jks`（30 年有效期，alias `vodapp`，SHA-256 `c76f64ef78f7dc0629c0cb3fb743e3eb3f7811b13180e72aa168a5f1fa577898`）+ `android/key.properties`，**两者均 gitignore，未入库**。
- CI：`.github/workflows/release.yml`，tag `v*` 触发 → 构建 → `apksigner verify`（必须非 debug 证书）→ 创建 Release 附 APK + sha256。
- 版本：versionName 取 tag（`v0.1.0`→`0.1.0`），versionCode 取 `github.run_number`。
- 实测：CI run 17 步全 success；Release 附件 61,335,351 字节，sha256 与官方 `.sha256` 一致；覆盖安装保留登录态。

---

## 2. 关键缺陷与修复一览

| # | 阶段 | 现象 | 根因 | 修复 |
|---|---|---|---|---|
| 1 | P3.1 | 设备管理页重复设备堆积 | 服务端未传 `current_token_id` + 客户端靠 `current` 找本机 token | 本地存 token id 精确删 + 服务端去重 |
| 2 | P3.2 | 移除设备后仍保持登录 | 三层根因（详见 P3 文档 §8） | 修复后本机立即掉线 |
| 3 | P5 | 真机播放黑屏 | 网络按 SNI 阻断 `*.ccwu.cc`（Conscrypt ClientHello 特征） | App 内本地媒体代理（MediaProxy） |
| 4 | P5 | 重试按钮点不到 | 错误态内容超出 16:9 区域，溢出部分不可点击 | 紧凑布局 + 可滚动 |
| 5 | P6 | 新上传视频黑屏 | 服务端把 key URI 写成绝对 URL，MediaProxy 无法改写 | 服务端改相对路径 + 客户端兼容本站绝对 URL |
| 6 | P6 | 我的视频上传者显示"其他用户" | `/api/my_videos` 不返回 `owner_id` | `VideoGrid.ownerFallback` 用当前用户名 |

---

## 2.1 P8 后修正：界面版本号漂移

首次发布后真机自检发现「我的」页脚写死 `云影 VOD  v1.0.0`，与安装包实际
`versionName=0.1.0` 不符。已修正：

- 新增 `lib/core/app_info.dart` 的 `kAppVersion`，页脚改为读常量
- 新增 `test/app_version_test.dart`，读取 `pubspec.yaml` 校验两者一致（防再漂移）
- 重新构建 release（versionCode 2）并在 Fold4 上覆盖安装验证，页脚已显示 `v0.1.0`，
  登录态保留

## 2.2 v0.1.1 发布（含 Web 端缺陷修复）

**App 侧**：`v0.1.1` 由 CI 自动构建发布（run 45581895707 全绿），
相对 `v0.1.0` 的唯一改动是页脚版本号修正（`kAppVersion` 常量 + 一致性测试）。
Release 附件 `yunying-vod-v0.1.1.apk`（61,335,355 字节，sha256
`538a146d7d1f9740d2f20b1d7229bca5330d460b2d9ec455cca9cd12d0ae973d`），
下载后 sha256 与官方附件一致；证书仍为 `CN=YunYing VOD`。

**Web 侧**（与 App 无关，但同批修复）：

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | 首页列表模式上传时间显示 `1970-01-22 02:44` | `fmtDateTime` 只认字符串，`created_at` 是 Unix **秒**整数，`new Date(1795490031)` 被当毫秒 | 数字/纯数字字符串按 `<1e11 视为秒` 处理，其余仍走原逻辑 |
| 2 | 管理后台「上传者」全是「其他」 | `admin.videos_list()` 的 SELECT 漏了 `owner_id`，前端 `ownersMap[v.owner_id]` 恒 undefined | SELECT 补 `owner_id` |

部署：`/var/www/html/app.js`、`/opt/siteauth/admin.py` 已更新并
`systemctl restart siteauth`；备份在 `/root/site-backups/`（`app.js.bak_webtime_*`、
`admin.py.bak_webowner_*`）。验证：`/api/admin/videos` 返回 `owner_id`，
首页列表时间显示正确。

## 3. 当前线上/仓库状态

| 项 | 值 |
|---|---|
| 仓库 | `striferxu/YunYingVOD`（public），main |
| 最新 Release | `v0.1.1`（`yunying-vod-v0.1.1.apk` + `.sha256`） |
| 包名 | `cc.ccwu.vod_app` |
| 显示名 | 云影 VOD |
| minSdk / targetSdk | 24 / 36 |
| 签名证书 | `CN=YunYing VOD`，SHA-256 `c76f64ef…7898` |
| 后端 | `siteauth`（systemd，`127.0.0.1:8000`），DB `/opt/siteauth/site.db` |
| 测试账号 | `user` / `123456`（站长暂未改密码） |
| 单元测试 | 104 条（`flutter test` 全绿） |

---

## 4. 跨阶段已知限制（用户已接受）

1. **蜂窝网络上传大文件**：>300s 会被 nginx 掐断（`proxy_read_timeout 300s`），仅建议 WiFi 上传。
2. **转码单并发**：多人同时上传需排队，状态显示 `queued`。
3. **admin 管理功能**（用户审核、视频管理）只在 Web 端，App 内不做。
4. **app token 有效期 30 天**：改密码后所有设备需重新登录；被踢设备最多 10 分钟感知。
5. **播放器**：不做倍速/字幕/下载（任务书明确禁止）；无播放进度记忆；播放中 Cookie 过期需手动点重试。
6. **设备去重**：同型号同平台的两台手机可能被合并为一条（`(user_id, device_name, platform)` 去重）。
7. **错误文案**：ExoPlayer 原始错误信息为英文，直接透传便于排查。

> 注：`PHASE_PLAN.md` 附录写"app token 有效期 90 天"，属旧文案；**实际实现为 30 天**（见 `OPEN_QUESTIONS.md` Q2）。

---

## 5. 文档索引

| 文档 | 内容 |
|---|---|
| `PHASE_PLAN.md` | P0–P8 分阶段任务书（原始需求） |
| `README.md` | 工程说明、环境、构建命令、目录约定 |
| `docs/CLIENT_API_SPEC.md` | **客户端唯一接口契约**（全部实测） |
| `docs/OPEN_QUESTIONS.md` | P0 决策留痕（Q1–Q4） |
| `docs/P1_APP_TOKEN_SPEC.md` | app token 设计与接口 |
| `docs/P2_ACCEPTANCE.md` | 骨架验收 + 环境踩坑 |
| `docs/P3_ACCEPTANCE.md` | 会话状态机、探针、P3.1/P3.2 真机 bug |
| `docs/P4_ACCEPTANCE.md` | 广场/我的验收、与任务书偏差说明 |
| `docs/P5_ACCEPTANCE.md` | 播放器 + SNI 阻断完整取证 |
| `docs/P6_ACCEPTANCE.md` | 上传/转码 + key URI 缺陷 |
| `docs/P7_ACCEPTANCE.md` | 注册（审核制） |
| `docs/P8_ACCEPTANCE.md` | 签名 + CI + Release 验证 |
| `docs/RELEASE.md` | 发版指南（keystore 备份、Secrets、排查、自查） |
| `docs/server_snapshot/` | 线上服务端代码快照 |
| `docs/verify/` | 验收证据（analyze/test 输出、APK 元信息、真机截图） |
| `docs/tools/` | 服务端探针与一次性运维脚本（历史留档，不再参与构建） |
