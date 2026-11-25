/// formatters.dart — 列表展示用的格式化函数。
///
/// **严格对齐 Web 端 `vod_site/web/app.js` 的实现**，不要用 intl 的通用格式，
/// 否则 App 与 Web 显示会不一致（验收标准要求"字段逐一对得上"）。
///
/// 对应关系：
///   fmtDuration  <- app.js:33
///   fmtViews     <- app.js:56
///   fmtDateTime  <- app.js:46
library;

/// 时长：`1 分钟 30 秒` / `45 秒`；空或 <=0 返回空串。
///
/// 注意与 `Video.durationText`（`1:30` 形式）不同——列表元信息用本函数，
/// 与 Web 端一致。
String fmtDuration(double? sec) {
  if (sec == null || sec <= 0) return '';
  final total = sec.round();
  final m = total ~/ 60;
  final s = total % 60;
  return '${m > 0 ? '$m 分钟 ' : ''}$s 秒';
}

/// 播放数：`1.2 万 次` / `12 次`。
String fmtViews(int n) {
  if (n >= 10000) {
    final v = (n / 10000).toStringAsFixed(1);
    final trimmed = v.endsWith('.0') ? v.substring(0, v.length - 2) : v;
    return '$trimmed 万 次';
  }
  return '$n 次';
}

/// 上传时间：`2026-11-24 11:13`。
/// 服务端给的是 `2026-11-24T11:13:51`（无时区），直接截取即可，
/// **不要转 DateTime 再 toLocal()**，否则会被当成 UTC 偏移 8 小时。
String fmtDateTime(String? s) {
  if (s == null || s.isEmpty) return '';
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})').firstMatch(s);
  if (m != null) {
    return '${m.group(1)}-${m.group(2)}-${m.group(3)} '
        '${m.group(4)}:${m.group(5)}';
  }
  return s;
}

/// 预计剩余时间：`约 30 秒` / `约 5 分钟` / `约 1 小时 20 分钟`。
///
/// **严格对齐 Web 端 `app.js:40 fmtEta`**（验收要求文案一致）：
///   * < 60 秒 → `约 N 秒`（最少 1 秒）
///   * < 60 分 → `约 N 分钟`
///   * 其余   → `约 N 小时 M 分钟`
/// null 返回 null（调用方据此决定不显示）。
String? fmtEta(int? sec) {
  if (sec == null) return null;
  if (sec < 60) {
    final s = sec.round();
    return '约 ${s < 1 ? 1 : s} 秒';
  }
  final m = sec ~/ 60;
  if (m < 60) return '约 $m 分钟';
  return '约 ${m ~/ 60} 小时 ${m % 60} 分钟';
}

/// 文件体积：`1.2 GB` / `856 MB` / `12 KB`。
String fmtFileSize(int bytes) {
  if (bytes <= 0) return '';
  const kb = 1024;
  if (bytes < kb) return '$bytes B';
  final mb = bytes / (kb * kb);
  if (mb < 1) return '${(bytes / kb).toStringAsFixed(0)} KB';
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}
