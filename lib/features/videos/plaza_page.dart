/// plaza_page.dart — 视频广场（P4）。
///
/// 功能对齐 Web 端 `vod_site/web/app.js` 的 `renderHome` / `toggleLayout`：
///   * 列表数据来自 `GET /api/videos?status=ready&limit=500`
///   * 搜索：Web 端是前端 filter，这里走服务端 `?q=`（语义等价、省流量），
///     输入 350ms 防抖
///   * 布局：网格 / 列表切换，偏好持久化到 `home_layout`（与 Web 同名）
///   * 下拉刷新
///   * 空态 / 错误态可重试
///
/// 点击卡片 → 播放页占位（P5 实现真实播放）。
library;

import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/layout_pref.dart';
import '../../core/models/video.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/video_repository.dart';
import '../../core/widgets/state_views.dart';
import '../../core/widgets/video_grid.dart';

class PlazaPage extends StatefulWidget {
  const PlazaPage({super.key});

  @override
  State<PlazaPage> createState() => PlazaPageState();
}

class PlazaPageState extends State<PlazaPage> {
  final VideoRepository _repo = VideoRepository();
  final TextEditingController _searchCtrl = TextEditingController();

  List<Video> _videos = const [];
  Map<String, String> _owners = const {};
  ListLayout _layout = ListLayout.grid;

  bool _loading = true;
  String? _error;

  /// 当前生效的搜索词（已提交给服务端的）。
  String _query = '';
  Timer? _debounce;

  /// 防止旧请求覆盖新请求（快速连续输入时）。
  int _reqSeq = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    // 布局偏好与首屏数据并行
    final layoutFuture = LayoutPref.load();
    final loadFuture = _load();
    final layout = await layoutFuture;
    if (mounted) setState(() => _layout = layout);
    await loadFuture;
  }

  Future<void> _load({bool silent = false}) async {
    final seq = ++_reqSeq;
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      // owners 与列表并行；owners 失败不阻断
      final ownersFuture = _repo.fetchOwners();
      final page = await _repo.fetchPlaza(q: _query);
      final owners = await ownersFuture;

      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _videos = page.items;
        _owners = owners;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _reqSeq) return;
      // 401 已由 ApiClient 广播，路由守卫会跳登录页；此处不重复处理
      setState(() {
        _loading = false;
        _error = _friendlyError(e);
      });
    } catch (e) {
      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  /// 把 ApiException 翻成用户能看懂的话。
  /// P3 已知问题：网络错误与 5xx 之前混在一起，这里区分开。
  String _friendlyError(ApiException e) {
    final code = e.statusCode;
    if (code == null) {
      // 网络层（超时 / SocketException）
      return '网络连接失败，请检查网络后重试';
    }
    if (code >= 500) return '服务器开小差了（$code），请稍后重试';
    return '加载失败（$code）：${e.message}';
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      final kw = value.trim();
      if (kw == _query) return;
      _query = kw;
      _load(silent: true);
    });
  }

  Future<void> _toggleLayout() async {
    final next = _layout.toggled;
    setState(() => _layout = next);
    await LayoutPref.save(next);
  }

  void _openPlayer(Video v) {
    context.push(AppRoutes.playerOf(v.id));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildSearchBar(),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.gap12, AppTheme.gap8, AppTheme.gap12, AppTheme.gap4),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 42,
              child: TextField(
                controller: _searchCtrl,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: '搜索视频标题',
                  hintStyle: const TextStyle(
                      fontSize: 14, color: AppTheme.textTertiary),
                  prefixIcon: const Icon(Icons.search_rounded,
                      size: 20, color: AppTheme.textTertiary),
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          color: AppTheme.textTertiary,
                          onPressed: () {
                            _searchCtrl.clear();
                            _onSearchChanged('');
                            setState(() {});
                          },
                        ),
                  filled: true,
                  fillColor: AppTheme.surfaceHigh,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(21),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppTheme.gap8),
          // 布局切换按钮（对应 Web 端 #layout-toggle）
          IconButton(
            tooltip: _layout.switchTooltip,
            onPressed: _toggleLayout,
            icon: Icon(
              _layout.isList ? Icons.view_list_rounded : Icons.grid_view_rounded,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingView(message: '加载中…');

    final err = _error;
    if (err != null) {
      return ErrorView(
        message: err,
        onRetry: () => _load(),
      );
    }

    if (_videos.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _load(silent: true),
        child: ListView(
          // 必须有可滚动内容，下拉刷新才能在空态下工作
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: EmptyView(
                icon: _query.isEmpty
                    ? Icons.movie_filter_outlined
                    : Icons.search_off_rounded,
                message: _query.isEmpty ? '暂无视频，快去上传第一个吧' : '未找到匹配的视频',
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: VideoGrid(
        videos: _videos,
        owners: _owners,
        layout: _layout,
        onTap: _openPlayer,
        physics: const AlwaysScrollableScrollPhysics(),
      ),
    );
  }
}
