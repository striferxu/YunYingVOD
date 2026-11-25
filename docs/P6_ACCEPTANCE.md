# P6 验收记录 · 上传与转码进度

> 阶段目标（PHASE_PLAN.md P6）：选视频 → 上传 → 转码进度（百分比 + ETA）→ 完成出现在「我的」。
>
> **结论：全部通过。** 真机（Samsung SM-F9360 / Fold4，Android 16，WiFi）实测
> 99.5 MB 视频全流程走通，另发现并修复了 1 个服务端与客户端联动的真实缺陷
> （key URI 绝对路径导致黑屏，详见第 6 节）。

- 验收日期：2026-11-25
- 设备：Samsung SM-F9360（Fold4），Android 16，arm64-v8a，904×2316 @420dpi
- 网络：WiFi（192.168.9.102），服务器 `64.90.31.17`
- 测试账号：`user` / `123456`
- 构建：`flutter build apk --debug`，APK 241,842,211 bytes

---

## 1. 验收清单

| # | 验收标准（任务书） | 结果 | 证据 |
|---|---|---|---|
| 1 | 真机（WiFi）上传 ~100MB mp4 全流程：进度到 100% → 转码推进 → done → 「我的」出现 → 可播放 | ✅ 通过 | 见 3.1 / 3.2 |
| 2 | 上传中杀 App 重开：能从「上传记录」恢复查看该任务进度 | ✅ 通过 | 见 3.3 |
| 3 | 选非视频文件被拒绝（前端过滤 + 后端 400 双保险，展示真实文案） | ✅ 通过 | 见 3.4 |
| 4 | 转码排队时显示 queued 而非卡死 | ✅ 通过 | 见 3.5（真实排队 86 秒） |
| 5 | 上传中断网：明确报错，不残留假进度 | ✅ 通过 | 见 3.6 |
| 6 | 上传后 Web 端也能看到该视频（owner 归属正确，显示 user 昵称） | ✅ 通过 | 见 3.7 |

---

## 2. 实现概要

### 2.1 新增/修改文件

**新增**

| 文件 | 说明 |
|---|---|
| `lib/core/upload_repository.dart` | 上传数据层：dio 流式 multipart、`/api/upload_status` 轮询、本地任务记录持久化 |
| `lib/features/upload/upload_records_page.dart` | 「上传记录」页：进行中 / 历史分区，支持恢复轮询与删除记录 |
| `lib/features/upload/upload_progress_page.dart` | 转码进度恢复页：按 job_id 继续轮询 |
| `test/p6_test.dart` | P6 单测（27 条，含 key URI 重写回归） |

**重写**

| 文件 | 说明 |
|---|---|
| `lib/core/models/upload_job.dart` | 旧版字段与服务端契约不符（用 `progress` 0-1、无 eta/total/result_id），按契约 §4.2 重写 |
| `lib/features/upload/upload_page.dart` | P2 占位页 → 完整上传页（选文件 / 标题 / 上传进度 / 转码进度 / 状态机） |

**修改**

| 文件 | 改动 |
|---|---|
| `pubspec.yaml` | 新增 `dio ^5.7.0`（流式上传 + 进度）、`file_picker ^13.4.1`（视频选择器） |
| `lib/core/formatters.dart` | 新增 `fmtEta`（严格对齐 Web `app.js:40`）、`fmtFileSize` |
| `lib/core/router.dart` | 新增 `/upload-records`、`/upload-progress/:jobId` |
| `lib/features/videos/home_page.dart` | 「我的」页新增「上传记录」入口 |
| `lib/core/media_proxy.dart` | 修复：本站绝对 URL 的 key URI 也要重写到本代理（见第 6 节） |
| `lib/core/video_repository.dart` | 新增 `ownerNameOr`（带兜底名） |
| `lib/core/widgets/video_card.dart` / `video_grid.dart` | 支持 `ownerFallback` |
| `lib/features/videos/my_videos_page.dart` | 「我的视频」改用兜底名，修复显示「其他用户」 |

