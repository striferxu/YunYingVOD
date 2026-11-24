/// auth_controller.dart — 会话状态机（P3 核心）。
///
/// 职责边界：
///   * 持有"当前是否已登录"的唯一真相，供路由守卫和 UI 订阅
///   * 负责三条路径的会话恢复：Cookie 有效 → 直接用；Cookie 失效但 app token 有效 →
///     静默换新 session；两者都无效 → 需要登录
///   * 登录 / 登出 / 前台保活
///
/// 不负责：页面跳转（由 router redirect 根据状态决定）、UI 文案（由页面决定）。
///
/// 服务端事实（P0/P1 实测，勿凭印象改）：
///   * `POST /api/login` 成功下发 `site_session` Cookie，1800s 滑动续期
///   * 错密码 / 用户不存在 / pending 审核 **都返回 401 同一文案**（不可做用户枚举提示）
///   * 第 11 次连续错密码 → 423，锁 600 秒
///   * nginx 登录限流 15r/m burst=5，超限 503 HTML
///   * `POST /api/logout` 必须带 `{}`（ApiClient 已统一处理）
library;

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'models/user.dart';
import 'session_store.dart';

/// 会话状态。
enum AuthStatus {
  /// 尚未完成启动检查（App 刚启动，正在读本地 Cookie/token）
  unknown,

  /// 已登录，Cookie 可用
  authenticated,

  /// 未登录，需要用户输入密码
  unauthenticated,
}

/// 登录失败的可展示错误。把 ApiException 翻译成用户能看懂的话。
class AuthError implements Exception {
  /// 面向用户的文案。
  final String message;

  /// 是否是"账号被锁定"（423）。页面可据此显示倒计时提示。
  final bool locked;

  /// 是否是限流（503）。页面可据此提示稍后再试。
  final bool rateLimited;

  /// 原始状态码，调试用。
  final int? statusCode;

  const AuthError(
    this.message, {
    this.locked = false,
    this.rateLimited = false,
    this.statusCode,
  });

  @override
  String toString() => message;
}

class AuthController extends ChangeNotifier {
  final ApiClient _api;
  final SessionStore _store;

  AuthController({ApiClient? api, SessionStore? store})
      : _api = api ?? ApiClient(),
        _store = store ?? SessionStore();

  AuthStatus _status = AuthStatus.unknown;
  AuthStatus get status => _status;

  AppUser? _user;
  AppUser? get user => _user;

  bool get isLoggedIn => _status == AuthStatus.authenticated;
  bool get isAdmin => _user?.isAdmin ?? false;

  /// 启动检查是否已完成（路由守卫用它决定是否显示 splash）。
  bool get isReady => _status != AuthStatus.unknown;

  /// 最近一次会话恢复的方式，便于调试与验收记录。
  String _lastRestorePath = 'none';
  String get lastRestorePath => _lastRestorePath;

  Timer? _keepAliveTimer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  /// 保活间隔。服务端 session 30 分钟滑动续期，10 分钟调一次足够安全。
  static const Duration keepAliveInterval = Duration(minutes: 10);

  // ---------------------------------------------------------------------------
  // 启动引导
  // ---------------------------------------------------------------------------

  /// App 启动时调用一次。按优先级尝试恢复会话。
  ///
  /// 返回 true 表示已登录。
  Future<bool> bootstrap() async {
    // 1. 先把持久化的 Cookie 灌进 ApiClient
    final savedCookies = await _store.readCookies();
    if (savedCookies.isNotEmpty) {
      _api.importCookies(savedCookies);
    }

    // 2. Cookie 路径：调 /api/me 验证
    if (_api.hasSession) {
      try {
        final resp = await _api.get('/api/me');
        _applyUser(AppUser.fromJson(resp.data));
        _setStatus(AuthStatus.authenticated);
        _lastRestorePath = 'cookie';
        _startKeepAlive();
        return true;
      } on ApiException catch (e) {
        if (!e.isUnauthorized) {
          // 网络问题（不是会话失效）：不要清 Cookie，标记未登录让用户重试
          // 这样网络恢复后仍能免登录
          _lastRestorePath = 'cookie-network-error';
          _setStatus(AuthStatus.unauthenticated);
          return false;
        }
        // 401 → Cookie 确实失效，继续尝试 token 路径
      }
    }

    // 3. token 路径：用 app token 静默换新 session
    final token = await _store.readAppToken();
    if (token != null) {
      try {
        final resp = await _api.post('/api/app/session', body: {
          'token': token.token,
        });
        _applyUser(AppUser.fromJson(resp.data));
        // 新 Cookie 必须落盘，否则下次启动又要换
        await _store.writeCookies(_api.exportCookies());
        _setStatus(AuthStatus.authenticated);
        _lastRestorePath = 'app_token';
        _startKeepAlive();
        return true;
      } on ApiException catch (e) {
        if (e.isUnauthorized) {
          // token 过期或被踢，清掉，走登录
          await _store.clearAppToken();
          _lastRestorePath = 'app_token-expired';
        } else {
          _lastRestorePath = 'app_token-network-error';
        }
      }
    }

    // 4. 都失败
    if (_lastRestorePath == 'none') _lastRestorePath = 'no-credentials';
    _api.clearCookies();
    await _store.clearCookies();
    _setStatus(AuthStatus.unauthenticated);
    return false;
  }

