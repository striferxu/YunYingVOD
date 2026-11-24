/// 通用状态组件：加载态、错误态、空态。
///
/// P4 之后每个列表页都会用，先固化下来避免各页各写一套。
library;

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// 居中加载圈。
class LoadingView extends StatelessWidget {
  final String? message;

  const LoadingView({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          if (message != null) ...[
            const SizedBox(height: AppTheme.gap16),
            Text(
              message!,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 错误态：图标 + 文案 + 重试按钮。
class ErrorView extends StatelessWidget {
  final String message;

  /// 可选的详细说明（如后端返回的原始错误）。
  final String? detail;
  final VoidCallback? onRetry;
  final String retryLabel;

  const ErrorView({
    super.key,
    required this.message,
    this.detail,
    this.onRetry,
    this.retryLabel = '重试',
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 48,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: AppTheme.gap16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (detail != null && detail!.isNotEmpty) ...[
              const SizedBox(height: AppTheme.gap8),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: 12,
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: AppTheme.gap24),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(retryLabel),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.seed,
                  side: const BorderSide(color: AppTheme.divider),
                  minimumSize: const Size(120, 44),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 空态：图标 + 说明。
class EmptyView extends StatelessWidget {
  final String message;
  final String? hint;
  final IconData icon;
  final Widget? action;

  const EmptyView({
    super.key,
    required this.message,
    this.hint,
    this.icon = Icons.inbox_rounded,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppTheme.textTertiary),
            const SizedBox(height: AppTheme.gap16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 15,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: AppTheme.gap8),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: 12,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppTheme.gap24),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
