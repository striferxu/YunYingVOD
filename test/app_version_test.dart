/// app_version_test.dart — 校验界面展示版本号与 pubspec.yaml 一致。
///
/// 背景：P8 首次发布时"我的"页脚写死 `v1.0.0`，实际安装包是 `0.1.0`，
/// 用户看到的信息与安装包不符。改为常量 + 本测试，杜绝再次漂移。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vod_app/core/app_info.dart';

void main() {
  test('kAppVersion 与 pubspec.yaml 的 version 主版本一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', multiLine: true)
        .firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml 缺少 version 字段');
    expect(kAppVersion, match!.group(1));
  });
}
