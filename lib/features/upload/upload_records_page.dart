/// upload_records_page.dart — 上传记录页（P6）。
///
/// 任务书要求：「上传中杀 App 重开，能从『我的/上传记录』恢复查看该任务进度」。
///
/// 数据来源：本地 `UploadRepository.loadJobs()`（shared_preferences）。
/// 每条记录都带 job_id，点进去即可继续轮询 `/api/upload_status/<id>`——
/// 服务端任务不会因为客户端退出而丢失。
///
/// 交互：
///   * 未终结的记录（uploading/queued/running）→ 顶部「进行中」区，点进去恢复
///   * 已终结的记录（done/failed）→ 「历史」区，可删除
///   * 全部记录可长按删除（本地清理，不影响服务端）
library;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/formatters.dart';
import '../../core/models/upload_job.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/upload_repository.dart';
import '../../core/widgets/state_views.dart';

class UploadRecordsPage extends StatefulWidget {
  const UploadRecordsPage({super.key});

  @override
  State<UploadRecordsPage> createState() => _UploadRecordsPageState();
}

class _UploadRecordsPageState extends State<UploadRecordsPage> {
  final UploadRepository _repo = UploadRepository();
  List<UploadJob> _jobs = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final jobs = await _repo.loadJobs();
    if (!mounted) return;
    setState(() {
      _jobs = jobs;
      _loading = false;
    });
  }

  Future<void> _delete(UploadJob job) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('删除这条记录？'),
        content: const Text(
          '只删除本机记录，不会删除已上传的视频。',
          style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.removeJob(job);
    await _load();
  }

  Future<void> _open(UploadJob job) async {
    // 有 job_id 且未终结 → 进进度页恢复轮询
    if (job.jobId != null && !job.status.isFinal) {
      await context.push(AppRoutes.uploadProgressOf(job.jobId!));
      if (mounted) await _load();
      return;
    }
    // 已完成 → 跳播放页
    if (job.status == UploadStatus.done && job.resultId != null) {
      await context.push(AppRoutes.playerOf(job.resultId!));
      return;
    }
    // 失败或本地中断 → 展示详情弹窗
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(job.status == UploadStatus.failed ? '上传/转码失败' : '任务详情'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('标题：${job.title}',
                style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            if (job.fileName.isNotEmpty)
              Text('文件：${job.fileName}',
                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            if (job.error != null) ...[
              const SizedBox(height: AppTheme.gap8),
              Text('原因：${job.error}',
                  style: const TextStyle(fontSize: 13, color: AppTheme.danger)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('上传记录'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingView(message: '加载中…');

    if (_jobs.isEmpty) {
      return EmptyView(
        icon: Icons.cloud_upload_outlined,
        message: '还没有上传记录',
        hint: '上传视频后，转码进度会显示在这里',
        action: FilledButton.icon(
          onPressed: () async {
            await context.push(AppRoutes.upload);
            if (mounted) await _load();
          },
          icon: const Icon(Icons.upload_rounded, size: 18),
          label: const Text('去上传'),
        ),
      );
    }

    final active = _jobs.where((j) => !j.status.isFinal).toList();
    final history = _jobs.where((j) => j.status.isFinal).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppTheme.gap16),
        children: [
          if (active.isNotEmpty) ...[
            _sectionTitle('进行中'),
            ...active.map((j) => _jobTile(j, active: true)),
            const SizedBox(height: AppTheme.gap16),
          ],
          if (history.isNotEmpty) ...[
            _sectionTitle('历史记录'),
            ...history.map((j) => _jobTile(j, active: false)),
          ],
          const SizedBox(height: AppTheme.gap24),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(
          left: AppTheme.gap4, bottom: AppTheme.gap8, top: AppTheme.gap4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppTheme.textTertiary,
        ),
      ),
    );
  }

  Widget _jobTile(UploadJob job, {required bool active}) {
    Color color;
    IconData icon;
    switch (job.status) {
      case UploadStatus.uploading:
        color = AppTheme.warning;
        icon = Icons.cloud_upload_rounded;
      case UploadStatus.queued:
        color = AppTheme.warning;
        icon = Icons.hourglass_top_rounded;
      case UploadStatus.running:
        color = AppTheme.seed;
        icon = Icons.sync_rounded;
      case UploadStatus.done:
        color = AppTheme.success;
        icon = Icons.check_circle_rounded;
      case UploadStatus.failed:
        color = AppTheme.danger;
        icon = Icons.error_rounded;
    }

    String subtitle;
    if (job.status == UploadStatus.running) {
      final eta = fmtEta(job.etaSeconds);
      subtitle = eta != null ? '${job.percentInt}% · 预计还需 $eta' : '${job.percentInt}%';
    } else if (job.status == UploadStatus.failed) {
      subtitle = job.error ?? '失败';
    } else if (job.status == UploadStatus.done) {
      subtitle = '已完成 · ${fmtDateTime(_fmtTime(job.createdAt))}';
    } else if (job.status == UploadStatus.uploading) {
      subtitle = '上传中断，点此重新查看';
    } else {
      subtitle = '排队中';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: AppTheme.gap8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusM),
        border: Border.all(color: AppTheme.divider),
      ),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(
          job.title.isEmpty ? job.fileName : job.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: color),
        ),
        trailing: IconButton(
          tooltip: '删除记录',
          icon: const Icon(Icons.delete_outline_rounded,
              size: 20, color: AppTheme.textTertiary),
          onPressed: () => _delete(job),
        ),
        onTap: () => _open(job),
      ),
    );
  }

  /// 毫秒时间戳 → 与服务端同格式的字符串（复用 fmtDateTime 的截取逻辑）。
  static String _fmtTime(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int n) => n < 10 ? '0$n' : '$n';
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }
}
