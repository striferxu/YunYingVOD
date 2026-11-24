/// session_store.dart — Cookie 与 app token 的持久化。
///
/// 安全约束：
///   * Cookie 与 app token 都存 flutter_secure_storage（Android Keystore 加密）。
///   * **不存明文密码**（PHASE_PLAN P3 明确禁止）。
///   * app token 明文只在此处持有，用于静默换 session；DB 侧只存 sha256。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SessionStore {
  static const _kCookies = 'vod_cookies_v1';
  static const _kAppToken = 'vod_app_token_v1';
  static const _kAppTokenExpiry = 'vod_app_token_expiry_v1';
  static const _kDeviceId = 'vod_device_id_v1';
  static const _kLastUser = 'vod_last_username_v1';

  final FlutterSecureStorage _storage;

  SessionStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            // flutter_secure_storage 11.x 默认使用 EncryptedSharedPreferences，
            // 不再需要（也不再支持）显式传 encryptedSharedPreferences: true
            const FlutterSecureStorage();

  // ---- Cookie ----

  Future<Map<String, String>> readCookies() async {
    final raw = await _storage.read(key: _kCookies);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {
      // 损坏就当没有，重新登录
    }
    return {};
  }

  Future<void> writeCookies(Map<String, String> cookies) async {
    if (cookies.isEmpty) {
      await _storage.delete(key: _kCookies);
      return;
    }
    await _storage.write(key: _kCookies, value: jsonEncode(cookies));
  }

  Future<void> clearCookies() => _storage.delete(key: _kCookies);

  // ---- app token ----

  Future<void> writeAppToken(String token, int expiresAt) async {
    await _storage.write(key: _kAppToken, value: token);
    await _storage.write(key: _kAppTokenExpiry, value: expiresAt.toString());
  }

  /// 返回 (token, expiresAt)；任一缺失或已过期返回 null。
  Future<({String token, int expiresAt})?> readAppToken() async {
    final token = await _storage.read(key: _kAppToken);
    final expRaw = await _storage.read(key: _kAppTokenExpiry);
    if (token == null || token.isEmpty || expRaw == null) return null;
    final exp = int.tryParse(expRaw);
    if (exp == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (exp <= now) return null;
    return (token: token, expiresAt: exp);
  }

  Future<void> clearAppToken() async {
    await _storage.delete(key: _kAppToken);
    await _storage.delete(key: _kAppTokenExpiry);
  }

  // ---- 杂项 ----

  /// 稳定的设备标识（随机生成一次后固定），用作 app token 的 device_name 后缀。
  Future<String> deviceId() async {
    final existing = await _storage.read(key: _kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final id = 'and-$now';
    await _storage.write(key: _kDeviceId, value: id);
    return id;
  }

  /// 上次登录的用户名，用于登录页预填（只填用户名，不填密码）。
  Future<String?> lastUsername() => _storage.read(key: _kLastUser);

  Future<void> saveLastUsername(String username) =>
      _storage.write(key: _kLastUser, value: username);

  /// 登出：清 Cookie + token，保留 deviceId 与 lastUsername。
  Future<void> clearSession() async {
    await clearCookies();
    await clearAppToken();
  }
}
