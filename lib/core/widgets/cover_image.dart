/// cover_image.dart — 视频封面组件（三段回退）。
///
/// 关键约束（P0 实测）：`/covers/` 与 `/videos/` 都走 nginx auth_request，
/// **必须带会话 Cookie**，否则 401。所以不能用裸 `Image.network(url)`，要传 headers。
///
/// 回退链**严格对齐 Web 端 `vod_site/web/app.js:252-287`**：
///   1. primary = `video.cover`（非空时）否则 `/videos/<id>/cover.jpg`
///   2. primary 失败 → fallback = `/covers/<id>.jpg`
///   3. fallback 也失败 → 占位图标（Web 端是 🎬）
///
/// 注意：任务书 PHASE_PLAN P4 写的顺序是 `/covers/` → `/videos/`，
/// 与 Web 端实际代码**相反**。验收标准要求"与 Web 端一致"，故以代码为准。
library;

import 'package:material_ui/material_ui.dart';

import '../api_client.dart';
import '../theme.dart';

class CoverImage extends StatefulWidget {
  /// 服务端返回的 `cover` 字段，可能为 null/空。
  final String? cover;

  /// 视频 id，用于拼 `/videos/<id>/cover.jpg` 与 `/covers/<id>.jpg`。
  final String videoId;

  final double? width;
  final double? height;
  final BoxFit fit;
  final double radius;

  /// 占位时显示的图标（列表里可用更小的图标）。
  final IconData placeholderIcon;

  const CoverImage({
    super.key,
    required this.videoId,
    this.cover,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.radius = AppTheme.radiusS,
    this.placeholderIcon = Icons.movie_outlined,
  });

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  /// 当前已尝试到第几级。0 = primary，1 = fallback，>=2 = 放弃（占位）。
  int _stage = 0;

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 复用到不同视频时重置（ListView 回收场景）
    if (oldWidget.videoId != widget.videoId ||
        oldWidget.cover != widget.cover) {
      _stage = 0;
    }
  }

  /// 候选 URL 列表，按尝试顺序。
  List<String> _candidates() {
    final id = widget.videoId;
    final cover = widget.cover?.trim();

    // 1) primary：cover 字段优先，否则 /videos/<id>/cover.jpg
    final primary = (cover != null && cover.isNotEmpty)
        ? cover
        : '/videos/$id/cover.jpg';
    // 2) fallback：/covers/<id>.jpg
    final fallback = '/covers/$id.jpg';

    // 两者相同时不重复请求
    if (primary == fallback) return [primary];
    return [primary, fallback];
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates();

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: _stage >= candidates.length
            ? _placeholder()
            : Image.network(
                ApiClient().absoluteUrl(candidates[_stage]),
                headers: ApiClient().imageHeaders,
                fit: widget.fit,
                // 加载中不闪白，用同色底
                loadingBuilder: (ctx, child, progress) {
                  if (progress == null) return child;
                  return _placeholder();
                },
                errorBuilder: (ctx, err, st) {
                  // 进入下一级回退。用 postFrame 避免 build 期间 setState。
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    setState(() => _stage++);
                  });
                  return _placeholder();
                },
              ),
      ),
    );
  }

  Widget _placeholder() {
    final small = widget.height != null && widget.height! < 80;
    return Container(
      color: AppTheme.surfaceHigh,
      alignment: Alignment.center,
      child: Icon(
        widget.placeholderIcon,
        color: AppTheme.textTertiary,
        size: small ? 20 : 28,
      ),
    );
  }
}
