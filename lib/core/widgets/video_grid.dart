/// video_grid.dart — 网格 / 列表两种布局的列表渲染器。
///
/// 广场与"我的"共用同一套布局逻辑（Web 端 `applyLayoutUI` 也是同一个
/// `home_layout` 同时控制两个列表），所以抽到这里。
///
/// 网格：2 列，宽高比 16:10 封面 + 标题 + meta
/// 列表：单列，左图右文，多一行信息行
library;

import 'package:material_ui/material_ui.dart';

import '../layout_pref.dart';
import '../models/video.dart';
import '../theme.dart';
import 'video_card.dart';

class VideoGrid extends StatelessWidget {
  final List<Video> videos;
  final Map<String, String> owners;
  final ListLayout layout;
  final void Function(Video v)? onTap;

  /// 是否可滚动。放在 RefreshIndicator 里时由外部控制。
  final bool shrinkWrap;
  final ScrollPhysics? physics;
  final EdgeInsetsGeometry padding;

  const VideoGrid({
    super.key,
    required this.videos,
    required this.owners,
    required this.layout,
    this.onTap,
    this.shrinkWrap = false,
    this.physics,
    this.padding = const EdgeInsets.all(AppTheme.gap12),
  });

  @override
  Widget build(BuildContext context) {
    if (layout.isList) {
      return ListView.separated(
        padding: padding,
        shrinkWrap: shrinkWrap,
        physics: physics,
        itemCount: videos.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppTheme.gap8),
        itemBuilder: (ctx, i) => VideoCard(
          video: videos[i],
          owners: owners,
          isList: true,
          onTap: onTap == null ? null : () => onTap!(videos[i]),
        ),
      );
    }

    return GridView.builder(
      padding: padding,
      shrinkWrap: shrinkWrap,
      physics: physics,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: AppTheme.gap12,
        mainAxisSpacing: AppTheme.gap12,
        // 封面 16:10 + 文字区约 56px，用 aspectRatio 近似
        childAspectRatio: 0.86,
      ),
      itemCount: videos.length,
      itemBuilder: (ctx, i) => VideoCard(
        video: videos[i],
        owners: owners,
        isList: false,
        onTap: onTap == null ? null : () => onTap!(videos[i]),
      ),
    );
  }
}
