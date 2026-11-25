/// upload_progress_page.dart — 转码进度恢复页（P6）。
///
/// 从「上传记录」点进来的任务详情页：按 job_id 继续轮询
/// `/api/upload_status/<id>`，展示实时进度。
///
/// 存在意义：任务书要求「上传中杀 App 重开，能从上传记录恢复查看进度」。
/// 服务端任务不丢，本页负责把轮询接回去。
///
/// 轮询策略与上传页一致：2 秒间隔，done/failed 停止；
/// 弱网抖动不中断（连续失败 5 次才放弃，给手动刷新按钮）。
library;

import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/formatters.dart';
import '../../core/models/upload_job.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/upload_repository.dart';

class UploadProgressPage extends StatefulWidget {
  final String jobId;

  const UploadProgressPage({super.key, required this.jobId});

  @override
  State<UploadProgressPage> createState() => _UploadProgressPageState();
}

class _UploadProgressPageState extends State<UploadProgressPage> {
  final UploadRepository _repo = UploadRepository();

  UploadJob? _job;
  bool _loading = true;
  String? _error;
  String? _transientHint;
  bool _polling = false;
  bool _stopped = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _stopped = true;
    super.dispose();
  }

  Future<void> _init() async {
    // 从本地记录里找到这条任务，拿到标题/文件名等展示信息
    final jobs = await _repo.loadJobs();
    final found = jobs.where((j) => j.jobId == widget.jobId).firstOrNull;
    if (!mounted) return;
    setState(() {
      _job = found ??
          UploadJob(
            jobId: widget.jobId,
            title: '上传任务',
            createdAt: DateTime.now().millisecondsSinceEpoch,
            status: UploadStatus.queued,
          );
      _loading = false;
    });
    _startPolling();
  }

  void _startPolling() {
    final job = _job;
    if (job == null || _polling) return;
    if (job.status.isFinal) return;
    _polling = true;
    setState(() {
      _error = null;
      _transientHint = null;
    });

    _repo
        .pollUntilDone(
      job,
      shouldStop: () => _stopped || !mounted,
      onUpdate: (updated) {
        if (!mounted || _stopped) return;
        setState(() {
          _job = updated;
          _transientHint = null;
        });
        _repo.saveJob(updated);
      },
      onTransientError: (e) {
        if (!mounted || _stopped) return;
        setState(() => _transientHint = '网络不稳定，正在重试…');
      },
    )
        .then((finalJob) {
      _polling = false;
      if (!mounted || _stopped) return;
      setState(() => _job = finalJob);
    }).catchError((Object e) {
      _polling = false;
      if (!mounted || _stopped) return;
      setState(() => _transientHint = '查询中断：$e');
    });
  }

  Future<void> _refresh() async {
    final job = _job;
    if (job?.jobId == null) return;
    setState(() {
      _transientHint = null;
      _error = null;
    });
    try {
      final data = await _repo.fetchStatus(job!.jobId!);
      final updated = job.mergeStatus(data);
      if (!mounted) return;
      setState(() => _job = updated);
      await _repo.saveJob(updated);
      if (!updated.status.isFinal) _startPolling();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.statusCode == null
            ? '网络连接失败：${e.message}'
            : '查询失败（${e.statusCode}）：${e.message}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('转码进度')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final job = _job;
    if (job == null) {
      return const Center(child: Text('任务不存在'));
    }

    final st = job.status;
    final isDone = st == UploadStatus.done;
    final isFailed = st == UploadStatus.failed;

    Color color = AppTheme.seed;
    IconData icon = Icons.sync_rounded;
    String title = st.label;
    switch (st) {
      case UploadStatus.queued:
        color = AppTheme.warning;
        icon = Icons.hourglass_top_rounded;
        title = '排队中，等待转码';
      case UploadStatus.running:
        color = AppTheme.seed;
        icon = Icons.sync_rounded;
        title = '正在转码…';
      case UploadStatus.done:
        color = AppTheme.success;
        icon = Icons.check_circle_rounded;
        title = '转码完成';
      case UploadStatus.failed:
        color = AppTheme.danger;
        icon = Icons.error_rounded;
        title = '转码失败';
      case UploadStatus.uploading:
        color = AppTheme.warning;
        icon = Icons.cloud_upload_rounded;
        title = '上传中断';
    }

    return ListView(
      padding: const EdgeInsets.all(AppTheme.gap16),
      children: [
        Container(
          padding: const EdgeInsets.all(AppTheme.gap16),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(AppTheme.radiusM),
            border: Border.all(color: AppTheme.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: color, size: 24),
                  const SizedBox(width: AppTheme.gap12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          job.title.isEmpty ? job.fileName : job.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          title,
                          style: TextStyle(fontSize: 12, color: color),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!isFailed) ...[
                const SizedBox(height: AppTheme.gap16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: st == UploadStatus.queued
                        ? null
                        : (isDone ? 1.0 : (job.percentInt / 100).clamp(0.0, 1.0)),
                    minHeight: 8,
                    backgroundColor: AppTheme.surfaceHigh,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
                const SizedBox(height: AppTheme.gap8),
                Text(
                  _progressText(job),
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textTertiary),
                ),
              ],
              if (isFailed) ...[
                const SizedBox(height: AppTheme.gap12),
                Text(
                  job.error ?? '未知错误',
                  style: const TextStyle(fontSize: 13, color: AppTheme.danger),
                ),
              ],
            ],
          ),
        ),
        if (_transientHint != null) ...[
          const SizedBox(height: AppTheme.gap12),
          Text(
            _transientHint!,
            style: const TextStyle(fontSize: 12, color: AppTheme.warning),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppTheme.gap12),
          Text(
            _error!,
            style: const TextStyle(fontSize: 12, color: AppTheme.danger),
          ),
        ],
        const SizedBox(height: AppTheme.gap24),
        if (isDone)
          FilledButton.icon(
            onPressed: job.resultId == null
                ? null
                : () => context.push(AppRoutes.playerOf(job.resultId!)),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('播放视频'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.seed,
              foregroundColor: const Color(0xFF06231F),
              minimumSize: const Size.fromHeight(48),
            ),
          )
        else if (!isFailed)
          OutlinedButton.icon(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('刷新进度'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.seed,
              minimumSize: const Size.fromHeight(48),
            ),
          ),
      ],
    );
  }

  String _progressText(UploadJob job) {
    switch (job.status) {
      case UploadStatus.queued:
        return '服务器正在处理其他任务，请稍候';
      case UploadStatus.running:
        final eta = fmtEta(job.etaSeconds);
        if (eta != null) return '${job.percentInt}% · 预计还需 $eta';
        if (job.totalSeconds != null) {
          return '${job.percentInt}% · 视频总长 ${fmtDuration(job.totalSeconds)}';
        }
        return '${job.percentInt}%';
      case UploadStatus.done:
        return '视频已发布，可在「我的视频」中查看';
      case UploadStatus.failed:
        return job.error ?? '未知错误';
      case UploadStatus.uploading:
        return '上传未完成，请重新上传';
    }
  }
}
