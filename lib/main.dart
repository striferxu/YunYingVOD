/// main.dart — 应用入口。
///
/// P2 阶段只做骨架：主题、路由、ApiClient 初始化、401 全局广播接线。
/// 业务页面全部是占位，不接真实接口。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'core/api_client.dart';
import 'core/router.dart';
import 'core/session_store.dart';
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

  // 恢复上次的 Cookie（有则 App 启动时可直接验证会话，避免重复登录）
  final store = SessionStore();
  final cookies = await store.readCookies();
  if (cookies.isNotEmpty) {
    ApiClient().importCookies(cookies);
  }

  runApp(const VodApp());
}

class VodApp extends StatefulWidget {
  const VodApp({super.key});

  @override
  State<VodApp> createState() => _VodAppState();
}

class _VodAppState extends State<VodApp> {
  StreamSubscription<void>? _unauthSub;

  @override
  void initState() {
    super.initState();
    // 全局 401 处理：任何接口返回 401 都清本地会话。
    // P3 起在这里接入跳转登录页；P2 只做清理，不强制导航。
    _unauthSub = ApiClient().onUnauthorized.listen((_) async {
      await SessionStore().clearCookies();
    });
  }

  @override
  void dispose() {
    _unauthSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: '云影 VOD',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      routerConfig: appRouter,
    );
  }
}
