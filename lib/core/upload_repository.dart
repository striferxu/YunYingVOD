/// upload_repository.dart — 上传与转码进度数据层（P6）。
///
/// 三个职责：
///   1. **流式上传** `POST /api/upload`（multipart）
///      用 dio 的 `MultipartFile.fromStream`，**绝不 readAsBytes**（2GB 会 OOM）。
///      上传进度通过 dio 的 `onSendProgress` 回调。
///   2. **查询进度** `GET /api/upload_status/<job_id>`
///   3. **本地任务记录持久化**（shared_preferences，JSON 数组）
///      任务书要求「上传中杀 App 重开能恢复进度」——服务端任务不丢，
///      本地只要记住 job_id 就能继续轮询。
///
/// 契约要点（docs/CLIENT_API_SPEC.md §4）：
///   * 成功 202 返回 `{ok, job_id, status:"queued"}`，job_id 是 8 位 hex，
///     **与最终 video id 相同**。
///   * 错误：400 缺字段/扩展名不支持/空文件；401 未登录；413 超限。
///   * 轮询建议 2 秒；`done`/`failed` 即停止。短小视频可能首次就 done。
///
/// ⚠️ nginx `proxy_read_timeout 300s`：蜂窝网络传 >300s 会断，
///    本阶段只保证 WiFi 下 2GB 内可靠（已知限制写入文档）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'models/upload_job.dart';

/// 上传进度回调：0.0 ~ 1.0。
typedef UploadProgressCallback = void Function(double progress);

class UploadRepository {
  static const _kJobs = 'vod_upload_jobs_v1';

  /// 允许的扩展名（与后端一致，契约 §4.1）。
  static const allowedExtensions = [
    '.mp4', '.mov', '.mkv', '.avi', '.webm', '.flv', '.ts', '.m2ts', '.m4v',
  ];

  final ApiClient _api;
  final Dio _dio;

