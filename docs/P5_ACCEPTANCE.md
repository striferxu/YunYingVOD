# P5 验收记录 · 播放器（HLS AES-128）

**阶段**：P5（全项目最高风险阶段）
**日期**：2026-11-25
**APK**：`dist/云影VOD-p5-debug.apk`
**验收设备**：Samsung SM-F9360（Fold4，Android 16，arm64-v8a）

---

## 0. 结论摘要

> **状态：代码完成，真机验收被外部网络阻断，未通过。**

| 验收项 | 结果 |
|---|---|
| 播放 3 条以上不同来源视频，出画有声 | ❌ **阻塞**：SNI 阻断，见第 6 节 |
| `/key/<id>` 带 Cookie 返回 200（硬性） | ✅ 服务端基线已验证（第 2 节）；真机链路被阻断 |
| seek 正常 | ⏸ 待链路打通后验 |
| 横竖屏切换 | ⏸ 待链路打通后验 |
| 断网错误态 + 重试恢复 | ✅ 错误态已验证（第 4.2 节） |
| 后台切回不崩溃 | ⏸ 待链路打通后验 |
| 是否被迫换库（media_kit） | **未换库**，方案本身可行（第 1 节） |

**一句话结论**：播放器代码与「Cookie 注入媒体请求」的技术方案都已验证可行；
但真机所在网络对 `SNI=51play.ccwu.cc` 的 TLS 握手做了特征阻断，
导致 Android 原生 TLS 栈（ExoPlayer / curl）无法建连，播放无法出画。
**这不是客户端代码缺陷，也不是服务端配置缺陷**，详见第 6 节完整取证。

---

## 1. 技术方案与可行性验证

### 1.1 方案（沿用 PHASE_PLAN 定死的方案，未更换）

```dart
VideoPlayerController.networkUrl(
  Uri.parse('https://51play.ccwu.cc/videos/<id>/output.m3u8'),
  httpHeaders: {'Cookie': 'site_session=<token>'},
)
```

### 1.2 从插件源码确认「Cookie 会带到 key 请求」

**这一步是本阶段能否成立的根本**，不能靠"能播就行"来推断，必须看源码。

`video_player_android-2.12.2` 的
`android/src/main/java/io/flutter/plugins/videoplayer/HttpVideoAsset.java`：

```java
public MediaSource.Factory getMediaSourceFactory(Context context) {
  return getMediaSourceFactory(context, new DefaultHttpDataSource.Factory());
}

MediaSource.Factory getMediaSourceFactory(
    Context context, DefaultHttpDataSource.Factory initialFactory) {
  unstableUpdateDataSourceFactory(initialFactory, httpHeaders, userAgent);
  DataSource.Factory dataSourceFactory = new DefaultDataSource.Factory(context, initialFactory);
  return new DefaultMediaSourceFactory(context).setDataSourceFactory(dataSourceFactory);
}

private static void unstableUpdateDataSourceFactory(
    DefaultHttpDataSource.Factory factory,
    Map<String, String> httpHeaders,
    String userAgent) {
  factory.setUserAgent(userAgent).setAllowCrossProtocolRedirects(true);
  if (!httpHeaders.isEmpty()) {
    factory.setDefaultRequestProperties(httpHeaders);   // ← 关键
  }
}
```

**推理链**：

1. `httpHeaders` 被 `setDefaultRequestProperties()` 写进 `DefaultHttpDataSource.Factory`。
2. 该 factory 通过 `DefaultMediaSourceFactory.setDataSourceFactory()` 成为**整个媒体源**的数据源工厂。
3. Media3 的 `HlsMediaSource` 处理 HLS 时，用同一个 `DataSource.Factory` 创建
   - 加载 `.m3u8` 的 DataSource
   - 加载每个 `.ts` 的 DataSource
   - **加载 `#EXT-X-KEY` 指向的 `/key/<id>` 的 DataSource**
4. 因此 Cookie 会出现在这三类请求上。

**结论：方案可行，无需切换到 `media_kit`。**

> 注意：`setDefaultRequestProperties` 是"默认请求属性"，若单个 DataSource 另有指定会被覆盖。
> HLS 场景下 Media3 不会对 key 请求单独设置属性，所以默认属性生效。

### 1.3 不手动加 Referer

nginx 对 `/videos/`、`/key/` 配了 `valid_referers none server_names`。
原生播放器默认不发 Referer → 命中 `none` → 放行。
手动加非本站 Referer 会被 403。代码中**只设 Cookie，不设 Referer**。

---

## 2. 服务端基线（改动前先立标准）

用临时 session 直接 curl，确认鉴权行为：

