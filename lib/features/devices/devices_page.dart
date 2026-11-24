/// devices_page.dart — 设备管理页（P3）。
///
/// 对应接口（P1 已上线，实测通过）：
///   GET    /api/app/tokens        列出当前用户全部有效令牌
///   DELETE /api/app/tokens/`<id>`  踢掉指定设备
///
/// 服务端行为：
///   * 只返回**未过期**的令牌，查询时顺手清理过期行
///   * 服务端 `current` 字段恒为 false（P1 未传 current_token_id），
///     所以本页改为**用本地保存的 token id 比对**来标记当前设备
///   * 踢别人的设备返回 403，不存在的 id 返回 404
library;

import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/models/user.dart';
import '../../core/session_store.dart';
import '../../core/theme.dart';
import '../../core/widgets/state_views.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  final _api = ApiClient();

  List<AppDevice>? _devices;
  String? _error;
  String? _errorDetail;
  bool _loading = true;

  /// 正在踢除的设备 id，用于按钮转圈
  int? _revoking;

  /// 本机保存的 app token id。用于标记"当前设备"——
  /// 服务端 current 字段恒为 false，只能靠本地 id 比对。
  int? _ownTokenId;

  static final _dateFmt = DateFormat('yyyy-MM-dd HH:mm');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _errorDetail = null;
    });
    try {
      final own = await SessionStore().readAppToken();
      final resp = await _api.get('/api/app/tokens');
      final items = (resp.data['items'] as List?) ?? const [];
      final list = items
          .whereType<Map>()
          .map((e) => AppDevice.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (!mounted) return;
      setState(() {
        _devices = list;
        _ownTokenId = own?.id;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.isUnauthorized ? '登录已过期，请重新登录' : '加载设备列表失败';
        _errorDetail = e.message;
      });
    }
  }

  Future<void> _revoke(AppDevice d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('移除此设备？'),
        content: Text(
          '「${d.deviceName}」将立即失效，需要重新输入密码登录。\n'
          '当前正在使用该设备的会话不受影响，但下次静默续期会失败。',
          style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _revoking = d.id);
    try {
      await _api.delete('/api/app/tokens/${d.id}');
      // 如果移除的是本机设备，本地存的 token 也要一并清掉，
      // 否则下次启动会拿一个已作废的 token 去换 session（必然 401）。
      if (_ownTokenId != null && d.id == _ownTokenId) {
        await SessionStore().clearAppToken();
      }
      if (!mounted) return;
      setState(() {
        _devices = _devices?.where((e) => e.id != d.id).toList();
        _revoking = null;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('已移除「${d.deviceName}」')));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _revoking = null);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('移除失败：${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备管理'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const LoadingView(message: '正在加载设备列表…');
    }
    if (_error != null) {
      return ErrorView(
        message: _error!,
        detail: _errorDetail,
        onRetry: _load,
      );
    }
    final list = _devices ?? const <AppDevice>[];
    if (list.isEmpty) {
      return const EmptyView(
        icon: Icons.devices_other_rounded,
        message: '暂无已授权设备',
        hint: '登录成功后会自动授权当前设备',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.seed,
      backgroundColor: AppTheme.surface,
      child: ListView.separated(
        padding: const EdgeInsets.all(AppTheme.gap16),
        itemCount: list.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: AppTheme.gap12),
        itemBuilder: (context, i) {
          if (i == 0) return _buildHint(list.length);
          return _buildCard(list[i - 1]);
        },
      ),
    );
  }

  Widget _buildHint(int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gap4),
      child: Text(
        '共 $count 台设备已授权，每台有效期 30 天，不会自动续期',
        style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary),
      ),
    );
  }

  Widget _buildCard(AppDevice d) {
    final busy = _revoking == d.id;
    final lastUsed = d.lastUsedAt == null
        ? '从未使用'
        : _dateFmt.format(
            DateTime.fromMillisecondsSinceEpoch(d.lastUsedAt! * 1000));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_platformIcon(d.platform),
                    size: 20, color: AppTheme.seed),
                const SizedBox(width: AppTheme.gap8),
                Expanded(
                  child: Text(
                    d.deviceName,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_isOwnDevice(d))
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.seed.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '当前设备',
                      style: TextStyle(fontSize: 11, color: AppTheme.seed),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppTheme.gap12),
            _kv('平台', d.platform),
            _kv('最近使用', lastUsed),
            if (d.ip != null) _kv('IP', d.ip!),
            _kv('剩余有效期', '${d.remainingDays} 天'),
            const SizedBox(height: AppTheme.gap8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: busy ? null : () => _revoke(d),
                icon: busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.logout_rounded, size: 16),
                label: Text(busy ? '移除中…' : '移除'),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.danger,
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              k,
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textTertiary),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  /// 是否本机。优先用本地 token id 比对；旧版本没存 id 时退回服务端 current 字段。
  bool _isOwnDevice(AppDevice d) {
    if (_ownTokenId != null && _ownTokenId! > 0) return d.id == _ownTokenId;
    return d.current;
  }

  IconData _platformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return Icons.android_rounded;
      case 'ios':
        return Icons.phone_iphone_rounded;
      default:
        return Icons.devices_other_rounded;
    }
  }
}