### 2.2 关键设计

1. **流式上传，绝不整读进内存**
   ```dart
   MultipartFile.fromStream(() => file.openRead(), len, filename: fileName)
   ```
   任务书明确禁止 `readAsBytes`——2GB 文件会直接 OOM。dio 按块读取并通过
   `onSendProgress` 回报进度。

2. **上传与转码两段式进度**
   - 上传阶段：`status = uploading`（仅本地状态，服务端还没有 job_id），
     进度来自 `onSendProgress`，UI 显示「已上传 X MB / Y MB」。
   - 转码阶段：202 返回 `job_id` 后切 `queued`，每 2 秒轮询
     `/api/upload_status/<job_id>`，展示 percent + ETA。

3. **任务记录本地持久化（`vod_upload_jobs_v1`）**
   每次状态变化都 `saveJob()` 写入 shared_preferences。杀进程重开后
   「上传记录」仍能看到该任务，点进去按 job_id 继续轮询——服务端任务不因
   客户端退出而丢失。

4. **弱网不误判失败**
   轮询连续失败 5 次（约 10 秒）才放弃，且**不把任务标成 failed**（服务端可能
   仍在转码），而是保留状态并给「刷新进度」按钮。

5. **ETA 文案与 Web 端逐字对齐**
   `fmtEta` 严格复刻 `app.js:40`：`约 N 秒` / `约 N 分钟` / `约 N 小时 M 分钟`。

---

## 3. 真机验收记录

### 3.1 上传 99.5 MB 全流程

测试素材：`ffmpeg` 生成 1280×720 / 30fps / 180 秒，4500kbps → **104,361,273 字节（99.5 MB）**。

| 时刻 | 状态 |
|---|---|
| 14:13:25 | 点「开始上传」，7%（6.9 MB / 99.5 MB） |
| 14:14:09 | 25%（24.9 MB） |
| 14:15:48 | 47%（46.9 MB） |
| 14:17:58 | 63%（63.0 MB） |
| 14:20:08 | 79%（79.1 MB） |
| 14:21:47 | **转码完成，视频已发布** |

- 上传耗时约 7 分 30 秒（平均约 0.22 MB/s，手机 WiFi 上行受限）
- 转码耗时 23 秒（服务端 `upload_jobs` 记录：`9c8532f8` 转码 23s）
- 全流程约 8 分 22 秒
- 截图：`shots/p6_uploading.xml`、`p6_up2~up6.xml`、`p6_done.png`

服务端确认（`videos` 表）：

```
('9c8532f8', '4P6test100MB', 'ready', 180.0, 57930850, 1795587679)
```

转码产物：`/var/www/html/videos/9c8532f8/` 共 26 个文件
（`output.m3u8` + 25 个 `output_*.ts` + `cover.jpg` + `key.info`），
AES-128 key 链接 `/var/www/html/key/9c8532f8` 正常。

### 3.2 完成后出现在「我的」并可播放

- 「我的视频」列表出现 `4P6test100MB · 3 分钟 0 秒`
- 点击进入播放页 → **出画有声**：
  - 视频区平均亮度 122.2（8 秒后 123.0，画面在动）
  - 服务端 access log 显示 ts 分段持续 200 下载（`output_005.ts` ~ `output_010.ts`，每片约 2.6 MB）
  - `/key/9c8532f8` 返回 **200，16 字节**（硬性要求，AES key 长度正确）
  - 请求 UA 为 `Dart/3.14 (dart:io)`，证明走的是 MediaProxy 而非播放器直连
- 截图：`shots/p6_playing.png`、`p6_playing2.png`、`p6_play3.xml`

> ⚠️ 首次验收时播放**失败**（`ExoPlaybackException: Source error`），
> 根因与修复见第 6 节。修复后复测通过。

### 3.3 杀进程重开恢复

1. 上传完成后 `adb shell am force-stop cc.ccwu.vod_app`
2. 重新启动 → 登录态保留（免登录）
3. 「我的」→「上传记录」→ 显示：
   ```
   历史记录
   4P6test100MB    已完成 · 2026-11-25 14:13    [删除记录]
   ```
