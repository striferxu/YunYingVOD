/// login_page.dart — 登录页（P3）。
///
/// 服务端行为（P0 实测，文案必须匹配）：
///   * 401「用户名或密码错误」—— 服务端不区分用户不存在 / pending 审核，客户端也不区分；
///     P7 起文案补为「用户名或密码错误，或账号正在等待管理员审核」
///   * 423「账号已锁定，请 10 分钟后再试」—— 第 11 次连续错密码触发，锁 600 秒
///   * 503「操作过于频繁，请稍后再试」—— nginx 限流 15r/m burst=5
///
/// 防连点：请求期间按钮禁用 + 转圈，避免自己触发限流。
library;

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/auth_controller.dart';
import '../../core/router.dart';
import '../../core/theme.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _userCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _pwdFocus = FocusNode();

  bool _submitting = false;
  bool _obscure = true;
  String? _error;
  bool _errorLocked = false;
  bool _errorRateLimited = false;

  @override
  void initState() {
    super.initState();
    _prefillUsername();
  }

  Future<void> _prefillUsername() async {
    final last = await context.read<AuthController>().lastUsername();
    if (!mounted) return;
    if (last != null && last.isNotEmpty) {
      _userCtrl.text = last;
      // 光标移到密码框，用户只需输密码
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pwdFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _pwdCtrl.dispose();
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
      _errorLocked = false;
      _errorRateLimited = false;
    });

    try {
      await context.read<AuthController>().login(_userCtrl.text, _pwdCtrl.text);
      if (!mounted) return;
      // 登录成功：路由守卫会自动放行，这里显式 go 一次保证跳转
      context.go(AppRoutes.home);
    } on AuthError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _errorLocked = e.locked;
        _errorRateLimited = e.rateLimited;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '登录失败：$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.gap24,
              vertical: AppTheme.gap32,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildBrand(),
                    const SizedBox(height: AppTheme.gap32),
                    _buildUsernameField(),
                    const SizedBox(height: AppTheme.gap16),
                    _buildPasswordField(),
                    if (_error != null) ...[
                      const SizedBox(height: AppTheme.gap16),
                      _buildErrorBanner(),
                    ],
                    const SizedBox(height: AppTheme.gap24),
                    _buildSubmitButton(),
                    const SizedBox(height: AppTheme.gap8),
                    _buildRegisterEntry(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrand() {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppTheme.seed.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(
            Icons.play_circle_fill_rounded,
            size: 44,
            color: AppTheme.seed,
          ),
        ),
        const SizedBox(height: AppTheme.gap16),
        const Text(
          '云影 VOD',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: AppTheme.gap8),
        const Text(
          '登录后观看全部视频',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
      ],
    );
  }

  Widget _buildUsernameField() {
    return TextFormField(
      controller: _userCtrl,
      enabled: !_submitting,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
      decoration: const InputDecoration(
        labelText: '用户名',
        hintText: '请输入用户名',
        prefixIcon: Icon(Icons.person_outline_rounded, size: 20),
      ),
      validator: (v) => (v == null || v.trim().isEmpty) ? '请输入用户名' : null,
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
        labelText: '密码',
        hintText: '请输入密码',
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
      validator: (v) => (v == null || v.isEmpty) ? '请输入密码' : null,
      onFieldSubmitted: (_) => _submit(),
    );
  }

  Widget _buildErrorBanner() {
    final icon = _errorLocked
        ? Icons.lock_clock_rounded
        : _errorRateLimited
            ? Icons.hourglass_bottom_rounded
            : Icons.error_outline_rounded;
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
          Icon(icon, size: 18, color: AppTheme.danger),
          const SizedBox(width: AppTheme.gap8),
          Expanded(
            child: Text(
              _error!,
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

  Widget _buildSubmitButton() {
    return SizedBox(
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
            : const Text('登录'),
      ),
    );
  }

  Widget _buildRegisterEntry() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          '还没有账号？',
          style: TextStyle(fontSize: 13, color: AppTheme.textTertiary),
        ),
        TextButton(
          onPressed: _submitting ? null : () => context.push(AppRoutes.register),
          child: const Text('申请注册', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}
