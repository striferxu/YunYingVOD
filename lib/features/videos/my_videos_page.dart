/// my_videos_page.dart — "我的视频"列表页（P4）。
///
/// 数据来自 `GET /api/my_videos`（契约 2.3）。
/// 该接口返回的 items **没有 owner_id / sort_pin**，所以：
///   * 上传者固定显示当前用户名（不查 /api/owners）
///   * 排序由服务端保证 `created_at DESC, id`
///
/// 布局与广场共用同一个 `home_layout` 偏好（Web 端也是同一键）。
library;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/auth_controller.dart';
import '../../core/layout_pref.dart';
import '../../core/models/video.dart';
import '../../core/router.dart';
import '../../core/video_repository.dart';
import '../../core/widgets/state_views.dart';
import '../../core/widgets/video_grid.dart';

class MyVideosPage extends StatefulWidget {
  const MyVideosPage({super.key});

  @override
  State<MyVideosPage> createState() => _MyVideosPageState();
}

class _MyVideosPageState extends State<MyVideosPage> {
  final VideoRepository _repo = VideoRepository();

  List<Video> _videos = const [];
  ListLayout _layout = ListLayout.grid;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final layoutFuture = LayoutPref.load();
    final loadFuture = _load();
    final layout = await layoutFuture;
    if (mounted) setState(() => _layout = layout);
    await loadFuture;
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final page = await _repo.fetchMine();
      if (!mounted) return;
      setState(() {
        _videos = page.items;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.statusCode == null
            ? '网络连接失败，请检查网络后重试'
            : '加载失败（${e.statusCode}）：${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _toggleLayout() async {
    final next = _layout.toggled;
    setState(() => _layout = next);
    await LayoutPref.save(next);
  }

  @override
  Widget build(BuildContext context) {
    final username = context.watch<AuthController>().user?.username ?? '我';

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的视频'),
        actions: [
          IconButton(
            tooltip: _layout.switchTooltip,
            onPressed: _toggleLayout,
            icon: Icon(
              _layout.isList ? Icons.view_list_rounded : Icons.grid_view_rounded,
            ),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => _load(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _buildBody(username),
    );
  }

  Widget _buildBody(String username) {
    if (_loading) return const LoadingView(message: '加载中…');

    final err = _error;
    if (err != null) {
      return ErrorView(message: err, onRetry: () => _load());
    }

    if (_videos.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _load(silent: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.65,
              child: EmptyView(
                icon: Icons.video_library_outlined,
                message: '暂无视频，快去上传第一个吧',
                action: FilledButton.icon(
                  onPressed: () => context.push(AppRoutes.upload),
                  icon: const Icon(Icons.upload_rounded, size: 18),
                  label: const Text('去上传'),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // /api/my_videos 无 owner_id，用当前用户名补一个映射，
    // 这样 VideoCard 里 owner 显示正确（不显示"其他用户"）。
    final owners = <String, String>{};
    for (final v in _videos) {
      final id = v.ownerId;
      if (id != null) owners[id.toString()] = username;
    }

    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: VideoGrid(
        videos: _videos,
        owners: owners,
        layout: _layout,
        onTap: (v) => context.push(AppRoutes.playerOf(v.id)),
        physics: const AlwaysScrollableScrollPhysics(),
      ),
    );
  }
}