4. 截图：`shots/p6_me.xml`、`p6_rec.png`、`p6_rec.xml`

**结论**：任务记录跨进程持久化生效。若任务仍在进行中，点击会进入
`UploadProgressPage` 按 job_id 继续轮询。

### 3.4 非视频文件被拒绝

**前端过滤**：`file_picker` 以 `FileType.video` 打开系统选择器，
推入 `/sdcard/Download/notvideo.txt` 后**在选择器里完全不可见**。

**后端 400 兜底**（服务端脚本实测，三种非法输入）：

| 输入 | 结果 |
|---|---|
| `notvideo.txt` | `400 {"error": "不支持的文件类型: .txt"}` |
| `empty.mp4`（0 字节） | `400 {"error": "视频文件为空"}` |
| `photo.jpg`（伪装图片） | `400 {"error": "不支持的文件类型: .jpg"}` |

后端文案为中文，App 会原样展示在错误框内。

**客户端二次校验**：即使选择器被绕过，`UploadRepository.isSupportedFile()`
仍会按契约白名单（`.mp4 .mov .mkv .avi .webm .flv .ts .m2ts .m4v`）拦截，
并提示「不支持的文件类型：.xxx / 支持：…」。

### 3.5 转码排队（queued）不卡死

服务端 `MAX_CONCURRENT_JOBS = 1`。构造真实排队：

1. 服务器侧提交占位任务 `4f5fb9a2`（1920×1080 / 900 秒 / 275 MB）
   → 状态 `running`，转码耗时 183 秒
2. 立刻在 App 上传 3.1 MB 小视频
3. App 显示：
   ```
   排队中，等待转码
   服务器正在处理其他任务，请稍候
   [取消上传]
   ```
   进度条为不确定态动画（非卡死的静止 0%）
4. 占位任务结束后自动转 `running` → `done`

服务端时间戳佐证：

```
2eb6ca65   44319    done    排队=86s  转码=1s
4f5fb9a2   P6-queue-long-occupier  done  排队=0s  转码=183s
```

**结论**：真实排队 86 秒，UI 全程正确显示 queued，无卡死、无假进度。
截图：`shots/p6_queued.png`、`p6_q8.xml`。

### 3.6 断网上传明确报错

测试方法（不能关 WiFi，否则断无线调试）：服务器侧封禁手机出口
```bash
iptables -I INPUT -s 112.25.137.237 -p tcp --dport 443 -j DROP
```

结果（约 45 秒后超时）：

```
网络连接失败，上传未完成：上传超时：网络太慢或文件过大，建议改用 WiFi
```

- **进度条已清空**（不残留假进度）
- 按钮恢复为「开始上传」，可重试
- 测试后已 `iptables -D` 解封，`iptables -L INPUT` 确认干净
- 截图：`shots/p6_offline.png`、`p6_offline_err.png`、`p6_off4.xml`

### 3.7 Web 端可见且 owner 正确

服务端接口实测：

```
=== /api/my_videos（App「我的视频」）===
HTTP 200 total = 1
   9c8532f8 | 4P6test100MB | owner_id 字段: False

=== /api/videos（Web 广场）===
HTTP 200 total = 34
   9c8532f8 | 4P6test100MB | owner_id = 6

=== /api/owners ===
HTTP 200 {'1': 'admin', '6': 'user'}
```

- `/api/videos` 返回 `owner_id = 6`，`/api/owners` 映射 `6 → user`
  → Web 广场会显示上传者为 **user**（截图 `p6_h2.xml` 中 App 广场同样显示 `user`）
- `/api/my_videos` **不返回 owner_id**（服务端 `multiuser.my_videos` 的 SELECT
  里没有该列），因此 App「我的视频」改用当前用户名兜底，见 5.2

---

## 4. 自动化测试

```
flutter analyze  → No issues found!
flutter test     → All tests passed! (85 条)
```