| 请求 | 带 Cookie | 不带 Cookie |
|---|---|---|
| `GET /key/tw_2124946082094260484` | **200**，16 bytes | **401**，172 bytes |
| `GET /videos/tw_2124946082094260484/output.m3u8` | **200**，37693 bytes | **401**，172 bytes |

与 `CLIENT_API_SPEC.md` 第 3.3 节记录完全一致。

**可用视频样本**（33 条 ready 全部有 m3u8）：

| id 形态 | 示例 |
|---|---|
| `tw_` 前缀 | `tw_2124946082094260484`（经典老片）、`tw_2119646616407965874`（爆火眼镜妹） |
| `cklou_` 前缀 | `cklou_46ea43d1e2b44ebda38384d0f28bf98c`、`cklou_cfb4eb094fda43c9b0b7cd0aa5215c21`（MNGS-067） |
| 8 位 hex | `2c5be4a1`（video_099）、`7fe00ad2`（IPX-811）、`b0ab4537` |

---

## 3. 实现清单

### 新增/改动

| 文件 | 改动 |
|---|---|
| `pubspec.yaml` | 新增 `video_player: ^2.9.2`（实际解析到 2.14.1 / android 2.12.2） |
| `lib/core/api_client.dart` | 新增 `mediaHeaders`（只含 `Cookie: site_session=xxx`）与 `hasMediaCookie` |
| `lib/features/player/player_page.dart` | 从 P2 占位重写为完整播放页 |

### 播放页能力

- **三态**：加载中 / 播放中 / 错误（错误分 `auth` 与 `play` 两类，`auth` 额外给"去登录"）
- **播放控制**：播放/暂停、进度条、拖动 seek、当前时间/总时长、全屏按钮
- **全屏**：横屏 + 沉浸式状态栏，点击画面切换控制条显隐（4 秒自动隐藏）
- **元数据**：播放前 `GET /api/videos/<id>`，展示标题、时长、体积、播放数、上传日期、简介
- **生命周期**：`WidgetsBindingObserver`，后台暂停并记录位置，回前台 seek 回去继续播
- **重试**：重试前先 `refreshSession(silent: true)` 续期会话（key/ts 401 的常见原因是 Cookie 过期）
- **鉴权前置检查**：没有 Cookie 直接判鉴权失效，不发空头请求（否则拿到 nginx 的 401 HTML，错误信息很难看）

### 错误分类逻辑

```dart
void _classifyAndFail(Object e) {
  final msg = e.toString();
  if (!ApiClient().hasMediaCookie) {          // 无 Cookie → 100% 是鉴权问题
    _fail(_PlayerError.auth, '会话已失效，无法获取解密密钥。');
    return;
  }
  if (msg.contains('401') || msg.contains('403') || msg.contains('Unauthorized')) {
    _fail(_PlayerError.auth, '服务器拒绝访问媒体资源：$msg');
    return;
  }
  _fail(_PlayerError.play, msg);              // 网络/解码/格式
}
```

---

## 4. 真机实测

### 4.1 现象

安装 P5 APK 后，登录态正常、视频广场列表正常加载（33 条，封面正常显示），
点击任意视频进入播放页，**播放区显示"播放失败"**：

```
播放失败
PlatformException(VideoError, Video player had error
androidx.media3.exoplayer.ExoPlaybackException: Source error, null, null)
[重试]
```

**关键观察**：同一时刻、同一台手机、同一个域名——

| 请求发起方 | TLS 实现 | 结果 |
|---|---|---|
| 封面 `/covers/*.jpg` | Dart 的 BoringSSL | ✅ 200，正常出图 |
| 列表 `/api/videos` | Dart 的 BoringSSL | ✅ 200，33 条 |
| 播放 m3u8 | Android Conscrypt / ExoPlayer | ❌ Connection reset |
| `/system/bin/curl` | Android BoringSSL（系统版） | ❌ Connection reset |

即「Dart 能通、Android 原生栈不通」。这说明问题不在 Cookie、不在 URL 拼接、
也不在服务端鉴权（因为服务端根本没收到这些请求，见 4.3）。

### 4.2 错误态 UI 验证（已通过）

播放失败时页面正确显示错误态：图标 + 「播放失败」+ 错误详情 + 「重试」按钮，
不崩溃、不白屏、不无限转圈。这一项符合验收要求。

### 4.3 服务端日志：媒体请求根本没到

在服务端 `tail -n +1051 /var/log/nginx/access.log`（播放操作前的行号基线）
观察点击播放后的全部请求：