  // ---------------------------------------------------------------------------
  // 登录
  // ---------------------------------------------------------------------------

  /// 登录。失败抛 [AuthError]（含面向用户的文案）。
  ///
  /// 成功后自动签发 app token 并持久化，实现"30 天内免登录"。
  Future<void> login(String username, String password) async {
    final u = username.trim();
    if (u.isEmpty) {
      throw const AuthError('请输入用户名');
    }
    if (password.isEmpty) {
      throw const AuthError('请输入密码');
    }

    // 登录前先清掉旧的 Cookie，避免带上失效 Cookie 造成混淆
    _api.clearCookies();

    ApiResponse resp;
    try {
      resp = await _api.post('/api/login', body: {
        'username': u,
        'password': password,
      });
    } on ApiException catch (e) {
      throw _translateLoginError(e);
    }

    _applyUser(AppUser.fromJson(resp.data));
    await _store.writeCookies(_api.exportCookies());
    await _store.saveLastUsername(u);

    // 签发前先清掉本地残留的旧 token，避免"杀进程不点登出"导致
    // 服务端同设备堆积多条记录。这里只是尽力而为，失败不影响登录。
    await _purgeStaleLocalToken();

    // 签发长效 token。失败不阻塞登录（用户这次仍能用），只是下次要重输。
    await _issueAppTokenQuietly();

    _setStatus(AuthStatus.authenticated);
    _lastRestorePath = 'login';
    _startKeepAlive();
  }

  /// 把服务端的原始错误翻译成用户能看懂的文案。
  ///
  /// 注意：401 不区分"用户不存在/密码错/pending 审核"，这是服务端刻意为之
  /// （防用户枚举），客户端也必须保持模糊。
  AuthError _translateLoginError(ApiException e) {
    if (e.isLocked) {
      return const AuthError(
        '账号已锁定，请 10 分钟后再试',
        locked: true,
        statusCode: 423,
      );
    }
    if (e.isRateLimited) {
      return const AuthError(
        '操作过于频繁，请稍后再试',
        rateLimited: true,
        statusCode: 503,
      );
    }
    if (e.statusCode == 401) {
      return const AuthError('用户名或密码错误', statusCode: 401);
    }
    if (e.statusCode == 403) {
      return AuthError('请求被拒绝（${e.message}）', statusCode: 403);
    }
    if (e.statusCode == null) {
      return AuthError(e.message);
    }
    return AuthError(e.message, statusCode: e.statusCode);
  }

  /// 登录前清理本地残留的旧 token（服务端一并删掉）。
  ///
  /// 场景：用户上次直接杀进程、没走登出流程 → 本地还有旧 token、服务端也有记录。
  /// 不清理的话每登录一次就多一条，设备管理页会看到一堆同名设备。
  Future<void> _purgeStaleLocalToken() async {
    final stale = await _store.readAppToken();
    if (stale == null) return;
    if (stale.id != null && stale.id! > 0) {
      try {
        await _api.delete('/api/app/tokens/${stale.id}');
      } catch (_) {
        // 404 或网络错误都无所谓，继续签发新 token
      }
    }
    await _store.clearAppToken();
  }

  /// 签发 app token 并持久化。失败静默（不影响本次登录）。
  Future<void> _issueAppTokenQuietly() async {
    try {
      final resp = await _api.post('/api/app/token', body: {
        'device_name': await deviceLabel(),
        'platform': 'android',
      });
      final issued = IssuedToken.fromJson(resp.data);
      if (issued.token.isNotEmpty) {
        await _store.writeAppToken(issued.token, issued.expiresAt,
            id: issued.id);
      }
    } catch (_) {
      // 忽略：本次会话仍可用，只是下次启动要重新登录
    }
  }

