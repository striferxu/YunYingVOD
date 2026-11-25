/// player_page.dart — 播放页（P5）。HLS + AES-128 加密播放。
///
/// ## 为什么这个页面是全项目最高风险点
///
/// 一个视频的播放要发三类受保护的请求，**全部**过 nginx `auth_request`：
///   1. `/videos/<id>/output.m3u8`  播放列表
///   2. `/videos/<id>/output*.ts`   每个分段（文件名不统一，靠解析 m3u8）
///   3. `/key/<id>`                 AES-128 解密密钥（m3u8 里是相对 URI）
///
/// 任何一个不带 Cookie 都会 401，表现是黑屏/一直转圈。
///
/// ## 方案（PHASE_PLAN 定死）
///
/// `video_player` + `VideoPlayerController.networkUrl(..., httpHeaders: {'Cookie': ...})`。
/// Android 底层 ExoPlayer 会把 httpHeaders 应用到该媒体源的**全部**请求，
/// 包括 m3u8 里 `#EXT-X-KEY:URI="/key/<id>"` 解析出的 key 请求。
///
/// ⚠️ **绝不加 Referer**：nginx 对 `/videos/`、`/key/` 配了
/// `valid_referers none server_names`，原生播放器不发 Referer 命中 `none` 放行；
/// 手动加非本站 Referer 会 403。
///
/// ## 三态
///   * 加载中：spinner
///   * 播放中：视频 + 控制条
///   * 错误：错误文案 + 重试按钮；鉴权失效额外给"去登录"
library;

import 'dart:async';

import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome, SystemUiMode;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/api_client.dart';
import '../../core/auth_controller.dart';
import '../../core/media_proxy.dart';
import '../../core/models/video.dart';
import '../../core/router.dart';
import '../../core/theme.dart';

/// 播放页的错误类型，决定 UI 给什么操作。
enum _PlayerError {
  /// 鉴权失效（无 Cookie / 401 / 403）
  auth,

  /// 其他播放失败（网络、解码、格式）
  play,
}

class PlayerPage extends StatefulWidget {
  final String videoId;

  const PlayerPage({super.key, required this.videoId});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  Video? _meta;

  /// 本地媒体代理（P5 网络绕行，见 media_proxy.dart）。
  /// 起不来时为 null，回退到直连上游。
  MediaProxy? _proxy;

  bool _loading = true;
  _PlayerError? _error;
  String _errorDetail = '';

  /// 是否已进入全屏（横屏）模式。
  bool _fullscreen = false;

  /// 控制条是否可见（全屏时点击画面切换）。
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// 记录上一次的播放位置，用于后台切回时恢复。
  Duration _lastPosition = Duration.zero;