```
... GET /api/me            200
... GET /api/owners        200
... GET /api/videos?status=ready&limit=500  200
... GET /covers/*.jpg      200   ← 封面全部成功（Dart）
... GET /api/videos/tw_2124946082094260484  200
```

**没有任何一条 `/videos/<id>/output.m3u8` 或 `/key/<id>` 请求。**

而 `GET /api/videos/<id>`（元数据）成功，说明同一个域名、同一个 Cookie、
Dart 侧完全正常。结论：**失败发生在 TLS 建连阶段，请求从未到达应用层。**

### 4.4 logcat 异常链

```
E ExoPlayerImplInternal: Playback error
E   androidx.media3.exoplayer.ExoPlaybackException: Source error
E   Caused by: HttpDataSource$HttpDataSourceException: java.net.SocketException: Connection reset
E   Caused by: java.net.SocketException: Connection reset
      at com.android.org.conscrypt.ConscryptEngineSocket.startHandshake(...)
      at androidx.media3.datasource.DefaultHttpDataSource.open(...)
```

`Connection reset` 发生在 `ConscryptEngineSocket.startHandshake` —— **TLS 握手阶段**，
不是 HTTP 401/403，也不是 Cookie 问题。

---

## 5. 服务端基线复核与清理

（本节已并入第 2 节；测试用临时 session、tcpdump 抓包文件、
8443 测试监听与 iptables 规则均已清理，服务 `siteauth`/`nginx` 正常。）

---

## 6. 根因定位：SNI 特征阻断（完整取证）

> 本节是 P5 未能通过验收的原因说明。**结论：外部网络干预，非代码缺陷。**

### 6.1 逐步排除

| 假设 | 验证方法 | 结论 |
|---|---|---|
| URL 拼接错误 | 服务端日志无 m3u8 请求，且 `/api/videos/<id>` 同域名成功 | ❌ 排除 |
| Cookie 未注入 | Dart 侧封面（同 Cookie 机制）全部 200 | ❌ 排除 |
| 服务端鉴权失败 | 失败发生在 TLS 握手，未到 HTTP 层；nginx error.log 无记录 | ❌ 排除 |
| 证书链不完整 | 服务器下发完整 4 张证书链，外部 openssl 验证 `code 0 (ok)` | ❌ 排除 |
| 证书域名不匹配 | 用 `-k` 跳过证书校验仍失败 | ❌ 排除 |
| IPv6 问题 | 域名只有 A 记录，无 AAAA | ❌ 排除 |
| 客户端代码问题 | 同一时刻 Dart 请求全通 | ❌ 排除 |

### 6.2 抓包证据（服务端 tcpdump）

对手机 IP `112.25.137.237` 抓包，发现两类截然不同的连接：

**A 类（Dart 发起，成功）**——服务端下发 26KB~65KB 数据，正常 HTTP 交互：

```
10:39:45 手机.52850 > 服务端.443  [S]     id 47011   ← IP ID 递增
10:39:45 服务端.443 > 手机.52850  [S.]    id 0
10:39:45 手机.52850 > 服务端.443  [.]     id 47012
10:39:45 手机.52850 > 服务端.443  [P.]    id 47013   length 1525  ← ClientHello 1473B
... 后续正常传输 ...
```

**B 类（ExoPlayer / curl 发起，失败）**——服务端下发 ~3.8KB 后连接被 RST：

```
10:39:56 手机.55360 > 服务端.443  [S]     id 31207   ← 真实包，ID 递增
10:39:56 手机.55360 > 服务端.443  [P.]    id 31209   length 517   ← ClientHello 465B
10:39:56 服务端.443 > 手机.55360  [P.]    ... 2776B（ServerHello+证书）
10:39:56 手机.55360 > 服务端.443  [R]     id 0       ← RST，IP ID = 0！
10:39:56 手机.55360 > 服务端.443  [R]     id 0       ← 同一 seq 重复注入
10:39:56 手机.55360 > 服务端.443  [R]     id 0       ← 第三次
```

**RST 包特征判定为中间设备注入，而非手机发出**：

1. `IP ID = 0` —— 真实手机包 ID 是递增的（31207→31208→31209），
   连续三个 RST 的 ID 全是 0，与真实包序列断裂。
2. **同一 seq 重复注入 3~4 次** —— 典型的中断设备"确保送达"行为。
3. 全抓包统计：13 个 RST 包 IP ID 全为 0；真实包的 ID 全部非 0。

### 6.3 定位到 SNI

用手机自带 `/system/bin/curl` 做受控变量实验（`--resolve` 强制指向同一 IP）：