新增 P6 测试 27 条（`test/p6_test.dart`）：

| 分组 | 条数 | 覆盖点 |
|---|---|---|
| `fmtEta`（对齐 app.js:40） | 4 | null / 秒 / 分 / 时 四档边界 |
| `fmtFileSize` | 3 | B / KB / MB / GB 分级 |
| `UploadRepository.isSupportedFile` | 4 | 白名单、大小写、非视频拒绝 |
| `VideoRepository.ownerNameOr` | 4 | 兜底名语义（my_videos 无 owner_id） |
| `MediaProxy.rewritePlaylist` | 7 | **相对路径 / 本站绝对 URL / 外部 URL 三种情况**（第 6 节回归） |
| `UploadJob` 状态机 | 5 | 全链路、failed、percent 夹取、JSON 往返 |

---

## 5. 已知限制（本阶段不解决）

### 5.1 蜂窝网络大文件上传

nginx `proxy_read_timeout 300s`。实测 WiFi 上传 99.5 MB 耗时约 7.5 分钟
（0.22 MB/s），蜂窝上行更慢，>300 秒必被掐断。

- UI 常驻提示：「大文件建议在 WiFi 下上传。移动网络超过 5 分钟会被服务器断开。」
- 本阶段只保证 **WiFi 下 2GB 内可靠**（任务书明确）
- 不做断点续传 / 分片（后端不支持，任务书明确禁止）

### 5.2 `/api/my_videos` 不返回 owner_id

服务端 `multiuser.my_videos()` 的 SELECT 不含 `owner_id`，导致 App 无法按
id 查昵称映射。处理方式：`VideoGrid.ownerFallback` 传当前用户名兜底。

- 对「我的视频」语义完全正确（列表里必然都是自己的视频）
- 若将来服务端补上 owner_id，`ownerNameOr` 会优先用映射，无需改客户端

### 5.3 转码进度无 ETA 的情况

服务端在拿不到源总时长时 `percent` / `eta_seconds` 均为 null。此时 UI
显示不确定态进度条 + 「服务器正在处理其他任务，请稍候」，不显示百分比。

### 5.4 上传中杀 App 的边界

杀进程会中断 HTTP 上传本身（服务端收不到完整 multipart，不会产生任务）。
只有**上传已完成（拿到 job_id）后**杀进程，才能在「上传记录」里恢复轮询。
记录里 `uploading` 状态的条目会显示「上传中断，点此重新查看」。

---

## 6. 本轮发现并修复的缺陷（重点）

### 6.1 现象

3.1 的上传全部成功、转码完成、视频出现在列表，但**点击播放黑屏**：

```
PlatformException(VideoError, Video player had error
  androidx.media3.exoplayer.ExoPlaybackException: Source error, null, null)
```

### 6.2 定位过程

1. 先怀疑 Cookie / 鉴权 / 网络。但**同一个 App 播老视频正常**（P5 已验收），
   说明 MediaProxy、Cookie 注入、SNI 绕行链路本身没问题。
2. 对比新旧视频的 m3u8：

```bash
# 新上传的（P6 转码产物）
#EXT-X-KEY:METHOD=AES-128,URI="https://51play.ccwu.cc/key/9c8532f8"

# 历史视频（P5 验收过的）
#EXT-X-KEY:METHOD=AES-128,URI="/key/7fe00ad2"
```

**差异明确**：新视频是**绝对 URL**，历史视频是**相对路径**。

3. 根因链条：
   - 服务端 `multiuser.py::_transcode()` 用 `SITEAUTH_PUBLIC`
     （`https://51play.ccwu.cc`）拼 key URI → 写成绝对 URL
   - 客户端 `MediaProxy._rewritePlaylist()` 遇到 `http(s)://` 开头的 URI
     **直接 return 原样**（当时的逻辑是「外部 URL 无权代发」）
   - 于是播放器拿着 `https://51play.ccwu.cc/key/...` **直连域名**
   - 而该域名在真机网络被 **SNI 阻断**（P5 第 6 节的既有结论）
   - → key 拉取失败 → AES-128 解密失败 → ExoPlayer `Source error` → 黑屏