  /// 显式重新签发 token（设备管理页或 token 快过期时用）。
  Future<IssuedToken?> issueAppToken() async {
    try {
      final resp = await _api.post('/api/app/token', body: {
        'device_name': await deviceLabel(),
        'platform': 'android',
      });
      final issued = IssuedToken.fromJson(resp.data);
      if (issued.token.isNotEmpty) {
        await _store.writeAppToken(issued.token, issued.expiresAt,
            id: issued.id);
      }
      return issued;
    } on ApiException {
      return null;
    }
  }

  /// 设备显示名，如 `Pixel 8 / Android 14`。取不到就用 deviceId。
  Future<String> deviceLabel() async {
    try {
      final info = DeviceInfoPlugin();
      final android = await info.androidInfo;
      final model = android.model.trim();
      final version = android.version.release.trim();
      if (model.isNotEmpty) {
        return version.isEmpty ? model : '$model / Android $version';
      }
    } catch (_) {
      // 非 Android 或插件不可用，退回 deviceId
    }
    return await _store.deviceId();
  }

  /// 上次登录的用户名，供登录页预填（**不预填密码**）。
  Future<String?> lastUsername() => _store.lastUsername();

  // ---------------------------------------------------------------------------
  // 登出
  // ---------------------------------------------------------------------------

  /// 登出：通知服务端销毁 session → 作废本机 app token → 清本地。
  ///
  /// 服务端失败也继续清本地（否则用户会被卡在登录态出不去）。
  Future<void> logout() async {
    _stopKeepAlive();

    // 1. 先作废本机 app token（需 session 还在，所以放在 logout 之前）
    await _revokeOwnToken();

    // 2. 销毁服务端 session
    try {
      await _api.post('/api/logout');
    } catch (_) {
      // 忽略：网络断了也要能登出
    }

    // 3. 清本地
    _api.clearCookies();
    await _store.clearSession();
    _user = null;
    _lastRestorePath = 'logout';
    _setStatus(AuthStatus.unauthenticated);
  }

  /// 作废本机 app token。
  ///
  /// 历史教训（P3 真机验收暴露的 bug）：早期实现靠 `/api/app/tokens` 返回的
  /// `current` 字段判断哪条是本机，但服务端 `list_tokens` 根本没传
  /// `current_token_id`，该字段恒为 false → 本机 token 从未被删除 →
  /// 每次登录多一条，设备管理页堆积重复记录。
  ///
  /// 现在改为**签发时就把 id 存进 secure storage**，登出按 id 精确 DELETE，
  /// 不依赖任何服务端字段。
  Future<void> _revokeOwnToken() async {
    final saved = await _store.readAppToken();
    if (saved == null) return;

    // 主路径：本地有 id，直接删
    if (saved.id != null && saved.id! > 0) {
      try {
        await _api.delete('/api/app/tokens/${saved.id}');
        return;
      } on ApiException catch (e) {
        // 404 = 服务端已经没有了（可能被别处删掉），也算成功
        if (e.statusCode == 404) return;
        // 其余错误继续走兜底
      } catch (_) {
        // 网络错误，继续走兜底
      }
    }

    // 兜底路径：旧版本存下的 token 没有 id，按设备名匹配删除。
    // 只删**与本机 device_name 完全一致**的条目，避免误删用户其他设备。
    try {
      final label = await deviceLabel();
      final listResp = await _api.get('/api/app/tokens');
      final items = (listResp.data['items'] as List?) ?? const [];
      for (final raw in items) {
        if (raw is! Map) continue;
        if (raw['device_name'] == label) {
          await _api.delete('/api/app/tokens/${raw['id']}');
          break;
        }
      }
    } catch (_) {
      // 彻底失败也不阻塞登出：session 已销毁，token 会自然过期
    }
  }

  // ---------------------------------------------------------------------------
  // 保活
  // ---------------------------------------------------------------------------

  void _startKeepAlive() {
    _stopKeepAlive();
    _keepAliveTimer = Timer.periodic(keepAliveInterval, (_) {
      // 不 await：失败由内部处理，不阻塞定时器
      refreshSession(silent: true);
    });
  }

