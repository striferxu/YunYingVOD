/// router.dart — 全局路由表（go_router 声明式）。
///
/// P2 只放占位页，P3 起往里填真实页面。路由路径在这里定死，后续不重构。
///
/// 路由约定：
///   /                    首页（占位）
///   /login               登录（P3）
///   /videos              视频广场（P4）
///   /videos/:id          视频详情（P4）
///   /player/:id          播放（P5）
///   /upload              上传（P6）
///   /register            注册（P7）
///   /devices             设备管理（P3 附带）
///   /me                  我的（P4）
library;

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/login_page.dart';
import '../features/player/player_page.dart';
import '../features/register/register_page.dart';
import '../features/upload/upload_page.dart';
import '../features/videos/home_page.dart';
import '../features/videos/my_page.dart';
import '../features/videos/video_detail_page.dart';

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

  static String videoDetailOf(String id) => '/videos/$id';
  static String playerOf(String id) => '/player/$id';
}

final GoRouter appRouter = GoRouter(
  initialLocation: AppRoutes.home,
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
  ],
  errorBuilder: (context, state) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_off_rounded, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text('页面不存在\n${state.uri}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 24),
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
