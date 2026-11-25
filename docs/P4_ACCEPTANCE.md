# P4 验收记录 · 视频广场 + 我的

**阶段**：P4
**日期**：2026-11-25
**APK**：`dist/云影VOD-p4-debug.apk`
**验收设备**：Samsung SM-F9360（Fold4，Android 16，arm64-v8a，904×2316 @420dpi），无线调试（adb over TLS）

---

## 0. 与任务书的偏差（先说明）

任务书 `PHASE_PLAN.md` P4 有 **2 处与实际代码不符**，本阶段按**实际代码**实现，因为验收标准要求"与 Web 端一致"：

| 项 | 任务书写法 | 实际代码（`vod_site/web/app.js`） | 本阶段采用 |
|---|---|---|---|
| 封面回退顺序 | `/covers/<id>.jpg` → `/videos/<id>/cover.jpg` → 占位 | `app.js:252-254`：**`v.cover`（或 `/videos/<id>/cover.jpg`）→ `/covers/<id>.jpg`** → 占位 | **按代码** |
| 广场条数 | "当前 18 条 ready" | 实测 **33 条** ready | **按实测 33 条** |

---

## 1. 实现清单

### 新增文件

| 文件 | 职责 |
|---|---|
| `lib/core/layout_pref.dart` | 布局偏好持久化。**键名 `home_layout`**，与 Web 端 `localStorage` 同名；值 `grid`/`list`，非法值回落 `grid` |
| `lib/core/formatters.dart` | `fmtDuration` / `fmtViews` / `fmtDateTime`，逐行对齐 `app.js:33/56/46` |
| `lib/core/video_repository.dart` | `/api/videos`、`/api/my_videos`、`/api/owners`；owners 失败不阻断列表 |
| `lib/core/widgets/video_card.dart` | 卡片，网格 / 列表双形态 |
| `lib/core/widgets/video_grid.dart` | 布局渲染器（GridView / ListView 切换） |
| `lib/features/videos/plaza_page.dart` | 视频广场页 |
| `lib/features/videos/my_videos_page.dart` | 我的视频页 |
| `test/p4_test.dart` | 22 个单测 |

### 修改文件

| 文件 | 改动 |
|---|---|
| `lib/core/widgets/cover_image.dart` | 改为 `StatefulWidget`，实现三段回退（原来只有单级） |
| `lib/features/videos/home_page.dart` | 广场接入 `PlazaPage`；"我的视频"入口启用；移除占位 `_PlazaPlaceholder` |
| `lib/core/router.dart` | 新增 `AppRoutes.myVideos = '/my-videos'`；`/me` 路由替换为 `/my-videos` |
| `pubspec.yaml` | 新增 `shared_preferences: ^2.3.3` |

### 删除文件

- `lib/features/videos/my_page.dart`（P2 占位页，已被 `my_videos_page.dart` 取代）

---

## 2. 关键实现细节

### 2.1 布局持久化键名

**键名 `home_layout`，存储介质 `SharedPreferences`（Android 上是 `EncryptedSharedPreferences` 之外的普通 prefs，本项非敏感）。**

一个键同时控制"广场"和"我的视频"两个列表——与 Web 端 `applyLayoutUI()` 同时 toggle `home-grid` 与 `mine-grid` 的行为一致。

### 2.2 格式化函数对齐表

| 函数 | Web 端行为 | App 实现 | 单测 |
|---|---|---|---|
| `fmtDuration` | `null`/`<=0` → `''`；否则 `"x 分钟 y 秒"` / `"y 秒"` | 同 | 4 个 |
| `fmtViews` | `>=10000` → `"1.2 万 次"`（去尾 `.0`）；否则 `"n 次"` | 同 | 2 个 |
| `fmtDateTime` | 正则截取 `YYYY-MM-DD HH:MM`，**不做时区换算** | 同 | 4 个 |

> **踩坑预防**：`fmtDateTime` 若改用 `DateTime.parse().toLocal()`，服务端无时区的 `2026-11-24T11:13:51` 会被当作 UTC，显示成 `19:13`，与 Web 端差 8 小时。故用正则直接截取。

### 2.3 封面三段回退

`CoverImage` 改为有状态，`_stage` 记录当前尝试级别：

```
stage 0 → primary = video.cover（非空）否则 /videos/<id>/cover.jpg
stage 1 → fallback = /covers/<id>.jpg
stage 2 → 占位图标（AppTheme.surfaceHigh 底 + movie 图标，对应 Web 端 🎬）
```

`errorBuilder` 里用 `addPostFrameCallback` 再 `setState`，避免 build 期间 setState 报错。
`didUpdateWidget` 在 `videoId`/`cover` 变化时重置 `_stage`，避免 ListView 回收复用导致误跳过。

### 2.4 搜索

- Web 端：前端 `filter(v => v.name.toLowerCase().includes(kw))`
- App：走服务端 `GET /api/videos?q=<kw>`（契约 2.1，`LIKE %q%` 不区分大小写）

