/// p6_test.dart — P6（上传与转码进度）单测。
///
/// 覆盖：
///   * `fmtEta` 与 Web 端 `app.js:40 fmtEta` 的文案一致性（验收要求）
///   * `fmtFileSize` 边界
///   * `UploadRepository.isSupportedFile` 扩展名白名单
///   * `VideoRepository.ownerNameOr` 兜底语义（/api/my_videos 无 owner_id）
///   * `UploadJob` 轮询合并的完整状态机流转
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vod_app/core/formatters.dart';
import 'package:vod_app/core/media_proxy.dart';
import 'package:vod_app/core/models/upload_job.dart';
import 'package:vod_app/core/models/video.dart';
import 'package:vod_app/core/upload_repository.dart';
import 'package:vod_app/core/video_repository.dart';

void main() {
  group('fmtEta（对齐 app.js:40）', () {
    test('null 返回 null（UI 据此不显示）', () {
      expect(fmtEta(null), isNull);
    });

    test('不足 60 秒显示「约 N 秒」，最少 1 秒', () {
      expect(fmtEta(0), '约 1 秒');
      expect(fmtEta(1), '约 1 秒');
      expect(fmtEta(30), '约 30 秒');
      expect(fmtEta(59), '约 59 秒');
    });

    test('不足 60 分显示「约 N 分钟」', () {
      expect(fmtEta(60), '约 1 分钟');
      expect(fmtEta(130), '约 2 分钟');
      expect(fmtEta(3599), '约 59 分钟');
    });

    test('超过 1 小时显示「约 N 小时 M 分钟」', () {
      expect(fmtEta(3600), '约 1 小时 0 分钟');
      expect(fmtEta(4800), '约 1 小时 20 分钟');
      expect(fmtEta(7320), '约 2 小时 2 分钟');
    });
  });

  group('fmtFileSize', () {
    test('0 / 负数返回空串', () {
      expect(fmtFileSize(0), '');
      expect(fmtFileSize(-5), '');
    });

    test('小于 1KB 显示 B', () {
      expect(fmtFileSize(512), '512 B');
    });

    test('KB / MB / GB 分级', () {
      expect(fmtFileSize(2048), '2 KB');
      expect(fmtFileSize(1048576), '1.0 MB');
      expect(fmtFileSize(104361273), '99.5 MB');
      expect(fmtFileSize(2 * 1024 * 1024 * 1024), '2.00 GB');
    });
  });

  group('UploadRepository.isSupportedFile', () {
    test('契约里的扩展名全部通过', () {
      for (final ext in UploadRepository.allowedExtensions) {
        expect(UploadRepository.isSupportedFile('clip$ext'), isTrue,
            reason: '$ext 应被支持');
      }
    });

    test('大小写不敏感', () {
      expect(UploadRepository.isSupportedFile('CLIP.MP4'), isTrue);
      expect(UploadRepository.isSupportedFile('a.MoV'), isTrue);
    });

    test('非视频扩展名被拒', () {
      expect(UploadRepository.isSupportedFile('a.txt'), isFalse);
      expect(UploadRepository.isSupportedFile('a.jpg'), isFalse);
      expect(UploadRepository.isSupportedFile('noext'), isFalse);
    });

    test('allowedHint 列出全部扩展名', () {
      final hint = UploadRepository.allowedHint;
      expect(hint, contains('.mp4'));
      expect(hint, contains('.mkv'));
    });
  });

  group('VideoRepository.ownerNameOr 兜底', () {
    Video v(int? ownerId) => Video(
          id: 'x',
          name: 'n',
          date: '2026-11-25T10:00:00',
          ownerId: ownerId,
        );

    test('owner_id 为 null 时用兜底名（/api/my_videos 场景）', () {
      expect(VideoRepository.ownerNameOr({}, v(null), 'user'), 'user');
    });

    test('映射命中时优先用映射', () {
      expect(VideoRepository.ownerNameOr({'6': '昵称A'}, v(6), 'user'), '昵称A');
    });

    test('映射缺失时用兜底名而非「其他用户」', () {
      expect(VideoRepository.ownerNameOr({}, v(6), 'user'), 'user');
    });

    test('对照：原 ownerName 仍回「其他用户」', () {
      expect(VideoRepository.ownerName({}, v(null)), '其他用户');
    });
  });

  // ---------------------------------------------------------------------------
  // P6 真机验收暴露的缺陷回归：新转码视频的 key URI 是本站绝对 URL，
  // 旧逻辑直接放行 → 播放器直连域名 → 撞 SNI 阻断 → 黑屏。
  // ---------------------------------------------------------------------------
  group('MediaProxy.rewritePlaylist（key URI 重写）', () {
    const local = 'http://127.0.0.1:38291';
    const upstream = 'https://51play.ccwu.cc';

    String rewrite(String body) => MediaProxy.rewritePlaylist(
          body,
          localUrl: local,
          upstreamBase: upstream,
        );

    test('历史视频：相对路径 /key/<id> → 本代理', () {
      const body = '#EXT-X-KEY:METHOD=AES-128,URI="/key/7fe00ad2"';
      expect(
        rewrite(body),
        '#EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1:38291/key/7fe00ad2"',
      );
    });

    test('无前导斜杠的相对路径 key/<id> → 本代理', () {
      expect(
        rewrite('URI="key/abc12345"'),
        'URI="http://127.0.0.1:38291/key/abc12345"',
      );
    });

    test('本站绝对 URL（P6 新转码产物）→ 必须重写回本代理', () {
      const body =
          '#EXT-X-KEY:METHOD=AES-128,URI="https://51play.ccwu.cc/key/9c8532f8"';
      expect(
        rewrite(body),
        '#EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1:38291/key/9c8532f8"',
      );
    });

    test('本站绝对 URL 的 /videos/ 路径同样重写', () {
      expect(
        rewrite('URI="https://51play.ccwu.cc/videos/9c8532f8/x.ts"'),
        'URI="http://127.0.0.1:38291/videos/9c8532f8/x.ts"',
      );
    });

    test('外部域名绝对 URL 原样保留（代理无权代发）', () {
      const body = 'URI="https://cdn.example.com/key/abc"';
      expect(rewrite(body), body);
    });

    test('本站域名但非白名单路径（如 /covers/）原样保留', () {
      const body = 'URI="https://51play.ccwu.cc/covers/abc.jpg"';
      expect(rewrite(body), body);
    });

    test('完整 m3u8 多行改写', () {
      const body = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-KEY:METHOD=AES-128,URI="https://51play.ccwu.cc/key/9c8532f8",IV=0x0000
#EXTINF:8.333333,
output_000.ts
''';
      final out = rewrite(body);
      expect(out, contains('URI="http://127.0.0.1:38291/key/9c8532f8"'));
      expect(out, isNot(contains('51play.ccwu.cc')));
      // ts 相对文件名不动，由播放器基于 m3u8 URL 解析
      expect(out, contains('output_000.ts'));
    });
  });

  group('UploadJob 完整状态机', () {
    UploadJob job() => UploadJob(
          jobId: 'abc12345',
          title: 'P6-test',
          fileName: 'clip.mp4',
          fileSize: 104361273,
          createdAt: 1,
          status: UploadStatus.uploading,
        );

    test('uploading → queued → running → done 全链路', () {
      var j = job();
      expect(j.status, UploadStatus.uploading);
      expect(j.status.isFinal, isFalse);

      j = j.copyWith(status: UploadStatus.queued, uploadProgress: 1.0);
      expect(j.status, UploadStatus.queued);

      j = j.mergeStatus({
        'status': 'running',
        'percent': 12.5,
        'eta_seconds': 200,
        'total_seconds': 180.0,
      });
      expect(j.status, UploadStatus.running);
      expect(j.percentInt, 13);
      expect(fmtEta(j.etaSeconds), '约 3 分钟');

      j = j.mergeStatus({
        'status': 'done',
        'percent': 100.0,
        'result_id': 'abc12345',
      });
      expect(j.status, UploadStatus.done);
      expect(j.status.isFinal, isTrue);
      expect(j.resultId, 'abc12345');
    });

    test('running → failed 携带后端 error', () {
      final j = job().mergeStatus({
        'status': 'failed',
        'error': 'ffmpeg exit 1',
      });
      expect(j.status, UploadStatus.failed);
      expect(j.error, 'ffmpeg exit 1');
      expect(j.status.isFinal, isTrue);
    });

    test('percent 超出范围被夹取', () {
      final j = job().mergeStatus({'status': 'running', 'percent': 150.0});
      expect(j.percentInt, 100);
      final k = job().mergeStatus({'status': 'running', 'percent': -5.0});
      expect(k.percentInt, 0);
    });

    test('上传进度百分比换算', () {
      final j = job().copyWith(uploadProgress: 0.47);
      expect(j.uploadPercentInt, 47);
    });
  });
}