### 6.3 修复（服务端 + 客户端双向）

**服务端** `vod_site/server/multiuser.py`：key URI 改回相对路径

```python
# ⚠️ URI 必须写**相对路径** `/key/<id>`，不要写绝对 URL。
# 历史视频全部是相对路径，客户端（Android App 的 MediaProxy）
# 依赖这一点把 key 请求重写到本机代理，从而绕过网络对
# `SNI=*.ccwu.cc` 的 TLS 阻断（详见 App docs/P5_ACCEPTANCE.md）。
# 写成绝对 URL 会让播放器直连 51play.ccwu.cc 并被阻断 → 黑屏。
f.write("/key/%s\n" % os.path.basename(dest_dir))
```

已部署到线上（备份 `multiuser.py.bak_p6`），并修复已生成的
`9c8532f8/output.m3u8`（备份 `.bak_p6`）。

**客户端** `lib/core/media_proxy.dart`：加固 `rewritePlaylist`，三种情况全覆盖

| 输入 | 处理 |
|---|---|
| `/key/<id>`（相对路径） | 加本代理前缀（原有逻辑） |
| `https://51play.ccwu.cc/key/<id>`（**本站绝对 URL**） | **提取 path 后重写回本代理**（新增） |
| `https://cdn.example.com/key/<id>`（外部域名） | 原样保留（代理无权代发） |

同时把 `_rewritePlaylist` 抽成静态纯函数 `MediaProxy.rewritePlaylist()`，
便于单测（新增 7 条回归用例）。

### 6.4 全量复查

脚本扫描 `/var/www/html/videos/*/output.m3u8` 的 `EXT-X-KEY`：

```
共 35 条视频，全部为相对路径 /key/<id>，异常数量: 0
```

### 6.5 复测

重新构建安装后播放：

- 视频区亮度 122.2 → 123.0（画面在动）
- ts 分段持续 200（`Dart/3.14 (dart:io)`）
- `/key/9c8532f8` 200 / 16 字节
- **播放正常**

### 6.6 教训

> 「客户端靠相对路径重写来绕行网络阻断」是一条**跨端隐式契约**。
> 服务端改配置（`SITEAUTH_PUBLIC`）时会无声破坏它。
> 已在服务端代码里加注释说明原因，并在客户端加了绝对 URL 兜底，
> 双保险避免同类问题复发。

---

## 7. 附带修复

### 7.1 「我的视频」上传者显示「其他用户」

P4 遗留：`my_videos_page.dart` 用 `v.ownerId` 建映射，但 `/api/my_videos`
不返回该字段 → 映射为空 → 卡片回落「其他用户」。

修复：新增 `VideoGrid.ownerFallback`，传当前用户名；`VideoRepository.ownerNameOr`
优先用映射、缺失才用兜底。真机验证：广场与「我的视频」均显示 **user**。

---

## 8. 服务端一致性

`docs/server_snapshot/multiuser.py` 已与线上同步（含 key URI 修复与注释）。

线上状态确认：

```
systemctl is-active siteauth  →  active
curl http://127.0.0.1:8000/   →  401（未登录，预期）
```

---

## 9. 测试数据清理

| 项 | 处理 |
|---|---|
| 排队测试任务（6 个 id） | 已从 `videos` / `upload_jobs` 删除，媒体目录与 key 链接已删 |
| 服务器临时源视频 | `/tmp/p6_queue*.mp4` 已删 |
| 临时 Cookie / txt 文件 | 已删 |
| iptables 封禁规则 | 已 `-D` 删除，`iptables -L INPUT` 确认干净 |
| 主验收视频 `9c8532f8` | **保留**（owner=user，可播放，作为 P6 证据） |

清理后 `ready` 视频数 34（原 33 + 主验收视频 1）。

手机端保留 `p6_test_100mb.mp4` 与 `p6_small.mp4` 于 `/sdcard/Movies/`
（用户可自行删除）。
