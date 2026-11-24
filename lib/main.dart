/// main.dart — 应用入口。
///
/// 职责：
///   1. 初始化主题、沉浸式状态栏
///   2. 创建 AuthController 并完成启动会话恢复（Cookie → /api/me → app token 换新）
///   3. 接线全局 401 广播（任何接口 401 都会触发状态机转向未登录）
///   4. 监听 App 生命周期（回前台刷新会话）
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/auth_controller.dart';
import 'core/router.dart';
import 'core/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 沉浸式状态栏
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppTheme.surface,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  final auth = AuthController();

  // 启动时同步恢复会话（Cookie 优先，失败回落 app token）。
  // 不阻塞首帧：先 runApp 显示 splash，bootstrap 在 App 内部 await。
  runApp(VodApp(auth: auth));
}

class VodApp extends StatefulWidget {
  final AuthController auth;

  const VodApp({super.key, required this.auth});

  @override
  State<VodApp> createState() => _VodAppState();
}

class _VodAppState extends State<VodApp> with WidgetsBindingObserver {
  late final GoRouter _router;
  StreamSubscription<void>? _unauthSub;
  bool _bootstrapped = false;

  @override
  void initState() {
    super.initState();
    _router = buildRouter(widget.auth);

    // 全局 401：ApiClient 已清 Cookie，这里同步把状态机切到未登录，
    // 路由守卫会自动把用户送回登录页。
    _unauthSub = ApiClient().onUnauthorized.listen((_) async {
      await widget.auth.handleGlobalUnauthorized();
    });

    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await widget.auth.bootstrap();
    if (mounted) setState(() => _bootstrapped = true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && _bootstrapped) {
      // 回前台：轻量刷新一次会话（滑动续期）
      widget.auth.onAppResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unauthSub?.cancel();
    widget.auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AuthController>.value(
      value: widget.auth,
      child: Consumer<AuthController>(
        builder: (context, auth, _) {
          // 启动检查未完成时显示 splash（避免闪一下登录页）
          if (!auth.isReady) {
            return MaterialApp(
              title: '云影 VOD',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.dark(),
              themeMode: ThemeMode.dark,
              home: const SplashPage(),
            );
          }
          return MaterialApp.router(
            title: '云影 VOD',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark(),
            darkTheme: AppTheme.dark(),
            themeMode: ThemeMode.dark,
            routerConfig: _router,
          );
        },
      ),
    );
  }
}
