/// register_page.dart — 注册页（P2 占位）。
///
/// P7 实现：POST /api/register，注册后为 pending 状态需管理员审核。
/// 站点采用注册审核机制，需展示管理员二维码 https://51play.ccwu.cc/admin_qr.png
library;

import 'package:material_ui/material_ui.dart';

import '../../core/widgets/state_views.dart';

class RegisterPage extends StatelessWidget {
  const RegisterPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('注册')),
      body: const EmptyView(
        icon: Icons.person_add_alt_outlined,
        message: '注册',
        hint: 'P2 骨架阶段：占位页\nP7 接入 POST /api/register（需管理员审核）',
      ),
    );
  }
}
