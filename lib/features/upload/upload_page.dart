/// upload_page.dart — 上传页（P6）。
///
/// 流程（任务书 P6）：
///   1. 选视频（`file_picker`，限定 video/*，并做扩展名二次校验）
///   2. 填标题 → 点「开始上传」
///   3. 流式 multipart 上传，显示上传进度（0~100%）
///   4. 202 返回 job_id → 每 2 秒轮询 `/api/upload_status/<job_id>`
///      展示 queued / running（percent + 「预计还需 约 X 分钟」）/ done / failed
///   5. done → 提示成功，可跳「我的视频」
///
/// 关键约束：
///   * **禁止 readAsBytes**：用 dio `MultipartFile.fromStream` 流式发送（2GB 文件会 OOM）。
///   * 上传任务写入本地记录（`UploadRepository.saveJob`），杀进程重开可在
///     「上传记录」里恢复轮询——服务端任务不会因客户端退出而丢失。
///   * 断网时明确报错，**不残留假进度**（进度只在 onSendProgress 回调里推进）。
///   * nginx 300s 超时：蜂窝网络大文件会断，UI 常驻提示「建议 WiFi 上传」。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/formatters.dart';
import '../../core/models/upload_job.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/upload_repository.dart';

class UploadPage extends StatefulWidget {
  const UploadPage({super.key});

  @override
  State<UploadPage> createState() => _UploadPageState();
}

class _UploadPageState extends State<UploadPage> {
  final UploadRepository _repo = UploadRepository();
  final TextEditingController _titleCtrl = TextEditingController();

  /// 已选择的本地文件。
  File? _file;
  String _fileName = '';
  int _fileSize = 0;

  /// 当前任务（null 表示还没开始上传）。
  UploadJob? _job;

  /// 上传进度 0.0~1.0（仅上传阶段）。
  double _uploadProgress = 0;

  /// 是否正在上传/轮询（用于禁用按钮）。
  bool _busy = false;

  /// 错误文案（上传失败、轮询放弃等）。
  String? _error;

  /// 轮询期间的瞬时网络错误提示（弱网抖动，不中断轮询）。
  String? _transientHint;

  CancelToken? _cancelToken;
  Timer? _pollTimer;
  bool _polling = false;
  bool _stopped = false;

  @override
  void initState() {
    super.initState();
    _repo.pruneJobs();
  }

  @override
  void dispose() {
    _stopped = true;
    _pollTimer?.cancel();
    _cancelToken?.cancel('页面已关闭');
    _titleCtrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 选文件
  // ---------------------------------------------------------------------------

  Future<void> _pickFile() async {
    try {
      // file_picker 13.x：静态方法 pickFile()，返回 PlatformFile?（取消为 null）
      final picked = await FilePicker.pickFile(
        type: FileType.video,
      );
      if (picked == null) return;
      final path = picked.path;
      if (path == null || path.isEmpty) {
        _showError('无法读取该文件的路径，请换一个文件试试');
        return;
      }

      // 前端二次校验扩展名（后端也会 400，双保险）
      if (!UploadRepository.isSupportedFile(picked.name)) {
        _showError('不支持的文件类型：${_extOf(picked.name)}\n'
            '支持：${UploadRepository.allowedHint}');
        return;
      }

      final f = File(path);
      final size = await f.length();
      if (size == 0) {
        _showError('视频文件为空，请换一个文件');
        return;
      }

      setState(() {
        _file = f;
        _fileName = picked.name;
        _fileSize = size;
        _error = null;
        _transientHint = null;
        // 标题为空时用文件名（去扩展名）预填，方便用户
        if (_titleCtrl.text.trim().isEmpty) {
          _titleCtrl.text = _stripExt(picked.name);
        }
      });
    } catch (e) {
      _showError('选择文件失败：$e');
    }
  }

  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? name : name.substring(i);
  }

  static String _stripExt(String name) {
    final i = name.lastIndexOf('.');
    return i <= 0 ? name : name.substring(0, i);
  }

  // ---------------------------------------------------------------------------
  // 上传 + 轮询
  // ---------------------------------------------------------------------------

