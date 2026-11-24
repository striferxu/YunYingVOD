/// cover_image.dart — 视频封面组件。
///
/// 关键约束（P0 实测）：`/covers/` 走 nginx auth_request，**必须带会话 Cookie**，
/// 否则 401。所以不能用裸 `Image.network(url)`，要传 headers。
///
/// 封面可能缺失（老数据 cover 为空），需回退到占位图。
library;

import 'package:material_ui/material_ui.dart';

import '../api_client.dart';
import '../theme.dart';

class CoverImage extends StatelessWidget {
  final String? path;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double radius;

  /// 占位时显示的图标（列表里可用更小的图标）。
  final IconData placeholderIcon;

  const CoverImage({
    super.key,
    required this.path,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.radius = AppTheme.radiusS,
    this.placeholderIcon = Icons.movie_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final p = path;
    final hasCover = p != null && p.trim().isNotEmpty;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: hasCover
            ? Image.network(
                ApiClient().absoluteUrl(p),
                headers: ApiClient().imageHeaders,
                fit: fit,
                // 加载中不闪白，用同色底
                loadingBuilder: (ctx, child, progress) {
                  if (progress == null) return child;
                  return _placeholder();
                },
                errorBuilder: (ctx, err, st) => _placeholder(),
              )
            : _placeholder(),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: AppTheme.surfaceHigh,
      alignment: Alignment.center,
      child: Icon(
        placeholderIcon,
        color: AppTheme.textTertiary,
        size: (height != null && height! < 80) ? 20 : 28,
      ),
    );
  }
}
