/// player_page.dart — 播放页（P2 占位）。
///
/// P5 是本项目最高风险点：
///   * HLS AES-128 加密，m3u8 里 key URI 是相对路径 `/key/<id>`
///   * /videos/ 与 /key/ 都走 nginx auth_request，**必须带会话 Cookie**
///   * ts 文件名不统一（output0.ts vs output_000.ts），不要硬编码
library;

import 'package:material_ui/material_ui.dart';

import '../../core/widgets/state_views.dart';

class PlayerPage extends StatelessWidget {
  final String videoId;

  const PlayerPage({super.key, required this.videoId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('播放')),
      backgroundColor: Colors.black,
      body: EmptyView(
        icon: Icons.play_circle_outline_rounded,
        message: '播放器',
        hint: 'videoId = $videoId\nP2 骨架阶段：占位页\nP5 接入 HLS + AES-128',
      ),
    );
  }
}
