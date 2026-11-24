/// video.dart — 视频模型。字段严格对齐 P0 契约 `docs/CLIENT_API_SPEC.md`。
///
/// 来源接口：
///   GET /api/videos          -> {total, items:[Video]}
///   GET /api/videos/`<id>`     -> Video（额外含 description/updated_at）
///   GET /api/my_videos       -> {total, items:[Video]}
library;

/// 视频状态。服务端 CHECK 约束只有这四个值。
enum VideoStatus {
  ready,
  hidden,
  deleted,
  broken;

  static VideoStatus parse(String? raw) {
    switch (raw) {
      case 'hidden':
        return VideoStatus.hidden;
      case 'deleted':
        return VideoStatus.deleted;
      case 'broken':
        return VideoStatus.broken;
      case 'ready':
      default:
        return VideoStatus.ready;
    }
  }

  String get label {
    switch (this) {
      case VideoStatus.ready:
        return '可播放';
      case VideoStatus.hidden:
        return '已隐藏';
      case VideoStatus.deleted:
        return '已删除';
      case VideoStatus.broken:
        return '文件异常';
    }
  }
}

class Video {
  /// 视频 id（8 位 hex 或 `tw_<id>`），不要重新生成。
  final String id;
  final String name;
  final String date;
  final String? cover;
  final String description;

  /// 时长（秒），服务端可能为 null。
  final double? duration;
  final int? sizeBytes;
  final VideoStatus status;
  final int sortPin;
  final int views;

  /// 上传者 user_id；老数据可能为 null。
  final int? ownerId;

  /// 上传时间（epoch 秒）。
  final int? createdAt;

  const Video({
    required this.id,
    required this.name,
    required this.date,
    this.cover,
    this.description = '',
    this.duration,
    this.sizeBytes,
    this.status = VideoStatus.ready,
    this.sortPin = 0,
    this.views = 0,
    this.ownerId,
    this.createdAt,
  });

  factory Video.fromJson(Map<String, dynamic> json) {
    return Video(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      date: (json['date'] ?? '').toString(),
      cover: _strOrNull(json['cover']),
      description: (json['description'] ?? '').toString(),
      duration: _doubleOrNull(json['duration']),
      sizeBytes: _intOrNull(json['size_bytes']),
      status: VideoStatus.parse(_strOrNull(json['status'])),
      sortPin: _intOrNull(json['sort_pin']) ?? 0,
      views: _intOrNull(json['views']) ?? 0,
      ownerId: _intOrNull(json['owner_id']),
      createdAt: _intOrNull(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'date': date,
        'cover': cover,
        'description': description,
        'duration': duration,
        'size_bytes': sizeBytes,
        'status': status.name,
        'sort_pin': sortPin,
        'views': views,
        'owner_id': ownerId,
        'created_at': createdAt,
      };

  /// HLS 播放列表路径（P5 使用）。服务端固定 output.m3u8。
  String get hlsPath => '/videos/$id/output.m3u8';

  /// 加密 key 路径（P5 使用）。注意是相对路径，播放器需按基址拼接并带 Cookie。
  String get keyPath => '/key/$id';

  /// 时长显示：`1:23:45` / `12:34`。
  String get durationText {
    final d = duration;
    if (d == null || d <= 0) return '--:--';
    final total = d.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// 体积显示：`1.2 GB` / `345.6 MB`。
  String get sizeText {
    final b = sizeBytes;
    if (b == null || b <= 0) return '';
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (b >= gb) return '${(b / gb).toStringAsFixed(2)} GB';
    return '${(b / mb).toStringAsFixed(1)} MB';
  }
}

/// 分页包装：`{total, items}`。
class VideoPage {
  final int total;
  final List<Video> items;

  const VideoPage({required this.total, required this.items});

  factory VideoPage.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    final list = raw is List
        ? raw
            .whereType<Map>()
            .map((e) => Video.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <Video>[];
    return VideoPage(
      total: _intOrNull(json['total']) ?? list.length,
      items: list,
    );
  }

  bool get isEmpty => items.isEmpty;
}

String? _strOrNull(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

int? _intOrNull(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

double? _doubleOrNull(Object? v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}
