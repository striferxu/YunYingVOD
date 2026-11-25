/// video_card.dart — 视频卡片，支持网格 / 列表两种形态。
///
/// **严格对齐 Web 端 `vod_site/web/app.js` 的 `videoCard(v, layout)`**：
///
/// 两种布局共有的内容：
///   * 缩略图（封面 + 播放遮罩）
///   * 标题（单行省略）
///   * meta 行：上传者 + 时长（时长有才显示）
///
/// **列表模式额外**多一行 `card-info`：
///   `上传者 | 时长 xx | xx 次 | 2026-11-24 11:13`
///   注意 Web 端这一行里上传者和时长是**重复出现**的（card-meta 已有，
///   card-info 再来一遍），这是 Web 端既有行为，App 保持一致。
library;

import 'package:material_ui/material_ui.dart';

import '../formatters.dart';
import '../models/video.dart';
import '../theme.dart';
import '../video_repository.dart';
import 'cover_image.dart';

class VideoCard extends StatelessWidget {
  final Video video;

  /// owner_id -> 昵称映射（来自 /api/owners）。
  final Map<String, String> owners;

  /// 是否为列表模式。
  final bool isList;

  /// 点击回调（P4 跳播放页占位）。
  final VoidCallback? onTap;

  const VideoCard({
    super.key,
    required this.video,
    required this.owners,
    this.isList = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(AppTheme.radiusM),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: isList ? _buildList() : _buildGrid(),
      ),
    );
  }

  // ---------------- 网格 ----------------

  Widget _buildGrid() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _thumb()),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppTheme.gap8, AppTheme.gap8, AppTheme.gap8, AppTheme.gap8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _title(maxLines: 1),
              const SizedBox(height: AppTheme.gap4),
              _metaRow(),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------- 列表 ----------------

  Widget _buildList() {
    return Padding(
      padding: const EdgeInsets.all(AppTheme.gap8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            height: 74,
            child: _thumb(radius: AppTheme.radiusS),
          ),
          const SizedBox(width: AppTheme.gap12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _title(maxLines: 2),
                const SizedBox(height: AppTheme.gap4),
                _metaRow(),
                const SizedBox(height: AppTheme.gap4),
                _infoRow(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 片段 ----------------

  Widget _thumb({double radius = AppTheme.radiusS}) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CoverImage(
          videoId: video.id,
          cover: video.cover,
          radius: radius,
          fit: BoxFit.cover,
        ),
        // 播放遮罩（对应 Web 端 .play-mask）
        Center(
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
      ],
    );
  }

  Widget _title({int maxLines = 1}) {
    return Text(
      video.name,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w500,
        color: AppTheme.textPrimary,
        height: 1.3,
      ),
    );
  }

  /// `上传者 · 时长`（对应 Web 端 .card-meta）。
  Widget _metaRow() {
    final owner = VideoRepository.ownerName(owners, video);
    final dur = fmtDuration(video.duration);
    return Row(
      children: [
        Flexible(
          child: Text(
            owner,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
          ),
        ),
        if (dur.isNotEmpty) ...[
          const SizedBox(width: AppTheme.gap8),
          Text(
            dur,
            style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
          ),
        ],
      ],
    );
  }

  /// 列表模式信息行：`上传者 | 时长 | 播放数 | 上传时间`。
  /// 对应 Web 端 `card-info`（app.js:255）。整行不换行，超出省略。
  Widget _infoRow() {
    final owner = VideoRepository.ownerName(owners, video);
    final dur = fmtDuration(video.duration);
    final parts = <String>[
      owner,
      if (dur.isNotEmpty) '时长 $dur',
      fmtViews(video.views),
      if (fmtDateTime(video.date).isNotEmpty) fmtDateTime(video.date),
    ];

    return Text(
      parts.join('  ·  '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
    );
  }
}
