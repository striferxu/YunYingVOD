/// upload_job.dart — 上传/转码任务模型（P6）。
///
/// 来源接口（契约 docs/CLIENT_API_SPEC.md §4）：
///   POST `/api/upload`             -> 202 {ok, job_id, status:"queued"}
///   GET  `/api/upload_status/<id>` -> {id,status,percent,eta_seconds,
///                                      current_seconds,total_seconds,error,result_id}
///
/// 一个任务的完整生命周期：
///   uploading（**仅本地**：文件已选、正在传，服务端还没有 job_id）
///     → queued（202 已返回 job_id，排队等转码）
///     → running（转码中，有 percent / eta_seconds）
///     → done（result_id 即最终 video id）
///     → failed（error 为后端原因）
///
/// **为什么要持久化**：任务书要求「上传中杀 App 重开，能从上传记录恢复查看进度」。
/// 服务端任务不因客户端退出而丢失，只要本地记住 job_id 就能继续轮询。
///
/// 服务端字段注意事项（P0 实测）：
///   * 转码单并发，多人同时上传会排队 → 先看到 `queued`，不是卡死。
///   * `percent` 在拿不到总时长时是 null（此时 UI 不显示百分比）。
///   * 短小视频可能第一次轮询就 `done`。
library;

/// 任务状态。
enum UploadStatus {
  /// 本地阶段：正在上传，服务端还没有 job_id。
  uploading,

  /// 已受理，排队等转码。
  queued,

  /// 转码中。
  running,

  /// 完成。
  done,

  /// 失败（上传失败或转码失败）。
  failed;

  static UploadStatus parse(String? raw) {
    switch (raw) {
      case 'uploading':
        return UploadStatus.uploading;
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
        return UploadStatus.queued;
    }
  }

  String get wire => name;

  String get label {
    switch (this) {
      case UploadStatus.uploading:
        return '上传中';
      case UploadStatus.queued:
        return '排队中';
      case UploadStatus.running:
        return '转码中';
      case UploadStatus.done:
        return '已完成';
      case UploadStatus.failed:
        return '失败';
    }
  }

  /// 是否已终结（不再轮询）。
  bool get isFinal => this == UploadStatus.done || this == UploadStatus.failed;
}

class UploadJob {
  /// 服务端 job_id（8 位 hex，与最终 video id 相同）。上传阶段为 null。
  final String? jobId;

  /// 用户填写的标题。
  final String title;

  /// 本地文件名（仅用于展示）。
  final String fileName;

  /// 文件字节数（仅用于展示）。
  final int fileSize;

  /// 本地创建时间（毫秒时间戳），用于排序。
  final int createdAt;

  final UploadStatus status;

  /// 上传阶段进度 0.0~1.0（仅 status == uploading 时有意义）。
  final double uploadProgress;

  /// 转码百分比 0~100（服务端原值）；无总时长时为 null。
  final double? percent;

  /// 预计剩余秒数。
  final int? etaSeconds;

  /// 源视频总时长（秒）。
  final double? totalSeconds;

  /// 失败原因。
  final String? error;

  /// 成功后的 video id。
  final String? resultId;

  const UploadJob({
    required this.jobId,
    required this.title,
    this.fileName = '',
    this.fileSize = 0,
    required this.createdAt,
    required this.status,
    this.uploadProgress = 0,
    this.percent,
    this.etaSeconds,
    this.totalSeconds,
    this.error,
    this.resultId,
  });

  /// 服务端 `percent` 是 0~100 的浮点。UI 展示取整并夹取范围。
  int get percentInt {
    final p = percent;
    if (p == null) return 0;
    return p.clamp(0, 100).round();
  }

  /// 上传阶段进度取整百分比。
  int get uploadPercentInt => (uploadProgress.clamp(0.0, 1.0) * 100).round();

  UploadJob copyWith({
    String? jobId,
    UploadStatus? status,
    double? uploadProgress,
    double? percent,
    int? etaSeconds,
    double? totalSeconds,
    String? error,
    String? resultId,
    bool clearError = false,
    bool clearPercent = false,
    bool clearEta = false,
  }) {
    return UploadJob(
      jobId: jobId ?? this.jobId,
      title: title,
      fileName: fileName,
      fileSize: fileSize,
      createdAt: createdAt,
      status: status ?? this.status,
      uploadProgress: uploadProgress ?? this.uploadProgress,
      percent: clearPercent ? null : (percent ?? this.percent),
      etaSeconds: clearEta ? null : (etaSeconds ?? this.etaSeconds),
      totalSeconds: totalSeconds ?? this.totalSeconds,
      error: clearError ? null : (error ?? this.error),
      resultId: resultId ?? this.resultId,
    );
  }

  /// 从 `/api/upload_status/<id>` 的响应合并出新状态。
  ///
  /// 字段语义见契约 §4.2：`percent`/`eta_seconds`/`total_seconds` 可能为 null，
  /// `error` 仅 failed 有值，`result_id` 仅 done 有值。
  UploadJob mergeStatus(Map<String, dynamic> d) {
    final st = UploadStatus.parse(d['status']?.toString());
    final pct = d['percent'];
    final eta = d['eta_seconds'];
    final total = d['total_seconds'];
    final err = d['error'];
    final rid = d['result_id'];
    return copyWith(
      status: st,
      percent: pct is num ? pct.toDouble() : null,
      clearPercent: pct == null,
      etaSeconds: eta is num ? eta.toInt() : null,
      clearEta: eta == null,
      totalSeconds: total is num ? total.toDouble() : null,
      error: err?.toString(),
      clearError: err == null,
      resultId: rid?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        'title': title,
        'fileName': fileName,
        'fileSize': fileSize,
        'createdAt': createdAt,
        'status': status.wire,
        'uploadProgress': uploadProgress,
        'percent': percent,
        'etaSeconds': etaSeconds,
        'totalSeconds': totalSeconds,
        'error': error,
        'resultId': resultId,
      };

  static UploadJob fromJson(Map<String, dynamic> j) => UploadJob(
        jobId: j['jobId']?.toString(),
        title: (j['title'] ?? '').toString(),
        fileName: (j['fileName'] ?? '').toString(),
        fileSize: (j['fileSize'] as num?)?.toInt() ?? 0,
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        status: UploadStatus.parse(j['status']?.toString()),
        uploadProgress: (j['uploadProgress'] as num?)?.toDouble() ?? 0,
        percent: (j['percent'] as num?)?.toDouble(),
        etaSeconds: (j['etaSeconds'] as num?)?.toInt(),
        totalSeconds: (j['totalSeconds'] as num?)?.toDouble(),
        error: j['error']?.toString(),
        resultId: j['resultId']?.toString(),
      );
}