  /// 防止重复初始化（重试时）。
  bool _initializing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _controller?.dispose();
    _proxy?.close();
    // 退出时恢复默认方向
    if (_fullscreen) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // 后台：暂停并记住位置，避免后台继续解码耗电
      _lastPosition = c.value.position;
      c.pause();
    } else if (state == AppLifecycleState.resumed) {
      // 回前台：恢复上次位置并继续播（暂停是我们主动做的，不是用户意图）
      if (_lastPosition > Duration.zero) {
        c.seekTo(_lastPosition).then((_) {
          if (mounted) c.play();
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 启动流程
  // ---------------------------------------------------------------------------

  Future<void> _start() async {
    if (_initializing) return;
    _initializing = true;

    setState(() {
      _loading = true;
      _error = null;
      _errorDetail = '';
    });

    try {
      // 1) 元数据（标题、时长）——失败不致命，用 videoId 当标题
      await _loadMeta();
      if (!mounted || _error != null) return;

      // 2) 鉴权前置检查：没有 Cookie 直接判鉴权失效，
      //    不要拿空头发请求（会得到 nginx 的 401 HTML，错误信息很难看）
      if (!ApiClient().hasMediaCookie) {
        _fail(_PlayerError.auth, '当前没有有效的登录会话，无法获取视频解密密钥。');
        return;
      }

      // 3) 建播放器
      await _createController();
    } finally {
      _initializing = false;
    }
  }

  Future<void> _loadMeta() async {
    try {
      final res = await ApiClient().get('/api/videos/${widget.videoId}');
      if (!mounted) return;
      setState(() => _meta = Video.fromJson(res.data));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isUnauthorized) {
        _fail(_PlayerError.auth, '登录状态已失效，请重新登录。');
      }
      // 其他错误忽略（弱网时仍可尝试播放）
    }
  }

  Future<void> _createController() async {
    // 优先走本地代理：由 Dart 完成上游 HTTPS（Dart 的 TLS 栈能通过当前网络），
    // ExoPlayer 只连 127.0.0.1 的明文 HTTP。代理起不来才回退直连。
    _proxy ??= await MediaProxy.start();
    final proxy = _proxy;

    final String url;
    final Map<String, String> headers;
    if (proxy != null) {
      url = '${proxy.localUrl}/videos/${widget.videoId}/output.m3u8';
      // Cookie 由代理注入，播放器不需要
      headers = const {};
    } else {
      url = ApiClient().absoluteUrl('/videos/${widget.videoId}/output.m3u8');
      headers = ApiClient().mediaHeaders;
    }

    final c = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers,
    );
    _controller = c;

    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      c.addListener(_onControllerUpdate);
      await c.play();
      if (!mounted) return;
      setState(() => _loading = false);
      _scheduleHideControls();
    } catch (e) {
      await c.dispose();
      _controller = null;
      if (!mounted) return;
      _classifyAndFail(e);
    }
  }

  /// 播放器抛的错分类。
  ///
  /// ExoPlayer 对 401/403 通常抛 `PlatformException(VideoError, ...)`，
  /// 消息里可能含状态码；认不出就当普通播放错误，
  /// 但**若当前已无 Cookie，优先判鉴权失效**（这种情况 100% 是鉴权问题）。
  void _classifyAndFail(Object e) {
    final msg = e.toString();
    if (!ApiClient().hasMediaCookie) {
      _fail(_PlayerError.auth, '会话已失效，无法获取解密密钥。');
      return;
    }
    if (msg.contains('401') ||
        msg.contains('403') ||
        msg.contains('Unauthorized')) {
      _fail(_PlayerError.auth, '服务器拒绝访问媒体资源：$msg');
      return;
    }
    _fail(_PlayerError.play, msg);
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    final c = _controller;
    if (c == null) return;
    if (c.value.hasError) {
      final err = c.value.errorDescription ?? '未知播放错误';
      if (_error == null) _classifyAndFail(err);
      return;
    }
    // 进度更新刷新进度条
    if (c.value.isInitialized) setState(() {});
  }

  void _fail(_PlayerError kind, String detail) {
    if (!mounted) return;
    _controller?.removeListener(_onControllerUpdate);
    setState(() {
      _loading = false;
      _error = kind;
      _errorDetail = detail;
    });
  }

  // ---------------------------------------------------------------------------
  // 交互
  // ---------------------------------------------------------------------------

  Future<void> _retry() async {
    if (!mounted) return;
    // 先给 UI 一个"正在重试"的即时反馈，避免用户以为按钮没反应
    setState(() {
      _loading = true;
      _error = null;
      _errorDetail = '';
    });

    // 1) 续期会话。注意：断网期间 refreshSession 会因为网络错误直接返回 false
    //    但**不会**清登录态（这是 auth_controller 的既定行为），此时 Cookie 仍然
    //    可用，所以不能因为返回 false 就放弃重试。
    try {
      await context.read<AuthController>().refreshSession(silent: true);
    } catch (_) {
      // 静默续期不应阻塞重试
    }
    if (!mounted) return;

    // 2) 彻底重建：controller 与代理都丢掉。
    //    代理持有的是启动时的 Cookie 快照，续期后必须重建才能用上新 Cookie。
    final old = _controller;
    _controller = null;
    old?.removeListener(_onControllerUpdate);
    await old?.dispose();

    final oldProxy = _proxy;
    _proxy = null;
    await oldProxy?.close();

    if (!mounted) return;
    _lastPosition = Duration.zero;

    // 3) 重新走完整启动流程
    _initializing = false; // 允许 _start 进入
    await _start();
  }

  Future<void> _goLogin() async {
    await context.read<AuthController>().logout();
    if (!mounted) return;
    context.go(AppRoutes.login);
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
    });
    _scheduleHideControls();
  }

  void _seekTo(Duration d) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    c.seekTo(d);
    _scheduleHideControls();
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      final c = _controller;
      if (c != null && c.value.isPlaying && mounted) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _scheduleHideControls();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_fullscreen) return _buildFullscreen();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          _meta?.name ?? widget.videoId,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          AspectRatio(aspectRatio: 16 / 9, child: _buildSurface()),
          Expanded(child: _buildInfo()),
        ],
      ),
    );
  }

  /// 全屏：整个屏幕都是视频，点击切控制条。
  Widget _buildFullscreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () {
          if (_controlsVisible) {
            setState(() => _controlsVisible = false);
            _hideTimer?.cancel();
          } else {
            _scheduleHideControls();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: _buildSurface(hideInlineControls: true)),
            if (_controlsVisible) _buildOverlay(showExit: true),
          ],
        ),
      ),
    );
  }

  Widget _buildSurface({bool hideInlineControls = false}) {
    if (_loading) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Colors.white70,
            ),
          ),
        ),
      );
    }

    final err = _error;
    if (err != null) return _buildError();

    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }

    final video = Center(
      child: AspectRatio(
        aspectRatio:
            c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
        child: VideoPlayer(c),
      ),
    );

    // 全屏模式下控制层由外层 Stack 统一画，这里只放画面
    if (hideInlineControls) return video;

    return GestureDetector(
      onTap: () {
        if (_controlsVisible) {
          setState(() => _controlsVisible = false);
        } else {
          _scheduleHideControls();
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          video,
          if (_controlsVisible) _buildOverlay(showExit: false),
        ],
      ),
    );
  }

  /// 播放控制层：播放/暂停、进度条、时间、全屏按钮。
  Widget _buildOverlay({required bool showExit}) {
    final c = _controller;
    final initialized = c != null && c.value.isInitialized;
    final pos = initialized ? c.value.position : Duration.zero;
    final dur = initialized ? c.value.duration : Duration.zero;

    return Container(
      color: Colors.black26,
      child: Column(
        children: [
          if (showExit)
            Align(
              alignment: Alignment.topLeft,
              child: SafeArea(
                child: IconButton(
                  icon: const Icon(Icons.fullscreen_exit_rounded,
                      color: Colors.white),
                  tooltip: '退出全屏',
                  onPressed: _toggleFullscreen,
                ),
              ),
            ),
          Expanded(
            child: Center(
              child: IconButton(
                iconSize: 56,
                icon: Icon(
                  (initialized && c.value.isPlaying)
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_filled_rounded,
                  color: Colors.white,
                  semanticLabel:
                      (initialized && c.value.isPlaying) ? '暂停' : '播放',
                ),
                onPressed: _togglePlay,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Text(
                  _fmt(pos),
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      value: dur.inMilliseconds == 0
                          ? 0
                          : pos.inMilliseconds
                              .clamp(0, dur.inMilliseconds)
                              .toDouble(),
                      max: dur.inMilliseconds == 0
                          ? 1
                          : dur.inMilliseconds.toDouble(),
                      onChanged: initialized
                          ? (v) => _seekTo(Duration(milliseconds: v.round()))
                          : null,
                    ),
                  ),
                ),
                Text(
                  _fmt(dur),
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(
                    _fullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    color: Colors.white,
                  ),
                  tooltip: _fullscreen ? '退出全屏' : '全屏',
                  onPressed: _toggleFullscreen,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    final err = _error!;
    late final IconData icon;
    late final String title;
    late final String hint;

    switch (err) {
      case _PlayerError.auth:
        icon = Icons.lock_outline_rounded;
        title = '登录状态已失效';
        hint = '解密密钥需要有效的登录会话。$_errorDetail';
      case _PlayerError.play:
        icon = Icons.error_outline_rounded;
        title = '播放失败';
        hint = _errorDetail;
    }

    return ColoredBox(
      color: Colors.black,
      // 视频区高度固定（AspectRatio 16:9 ≈ 508px），错误内容（图标+标题+4行
      // 提示+按钮）原生高度可能超过这个值：溢出 AspectRatio 的部分虽然会绘制
      // 出来，但**不参与命中测试**——按钮会被"画出来却点不到"（P5 实测踩坑）。
      // 所以这里：内容紧凑化 + 竖向可滚动，保证按钮始终在视频区内可点击。
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(AppTheme.gap16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 36, color: Colors.white38),
                    const SizedBox(height: AppTheme.gap8),
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: AppTheme.gap8),
                    Text(
                      hint,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    const SizedBox(height: AppTheme.gap16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('重试'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white24),
                            minimumSize: const Size(96, 38),
                          ),
                        ),
                        if (err == _PlayerError.auth) ...[
                          const SizedBox(width: AppTheme.gap12),
                          FilledButton(
                            onPressed: _goLogin,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.seed,
                              foregroundColor: const Color(0xFF06231F),
                              minimumSize: const Size(96, 38),
                            ),
                            child: const Text('去登录'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 视频信息区（非全屏时显示在下方）。
  Widget _buildInfo() {
    final m = _meta;
    return ListView(
      padding: const EdgeInsets.all(AppTheme.gap16),
      children: [
        Text(
          m?.name ?? widget.videoId,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppTheme.gap12),
        Wrap(
          spacing: AppTheme.gap8,
          runSpacing: AppTheme.gap8,
          children: [
            if (m != null && m.duration != null)
              _chip(Icons.schedule_rounded, m.durationText),
            if (m != null && m.sizeBytes != null)
              _chip(Icons.sd_storage_outlined, m.sizeText),
            _chip(Icons.visibility_outlined, '${m?.views ?? 0} 次播放'),
            if (m != null && m.date.isNotEmpty)
              _chip(Icons.event_outlined, m.date.split('T').first),
          ],
        ),
        if (m != null && m.description.trim().isNotEmpty) ...[
          const SizedBox(height: AppTheme.gap16),
          Text(
            m.description,
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 13, height: 1.5),
          ),
        ],
        const SizedBox(height: AppTheme.gap24),
        Text(
          'videoId: ${widget.videoId}',
          style: const TextStyle(fontSize: 10, color: AppTheme.textTertiary),
        ),
      ],
    );
  }

  Widget _chip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppTheme.textTertiary),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final total = d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
