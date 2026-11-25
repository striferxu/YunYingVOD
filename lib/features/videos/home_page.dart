/// home_page.dart — 首页外壳：广场 / 我的 两个 Tab。
///
/// P4：广场接入真实列表（PlazaPage），"我的"页启用"我的视频"入口。
/// 搜索框放在广场页内部（与 Web 端一致，搜索只作用于广场列表）。
library;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/auth_controller.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import 'plaza_page.dart';

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
      ),
      body: _tabIndex == 0 ? const PlazaPage() : const _MyTab(),
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
}

/// "我的"标签页：真实账号信息 + 设备管理 + 登出。
class _MyTab extends StatelessWidget {
  const _MyTab();

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('退出登录？'),
        content: const Text(
          '退出后需要重新输入用户名和密码。\n本机的自动登录授权也会一并作废。',
          style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    await context.read<AuthController>().logout();
    // 状态变化后路由守卫自动跳登录页
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final user = auth.user;

    return ListView(
      padding: const EdgeInsets.all(AppTheme.gap16),
      children: [
        _buildProfileCard(user?.username ?? '-', user?.role.label ?? '-'),
        const SizedBox(height: AppTheme.gap16),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.devices_other_rounded,
                    color: AppTheme.seed),
                title: const Text('设备管理'),
                subtitle: const Text(
                  '查看并移除已授权的设备',
                  style: TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push(AppRoutes.devices),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.video_library_outlined,
                    color: AppTheme.seed),
                title: const Text('我的视频'),
                subtitle: const Text(
                  '查看我上传的全部视频',
                  style: TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push(AppRoutes.myVideos),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.gap16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.logout_rounded, color: AppTheme.danger),
            title: const Text('退出登录',
                style: TextStyle(color: AppTheme.danger)),
            onTap: () => _confirmLogout(context),
          ),
        ),
        const SizedBox(height: AppTheme.gap24),
        Center(
          child: Text(
            '云影 VOD  v1.0.0',
            style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
          ),
        ),
      ],
    );
  }

  Widget _buildProfileCard(String username, String role) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap16),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: AppTheme.seed.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(26),
              ),
              child: const Icon(Icons.person_rounded,
                  size: 28, color: AppTheme.seed),
            ),
            const SizedBox(width: AppTheme.gap16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    username,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    role == 'admin' ? '管理员' : '普通用户',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textTertiary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