语义等价，但省流量。输入 **350ms 防抖**；用 `_reqSeq` 序号丢弃过期响应，避免快速输入时旧结果覆盖新结果。

### 2.5 错误态区分（修 P3 遗留）

P3 已知问题"弱网判定较粗"在本阶段处理：

| 情况 | 判定 | 文案 |
|---|---|---|
| `statusCode == null` | 网络层（超时 / SocketException） | 网络连接失败，请检查网络后重试 |
| `statusCode >= 500` | 服务端故障 | 服务器开小差了（5xx），请稍后重试 |
| 其他 4xx | 业务错误 | 加载失败（4xx）：<原始文案> |
| 401 | 不显示错误页 | ApiClient 广播 → 路由守卫跳登录页 |

---

## 3. 验收结果

### 3.1 自动化测试

```
flutter analyze  →  No issues found!
flutter test     →  56 tests passed（P2 19 + P3 15 + P4 22）
```

### 3.2 服务端基准数据（验收对照）

```
ready 总数             : 33
user(uid=6) 的 ready 数 : 0     ← "我的"页应为空态
含 "IPX" 的 ready      : 1
排序（sort_pin DESC, date DESC, id）首条：
  tw_2124946082094260484  "经典老片 - 💖💖💖"  owner=1
```

### 3.3 真机验收（adb 自动化）

> 设备：`adb-RFCT9095XBJ-3IwE8v._adb-tls-connect._tcp`
> 方法：`adb install -r` + `pm clear`（干净起点）+ `uiautomator dump` 读 UI 树 + `input tap/text` 操作

| # | 验收项 | 预期 | 结果 |
|---|---|---|---|
| 1 | 未登录启动 | 登录页 | ✅ 显示"云影 VOD / 登录后观看全部视频 / 登录 / 申请注册" |
| 2 | 登录 user/123456 | 进广场 | ✅ 进入"视频广场" |
| 3 | 广场条数 | 33 条 | ✅ 33 / 33 |
| 4 | 网格布局 | 2 列卡片 + 封面 + 标题 + 上传者/时长 | ✅ |
| 5 | 切列表布局 | 单列 + 左图右文 + 信息行 | ✅ |
| 6 | 布局记忆 | 杀进程重开保持上次选择 | ✅ |
| 7 | 搜索 "IPX" | 1 条（IPX-811） | ✅ |
| 8 | 搜索无结果 | "未找到匹配的视频" | ✅ |
| 9 | 断网 | 错误页 + 重试按钮，不崩溃 | ✅ 进程 PID 不变 |
| 10 | 恢复网络重试 | 正常加载 | ✅ |
| 11 | 封面回退 | 缺封面视频显示占位，不崩 | ✅ 三级回退走到尽头 |
| 12 | 我的视频（user 空） | "暂无视频，快去上传第一个吧" | ✅ |
| 13 | 点卡片 | 跳播放页占位并传 videoId | ✅ videoId 正确 |

### 3.4 广场列表与布局

**条数：33 / 33 ✅**

用 `uiautomator dump` 逐屏滚动收集卡片标题，去重后得 **33 条**，与服务端 `SELECT COUNT(*) WHERE status='ready'` 完全一致。

> **踩坑记录**：第一次扫描只得到 29 条，误以为漏了 4 条。原因是滑动步长过大（swipe 从 y=1700 到 y=500），一次跨过 4 行卡片，中间的卡片从未出现在任何一屏。改成小步长（y=1500→900，30 次）后得到完整 33 条。**结论：这不是程序缺陷，是验收脚本的采样问题。**

首条为 `经典老片 - 💖💖💖`（owner=admin, 2026-11-24 11:13），与服务端
`ORDER BY sort_pin DESC, date DESC, id` 的结果一致。

**网格布局**：2 列，卡片含封面 + 播放遮罩 + 标题（单行省略）+ `admin`（上传者）。
首屏 8 张（4 行），布局正常。

**列表布局**：点击右上角切换按钮后，变单列左图右文，每张卡片多一行信息：

```
经典老片 - 💖💖💖
admin
admin  ·  0 次  ·  2026-11-24 11:13
```

上传者出现两次（`card-meta` 一次、`card-info` 一次）——这是 **Web 端既有行为**，App 刻意保持一致。

**布局记忆：✅ 通过**

切到列表布局后 `am force-stop` 杀进程再 `am start`，重开后：
- 切换按钮 tooltip 仍是「切换为网格视图」（说明当前是列表态）
- 首条卡片仍带 `admin · 0 次 · 2026-11-24 11:13` 信息行

**搜索：✅ 通过**

| 输入 | 结果 |
|---|---|
| `IPX` | 1 条：`IPX-811`（admin, 0 次, 2026-09-03 05:55），与服务端 `q=IPX` 的 1 条一致 |
| `IPXzzzz` | 空态「未找到匹配的视频」 |
| 点 X 清空 | 恢复完整 33 条列表 |

