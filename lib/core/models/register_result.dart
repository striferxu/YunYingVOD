/// register_result.dart — 注册成功返回（契约 §5.3）。
///
/// 服务端 200 响应：
/// ```json
/// {"ok": true, "id": 181, "username": "newuser", "status": "pending",
///  "message": "注册成功，账号待管理员审核后即可登录"}
/// ```
///
/// 注意：注册成功后**不会**建立会话，用户必须等管理员审核通过后才能登录。
library;

class RegisterResult {
  /// 新用户 id（服务端 users.id）。
  final int? id;

  /// 注册的用户名（服务端回显）。
  final String username;

  /// 账号状态，注册后固定为 `pending`。
  final String status;

  /// 服务端给的用户可读提示。
  final String message;

  const RegisterResult({
    this.id,
    required this.username,
    this.status = 'pending',
    this.message = '注册成功，账号待管理员审核后即可登录',
  });

  /// 是否处于待审核状态。
  bool get isPending => status == 'pending';

  /// 用户名规则提示，与后端 400 文案保持一致。
  ///
  /// 后端原文：`username 需为 3-32 位字母/数字/下划线/点/横线`
  /// Web 端 `app.js:140` 用的是同一句话（去掉前缀 username）。
  static const String usernameRuleText = '用户名需为 3-32 位字母/数字/下划线/点/横线';

  factory RegisterResult.fromJson(Map<String, dynamic> json) {
    return RegisterResult(
      id: (json['id'] as num?)?.toInt(),
      username: (json['username'] ?? '').toString(),
      status: (json['status'] ?? 'pending').toString(),
      message: (json['message'] ?? '注册成功，账号待管理员审核后即可登录')
          .toString(),
    );
  }
}