  UploadRepository({ApiClient? api, Dio? dio})
      : _api = api ?? ApiClient(),
        _dio = dio ??
            Dio(BaseOptions(
              // 上传大文件必须放宽超时：15 秒的默认值完全不够。
              // 但 nginx 侧 300s 会掐断，所以这里设 10 分钟留给客户端感知失败。
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 2),
              sendTimeout: const Duration(minutes: 10),
              // 自己处理状态码，避免 dio 对 4xx 抛通用异常
              validateStatus: (_) => true,
            ));

  /// 扩展名是否受支持（大小写不敏感）。用于选择文件后立即拦截。
  static bool isSupportedFile(String name) {
    final lower = name.toLowerCase();
    return allowedExtensions.any(lower.endsWith);
  }

  /// 把扩展名列表渲染成提示文案。
  static String get allowedHint => allowedExtensions.join(' ');

  // ---------------------------------------------------------------------------
  // 上传
  // ---------------------------------------------------------------------------

  /// 流式上传。
  ///
  /// [file] 用 `File` 而不是字节数组：dio 会以流的方式读取并分块发送。
  /// 返回服务端 202 里的 job_id。
  ///
  /// 抛 [ApiException]（含后端 `{"error": ...}` 原文）。
  Future<String> upload({
    required File file,
    required String title,
    UploadProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    final fileName = file.uri.pathSegments.last;
    final len = await file.length();
    if (len == 0) {
      throw const ApiException('视频文件为空');
    }

    final form = FormData();
    form.files.add(MapEntry(
      'video',
      MultipartFile.fromStream(
        // 关键：流式读取，不把整个文件读进内存
        () => file.openRead(),
        len,
        filename: fileName,
      ),
    ));
    form.fields.add(MapEntry('title', title));

    Response<dynamic> resp;
    try {
      resp = await _dio.post<dynamic>(
        '${_api.baseUrl}/api/upload',
        data: form,
        cancelToken: cancelToken,
        options: Options(
          headers: {
            ..._authHeaders(),
            'Accept': 'application/json',
          },
          // 让 dio 自己算 multipart 的 Content-Type 与 boundary
          contentType: 'multipart/form-data',
        ),
        onSendProgress: (sent, total) {
          if (total > 0 && onProgress != null) {
            onProgress((sent / total).clamp(0.0, 1.0));
          }
        },
      );
    } on DioException catch (e) {
      throw _mapDioError(e);
    }

    final status = resp.statusCode ?? 0;
    final data = _asMap(resp.data);

    if (status == 401) {
      throw ApiException('登录已过期，请重新登录', statusCode: 401, body: data);
    }
    if (status < 200 || status >= 300) {
      final msg = (data['error'] ?? '上传失败').toString();
      throw ApiException(msg, statusCode: status, body: data);
    }

    final jobId = data['job_id']?.toString();
    if (jobId == null || jobId.isEmpty) {
      throw const ApiException('服务端未返回 job_id');
    }
    return jobId;
  }

  // ---------------------------------------------------------------------------
  // 查询进度
  // ---------------------------------------------------------------------------

  /// 查询一次转码进度。失败抛 [ApiException]。
  Future<Map<String, dynamic>> fetchStatus(String jobId) async {
    final res = await _api.get('/api/upload_status/$jobId');
    return res.data;
  }

  /// 轮询直到 `done`/`failed` 或取消。
  ///
  /// [onUpdate] 每次拿到新状态都会回调（包含中间态）。
  /// [interval] 默认 2 秒（契约建议）。
  ///
  /// 网络错误**不中断**轮询（弱网抖动很常见），只把错误信息通过
  /// [onTransientError] 上报，由 UI 决定是否提示；连续失败超过
  /// [maxConsecutiveErrors] 次才放弃（默认 5 次 ≈ 10 秒）。
  Future<UploadJob> pollUntilDone(
    UploadJob job, {
    required void Function(UploadJob) onUpdate,
    Duration interval = const Duration(seconds: 2),
    void Function(Object error)? onTransientError,
    bool Function()? shouldStop,
    int maxConsecutiveErrors = 5,
  }) async {
    var current = job;
    var errors = 0;
    while (true) {
      if (shouldStop != null && shouldStop()) return current;
      try {
        final data = await fetchStatus(current.jobId!);
        errors = 0;
        current = current.mergeStatus(data);
        onUpdate(current);
        if (current.status.isFinal) return current;
      } catch (e) {
        errors++;
        onTransientError?.call(e);
        if (errors >= maxConsecutiveErrors) {
          // 不把任务标成 failed——服务端任务可能仍在跑，
          // 只是本地查不到。保留当前状态，让用户手动刷新。
          return current;
        }
      }
      await Future<void>.delayed(interval);
    }
  }

  // ---------------------------------------------------------------------------
  // 本地任务记录
  // ---------------------------------------------------------------------------

  /// 读取全部任务（按创建时间倒序）。
  Future<List<UploadJob>> loadJobs() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kJobs);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final jobs = decoded
          .whereType<Map>()
          .map((m) => UploadJob.fromJson(m.map((k, v) => MapEntry(k.toString(), v))))
          .toList();
      jobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return jobs;
    } catch (_) {
      return const [];
    }
  }

  /// 新增或按 jobId/createdAt 更新一条任务。
  ///
  /// 上传阶段 jobId 还是 null，用 createdAt 作为唯一标识。
  Future<void> saveJob(UploadJob job) async {
    final jobs = (await loadJobs()).toList();
    final idx = jobs.indexWhere((j) => _sameJob(j, job));
    if (idx >= 0) {
      jobs[idx] = job;
    } else {
      jobs.insert(0, job);
    }
    await _writeJobs(jobs);
  }

  /// 删除一条任务记录。
  Future<void> removeJob(UploadJob job) async {
    final jobs = (await loadJobs()).where((j) => !_sameJob(j, job)).toList();
    await _writeJobs(jobs);
  }

  /// 清理已终结且超过 [keepDays] 天的记录，避免无限增长。
  Future<void> pruneJobs({int keepDays = 7}) async {
    final cutoff = DateTime.now()
        .subtract(Duration(days: keepDays))
        .millisecondsSinceEpoch;
    final jobs =
        (await loadJobs()).where((j) => !j.status.isFinal || j.createdAt >= cutoff).toList();
    await _writeJobs(jobs);
  }

  Future<void> _writeJobs(List<UploadJob> jobs) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kJobs, jsonEncode(jobs.map((j) => j.toJson()).toList()));
  }

  static bool _sameJob(UploadJob a, UploadJob b) {
    if (a.jobId != null && b.jobId != null) return a.jobId == b.jobId;
    return a.createdAt == b.createdAt;
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// 复用 ApiClient 的 Cookie 罐（会话 Cookie 是鉴权唯一凭据）。
  Map<String, String> _authHeaders() {
    final cookies = _api.exportCookies();
    if (cookies.isEmpty) return const {};
    return {
      'Cookie': cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
    };
  }

  static Map<String, dynamic> _asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) {
      return data.map((k, v) => MapEntry(k.toString(), v));
    }
    if (data is String && data.isNotEmpty) {
      try {
        final d = jsonDecode(data);
        if (d is Map) return d.map((k, v) => MapEntry(k.toString(), v));
      } catch (_) {}
    }
    return const {};
  }

  static ApiException _mapDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
        return const ApiException('上传超时：网络太慢或文件过大，建议改用 WiFi');
      case DioExceptionType.receiveTimeout:
        return const ApiException('服务器响应超时，请稍后重试');
      case DioExceptionType.cancel:
        return const ApiException('上传已取消');
      case DioExceptionType.connectionError:
        return const ApiException('网络连接失败，请检查网络后重试');
      case DioExceptionType.badCertificate:
        return const ApiException('服务器证书校验失败');
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        final data = _asMap(e.response?.data);
        final msg = (data['error'] ?? '上传失败').toString();
        return ApiException(msg, statusCode: code, body: data);
      case DioExceptionType.unknown:
        final inner = e.error;
        if (inner is SocketException) {
          return ApiException('网络不可用：${inner.message}');
        }
        return ApiException('上传失败：${e.message ?? inner ?? '未知错误'}');
      case DioExceptionType.transformTimeout:
        return const ApiException('服务器响应超时，请稍后重试');
    }
  }
}