  void _stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  /// 刷新会话。`silent = true` 时失败不抛异常、不改登录态（用于定时保活）。
  ///
  /// 返回 true 表示会话仍有效。
  Future<bool> refreshSession({bool silent = false}) async {
    if (_status != AuthStatus.authenticated) return false;
    try {
      final resp = await _api.get('/api/me');
      _applyUser(AppUser.fromJson(resp.data));
      // 滑动续期后 Cookie 值不变但过期时间变了，无需重存（值没变）
      return true;
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        // 会话过期 → 试 token 静默换新
        final ok = await _tryTokenRefresh();
        if (!ok) {
          _api.clearCookies();
          await _store.clearCookies();
          _setStatus(AuthStatus.unauthenticated);
          if (!silent) {
            throw const AuthError('登录已过期，请重新登录', statusCode: 401);
          }
          return false;
        }
        return true;
      }
      // 网络错误：保持登录态（可能是弱网），不改状态
      return false;
    }
  }

  /// 用 app token 换新 session。成功返回 true。
  Future<bool> _tryTokenRefresh() async {
    if (_refreshing) return false;
    final token = await _store.readAppToken();
    if (token == null) return false;
    _refreshing = true;
    try {
      final resp = await _api.post('/api/app/session', body: {
        'token': token.token,
      });
      _applyUser(AppUser.fromJson(resp.data));
      await _store.writeCookies(_api.exportCookies());
      _lastRestorePath = 'app_token-refresh';
      return true;
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await _store.clearAppToken();
      }
      return false;
    } finally {
      _refreshing = false;
    }
  }

  /// App 回到前台时调用。轻量刷新一次。
  Future<void> onAppResumed() async {
    if (_status != AuthStatus.authenticated) return;
    await refreshSession(silent: true);
  }

  /// 本机设备被踢下线时调用（设备管理页移除当前设备后）。
  ///
  /// 与 [logout] 的区别：这里服务端 session 已被 revoke 连带销毁，
  /// 不需要再调 /api/logout，只需清本地并切状态。
  ///
  /// 为什么必须显式调用：服务端 revoke 会删掉 token 和对应 session，
  /// 但客户端内存里的 Cookie 还在。若不立刻切状态，用户会停留在已登录界面；
  /// 更糟的是 bootstrap 会先试 Cookie → 服务端已删 → 401 → 再试 token → 也没了
  /// → 才降级到登录页，中间多绕两圈还可能撞上网络错误而"看起来仍登录"。
  Future<void> onSelfRevoked() async {
    _stopKeepAlive();
    _api.clearCookies();
    await _store.clearSession();
    _user = null;
    _lastRestorePath = 'self_revoked';
    _setStatus(AuthStatus.unauthenticated);
  }

  /// 全局 401 回调（由 main.dart 订阅 ApiClient.onUnauthorized 触发）。
  ///
  /// 注意：`refreshSession` 内部也会遇到 401，那时会先尝试 token 换新；
  /// 这里是被动兜底——某个业务接口 401 了，说明当前 Cookie 已废。
  /// 先尝试用 token 救回来，救不回来才切未登录。
  Future<void> handleGlobalUnauthorized() async {
    if (_status != AuthStatus.authenticated) return;
    // 已经在刷新中就不重复触发
    if (_refreshing) return;
    final ok = await _tryTokenRefresh();
    if (!ok) {
      _stopKeepAlive();
      _api.clearCookies();
      await _store.clearCookies();
      _setStatus(AuthStatus.unauthenticated);
    }
  }

  bool _refreshing = false;

  // ---------------------------------------------------------------------------
  // 网络状态（给 UI 提示用）
  // ---------------------------------------------------------------------------

  /// 当前是否在线。null 表示尚未探测。
  bool? _online;
  bool? get online => _online;

  /// 开始监听网络状态变化。返回订阅，调用方可自行取消。
  StreamSubscription<List<ConnectivityResult>> watchConnectivity(
      void Function(bool online) onChange) {
    final conn = Connectivity();
    // 立即探一次
    conn.checkConnectivity().then((r) {
      final isOnline = r.any((e) => e != ConnectivityResult.none);
      _online = isOnline;
      onChange(isOnline);
    }).catchError((_) {});
    _connSub?.cancel();
    _connSub = conn.onConnectivityChanged.listen((r) {
      final isOnline = r.any((e) => e != ConnectivityResult.none);
      _online = isOnline;
      onChange(isOnline);
    });
    return _connSub!;
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  void _applyUser(AppUser u) {
    _user = u;
  }

  void _setStatus(AuthStatus s) {
    if (_status == s) return;
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopKeepAlive();
    _connSub?.cancel();
    super.dispose();
  }
}

/// 便于日志/验收记录：当前运行平台名。
String get platformLabel {
  if (kIsWeb) return 'web';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isWindows) return 'windows';
  return 'unknown';
}
