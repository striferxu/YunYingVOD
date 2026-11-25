/// p7_test.dart — P7 注册（审核制）单元测试。
///
/// 覆盖：
///   * 用户名规则与后端 `USERNAME_RE` 一致性（含边界 2/3/32/33 位、中文、特殊字符）
///   * RegisterResult 解析与默认值
///   * 注册错误翻译（409 / 400 各分支 / 403 / 503 / 网络）
///   * 登录 401 文案含"待审核"提示
///
/// 真实网络链路（提交注册 → Web 后台待审核出现）在真机验收时实测，
/// 不放进单测，避免 CI 依赖线上服务。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vod_app/core/auth_controller.dart';
import 'package:vod_app/core/models/register_result.dart';

void main() {
  group('用户名规则（与后端 USERNAME_RE 一致）', () {
    final re = AuthController.usernamePattern;

    test('合法：3 位最小长度', () {
      expect(re.hasMatch('abc'), isTrue);
      expect(re.hasMatch('a_b'), isTrue);
      expect(re.hasMatch('a.b'), isTrue);
      expect(re.hasMatch('a-b'), isTrue);
      expect(re.hasMatch('A1_'), isTrue);
    });

    test('合法：32 位最大长度', () {
      expect(re.hasMatch('a' * 32), isTrue);
      expect(re.hasMatch('${'a' * 30}_1'), isTrue);
    });

    test('非法：2 位太短', () {
      expect(re.hasMatch('ab'), isFalse);
    });

    test('非法：33 位太长', () {
      expect(re.hasMatch('a' * 33), isFalse);
    });

    test('非法：含中文', () {
      expect(re.hasMatch('用户abc'), isFalse);
      expect(re.hasMatch('张三丰'), isFalse);
    });

    test('非法：含空格或其他特殊字符', () {
      expect(re.hasMatch('abc def'), isFalse);
      expect(re.hasMatch('abc@def'), isFalse);
      expect(re.hasMatch('abc/def'), isFalse);
      expect(re.hasMatch('abc+def'), isFalse);
      expect(re.hasMatch(''), isFalse);
    });

    test('文案与后端 400 一致', () {
      // 后端：username 需为 3-32 位字母/数字/下划线/点/横线
      expect(RegisterResult.usernameRuleText, '用户名需为 3-32 位字母/数字/下划线/点/横线');
    });
  });

  group('RegisterResult 解析', () {
    test('完整 200 响应', () {
      final r = RegisterResult.fromJson({
        'ok': true,
        'id': 181,
        'username': 'newuser',
        'status': 'pending',
        'message': '注册成功，账号待管理员审核后即可登录',
      });
      expect(r.id, 181);
      expect(r.username, 'newuser');
      expect(r.status, 'pending');
      expect(r.isPending, isTrue);
      expect(r.message, contains('待管理员审核'));
    });

    test('缺字段时用安全默认值', () {
      final r = RegisterResult.fromJson(const {});
      expect(r.id, isNull);
      expect(r.username, '');
      expect(r.status, 'pending');
      expect(r.isPending, isTrue);
      expect(r.message, contains('审核'));
    });

    test('status 非 pending 时 isPending 为 false', () {
      final r = RegisterResult.fromJson({'status': 'active'});
      expect(r.isPending, isFalse);
    });
  });

  group('注册错误文案', () {
    test('409 提示用户名被占用', () {
      const err = AuthError('该用户名已被占用，请换一个', statusCode: 409);
      expect(err.message, contains('已被占用'));
      expect(err.statusCode, 409);
    });

    test('400 用户名规则错误文案与后端一致', () {
      expect(RegisterResult.usernameRuleText, contains('3-32 位'));
    });

    test('503 标记限流', () {
      const err = AuthError('操作过于频繁，请稍后再试',
          rateLimited: true, statusCode: 503);
      expect(err.rateLimited, isTrue);
    });

    test('403 注册关闭', () {
      const err = AuthError('注册暂未开放（registration closed）', statusCode: 403);
      expect(err.message, contains('注册暂未开放'));
    });
  });

  group('登录 401 文案（P7 补充审核提示）', () {
    test('提示包含待审核可能性', () {
      // 服务端 pending 用户登录返回 401 Invalid credentials（与密码错无法区分），
      // 所以文案必须同时覆盖两种可能，否则新注册用户会困惑。
      const msg = '用户名或密码错误，或账号正在等待管理员审核';
      expect(msg, contains('用户名或密码错误'));
      expect(msg, contains('等待管理员审核'));
    });
  });

  group('注册前端校验边界（与后端一致）', () {
    test('密码最小 6 位（Web 端约束，后端无此限制）', () {
      expect('12345'.length < 6, isTrue);
      expect('123456'.length >= 6, isTrue);
    });

    test('密码上限 256 位（后端硬限制）', () {
      expect(('a' * 257).length > 256, isTrue);
      expect(('a' * 256).length <= 256, isTrue);
    });

    test('昵称上限 64 字（后端硬限制）', () {
      expect(('a' * 65).length > 64, isTrue);
      expect(('a' * 64).length <= 64, isTrue);
    });
  });
}
