/// p4_test.dart — P4 阶段纯逻辑单测。
///
/// 覆盖：
///   * 格式化函数与 Web 端 `app.js` 的行为一致性（验收标准要求"字段逐一对得上"）
///   * 布局偏好解析与切换语义
///   * VideoRepository.ownerName 回落规则
///   * VideoPage 解析（含 my_videos 缺 owner_id 的情况）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vod_app/core/formatters.dart';
import 'package:vod_app/core/layout_pref.dart';
import 'package:vod_app/core/models/video.dart';
import 'package:vod_app/core/video_repository.dart';

void main() {
  group('fmtDuration（对齐 app.js:33）', () {
    test('null / 0 / 负数返回空串', () {
      expect(fmtDuration(null), '');
      expect(fmtDuration(0), '');
      expect(fmtDuration(-1), '');
    });

    test('不足 1 分钟只显示秒', () {
      expect(fmtDuration(3.024), '3 秒');
      expect(fmtDuration(45), '45 秒');
    });

    test('超过 1 分钟显示「x 分钟 y 秒」', () {
      expect(fmtDuration(90), '1 分钟 30 秒');
      expect(fmtDuration(3600), '60 分钟 0 秒');
    });

    test('四舍五入到整数秒', () {
      expect(fmtDuration(2.6), '3 秒');
      expect(fmtDuration(2.4), '2 秒');
    });
  });

  group('fmtViews（对齐 app.js:56）', () {
    test('万以下直接加「次」', () {
      expect(fmtViews(0), '0 次');
      expect(fmtViews(12), '12 次');
      expect(fmtViews(9999), '9999 次');
    });

    test('万以上换算并去掉多余的 .0', () {
      expect(fmtViews(10000), '1 万 次');
      expect(fmtViews(12345), '1.2 万 次');
      expect(fmtViews(12000), '1.2 万 次');
      expect(fmtViews(100000), '10 万 次');
    });
  });

  group('fmtDateTime（对齐 app.js:46）', () {
    test('ISO 无时区直接截取，不做时区换算', () {
      expect(fmtDateTime('2026-11-24T11:13:51'), '2026-11-24 11:13');
    });

    test('空格分隔也支持', () {
      expect(fmtDateTime('2026-11-24 11:13:51'), '2026-11-24 11:13');
    });

    test('空值返回空串', () {
      expect(fmtDateTime(null), '');
      expect(fmtDateTime(''), '');
    });

    test('非标准格式原样返回', () {
      expect(fmtDateTime('unknown'), 'unknown');
    });
  });

  group('ListLayout', () {
    test('解析：只有 list 是列表，其余一律网格', () {
      expect(ListLayout.parse('list'), ListLayout.list);
      expect(ListLayout.parse('grid'), ListLayout.grid);
      expect(ListLayout.parse(null), ListLayout.grid);
      expect(ListLayout.parse('whatever'), ListLayout.grid);
    });

    test('切换语义', () {
      expect(ListLayout.grid.toggled, ListLayout.list);
      expect(ListLayout.list.toggled, ListLayout.grid);
    });

    test('存储值与 Web 端 localStorage 一致', () {
      expect(ListLayout.grid.storageValue, 'grid');
      expect(ListLayout.list.storageValue, 'list');
      expect(LayoutPref.storageKey, 'home_layout');
    });

    test('tooltip 文案', () {
      expect(ListLayout.grid.switchTooltip, '切换为列表视图');
      expect(ListLayout.list.switchTooltip, '切换为网格视图');
    });
  });

  group('VideoRepository.ownerName', () {
    const v = Video(id: 'a', name: 'n', date: 'd', ownerId: 1);

    test('命中映射', () {
      expect(VideoRepository.ownerName({'1': 'admin'}, v), 'admin');
    });

    test('映射缺失回落「其他用户」', () {
      expect(VideoRepository.ownerName({}, v), '其他用户');
    });

    test('ownerId 为 null 回落「其他用户」', () {
      const noOwner = Video(id: 'b', name: 'n', date: 'd');
      expect(VideoRepository.ownerName({'1': 'admin'}, noOwner), '其他用户');
    });

    test('映射值为空串也回落', () {
      expect(VideoRepository.ownerName({'1': ''}, v), '其他用户');
    });
  });

  group('VideoPage 解析', () {
    test('标准响应', () {
      final page = VideoPage.fromJson({
        'total': 2,
        'items': [
          {'id': 'a', 'name': 'A', 'date': '2026-11-24T11:13:51'},
          {'id': 'b', 'name': 'B', 'date': '2026-11-24T12:00:00'},
        ],
      });
      expect(page.total, 2);
      expect(page.items.length, 2);
      expect(page.isEmpty, isFalse);
    });

    test('my_videos 缺 owner_id / sort_pin 不报错', () {
      final page = VideoPage.fromJson({
        'total': 1,
        'items': [
          {
            'id': '97c4e6fe',
            'name': 'P0 探针测试视频（可删除）',
            'date': '2026-11-24T23:21:28',
            'cover': '/covers/97c4e6fe.jpg',
            'duration': 3.024,
            'size_bytes': 56936,
            'status': 'ready',
            'views': 0,
            'created_at': 1795533688,
          }
        ],
      });
      final v = page.items.single;
      expect(v.ownerId, isNull);
      expect(v.sortPin, 0);
      expect(v.duration, 3.024);
      expect(fmtDuration(v.duration), '3 秒');
    });

    test('空列表', () {
      final page = VideoPage.fromJson({'total': 0, 'items': []});
      expect(page.isEmpty, isTrue);
      expect(page.total, 0);
    });

    test('items 缺失时按空处理', () {
      final page = VideoPage.fromJson({'total': 0});
      expect(page.isEmpty, isTrue);
    });
  });
}
