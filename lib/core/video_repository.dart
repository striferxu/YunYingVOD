/// video_repository.dart — 视频列表数据层。
///
/// 三个接口（契约见 docs/CLIENT_API_SPEC.md 第 2.1/2.3/2.4 节）：
///   GET /api/videos      -> {total, items:[Video]}   （广场，默认 status=ready）
///   GET /api/my_videos   -> {total, items:[Video]}   （我的，无 owner_id/sort_pin）
///   GET /api/owners      -> {"1":"admin"}            （owner_id -> 昵称）
///
/// 设计要点：
///   * 不缓存到磁盘：列表数据每次进页面重新拉，避免看到已删除视频。
///   * owners 失败**不阻断**列表渲染：取不到就显示"其他用户"（Web 端同语义）。
///   * 搜索用服务端 `?q=`（`LIKE %q%`，不区分大小写），与 Web 端一致；
///     Web 端是前端 filter，但服务端 `q` 语义等价，且能省流量。
library;

import 'api_client.dart';
import 'models/video.dart';

class VideoRepository {
  final ApiClient _api;

  VideoRepository({ApiClient? api}) : _api = api ?? ApiClient();

  /// 广场列表。`q` 非空时走服务端模糊搜索。
  ///
  /// limit 用契约上限 500，一页拉完（当前数据量 18 条 ready，远小于上限）。
  Future<VideoPage> fetchPlaza({String? q, String status = 'ready'}) async {
    final params = <String>['status=$status', 'limit=500'];
    final kw = (q ?? '').trim();
    if (kw.isNotEmpty) {
      params.add('q=${Uri.encodeQueryComponent(kw)}');
    }
    final res = await _api.get('/api/videos?${params.join('&')}');
    return VideoPage.fromJson(res.data);
  }

  /// 我的视频列表。
  Future<VideoPage> fetchMine() async {
    final res = await _api.get('/api/my_videos');
    return VideoPage.fromJson(res.data);
  }

  /// 上传者 id -> 昵称。失败返回空 Map（列表仍可渲染，显示"其他用户"）。
  Future<Map<String, String>> fetchOwners() async {
    try {
      final res = await _api.get('/api/owners');
      final out = <String, String>{};
      res.data.forEach((k, v) {
        final name = v?.toString() ?? '';
        if (name.isNotEmpty) out[k] = name;
      });
      return out;
    } on ApiException {
      return const {};
    }
  }

  /// 取昵称；取不到回落"其他用户"（对齐 Web 端 `ownersMap[v.owner_id] || '其他用户'`）。
  static String ownerName(Map<String, String> owners, Video v) {
    final id = v.ownerId;
    if (id == null) return '其他用户';
    final name = owners[id.toString()];
    return (name == null || name.isEmpty) ? '其他用户' : name;
  }

  /// 取昵称，带兜底名。
  ///
  /// 「我的视频」用：`GET /api/my_videos` **不返回 owner_id**（服务端
  /// `multiuser.my_videos` 只查 id/name/date/cover/duration/size_bytes/
  /// status/views/created_at），所以无法按 id 查映射。这类场景调用方直接
  /// 把当前用户名当兜底传进来，避免显示成"其他用户"。
  static String ownerNameOr(Map<String, String> owners, Video v, String fallback) {
    final id = v.ownerId;
    if (id != null) {
      final name = owners[id.toString()];
      if (name != null && name.isNotEmpty) return name;
    }
    return fallback;
  }
}
