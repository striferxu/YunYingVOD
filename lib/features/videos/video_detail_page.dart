/// video_detail_page.dart — 视频详情（P2 占位）。
///
/// P4 接入 GET `/api/videos/<id>`，P5 从这里进入播放页。
library;

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/widgets/state_views.dart';

class VideoDetailPage extends StatelessWidget {
  final String videoId;

  const VideoDetailPage({super.key, required this.videoId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('视频详情')),
      body: EmptyView(
        icon: Icons.info_outline_rounded,
        message: '视频详情',
        hint: 'videoId = $videoId\nP2 骨架阶段：占位页',
        action: FilledButton.icon(
          onPressed: () => context.push(AppRoutes.playerOf(videoId)),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('去播放页（占位）'),
          style: FilledButton.styleFrom(backgroundColor: AppTheme.seed),
        ),
      ),
    );
  }
}