| SNI | 目标 IP | 结果 |
|---|---|---|
| `51play.ccwu.cc` | 本站 64.90.31.17 | ❌ 000 reset |
| `ccwu.cc`（裸域） | 本站 64.90.31.17 | ❌ 000 reset |
| `abc123xyz.ccwu.cc`（随机子域） | 本站 64.90.31.17 | ❌ 000 reset |
| `example.com`（无关域） | 本站 64.90.31.17 | ✅ 200 |
| **无 SNI**（直接 `https://64.90.31.17/`） | 本站 64.90.31.17 | ✅ 200 |
| `51play.ccwu.cc` | **百度 IP** 110.242.68.66 | ❌ 000 reset |
| `www.baidu.com` | 本站 64.90.31.17 | ✅ 200 |

**结论**：
- 阻断依据是 **ClientHello 里的明文 SNI**，与目标 IP 无关
  （SNI=51play 连百度 IP 也被 reset）。
- 阻断范围是 **`*.ccwu.cc` 整个域**（裸域、随机子域都被 reset）。
- **不带 SNI 的同一 IP 访问完全正常**（200），说明服务器本身没问题。
- 与端口无关：在 8443 端口复现同样结果。

### 6.4 关键机制：ClientHello 大小决定是否被阻断

进一步实验发现，阻断并非简单的"见到 ccwu.cc 就 reset"，
而是与 **ClientHello 报文大小 / 是否被 TCP 分片**相关：

| ClientHello 特征 | 大小 | 10 次成功率 |
|---|---|---|
| 仅 `x25519`（小） | 465~517 B | **1/10** |
| 含 `X25519MLKEM768` 后量子密钥（大） | 1473 B（跨 2 个 TCP 段） | **10/10** |

`curl --curves X25519MLKEM768:x25519` 连续 10 次全部 200；
`curl --curves x25519` 连续 10 次仅 1 次成功。

**这解释了为什么 Dart 能通、ExoPlayer 不通**：

- **Dart 的 BoringSSL** 默认启用后量子密钥交换（`X25519MLKEM768`），
  ClientHello 带 1216 字节的 ML-KEM key share，总长 1473 字节，
  超过 MSS 被 TCP 分片成两个段 → 阻断设备无法匹配完整特征 → 放行。
- **Android Conscrypt（ExoPlayer）** 与**系统 curl** 只发 `x25519`，
  ClientHello 仅 465~517 字节，单个 TCP 段完整可见 → 被匹配并 RST。

### 6.5 为什么之前 P4 阶段没暴露

P4 的全部请求（`/api/*`、`/covers/*`）都由 **Dart 的 HttpClient** 发起，
走的是大 ClientHello 路径，因此一直正常。
P5 是项目里**第一次由 Android 原生 TLS 栈发起请求**，才暴露该阻断。

### 6.6 归属判定

| 层 | 是否有问题 | 依据 |
|---|---|---|
| 客户端代码 | ❌ 无问题 | 方案从插件源码验证可行；Dart 侧同域全通 |
| 服务端配置 | ❌ 无问题 | 无 SNI / 非 ccwu.cc SNI 访问均 200；外部 openssl 验证通过 |
| **中间网络** | ✅ **问题所在** | RST 由中间设备注入（IP ID=0、重复注入）；按 SNI + ClientHello 特征匹配 |

---

## 7. 待决策：如何绕过

以下方案需要用户拍板，**未获批准前不擅自改动**：

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **A. 加 IP SAN 证书**（推荐） | 给证书加 `IP:64.90.31.17`，客户端改用 `https://64.90.31.17/...` 访问 | 无 SNI → 已实测 200；不碰用户网络 | 需重签证书；IP 变更需同步；多个入口 IP 要各自加 |
| **B. 用户侧走代理** | 手机开代理/VPN 访问该域 | 零改动 | 依赖用户网络环境；App 无法强制 |
| **C. 换域名** | 换一个未被阻断的域名 | 干净 | 需重新备案/解析/签证书，成本高 |
| **D. 保持现状** | 接受当前网络下不能播 | 零成本 | 功能不可用 |

> 注：方案 A 只解决「当前这个 IP + 无 SNI」的组合。
> 若后续阻断策略升级为按 IP 阻断，则 A 也会失效。

---

## 8. 已知限制（代码层面）

| 项 | 说明 |
|---|---|
| 播放中途 Cookie 过期 | 30 分钟后 key/ts 会 401，播放中断。当前需用户点"重试"（重试会先续期会话）。未做自动续期重载 |
| 无倍速/字幕/下载 | PHASE_PLAN 明确禁止，不做 |
| 无播放进度记忆 | 退出再进从 0 开始 |
| 错误文案含英文 | ExoPlayer 原始错误信息是英文，直接透传便于排查 |
