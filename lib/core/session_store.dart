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
  static const _kAppTokenId = 'vod_app_token_id_v1';
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

  /// 保存 token。
  ///
  /// [id] 是服务端 app_tokens 表的主键，**登出时必须靠它精确删除**。
  /// 不能用 `/api/app/tokens` 返回的 `current` 字段判断——服务端 P1 实现里
  /// `list_tokens` 没传 current_token_id，该字段恒为 false（P3 真机验收暴露）。
  Future<void> writeAppToken(String token, int expiresAt, {int? id}) async {
    await _storage.write(key: _kAppToken, value: token);
    await _storage.write(key: _kAppTokenExpiry, value: expiresAt.toString());
    if (id != null && id > 0) {
      await _storage.write(key: _kAppTokenId, value: id.toString());
    } else {
      await _storage.delete(key: _kAppTokenId);
    }
  }

  /// 返回 (token, expiresAt, id)；token 缺失或已过期返回 null。
  ///
  /// `id` 可能为 null（旧版本存下的 token 没有记录 id）。
  Future<({String token, int expiresAt, int? id})?> readAppToken() async {
    final token = await _storage.read(key: _kAppToken);
    final expRaw = await _storage.read(key: _kAppTokenExpiry);
    if (token == null || token.isEmpty || expRaw == null) return null;
    final exp = int.tryParse(expRaw);
    if (exp == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (exp <= now) return null;
    final idRaw = await _storage.read(key: _kAppTokenId);
    return (token: token, expiresAt: exp, id: int.tryParse(idRaw ?? ''));
  }

  Future<void> clearAppToken() async {
    await _storage.delete(key: _kAppToken);
    await _storage.delete(key: _kAppTokenExpiry);
    await _storage.delete(key: _kAppTokenId);
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
