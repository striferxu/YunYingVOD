/// login_page.dart — 登录页（P2 占位）。
///
/// P3 实现：POST /api/login {username,password}，成功后 POST /api/app/token 存 secure storage。
/// 注意：错误密码 401，连续 10 次后第 11 次返回 423（锁 10 分钟），需友好提示。
library;

import 'package:material_ui/material_ui.dart';

import '../../core/widgets/state_views.dart';

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('登录')),
      body: const EmptyView(
        icon: Icons.lock_outline_rounded,
        message: '登录',
        hint: 'P2 骨架阶段：占位页\nP3 阶段实现 POST /api/login',
      ),
    );
  }
}
