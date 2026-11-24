/// upload_job.dart — 上传任务模型。
///
/// 来源接口：
///   POST /api/upload              -> {ok, job_id, ...}
///   GET  /api/upload_status/`<id>`  -> UploadJob
///
/// 注意（P0 实测）：
///   * 转码单并发，多人同时上传会排队，status 会是 `queued`。
///   * nginx 代理超时 300s，蜂窝网络传大文件会断，客户端需提示用 WiFi。
library;

/// 任务状态。服务端取值见 multiuser.py。
enum UploadStatus {
  queued,
  running,
  done,
  failed,
  unknown;

  static UploadStatus parse(String? raw) {
    switch (raw) {
      case 'queued':
        return UploadStatus.queued;
      case 'running':
      case 'transcoding':
        return UploadStatus.running;
      case 'done':
      case 'ready':
        return UploadStatus.done;
      case 'failed':
      case 'error':
        return UploadStatus.failed;
      default:
        return UploadStatus.unknown;
    }
  }

  String get label {
    switch (this) {
      case UploadStatus.queued:
        return '排队中';
      case UploadStatus.running:
        return '转码中';
      case UploadStatus.done:
        return '已完成';
      case UploadStatus.failed:
        return '失败';
      case UploadStatus.unknown:
        return '未知';
    }
  }

  bool get isTerminal =>
      this == UploadStatus.done || this == UploadStatus.failed;
}

class UploadJob {
  final String jobId;
  final String title;
  final UploadStatus status;

  /// 0.0 ~ 1.0；服务端可能给 0-100 的整数，fromJson 统一归一化。
  final double progress;
  final String? error;

  /// 完成后产出的视频 id。
  final String? videoId;

  const UploadJob({
    required this.jobId,
    this.title = '',
    this.status = UploadStatus.unknown,
    this.progress = 0,
    this.error,
    this.videoId,
  });

  factory UploadJob.fromJson(Map<String, dynamic> json) {
    return UploadJob(
      jobId: (json['job_id'] ?? json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      status: UploadStatus.parse(_strOrNull(json['status'])),
      progress: _normalizeProgress(json['progress']),
      error: _strOrNull(json['error'] ?? json['message']),
      videoId: _strOrNull(json['video_id']),
    );
  }

  /// 百分比整数，便于直接展示 `62%`。
  int get percent => (progress.clamp(0.0, 1.0) * 100).round();

  UploadJob copyWith({
    UploadStatus? status,
    double? progress,
    String? error,
    String? videoId,
  }) {
    return UploadJob(
      jobId: jobId,
      title: title,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      error: error ?? this.error,
      videoId: videoId ?? this.videoId,
    );
  }
}

double _normalizeProgress(Object? v) {
  if (v == null) return 0;
  double raw;
  if (v is num) {
    raw = v.toDouble();
  } else {
    raw = double.tryParse(v.toString()) ?? 0;
  }
  // 服务端历史版本有给 0-100 的，统一成 0-1
  if (raw > 1.0) raw = raw / 100.0;
  return raw.clamp(0.0, 1.0);
}

String? _strOrNull(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}
