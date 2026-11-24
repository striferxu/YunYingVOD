// models_test.dart — 模型解析单测。
// 用例数据全部来自 P0 实测真实响应（docs/CLIENT_API_SPEC.md）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vod_app/core/models/upload_job.dart';
import 'package:vod_app/core/models/user.dart';
import 'package:vod_app/core/models/video.dart';

void main() {
  group('Video.fromJson', () {
    test('解析 /api/videos 真实响应项（含 owner_id / created_at）', () {
      const raw = '''
      {"id":"a1b2c3d4","name":"测试视频","date":"2026-11-20",
       "cover":"/covers/a1b2c3d4.jpg","duration":1834.5,
       "size_bytes":734003200,"status":"ready","sort_pin":0,"views":42,
       "owner_id":6,"created_at":1795000000}
      ''';
      final v = Video.fromJson(jsonDecode(raw) as Map<String, dynamic>);

      expect(v.id, 'a1b2c3d4');
      expect(v.name, '测试视频');
      expect(v.date, '2026-11-20');
      expect(v.cover, '/covers/a1b2c3d4.jpg');
      expect(v.duration, 1834.5);
      expect(v.sizeBytes, 734003200);
      expect(v.status, VideoStatus.ready);
      expect(v.views, 42);
      expect(v.ownerId, 6);
      expect(v.createdAt, 1795000000);
    });

    test('老数据缺字段时不崩溃（cover 为 null、无 owner_id）', () {
      final v = Video.fromJson({'id': 'tw_001', 'name': '老视频', 'date': '2024-01-01'});
      expect(v.id, 'tw_001');
      expect(v.cover, isNull);
      expect(v.ownerId, isNull);
      expect(v.duration, isNull);
      expect(v.status, VideoStatus.ready);
      expect(v.sortPin, 0);
    });

    test('cover 为空字符串归一化为 null', () {
      final v = Video.fromJson({'id': 'x', 'name': 'n', 'date': 'd', 'cover': ''});
      expect(v.cover, isNull);
    });

    test('durationText 格式：<1h 为 mm:ss，>=1h 为 h:mm:ss', () {
      expect(const Video(id: 'a', name: 'a', date: 'd', duration: 65).durationText, '01:05');
      expect(const Video(id: 'a', name: 'a', date: 'd', duration: 3725).durationText, '1:02:05');
      expect(const Video(id: 'a', name: 'a', date: 'd').durationText, '--:--');
    });

    test('sizeText 换算 GB / MB', () {
      expect(const Video(id: 'a', name: 'a', date: 'd', sizeBytes: 734003200).sizeText, '700.0 MB');
      expect(const Video(id: 'a', name: 'a', date: 'd', sizeBytes: 2147483648).sizeText, '2.00 GB');
      expect(const Video(id: 'a', name: 'a', date: 'd').sizeText, '');
    });

    test('媒体路径拼接（P5 依赖）', () {
      const v = Video(id: 'abc123', name: 'n', date: 'd');
      expect(v.hlsPath, '/videos/abc123/output.m3u8');
      expect(v.keyPath, '/key/abc123');
    });

    test('VideoStatus 未知值回退 ready', () {
      expect(VideoStatus.parse('weird'), VideoStatus.ready);
      expect(VideoStatus.parse(null), VideoStatus.ready);
      expect(VideoStatus.parse('hidden'), VideoStatus.hidden);
    });
  });

  group('VideoPage.fromJson', () {
    test('解析 {total, items}', () {
      const raw = '''
      {"total":33,"items":[
        {"id":"a","name":"A","date":"2026-01-01","status":"ready"},
        {"id":"b","name":"B","date":"2026-01-02","status":"hidden"}
      ]}
      ''';
      final page = VideoPage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(page.total, 33);
      expect(page.items.length, 2);
      expect(page.items[1].status, VideoStatus.hidden);
      expect(page.isEmpty, isFalse);
    });

    test('items 为空数组', () {
      final page = VideoPage.fromJson({'total': 0, 'items': []});
      expect(page.total, 0);
      expect(page.isEmpty, isTrue);
    });

    test('items 缺失时按空处理', () {
      final page = VideoPage.fromJson({'total': 5});
      expect(page.items, isEmpty);
    });
  });

  group('AppUser.fromJson', () {
    test('解析 /api/me', () {
      final u = AppUser.fromJson({'username': 'user', 'role': 'user', 'expires_at': 1795538118});
      expect(u.username, 'user');
      expect(u.role, UserRole.user);
      expect(u.isAdmin, isFalse);
      expect(u.expiresAt, 1795538118);
    });

    test('admin 角色识别', () {
      final u = AppUser.fromJson({'username': 'admin', 'role': 'admin'});
      expect(u.isAdmin, isTrue);
      expect(u.role.label, '管理员');
    });
  });

  group('AppDevice.fromJson', () {
    test('解析 /api/app/tokens 项（P1 实测字段）', () {
      const raw = '''
      {"id":3,"device_name":"Pixel 8","platform":"android",
       "created_at":1795000000,"last_used_at":1795100000,
       "expires_at":1797592000,"ip":"1.2.3.4","current":true}
      ''';
      final d = AppDevice.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(d.id, 3);
      expect(d.deviceName, 'Pixel 8');
      expect(d.platform, 'android');
      expect(d.current, isTrue);
      expect(d.lastUsedAt, 1795100000);
      expect(d.remainingDays, greaterThan(0));
    });

    test('从未使用的设备 lastUsedAt 为 null', () {
      final d = AppDevice.fromJson({'id': 1, 'device_name': 'x', 'platform': 'ios',
        'created_at': 1, 'expires_at': 2, 'last_used_at': null});
      expect(d.lastUsedAt, isNull);
    });
  });

  group('IssuedToken.fromJson', () {
    test('解析 POST /api/app/token 真实响应', () {
      const raw = '''
      {"ok":true,"id":1,"token":"vap_TOkv9XqaEEym","expires_at":1798128317,
       "ttl_days":30,"device_name":"P1-Probe-Device","platform":"android"}
      ''';
      final t = IssuedToken.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(t.token, startsWith('vap_'));
      expect(t.ttlDays, 30);
      expect(t.expiresAt, 1798128317);
    });
  });

  group('UploadJob.fromJson', () {
    test('progress 0-100 归一化为 0-1', () {
      final j = UploadJob.fromJson({'job_id': 'j1', 'status': 'running', 'progress': 62});
      expect(j.progress, closeTo(0.62, 0.0001));
      expect(j.percent, 62);
      expect(j.status, UploadStatus.running);
    });

    test('progress 已是 0-1 时不重复除', () {
      final j = UploadJob.fromJson({'job_id': 'j2', 'status': 'done', 'progress': 0.85});
      expect(j.progress, closeTo(0.85, 0.0001));
      expect(j.status.isTerminal, isTrue);
    });

    test('queued 状态（转码单并发排队）', () {
      final j = UploadJob.fromJson({'job_id': 'j3', 'status': 'queued', 'progress': 0});
      expect(j.status, UploadStatus.queued);
      expect(j.status.label, '排队中');
      expect(j.status.isTerminal, isFalse);
    });

    test('failed 带 error 文案', () {
      final j = UploadJob.fromJson({'job_id': 'j4', 'status': 'failed', 'error': '转码失败'});
      expect(j.status, UploadStatus.failed);
      expect(j.error, '转码失败');
    });
  });
}
