/// upload_page.dart — 上传页（P2 占位）。
///
/// P6 实现：multipart POST /api/upload（字段 video + title），轮询 `/api/upload_status/<id>`。
/// 已知限制：nginx 代理超时 300s，蜂窝网络传大文件会断 → 必须提示"建议 WiFi 上传"。
/// 转码单并发，status 会先出现 queued。
library;

import 'package:material_ui/material_ui.dart';

import '../../core/widgets/state_views.dart';

class UploadPage extends StatelessWidget {
  const UploadPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('上传视频')),
      body: const EmptyView(
        icon: Icons.cloud_upload_outlined,
        message: '上传视频',
        hint: 'P2 骨架阶段：占位页\nP6 接入 multipart 上传 + 转码进度',
      ),
    );
  }
}