  Future<void> _startUpload() async {
    final file = _file;
    if (file == null) {
      _showError('请先选择视频文件');
      return;
    }
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _showError('请填写视频标题');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _transientHint = null;
      _uploadProgress = 0;
      _job = UploadJob(
        jobId: null,
        title: title,
        fileName: _fileName,
        fileSize: _fileSize,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        status: UploadStatus.uploading,
      );
    });

    // 先落盘一条 uploading 记录，杀进程后能看出"有个上传中断了"
    await _repo.saveJob(_job!);

    _cancelToken = CancelToken();
    try {
      final jobId = await _repo.upload(
        file: file,
        title: title,
        cancelToken: _cancelToken,
        onProgress: (p) {
          if (!mounted || _stopped) return;
          setState(() => _uploadProgress = p);
        },
      );
      if (!mounted || _stopped) return;

      // 上传完成，进入转码轮询
      final job = _job!.copyWith(
        jobId: jobId,
        status: UploadStatus.queued,
        uploadProgress: 1.0,
      );
      setState(() => _job = job);
      await _repo.saveJob(job);
      _startPolling(job);
    } on ApiException catch (e) {
      if (!mounted || _stopped) return;
      final job = _job!.copyWith(
        status: UploadStatus.failed,
        error: e.message,
      );
      setState(() {
        _job = job;
        _busy = false;
        _error = e.statusCode == null
            ? '网络连接失败，上传未完成：${e.message}'
            : e.message;
        // 断网/失败时清掉进度，不留假进度条
        _uploadProgress = 0;
      });
      await _repo.saveJob(job);
    } catch (e) {
      if (!mounted || _stopped) return;
      final job = _job!.copyWith(
        status: UploadStatus.failed,
        error: e.toString(),
      );
      setState(() {
        _job = job;
        _busy = false;
        _error = '上传失败：$e';
        _uploadProgress = 0;
      });
      await _repo.saveJob(job);
    }
  }

  void _startPolling(UploadJob job) {
    if (_polling) return;
    _polling = true;
    setState(() => _busy = true);

    _repo.pollUntilDone(
      job,
      shouldStop: () => _stopped || !mounted,
      onUpdate: (updated) {
        if (!mounted || _stopped) return;
        setState(() {
          _job = updated;
          _transientHint = null;
          if (updated.status.isFinal) _busy = false;
        });
        _repo.saveJob(updated);
      },
      onTransientError: (e) {
        if (!mounted || _stopped) return;
        setState(() => _transientHint = '网络不稳定，正在重试查询进度…');
      },
    ).then((finalJob) {
      _polling = false;
      if (!mounted || _stopped) return;
      setState(() {
        _job = finalJob;
        _busy = !finalJob.status.isFinal;
      });
    }).catchError((Object e) {
      _polling = false;
      if (!mounted || _stopped) return;
      setState(() {
        _busy = false;
        _transientHint = '进度查询中断：$e';
      });
    });
  }

  /// 手动刷新一次进度（轮询放弃后用户点「刷新进度」）。
  Future<void> _refreshStatus() async {
    final job = _job;
    if (job?.jobId == null) return;
    setState(() {
      _transientHint = null;
      _busy = true;
    });
    try {
      final data = await _repo.fetchStatus(job!.jobId!);
      final updated = job.mergeStatus(data);
      if (!mounted) return;
      setState(() {
        _job = updated;
        _busy = !updated.status.isFinal;
      });
      await _repo.saveJob(updated);
      if (!updated.status.isFinal) _startPolling(updated);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _transientHint = '刷新失败：${e.message}';
      });
    }
  }

  void _cancelUpload() {
    _cancelToken?.cancel('用户取消');
    _pollTimer?.cancel();
    setState(() {
      _busy = false;
      _error = '上传已取消';
      _uploadProgress = 0;
      _job = null;
    });
  }

  void _reset() {
    _pollTimer?.cancel();
    setState(() {
      _file = null;
      _fileName = '';
      _fileSize = 0;
      _job = null;
      _uploadProgress = 0;
      _busy = false;
      _error = null;
      _transientHint = null;
      _titleCtrl.clear();
    });
  }

  void _showError(String msg) {
    if (!mounted) return;
    setState(() => _error = msg);
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('上传视频')),
      body: ListView(
        padding: const EdgeInsets.all(AppTheme.gap16),
        children: [
          _wifiTip(),
          const SizedBox(height: AppTheme.gap16),
          _buildFilePicker(),
          const SizedBox(height: AppTheme.gap16),
          TextField(
            controller: _titleCtrl,
            enabled: !_busy,
            maxLength: 100,
            decoration: const InputDecoration(
              labelText: '视频标题',
              hintText: '给视频起个名字',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppTheme.gap8),
          if (_error != null) _errorBox(_error!),
          if (_transientHint != null) _hintBox(_transientHint!),
          const SizedBox(height: AppTheme.gap16),
          if (_job != null && _job!.jobId != null)
            _buildProgressCard(_job!)
          else if (_busy)
            _buildUploadingCard(),
          const SizedBox(height: AppTheme.gap16),
          _buildActions(),
          const SizedBox(height: AppTheme.gap24),
        ],
      ),
    );
  }

  Widget _wifiTip() {
    return Container(
      padding: const EdgeInsets.all(AppTheme.gap12),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusM),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.35)),
      ),
      child: const Row(
        children: [
          Icon(Icons.wifi_rounded, size: 18, color: AppTheme.warning),
          SizedBox(width: AppTheme.gap8),
          Expanded(
            child: Text(
              '大文件建议在 WiFi 下上传。移动网络超过 5 分钟会被服务器断开。',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilePicker() {
    final hasFile = _file != null;
    return InkWell(
      onTap: _busy ? null : _pickFile,
      borderRadius: BorderRadius.circular(AppTheme.radiusM),
      child: Container(
        padding: const EdgeInsets.all(AppTheme.gap16),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusM),
          border: Border.all(
            color: hasFile ? AppTheme.seed.withValues(alpha: 0.5) : AppTheme.divider,
          ),
        ),
        child: Row(
          children: [
            Icon(
              hasFile ? Icons.movie_rounded : Icons.add_circle_outline_rounded,
              size: 28,
              color: hasFile ? AppTheme.seed : AppTheme.textTertiary,
            ),
            const SizedBox(width: AppTheme.gap12),
            Expanded(
              child: hasFile
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${fmtFileSize(_fileSize)} · 点击可重新选择',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textTertiary,
                          ),
                        ),
                      ],
                    )
                  : const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '选择视频文件',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '支持 mp4 / mov / mkv / avi 等',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textTertiary,
                          ),
                        ),
                      ],
                    ),
            ),
            if (!_busy)
              const Icon(Icons.chevron_right_rounded,
                  color: AppTheme.textTertiary),
          ],
        ),
      ),
    );
  }

  /// 上传中（还没有 job_id）的卡片。
  Widget _buildUploadingCard() {
    final pct = (_uploadProgress * 100).round();
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_upload_rounded,
                  size: 20, color: AppTheme.seed),
              const SizedBox(width: AppTheme.gap8),
              const Text('正在上传…',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
              const Spacer(),
              Text('$pct%',
                  style: const TextStyle(
                      fontSize: 14, color: AppTheme.seed)),
            ],
          ),
          const SizedBox(height: AppTheme.gap12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _uploadProgress,
              minHeight: 8,
              backgroundColor: AppTheme.surfaceHigh,
              valueColor: const AlwaysStoppedAnimation(AppTheme.seed),
            ),
          ),
          const SizedBox(height: AppTheme.gap8),
          Text(
            '已上传 ${fmtFileSize((_fileSize * _uploadProgress).round())}'
            ' / ${fmtFileSize(_fileSize)}',
            style: const TextStyle(
                fontSize: 12, color: AppTheme.textTertiary),
          ),
        ],
      ),
    );
  }

  /// 转码进度卡片（job_id 已存在）。
  Widget _buildProgressCard(UploadJob job) {
    final st = job.status;
    final isDone = st == UploadStatus.done;
    final isFailed = st == UploadStatus.failed;

    Color color = AppTheme.seed;
    IconData icon = Icons.autorenew_rounded;
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
        title = '转码完成，视频已发布';
      case UploadStatus.failed:
        color = AppTheme.danger;
        icon = Icons.error_rounded;
        title = '转码失败';
      case UploadStatus.uploading:
        color = AppTheme.seed;
        icon = Icons.cloud_upload_rounded;
        title = '正在上传…';
    }

    // 进度条取值：running 用 percent/100，done 满格，queued 用不确定态动画
    final bool indeterminate = st == UploadStatus.queued;
    final double value = isDone ? 1.0 : (job.percentInt / 100).clamp(0.0, 1.0);

    // 副标题：对齐 Web 端文案（`正在转码... N% · 预计还需 约 X 分钟`）
    String? subtitle;
    if (st == UploadStatus.running) {
      final eta = fmtEta(job.etaSeconds);
      if (eta != null) {
        subtitle = '${job.percentInt}% · 预计还需 $eta';
      } else if (job.totalSeconds != null) {
        subtitle = '${job.percentInt}% · 视频总长 ${fmtDuration(job.totalSeconds)}';
      } else {
        subtitle = '${job.percentInt}%';
      }
    } else if (st == UploadStatus.queued) {
      subtitle = '服务器正在处理其他任务，请稍候';
    } else if (isFailed) {
      subtitle = job.error ?? '未知错误';
    } else if (isDone) {
      subtitle = '已出现在「我的视频」中';
    }

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: AppTheme.gap8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isFailed ? AppTheme.danger : AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          if (!isFailed) ...[
            const SizedBox(height: AppTheme.gap12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: indeterminate ? null : value,
                minHeight: 8,
                backgroundColor: AppTheme.surfaceHigh,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ],
          if (subtitle != null) ...[
            const SizedBox(height: AppTheme.gap8),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: isFailed ? AppTheme.danger : AppTheme.textTertiary,
              ),
            ),
          ],
          if (isDone) ...[
            const SizedBox(height: AppTheme.gap16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => context.push(AppRoutes.myVideos),
                    icon: const Icon(Icons.video_library_rounded, size: 18),
                    label: const Text('去我的视频'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.seed,
                      foregroundColor: const Color(0xFF06231F),
                    ),
                  ),
                ),
                const SizedBox(width: AppTheme.gap8),
                OutlinedButton(
                  onPressed: _reset,
                  child: const Text('再传一个'),
                ),
              ],
            ),
          ],
          if (isFailed) ...[
            const SizedBox(height: AppTheme.gap16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _reset,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重新选择'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActions() {
    // 已完成/失败：只显示重置入口（进度卡片里已有）
    final job = _job;
    if (job != null && job.status.isFinal) return const SizedBox.shrink();

    // 上传/转码进行中：允许取消
    if (_busy) {
      return OutlinedButton.icon(
        onPressed: _cancelUpload,
        icon: const Icon(Icons.close_rounded, size: 18),
        label: const Text('取消上传'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.danger,
          minimumSize: const Size.fromHeight(48),
        ),
      );
    }

    // 轮询放弃（有 job_id 但未终结且不在忙）：给手动刷新
    if (job != null && job.jobId != null && !job.status.isFinal) {
      return OutlinedButton.icon(
        onPressed: _refreshStatus,
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('刷新进度'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.seed,
          minimumSize: const Size.fromHeight(48),
        ),
      );
    }

    return FilledButton.icon(
      onPressed: _file == null ? null : _startUpload,
      icon: const Icon(Icons.cloud_upload_rounded, size: 20),
      label: const Text('开始上传'),
      style: FilledButton.styleFrom(
        backgroundColor: AppTheme.seed,
        foregroundColor: const Color(0xFF06231F),
        minimumSize: const Size.fromHeight(48),
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.gap16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusM),
        border: Border.all(color: AppTheme.divider),
      ),
      child: child,
    );
  }

  Widget _errorBox(String msg) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.gap12),
      margin: const EdgeInsets.only(top: AppTheme.gap8),
      decoration: BoxDecoration(
        color: AppTheme.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusS),
        border: Border.all(color: AppTheme.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 18, color: AppTheme.danger),
          const SizedBox(width: AppTheme.gap8),
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(fontSize: 12, color: AppTheme.danger),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hintBox(String msg) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.gap12),
      margin: const EdgeInsets.only(top: AppTheme.gap8),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radiusS),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              size: 16, color: AppTheme.warning),
          const SizedBox(width: AppTheme.gap8),
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
