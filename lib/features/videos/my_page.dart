/// my_page.dart — "我的"页（P2 占位）。
///
/// P4 会接入 GET /api/my_videos + GET /api/me_full。
/// 同时提供设备管理入口（P3 的 GET/DELETE /api/app/tokens）。
library;

import 'package:material_ui/material_ui.dart';

import '../../core/widgets/state_views.dart';

class MyPage extends StatelessWidget {
  const MyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: const EmptyView(
        icon: Icons.account_circle_outlined,
        message: '我的',
        hint: 'P2 骨架阶段：占位页\nP4 阶段接入 /api/my_videos',
      ),
    );
  }
}
