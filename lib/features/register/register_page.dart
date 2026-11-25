/// register_page.dart — 注册页（P7，审核制）。
///
/// 与 Web 端 `index.html#register-mode` / `app.js:doRegister` 的信息结构对齐：
///   用户名 *  [ 3-32位字母/数字/_-. ]
///   昵称 *    [ 展示昵称 ]
///   密码 *    [ 至少6位 ]
///   ┌ 📋 本站采用注册审核机制 ─────────────┐
///   │ 说明文案 + 管理员微信二维码           │
///   └──────────────────────────────────────┘
///   [ 提交注册申请 ]
///   已有账号？去登录
///
/// 服务端契约（docs/CLIENT_API_SPEC.md §5）：
///   * POST /api/register 公开，必须 `Content-Type: application/json`
///   * 200 → status=pending，需管理员审核
///   * 409 → 用户名已存在（不区分大小写）
///   * 400 → 格式错误，error 为中文文案
///
/// 注册成功**不建立会话**，所以成功后不跳首页，而是展示"待审核"结果页 +
/// 二维码，并提示可去登录（pending 登录会 401）。
library;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/auth_controller.dart';
import '../../core/models/register_result.dart';
import '../../core/router.dart';
import '../../core/theme.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  /// 管理员二维码（契约 §5.2 实测公开可访问，无需 Cookie）。
  static const String adminQrUrl = 'https://51play.ccwu.cc/admin_qr.png';

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _userCtrl = TextEditingController();
  final _nickCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _nickFocus = FocusNode();
  final _pwdFocus = FocusNode();

  bool _submitting = false;
  bool _obscure = true;
  String? _error;
  RegisterResult? _result;

  @override
  void dispose() {
    _userCtrl.dispose();
    _nickCtrl.dispose();
    _pwdCtrl.dispose();
    _nickFocus.dispose();
    _pwdFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final res = await context.read<AuthController>().register(
            username: _userCtrl.text,
            nickname: _nickCtrl.text,
            password: _pwdCtrl.text,
          );
      if (!mounted) return;
      setState(() => _result = res);
    } on AuthError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '注册失败：$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _openQrFullscreen() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const _QrViewerPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_result == null ? '创建账号' : '注册申请已提交')),
      body: SafeArea(
        child: _result == null ? _buildForm() : _buildSuccess(_result!),
      ),
    );
  }

  // ---------------------------------------------------------------- 表单

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.gap24,
        vertical: AppTheme.gap24,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '加入云影点播，分享你的视频',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: AppTheme.gap24),
                _buildUsernameField(),
                const SizedBox(height: AppTheme.gap16),
                _buildNicknameField(),
                const SizedBox(height: AppTheme.gap16),
                _buildPasswordField(),
                if (_error != null) ...[
                  const SizedBox(height: AppTheme.gap16),
                  _buildErrorBanner(_error!),
                ],
                const SizedBox(height: AppTheme.gap24),
                _buildReviewNotice(),
                const SizedBox(height: AppTheme.gap24),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF06231F),
                            ),
                          )
                        : const Text('提交注册申请'),
                  ),
                ),
                const SizedBox(height: AppTheme.gap8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('已有账号？',
                        style: TextStyle(
                            fontSize: 13, color: AppTheme.textTertiary)),
                    TextButton(
                      onPressed: _submitting
                          ? null
                          : () {
                              // 从注册页回登录页：优先 pop，直接进来则 go
                              if (context.canPop()) {
                                context.pop();
                              } else {
                                context.go(AppRoutes.login);
                              }
                            },
                      child: const Text('去登录', style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUsernameField() {
    return TextFormField(
      controller: _userCtrl,
      enabled: !_submitting,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      enableSuggestions: false,
      maxLength: 32,
      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
      decoration: const InputDecoration(
        labelText: '用户名 *',
        hintText: '3-32 位字母/数字/_.-',
        helperText: '登录时使用，注册后不可修改',
        counterText: '',
        prefixIcon: Icon(Icons.person_outline_rounded, size: 20),
      ),
      validator: _validateUsername,
      onFieldSubmitted: (_) => _nickFocus.requestFocus(),
    );
  }

  Widget _buildNicknameField() {
    return TextFormField(
      controller: _nickCtrl,
      focusNode: _nickFocus,
      enabled: !_submitting,
      textInputAction: TextInputAction.next,
      maxLength: 64,
      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
      decoration: const InputDecoration(
        labelText: '昵称 *',
        hintText: '展示昵称',
        helperText: '留空则与用户名相同',
        counterText: '',
        prefixIcon: Icon(Icons.badge_outlined, size: 20),
      ),
      validator: (v) {
        final s = (v ?? '').trim();
        if (s.length > 64) return '昵称最多 64 字';
        return null;
      },
      onFieldSubmitted: (_) => _pwdFocus.requestFocus(),
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _pwdCtrl,
      focusNode: _pwdFocus,
      enabled: !_submitting,
      obscureText: _obscure,
      textInputAction: TextInputAction.done,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
      decoration: InputDecoration(
        labelText: '密码 *',
        hintText: '至少 6 位',
        prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
        suffixIcon: IconButton(
          tooltip: _obscure ? '显示密码' : '隐藏密码',
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(
            _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            size: 20,
          ),
        ),
      ),
      validator: (v) {
        final s = v ?? '';
        if (s.isEmpty) return '请输入密码';
        if (s.length < 6) return '密码至少 6 位';
        if (s.length > 256) return '密码过长（最多 256 位）';
        return null;
      },
      onFieldSubmitted: (_) => _submit(),
    );
  }

  /// 用户名校验：与后端 `USERNAME_RE` 逐字一致，文案也与后端 400 相同。
  static String? _validateUsername(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return '请输入用户名';
    if (!AuthController.usernamePattern.hasMatch(s)) {
      return RegisterResult.usernameRuleText;
    }
    return null;
  }

  Widget _buildErrorBanner(String msg) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.gap16,
        vertical: AppTheme.gap12,
      ),
      decoration: BoxDecoration(
        color: AppTheme.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radiusS),
        border: Border.all(color: AppTheme.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 18, color: AppTheme.danger),
          const SizedBox(width: AppTheme.gap8),
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.danger,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 审核机制说明 + 管理员二维码（与 Web 端 `.review-notice` 对齐）。
  Widget _buildReviewNotice() {
    return Container(
      padding: const EdgeInsets.all(AppTheme.gap16),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusM),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.assignment_outlined,
                  size: 18, color: AppTheme.warning),
              const SizedBox(width: AppTheme.gap8),
              Expanded(
                child: Text(
                  '本站采用注册审核机制',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.warning,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.gap8),
          const Text(
            '新注册的账号需要经过管理员审核通过后才能登录。如有疑问，请扫描下方二维码联系管理员。',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: AppTheme.gap16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AdminQr(
                size: 104,
                onTap: _openQrFullscreen,
              ),
              const SizedBox(width: AppTheme.gap12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '管理员联系方式',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    SizedBox(height: AppTheme.gap4),
                    Text(
                      '点击二维码可放大查看。添加管理员时备注你的用户名，可加速审核。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 成功页

  Widget _buildSuccess(RegisterResult r) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.gap24,
        vertical: AppTheme.gap32,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.mark_email_read_outlined,
                  size: 56, color: AppTheme.seed),
              const SizedBox(height: AppTheme.gap16),
              const Text(
                '注册成功，账号待管理员审核',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: AppTheme.gap8),
              Text(
                r.message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: AppTheme.gap24),
              Container(
                padding: const EdgeInsets.all(AppTheme.gap16),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(AppTheme.radiusM),
                  border: Border.all(color: AppTheme.divider),
                ),
                child: Column(
                  children: [
                    const Text(
                      '你的账号信息',
                      style: TextStyle(
                          fontSize: 13, color: AppTheme.textTertiary),
                    ),
                    const SizedBox(height: AppTheme.gap8),
                    Text(
                      r.username,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppTheme.gap4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppTheme.warning.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        '待审核',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.gap24),
              _buildReviewNotice(),
              const SizedBox(height: AppTheme.gap24),
              SizedBox(
                height: 48,
                child: FilledButton.icon(
                  onPressed: () => context.go(AppRoutes.login),
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text('去登录（审核通过后）'),
                ),
              ),
              const SizedBox(height: AppTheme.gap8),
              TextButton(
                onPressed: () => setState(() {
                  _result = null;
                  _error = null;
                  _userCtrl.clear();
                  _nickCtrl.clear();
                  _pwdCtrl.clear();
                }),
                child: const Text('再注册一个账号', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------- 二维码

/// 管理员二维码。加载失败展示可重试的错误块（任务书要求）。
class _AdminQr extends StatefulWidget {
  final double size;
  final VoidCallback? onTap;

  const _AdminQr({required this.size, this.onTap});

  @override
  State<_AdminQr> createState() => _AdminQrState();
}

class _AdminQrState extends State<_AdminQr> {
  /// 重试计数：作为 key 的一部分，让 Image 重新发起请求。
  int _attempt = 0;

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppTheme.radiusS),
          border: Border.all(color: AppTheme.divider),
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.network(
          RegisterPage.adminQrUrl,
          key: ValueKey('admin_qr_$_attempt'),
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress.expectedTotalBytes != null
                      ? progress.cumulativeBytesLoaded /
                          progress.expectedTotalBytes!
                      : null,
                ),
              ),
            );
          },
          errorBuilder: (context, error, stack) => InkWell(
            onTap: () => setState(() => _attempt++),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.qr_code_2_rounded,
                      size: 28, color: AppTheme.textTertiary),
                  SizedBox(height: 4),
                  Text(
                    '加载失败\n点击重试',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10, color: AppTheme.textTertiary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 全屏二维码查看页：可双指缩放、可长按保存。
class _QrViewerPage extends StatelessWidget {
  const _QrViewerPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('管理员二维码'),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 5,
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.gap24),
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: Image.network(
                RegisterPage.adminQrUrl,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stack) => const SizedBox(
                  width: 240,
                  height: 240,
                  child: Center(
                    child: Text(
                      '二维码加载失败\n请检查网络后重试',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54, fontSize: 13),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gap16),
          child: Text(
            '双指缩放查看 · 截图后可在微信「扫一扫」从相册识别',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}
