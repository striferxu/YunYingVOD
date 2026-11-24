/// home_page.dart — 首页 / 视频广场（P2 占位）。
///
/// P4 会替换成真实列表：GET /api/videos?page=1&limit=20，支持网格/列表切换。
library;

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/widgets/state_views.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tabIndex = 0;

  static const _tabs = [
    (icon: Icons.explore_outlined, active: Icons.explore, label: '广场'),
    (icon: Icons.person_outline, active: Icons.person, label: '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tabIndex == 0 ? '视频广场' : '我的'),
        actions: [
          IconButton(
            tooltip: '搜索（P4）',
            onPressed: () => _toast('搜索功能在 P4 阶段实现'),
            icon: const Icon(Icons.search_rounded),
          ),
        ],
      ),
      body: _tabIndex == 0 ? const _PlazaPlaceholder() : const _MyPlaceholder(),
      floatingActionButton: _tabIndex == 0
          ? FloatingActionButton.extended(
              onPressed: () => context.push(AppRoutes.upload),
              backgroundColor: AppTheme.seed,
              foregroundColor: const Color(0xFF06231F),
              icon: const Icon(Icons.upload_rounded),
              label: const Text('上传'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: _tabs
            .map((t) => NavigationDestination(
                  icon: Icon(t.icon),
                  selectedIcon: Icon(t.active),
                  label: t.label,
                ))
            .toList(),
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _PlazaPlaceholder extends StatelessWidget {
  const _PlazaPlaceholder();

  @override
  Widget build(BuildContext context) {
    return EmptyView(
      icon: Icons.movie_filter_outlined,
      message: '视频广场',
      hint: 'P2 骨架阶段：这里是占位页\nP4 阶段接入 /api/videos 显示真实列表',
      action: OutlinedButton.icon(
        onPressed: () => context.push(AppRoutes.login),
        icon: const Icon(Icons.login_rounded, size: 18),
        label: const Text('前往登录页（占位）'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.seed,
          side: const BorderSide(color: AppTheme.divider),
        ),
      ),
    );
  }
}

class _MyPlaceholder extends StatelessWidget {
  const _MyPlaceholder();

  @override
  Widget build(BuildContext context) {
    return EmptyView(
      icon: Icons.video_library_outlined,
      message: '我的视频',
      hint: 'P2 骨架阶段：占位页\nP4 阶段接入 /api/my_videos',
    );
  }
}
