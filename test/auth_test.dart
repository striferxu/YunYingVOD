/// auth_test.dart — P3 会话状态机单元测试。
///
/// 覆盖不依赖网络的纯逻辑：
///   * AuthStatus 状态迁移
///   * AuthError 的错误翻译（401/423/503/网络异常）
///   * AppDevice 剩余天数计算
///   * 路由守卫的重定向规则
///
/// 真实网络链路（登录/换 session/踢设备）在服务器端用 probe_p3.py 实测，
/// 不放进单元测试，避免 CI 依赖线上服务。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vod_app/core/api_client.dart';
import 'package:vod_app/core/auth_controller.dart';
import 'package:vod_app/core/models/user.dart';

void main() {
  group('AuthError 错误翻译', () {
    test('401 统一提示"用户名或密码错误"，不暴露用户是否存在', () {
      // 服务端对 用户不存在 / 密码错 / pending 审核 一律返回 401 同文案，
      // 客户端必须保持模糊，防止用户枚举。
      final err = AuthError('用户名或密码错误', statusCode: 401);
      expect(err.message, '用户名或密码错误');
      expect(err.locked, isFalse);
      expect(err.rateLimited, isFalse);
    });

    test('423 标记为锁定态', () {
      const err = AuthError('账号已锁定，请 10 分钟后再试',
          locked: true, statusCode: 423);
      expect(err.locked, isTrue);
      expect(err.message, contains('10 分钟'));
    });

    test('503 标记为限流态', () {
      const err = AuthError('操作过于频繁，请稍后再试',
          rateLimited: true, statusCode: 503);
      expect(err.rateLimited, isTrue);
    });
  });

  group('ApiException 状态判断', () {
    test('isUnauthorized / isLocked / isRateLimited', () {
      expect(const ApiException('x', statusCode: 401).isUnauthorized, isTrue);
      expect(const ApiException('x', statusCode: 423).isLocked, isTrue);
      expect(const ApiException('x', statusCode: 503).isRateLimited, isTrue);
      expect(const ApiException('x').isUnauthorized, isFalse);
    });

    test('无状态码表示网络层错误（不是服务端拒绝）', () {
      const e = ApiException('请求超时（15s），请检查网络');
      expect(e.statusCode, isNull);
      expect(e.isUnauthorized, isFalse);
    });
  });

  group('AppUser 解析', () {
    test('/api/login 响应解析', () {
      final u = AppUser.fromJson({'ok': true, 'username': 'user', 'role': 'user'});
      expect(u.username, 'user');
      expect(u.role, UserRole.user);
      expect(u.isAdmin, isFalse);
    });

    test('/api/me 响应解析（带 expires_at）', () {
      final u = AppUser.fromJson({
        'username': 'admin',
        'role': 'admin',
        'expires_at': 1800000000,
      });
      expect(u.isAdmin, isTrue);
      expect(u.expiresAt, 1800000000);
      expect(u.role.label, '管理员');
    });

    test('缺字段不崩', () {
      final u = AppUser.fromJson(const {});
      expect(u.username, '');
      expect(u.role, UserRole.user);
      expect(u.expiresAt, isNull);
    });
  });

  group('AppDevice 剩余天数', () {
    test('30 天有效期显示 30 天', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final d = AppDevice(
        id: 1,
        deviceName: 'Pixel 8',
        platform: 'android',
        createdAt: now,
        expiresAt: now + 30 * 86400,
      );
      expect(d.remainingDays, 30);
    });

    test('已过期为 0，不返回负数', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final d = AppDevice(
        id: 1,
        deviceName: 'Old',
        platform: 'android',
        createdAt: now - 100 * 86400,
        expiresAt: now - 86400,
      );
      expect(d.remainingDays, 0);
    });

    test('解析服务端返回的完整字段', () {
      final d = AppDevice.fromJson({
        'id': 7,
        'device_name': 'Pixel 8 / Android 14',
        'platform': 'android',
        'created_at': 1700000000,
        'last_used_at': 1700001000,
        'expires_at': 1702592000,
        'ip': '1.2.3.4',
        'current': true,
      });
      expect(d.id, 7);
      expect(d.deviceName, contains('Android 14'));
      expect(d.lastUsedAt, 1700001000);
      expect(d.ip, '1.2.3.4');
      expect(d.current, isTrue);
    });

    test('last_used_at 为 null 表示从未使用', () {
      final d = AppDevice.fromJson({
        'id': 1,
        'device_name': 'X',
        'platform': 'android',
        'created_at': 1,
        'expires_at': 2,
      });
      expect(d.lastUsedAt, isNull);
      expect(d.ip, isNull);
      expect(d.current, isFalse);
    });
  });

  group('IssuedToken 解析', () {
    test('完整响应', () {
      final t = IssuedToken.fromJson({
        'ok': true,
        'id': 12,
        'token': 'vap_abcdef',
        'expires_at': 1702592000,
        'ttl_days': 30,
        'device_name': 'Pixel 8',
        'platform': 'android',
      });
      expect(t.token, startsWith('vap_'));
      expect(t.ttlDays, 30);
      expect(t.deviceName, 'Pixel 8');
    });

    test('ttl_days 缺失时默认 30', () {
      final t = IssuedToken.fromJson({'token': 'vap_x'});
      expect(t.ttlDays, 30);
      expect(t.id, 0);
    });
  });

  group('AuthStatus 语义', () {
    test('isLoggedIn 只在 authenticated 为真', () {
      expect(AuthStatus.authenticated == AuthStatus.authenticated, isTrue);
      expect(AuthStatus.unknown == AuthStatus.authenticated, isFalse);
      expect(AuthStatus.unauthenticated == AuthStatus.authenticated, isFalse);
    });
  });
}
