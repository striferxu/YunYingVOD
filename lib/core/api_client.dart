/// api_client.dart — 唯一的 HTTP 出口。
///
/// 设计约束（来自 PHASE_PLAN P2 验收标准）：
///   1. 超时 15 秒
///   2. 自动带 Cookie（服务端用 `site_session` Cookie，HttpOnly;Secure;SameSite=Lax）
///   3. 401 时通过 broadcast stream 广播，页面可订阅后统一跳登录
///
/// 服务端细节（P0 实测，勿凭印象改）：
///   * 写接口（POST/DELETE/PUT）必须 `Content-Type: application/json`，
///     且**即使没有请求体也要发 `{}`**，否则 403 CSRF check failed。
///   * `POST /api/logout` 同理必须带 `{}`。
///   * 登录限流 15r/m burst=5，超限返回 503 HTML；第 11 次错密码返回 423 锁 10 分钟。
///   * Flutter 不带 Origin 头，服务端放行（Origin 校验只针对浏览器）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 服务端返回的业务错误。
class ApiException implements Exception {
  /// HTTP 状态码；网络层失败时为 null。
  final int? statusCode;

  /// 服务端 `{"error": "..."}` 里的原始文案（未翻译）。
  final String message;

  /// 附加的解析后 body，便于调用方取细节。
  final Map<String, dynamic>? body;

  const ApiException(this.message, {this.statusCode, this.body});

  bool get isUnauthorized => statusCode == 401;

  /// 账号被锁定（423）。服务端锁定 600 秒。
  bool get isLocked => statusCode == 423;

  /// 限流（503，nginx limit_req）。
  bool get isRateLimited => statusCode == 503;

  @override
  String toString() =>
      'ApiException($statusCode): $message';
}

/// 统一的响应封装。
class ApiResponse {
  final int statusCode;
  final Map<String, dynamic> data;

  const ApiResponse(this.statusCode, this.data);

  bool get ok => statusCode >= 200 && statusCode < 300;
}

class ApiClient {
  /// 服务端基址。改环境只改这里。
  static const String defaultBaseUrl = 'https://51play.ccwu.cc';

  static const Duration defaultTimeout = Duration(seconds: 15);

  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;
  ApiClient._internal();

  String baseUrl = defaultBaseUrl;
  Duration timeout = defaultTimeout;

  final http.Client _http = http.Client();

  /// Cookie 罐：只存 name -> value。服务端只用一个 Cookie（site_session），
  /// 但不写死，便于将来扩展。
  final Map<String, String> _cookies = {};

  /// 401 广播。页面订阅后统一处理跳登录。
  final StreamController<void> _unauthorized =
      StreamController<void>.broadcast();

  Stream<void> get onUnauthorized => _unauthorized.stream;

  /// 会话 Cookie 名（P0 实测）。
  static const String sessionCookieName = 'site_session';

  /// 是否有会话 Cookie（不代表仍有效，需调 /api/me 验证）。
  bool get hasSession => _cookies.containsKey(sessionCookieName);

  /// 导出 Cookie 供持久化（session_store 用）。
  Map<String, String> exportCookies() => Map.unmodifiable(_cookies);

  /// 从持久化恢复 Cookie。
  void importCookies(Map<String, String> cookies) {
    _cookies
      ..clear()
      ..addAll(cookies);
  }

  void clearCookies() => _cookies.clear();

  // ---- 底层请求 ----

  Map<String, String> _headers({
    bool json = false,
    Map<String, String>? extra,
  }) {
    final h = <String, String>{
      'Accept': 'application/json',
      'User-Agent': 'VODApp/1.0 (Flutter; Android)',
    };
    if (json) {
      h['Content-Type'] = 'application/json';
    }
    if (_cookies.isNotEmpty) {
      h['Cookie'] = _cookies.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
    }
    if (extra != null) h.addAll(extra);
    return h;
  }

  /// 从响应里吸收 Set-Cookie。
  void _absorbCookies(http.StreamedResponse resp) {
    final raw = resp.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    // http 包会把多个 Set-Cookie 用逗号合并，这里按 `, name=` 切分够用。
    for (final part in _splitSetCookie(raw)) {
      final first = part.split(';').first.trim();
      final idx = first.indexOf('=');
      if (idx <= 0) continue;
      final name = first.substring(0, idx).trim();
      final value = first.substring(idx + 1).trim();
      if (value.isEmpty || value == 'deleted') {
        _cookies.remove(name);
      } else {
        _cookies[name] = value;
      }
    }
  }