### 3.5 断网与重试

**断网表现：✅ 通过**

断网方式：服务器侧 `iptables -I INPUT -s <手机公网IP> -p tcp --dport 443 -j DROP`
（**不关 WiFi**——无线调试走 WiFi，关了会断连，这也是第一次测试踩的坑）。

触发方式：切到「我的」Tab 再切回「广场」，迫使 `PlazaPage` 重新拉列表。

等待 15s 超时后界面：

```
视频广场
网络连接失败，请检查网络后重试
[重试]
```

- 显示的是**网络类**文案，不是 5xx 文案 → 说明 `statusCode == null` 分支判定正确
- 进程 PID 保持 9255 不变 → **未崩溃**
- 重试按钮存在且可点（bounds `[295,1309][610,1435]`）

**恢复网络重试：✅ 通过**

`iptables -D` 解封后点「重试」，8 秒内恢复正常 33 条列表。

> **额外发现（预期行为，非缺陷）**：如果在**完全断网**状态下冷启动 App，
> 会话校验（`/api/me` 或 token 换 session）会失败，App 退回**登录页**。
> 这是 P3 设计的正确行为——无法确认会话有效时不应放行。
> 所以断网错误态只有在「已登录 + 会话有效 + 仅列表请求失败」时才会出现，
> 本测试正是按这个前提构造的。

### 3.6 封面回退

**测试方法**：临时插入一条 `cover=NULL` 且 `/covers/<id>.jpg`、`/videos/<id>/cover.jpg` 都**不存在**的视频记录（`zz_cover_test_001`，`sort_pin=999` 置顶），刷新后观察，测完删除。

**结果：✅ 通过**

- 该卡片正常出现在**第一位**（`bounds=[32,423][873,667]`）
- 封面区域显示占位（`AppTheme.surfaceHigh` 底 + 电影图标）
- 卡片标题、上传者、信息行都正常渲染
- 进程未崩溃

**回退链验证细节**：该卡片的无障碍节点 class 是 `android.view.View` 而非
`ImageView`——因为 `Image.network` 两次都失败后 `_stage >= candidates.length`，
渲染的是纯 `Container`+`Icon`，不再有图片节点。这正是**三级回退走到尽头**的证据。

> 数据已还原：`DELETE FROM videos WHERE id='zz_cover_test_001'`，ready 数恢复 33，
> `zz_%` 前缀记录数 0。备份存于 `/root/site-backups/site.db.before_cover_test`。

### 3.7 我的视频空态

**结果：✅ 通过**

`user` 账号（uid=6）当前 0 条 ready 视频，进入「我的 → 我的视频」显示：

```
我的视频
暂无视频，快去上传第一个吧
[去上传]
```

与任务书要求的文案完全一致。同时该页也读取了同一个 `home_layout` 偏好
（tooltip 显示「切换为网格视图」，说明继承了广场的列表布局），
符合 Web 端「一个键管两个列表」的语义。

### 3.8 播放页占位

**结果：✅ 通过**

点击卡片后跳转，页面显示：

```
播放
播放器
videoId = tw_2119646616407965874
P2 骨架阶段：占位页
P5 接入 HLS + AES-128
```

videoId 正确传递（点的是「爆火眼镜妹」，id 与之匹配），P5 可直接接手。

---

## 4. 实测记录

> 原始 UI 树快照存于 `docs/verify/shots/p4_*.xml`，截图 `p4_12_cover_fallback.png`。

| 文件 | 对应验收项 |
|---|---|
| `p4_01_launch.xml` | 未登录启动 → 登录页 |
| `p4_02_plaza.xml` | 登录后广场网格布局 |
| `p4_03_list.xml` | 切换为列表布局 |
| `p4_04_layout_memory.xml` | 杀进程重开保持列表布局 |
| `p4_05_search_ipx.xml` | 搜索 IPX → 1 条 |
| `p4_06_search_empty.xml` | 搜索无结果空态 |
| `p4_07_my.xml` | 我的页（入口已启用） |
| `p4_08_my_videos_empty.xml` | 我的视频空态 |
| `p4_09_offline.xml` | 断网错误页 + 重试 |
| `p4_10_retry_ok.xml` | 恢复网络重试成功 |
| `p4_11_player_placeholder.xml` | 播放页占位 + videoId |
| `p4_12_cover_fallback.xml/.png` | 封面三级回退 |

---

## 5. 已知限制与后续

| 项 | 说明 | 计划 |
|---|---|---|
| 同型号设备合并 | P3.1 已知：`(user_id, device_name, platform)` 去重会把两台同型号设备合并 | P4 未处理，建议 P7 前评估把随机 deviceId 拼进 device_name |
| 列表一次拉 500 条 | 当前 33 条，无分页 UI | 数据量上千时再加分页 |
| 搜索无高亮 | Web 端也没有 | 不处理 |
| 播放页仍是占位 | P4 只传 videoId | P5 实现 HLS AES-128 |
