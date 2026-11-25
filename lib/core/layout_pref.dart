/// layout_pref.dart — 广场/我的列表的布局偏好持久化。
///
/// 与 Web 端保持完全一致：
///   * 存储介质：SharedPreferences（Web 端是 localStorage）
///   * **键名 `home_layout`**（与 Web 端 `app.js` 的 `localStorage.setItem('home_layout', ...)` 同名）
///   * 取值 `grid` / `list`，其他值一律按 `grid` 处理（Web 端：`=== 'list' ? 'list' : 'grid'`）
///
/// 注意：Web 端一个键同时控制"广场"和"我的"两个列表（`applyLayoutUI` 同时 toggle
/// home-grid 与 mine-grid），本 App 沿用同一语义。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 列表布局形态。
enum ListLayout {
  grid,
  list;

  static ListLayout parse(String? raw) =>
      raw == 'list' ? ListLayout.list : ListLayout.grid;

  String get storageValue => name;

  bool get isList => this == ListLayout.list;

  ListLayout get toggled => isList ? ListLayout.grid : ListLayout.list;

  /// 按钮提示文案，对齐 Web 端 `btn.title`。
  String get switchTooltip => isList ? '切换为网格视图' : '切换为列表视图';
}

class LayoutPref {
  /// 与 Web 端 localStorage 完全同名的键。
  static const String storageKey = 'home_layout';

  const LayoutPref._();

  /// 读取偏好；读失败（如平台插件不可用）回落 grid，不抛异常。
  static Future<ListLayout> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return ListLayout.parse(sp.getString(storageKey));
    } catch (_) {
      return ListLayout.grid;
    }
  }

  /// 写入偏好；失败静默（与 Web 端 `try { ... } catch (e) {}` 一致）。
  static Future<void> save(ListLayout layout) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(storageKey, layout.storageValue);
    } catch (_) {
      // 忽略：布局偏好丢失不影响功能
    }
  }
}