  static List<String> _splitSetCookie(String raw) {
    final out = <String>[];
    var start = 0;
    for (var i = 0; i < raw.length; i++) {
      if (raw[i] == ',' &&
          i + 1 < raw.length &&
          raw[i + 1] == ' ' &&
          // 只在疑似新 cookie 起始处切：逗号后是 `name=`
          _looksLikeCookieStart(raw, i + 2)) {
        out.add(raw.substring(start, i).trim());
        start = i + 2;
      }
    }
    out.add(raw.substring(start).trim());
    return out.where((e) => e.isNotEmpty).toList();
  }

  static bool _looksLikeCookieStart(String s, int from) {
    final eq = s.indexOf('=', from);
    if (eq < 0) return false;
    final semi = s.indexOf(';', from);
    return semi < 0 || eq < semi;
  }

  Future<ApiResponse> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    bool allowNonJson = false,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final isWrite =
        method == 'POST' || method == 'PUT' || method == 'DELETE' || method == 'PATCH';
    // 写接口即使无 body 也发 `{}`，否则服务端 403 CSRF check failed
    final payload = isWrite ? jsonEncode(body ?? const <String, dynamic>{}) : null;

    http.StreamedResponse resp;
    try {
      final req = http.Request(method, uri)
        ..headers.addAll(_headers(json: isWrite, extra: headers))
        ..followRedirects = false;
      if (payload != null) req.body = payload;

      resp = await _http.send(req).timeout(timeout);
    } on TimeoutException {
      throw ApiException('请求超时（${timeout.inSeconds}s），请检查网络');
    } on SocketException catch (e) {
      throw ApiException('网络不可用：${e.message}');
    } on http.ClientException catch (e) {
      throw ApiException('请求失败：${e.message}');
    }

    _absorbCookies(resp);

    final text = await resp.stream.bytesToString();
    final status = resp.statusCode;

    if (status == 401) {
      _cookies.remove(sessionCookieName);
      _unauthorized.add(null);
    }

    // 503 通常是 nginx 限流的 HTML 页
    if (status == 503) {
      throw ApiException('请求过于频繁，请稍后再试', statusCode: 503);
    }

    Map<String, dynamic> data;
    if (text.isEmpty) {
      data = const {};
    } else {
      try {
        final decoded = jsonDecode(text);
        data = decoded is Map<String, dynamic>
            ? decoded
            : <String, dynamic>{'data': decoded};
      } catch (_) {
        if (!allowNonJson) {
          // HTML 错误页（nginx/网关），截断避免刷屏
          final brief = text.length > 120 ? '${text.substring(0, 120)}…' : text;
          throw ApiException('服务端返回非 JSON（$status）：$brief',
              statusCode: status);
        }
        data = <String, dynamic>{'raw': text};
      }
    }

    if (status < 200 || status >= 300) {
      final msg = (data['error'] ?? data['message'] ?? '请求失败').toString();
      throw ApiException(msg, statusCode: status, body: data);
    }

    return ApiResponse(status, data);
  }

  // ---- 便捷方法 ----

  Future<ApiResponse> get(String path, {Map<String, String>? headers}) =>
      _send('GET', path, headers: headers);

  Future<ApiResponse> post(String path,
          {Map<String, dynamic>? body, Map<String, String>? headers}) =>
      _send('POST', path, body: body, headers: headers);

  Future<ApiResponse> delete(String path, {Map<String, dynamic>? body}) =>
      _send('DELETE', path, body: body);

  /// 直接用已有 Cookie 拉二进制（P5 拉 key、P4 拉封面会用到）。
  Future<List<int>> getBytes(String path) async {
    final uri = Uri.parse('$baseUrl$path');
    try {
      final req = http.Request('GET', uri)
        ..headers.addAll(_headers());
      final resp = await _http.send(req).timeout(timeout);
      final bytes = await resp.stream.toBytes();
      if (resp.statusCode == 401) {
        _cookies.remove(sessionCookieName);
        _unauthorized.add(null);
        throw ApiException('未授权', statusCode: 401);
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw ApiException('下载失败', statusCode: resp.statusCode);
      }
      return bytes;
    } on TimeoutException {
      throw ApiException('请求超时（${timeout.inSeconds}s）');
    } on SocketException catch (e) {
      throw ApiException('网络不可用：${e.message}');
    }
  }

  /// 把相对路径（如 `/covers/x.jpg`）拼成完整 URL，供 Image.network 用。
  String absoluteUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (!path.startsWith('/')) return '$baseUrl/$path';
    return '$baseUrl$path';
  }

  /// 带 Cookie 的图片请求头，供 Image.network(headers:) 用。
  /// 注意：封面路径 `/covers/` 需要 auth_request 鉴权，必须带 Cookie。
  Map<String, String> get imageHeaders {
    if (_cookies.isEmpty) return const {};
    return {
      'Cookie': _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
    };
  }

  void dispose() {
    _http.close();
    _unauthorized.close();
  }
}
