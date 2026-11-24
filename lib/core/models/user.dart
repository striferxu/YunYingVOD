/// user.dart — 用户与设备模型。
///
/// 来源接口：
///   POST /api/login         -> {ok, username, role}
///   GET  /api/me            -> {username, role, expires_at}
///   GET  /api/me_full       -> {user:{...}, stats:{...}}
///   GET  /api/app/tokens    -> {total, items:[AppDevice]}
///   POST /api/app/token     -> {ok, id, token, expires_at, ttl_days, device_name, platform}
library;

/// 用户角色。admin 管理功能不进 App（P8 决策），仅用于判断是否显示入口。
enum UserRole {
  admin,
  user;

  static UserRole parse(String? raw) =>
      raw == 'admin' ? UserRole.admin : UserRole.user;

  String get label => this == UserRole.admin ? '管理员' : '普通用户';
}

class AppUser {
  final String username;
  final UserRole role;

  /// 当前会话到期时间（epoch 秒）。来自 /api/me。
  final int? expiresAt;

  const AppUser({
    required this.username,
    this.role = UserRole.user,
    this.expiresAt,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      username: (json['username'] ?? json['user'] ?? '').toString(),
      role: UserRole.parse(_strOrNull(json['role'])),
      expiresAt: _intOrNull(json['expires_at']),
    );
  }

  Map<String, dynamic> toJson() => {
        'username': username,
        'role': role.name,
        'expires_at': expiresAt,
      };

  bool get isAdmin => role == UserRole.admin;
}

/// 已授权设备（app token）。
class AppDevice {
  final int id;
  final String deviceName;
  final String platform;

  /// 签发时间（epoch 秒）。
  final int createdAt;

  /// 最近一次用该 token 换 session 的时间；从未使用则为 null。
  final int? lastUsedAt;
  final int expiresAt;
  final String? ip;

  /// 是否是当前会话对应的设备。
  final bool current;

  const AppDevice({
    required this.id,
    required this.deviceName,
    required this.platform,
    required this.createdAt,
    required this.expiresAt,
    this.lastUsedAt,
    this.ip,
    this.current = false,
  });

  factory AppDevice.fromJson(Map<String, dynamic> json) {
    return AppDevice(
      id: _intOrNull(json['id']) ?? 0,
      deviceName: (json['device_name'] ?? '未命名设备').toString(),
      platform: (json['platform'] ?? 'unknown').toString(),
      createdAt: _intOrNull(json['created_at']) ?? 0,
      lastUsedAt: _intOrNull(json['last_used_at']),
      expiresAt: _intOrNull(json['expires_at']) ?? 0,
      ip: _strOrNull(json['ip']),
      current: json['current'] == true,
    );
  }

  /// 剩余有效天数（向上取整），已过期为 0。
  int get remainingDays {
    final left = expiresAt - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (left <= 0) return 0;
    return (left / 86400).ceil();
  }
}

/// 签发 app token 的响应。
class IssuedToken {
  final int id;
  final String token;
  final int expiresAt;
  final int ttlDays;
  final String deviceName;
  final String platform;

  const IssuedToken({
    required this.id,
    required this.token,
    required this.expiresAt,
    required this.ttlDays,
    required this.deviceName,
    required this.platform,
  });

  factory IssuedToken.fromJson(Map<String, dynamic> json) {
    return IssuedToken(
      id: _intOrNull(json['id']) ?? 0,
      token: (json['token'] ?? '').toString(),
      expiresAt: _intOrNull(json['expires_at']) ?? 0,
      ttlDays: _intOrNull(json['ttl_days']) ?? 30,
      deviceName: (json['device_name'] ?? '').toString(),
      platform: (json['platform'] ?? '').toString(),
    );
  }
}

String? _strOrNull(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

int? _intOrNull(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}
