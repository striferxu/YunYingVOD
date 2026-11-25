/// app_info.dart — 应用版本号常量。
///
/// 只用于界面展示（"我的"页脚）。真正的 versionName / versionCode 由
/// `pubspec.yaml` 的 `version:` 字段决定，CI 发布会用 git tag 覆盖
/// versionName，所以这里**不能**当作唯一真值来源。
///
/// `test/app_version_test.dart` 会读取 pubspec.yaml 校验两者一致，
/// 避免界面显示 1.0.0、实际安装 0.1.0 这种不一致（P8 首次发布时出现过）。
library;

const String kAppVersion = '0.1.0';
