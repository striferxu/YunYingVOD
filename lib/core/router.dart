/// router.dart — 全局路由表（go_router 声明式）+ 登录守卫。
///
/// 路由路径在这里定死，后续阶段不再重构。
///
/// 守卫规则：
///   * 未登录访问受保护页 → 重定向到 /login?from=<原地址>
///   * 已登录访问 /login → 回到 from 或首页
///   * /register 公开（P7 注册审核制，未登录也能申请）
///   * 启动检查未完成（AuthStatus.unknown）→ 不拦截，由 splash 显示
library;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../features/auth/login_page.dart';
import '../features/devices/devices_page.dart';
import '../features/player/player_page.dart';
import '../features/register/register_page.dart';
import '../features/upload/upload_page.dart';
import '../features/videos/home_page.dart';
import '../features/videos/my_page.dart';
import '../features/videos/video_detail_page.dart';
import 'auth_controller.dart';
import 'theme.dart';

class AppRoutes {
  AppRoutes._();

  static const home = '/';
  static const login = '/login';
  static const videos = '/videos';
  static const videoDetail = '/videos/:id';
  static const player = '/player/:id';
  static const upload = '/upload';
  static const register = '/register';
  static const me = '/me';
  static const devices = '/devices';

  static String videoDetailOf(String id) => '/videos/$id';
  static String playerOf(String id) => '/player/$id';
}

/// 构建路由表。需要 AuthController 供守卫使用。
GoRouter buildRouter(AuthController auth) {
  return GoRouter(
    initialLocation: AppRoutes.home,
    refreshListenable: auth,
    redirect: (context, state) {
      // 启动检查未完成：不拦截，首页会显示 splash 占位
      if (!auth.isReady) return null;

      final loc = state.matchedLocation;
      final isPublic = loc == AppRoutes.login || loc == AppRoutes.register;
      final loggedIn = auth.isLoggedIn;

      if (!loggedIn && !isPublic) {
        final from = Uri.encodeComponent(state.uri.toString());
        return '${AppRoutes.login}?from=$from';
      }
      if (loggedIn && loc == AppRoutes.login) {
        final from = state.uri.queryParameters['from'];
        if (from != null && from.isNotEmpty && !from.startsWith('/login')) {
          return from;
        }
        return AppRoutes.home;
      }
      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const HomePage(),
      ),
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: AppRoutes.videos,
        builder: (context, state) => const HomePage(),
      ),
      GoRoute(
        path: AppRoutes.videoDetail,
        builder: (context, state) => VideoDetailPage(
          videoId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: AppRoutes.player,
        builder: (context, state) => PlayerPage(
          videoId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: AppRoutes.upload,
        builder: (context, state) => const UploadPage(),
      ),
      GoRoute(
        path: AppRoutes.register,
        builder: (context, state) => const RegisterPage(),
      ),
      GoRoute(
        path: AppRoutes.me,
        builder: (context, state) => const MyPage(),
      ),
      GoRoute(
        path: AppRoutes.devices,
        builder: (context, state) => const DevicesPage(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gap24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off_rounded,
                  size: 48, color: AppTheme.textTertiary),
              const SizedBox(height: AppTheme.gap16),
              Text(
                '页面不存在\n${state.uri}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: AppTheme.gap24),
              FilledButton(
                onPressed: () => context.go(AppRoutes.home),
                child: const Text('回到首页'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 启动检查期间的占位页。
class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_circle_fill_rounded, size: 56, color: AppTheme.seed),
            SizedBox(height: AppTheme.gap24),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ],
        ),
      ),
    );
  }
}
