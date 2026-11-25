/// media_proxy.dart — 本地媒体代理（P5 网络绕行方案）。
///
/// ## 为什么需要这个
///
/// 实测（详见 docs/P5_ACCEPTANCE.md 第 6 节）：真机所在网络对
/// `SNI=*.ccwu.cc` 的 TLS 握手做了特征阻断——中间设备按 ClientHello 特征
/// 注入 RST（IP ID=0、同一 seq 重复 3~4 次）。
///
/// 关键差异：
///   * **Dart 的 BoringSSL** 默认带后量子密钥交换（X25519MLKEM768），
///     ClientHello 约 1473 字节、跨两个 TCP 段 → 阻断设备匹配不上 → 放行。
///   * **Android Conscrypt（ExoPlayer）** 只发 x25519，ClientHello 约 465 字节
///     单段完整可见 → 被匹配并 RST。
///
/// 所以：让 ExoPlayer 只连本机明文 HTTP，由 Dart 去完成真正的 HTTPS 请求。
///
/// ## 设计要点
///
/// 1. 只监听 `127.0.0.1`，端口由系统分配（避免冲突），生命周期跟随播放器。
/// 2. **白名单**：只转发 `/videos/` 与 `/key/` 两类路径，其余一律 404。
///    不做成通用开放代理（安全 + 避免被滥用）。
/// 3. **Cookie 由本进程注入**，不经过播放器；播放器完全不需要知道会话。
/// 4. m3u8 里的 `#EXT-X-KEY:URI="/key/<id>"` 会被重写成
///    `http://127.0.0.1:<port>/key/<id>`，保证 key 请求也回到本代理。
///    ts 分段是相对文件名，会基于 m3u8 的 URL 解析成
///    `http://127.0.0.1:<port>/videos/<id>/xxx.ts` → 同样回到本代理。
/// 5. 上游请求**不带 Referer**（nginx `valid_referers none server_names`，
///    不带 Referer 命中 `none` 放行）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_client.dart';

/// 本地媒体代理。`start()` 后把 [localUrl] 交给播放器即可。
class MediaProxy {
  MediaProxy._(this._server, this._upstreamBase, this._cookie);

  final HttpServer _server;
  final String _upstreamBase;
  final String _cookie;

  /// 本地可访问的基地址，如 `http://127.0.0.1:38291`。
  String get localUrl => 'http://127.0.0.1:${_server.port}';

  bool _closed = false;

  /// 允许转发的路径前缀白名单。
  static const _allowedPrefixes = ['/videos/', '/key/'];

  /// 启动代理。失败返回 null（调用方应回退到直连上游）。
  ///
  /// 复用 [ApiClient] 的 baseUrl 与当前会话 Cookie。
  static Future<MediaProxy?> start() async {
    final api = ApiClient();
    final cookie = api.mediaHeaders['Cookie'];
    if (cookie == null || cookie.isEmpty) return null;

    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0, // 端口由系统分配
        shared: false,
      );
      final proxy = MediaProxy._(server, api.baseUrl, cookie);
      // 不 await：常驻监听
      unawaited(proxy._serve());
      return proxy;
    } on SocketException {
      return null;
    }
  }

  Future<void> _serve() async {
    await for (final req in _server) {
      // 每条请求独立处理，异常不拖垮整个代理
      unawaited(_handle(req).catchError((Object _) async {
        try {
          req.response.statusCode = HttpStatus.badGateway;
          await req.response.close();
        } catch (_) {}
      }));
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;

    // 白名单：只允许媒体相关路径
    if (!_allowedPrefixes.any(path.startsWith)) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final upstream = await client.getUrl(
        Uri.parse('$_upstreamBase$path${req.uri.hasQuery ? '?${req.uri.query}' : ''}'),
      );
      // 只注入 Cookie，绝不加 Referer
      upstream.headers.set(HttpHeaders.cookieHeader, _cookie);

      // Range 透传：ExoPlayer 会带 Range 请求 ts 片段
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        upstream.headers.set(HttpHeaders.rangeHeader, range);
      }

      final resp = await upstream.close();

      // m3u8 要改写 key URI；其余原样流式转发
      final isPlaylist = path.endsWith('.m3u8') ||
          (resp.headers.contentType?.mimeType == 'application/vnd.apple.mpegurl');

      if (isPlaylist) {
        final body = await resp.transform(utf8.decoder).join();
        final rewritten = _rewritePlaylist(body);
        final bytes = utf8.encode(rewritten);
        req.response.statusCode = resp.statusCode;
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        req.response.headers.contentLength = bytes.length;
        req.response.add(bytes);
      } else {
        req.response.statusCode = resp.statusCode;
        final ct = resp.headers.contentType;
        if (ct != null) req.response.headers.contentType = ct;
        // 注意：不复制 contentLength。Dart 的 HttpClient 默认会自动解 gzip，
        // 上游声明的长度是压缩后的，直接透传会导致长度不匹配、连接卡死。
        // 交给 chunked 编码即可，ExoPlayer 完全支持。
        await resp.pipe(req.response);
        return;
      }
      await req.response.close();
    } finally {
      client.close();
    }
  }

  /// 把 m3u8 里的 `URI="/key/<id>"` 改成指向本代理的绝对地址。
  ///
  /// 用绝对地址而不是相对路径，是为了不依赖播放器对相对 URI 的解析行为
  /// （相对 URI 在 HLS 里是相对 m3u8 的位置，虽然结果相同，但显式更稳）。
  String _rewritePlaylist(String body) {
    return body.replaceAllMapped(
      RegExp(r'URI="([^"]+)"'),
      (m) {
        final uri = m.group(1)!;
        if (uri.startsWith('http://') || uri.startsWith('https://')) return m.group(0)!;
        // 相对路径（可能是 /key/xxx 或 key/xxx）
        final abs = uri.startsWith('/') ? uri : '/$uri';
        return 'URI="$localUrl$abs"';
      },
    );
  }

  /// 关闭代理。播放页 dispose 时调用。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
  }
}
