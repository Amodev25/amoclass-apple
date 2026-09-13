import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';
import '../services/session_service.dart';
import 'course_select_screen.dart';
import 'package:amo_core/amo_core.dart';
import '../services/course_files_service.dart';
import '../widgets/course_files_prompt.dart';

class LoginScreen extends StatefulWidget {
  final bool isAddingCourse;

  const LoginScreen({super.key, this.isAddingCourse = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _serverCodeController = TextEditingController();
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _error;

  /// True once the server has refused the code+password pair and the name is
  /// worth asking for. Never true on a first attempt — see [_handleLogin].
  bool _nameRequested = false;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
        );
    _animController.forward();
  }

  @override
  void dispose() {
    _serverCodeController.dispose();
    _nameController.dispose();
    _passwordController.dispose();
    _animController.dispose();
    super.dispose();
  }

  /// Spec D1: the course code and the password ARE the credential. The student's
  /// name is not asked for, and not sent.
  ///
  /// With ONE exception, and it is not cosmetic. A student enrolled before
  /// migration 0022 has no `password_lookup` yet, and the server can only
  /// backfill it on a login that succeeds. Without a name, that login reaches
  /// the server's capped legacy scan — 25 rows — so in a course of 500 an
  /// unconverted student would be refused, and would be refused forever, because
  /// the conversion can only happen on a success. Asking for the name once, only
  /// after the password-only attempt has actually failed, is what closes that
  /// loop: the retry succeeds, the server converts the row, and no later sign-in
  /// on any device ever needs the name again.
  ///
  /// So the name field is not a field the student fills in. It is a recovery step
  /// the app reveals when the server says it could not find them.
  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final String? nameToSend;
    if (_nameRequested) {
      final typed = _nameController.text.trim();
      nameToSend = typed.isEmpty ? null : typed;
    } else {
      nameToSend = null;
    }

    final LoginFailure? failure;
    if (widget.isAddingCourse) {
      // Adding a new course: merge into existing session
      failure = await AuthService.addCourseLogin(
        _serverCodeController.text.trim(),
        _passwordController.text.trim(),
        name: nameToSend,
      );
    } else {
      // Initial login: create fresh session
      failure = await AuthService.login(
        _serverCodeController.text.trim(),
        _passwordController.text.trim(),
        name: nameToSend,
      );
    }

    if (!mounted) return;

    if (failure == null) {
      // Get ALL stored courses from session and go to course select
      final storedCourses = await SessionService.getStoredCourses();

      if (!mounted) return;

      // Use pushAndRemoveUntil to clear the entire nav stack
      // This avoids stale CourseSelectScreen remaining underneath
      Navigator.pushAndRemoveUntil(
        context,
        PageRouteBuilder(
          pageBuilder: (_, _, _) =>
              CourseSelectScreen(storedCourses: storedCourses),
          transitionsBuilder: (_, anim, _, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 400),
        ),
        (route) => false,
      );
    } else {
      // INVALID_LOGIN is the only refusal that can mean "not converted yet" —
      // every other one names something specific (suspended, expired, seats
      // lapsed) that a name would not change, so retrying with one would only
      // waste an attempt against the rate limiter. It is ALSO what a genuinely
      // wrong password returns, which is why the copy covers both readings
      // instead of promising that the name will fix it.
      if (!_nameRequested && failure.code == 'INVALID_LOGIN') {
        setState(() {
          _isLoading = false;
          _nameRequested = true;
          _error = AmoL10n.of(context).loginNameNeeded;
        });
        return;
      }

      // Read OUT of the closure: Dart does not carry a promotion from
      // `failure != null` into a callback, because the callback could run later.
      final message = failure.message;
      setState(() {
        _isLoading = false;
        _error = message;
      });

      // Access to this course has ended. If the student kept its files when
      // they were signed out, this is where they can still let them go.
      if (courseAccessEndedCodes.contains(failure.code)) {
        final serverCodes = await CourseFilesService.serverCodesForLogin(
          _serverCodeController.text.trim(),
        );
        if (!mounted) return;
        await CourseFilesPrompt.offer(
          context,
          serverCodes: serverCodes,
          message: message,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBg,
      body: Stack(
        children: [
          _buildBackground(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: FadeTransition(
                  opacity: _fadeAnim,
                  child: SlideTransition(
                    position: _slideAnim,
                    child: _buildLoginCard(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Background glows ────────────────────────────────────────────────────────

  Widget _buildBackground() {
    return PositionedDirectional(
      top: -150,
      end: -100,
      child: Container(
        width: 400,
        height: 400,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [Colors.white.withValues(alpha: 0.03), Colors.transparent],
          ),
        ),
      ),
    );
  }

  // ── Login card ──────────────────────────────────────────────────────────────

  Widget _buildLoginCard() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 440),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 48,
            offset: const Offset(0, 20),
          ),
          BoxShadow(color: Colors.white.withValues(alpha: 0.04), blurRadius: 1),
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Logo + Settings gear
            Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.iconChipBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.border),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.06),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const LockMark(size: 36, color: Colors.white, weight: 7.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            const Text(
              'Lockclass',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Text(
                AmoL10n.of(context).loginHeader,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              AmoL10n.of(context).loginSubtitle,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),

            // ── Server Code field ─────────────────────────────────────────
            _buildSectionLabel(
              AmoL10n.of(context).loginCourseCodeLabel,
              Icons.vpn_key_outlined,
              Colors.white,
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _serverCodeController,
              keyboardType: TextInputType.text,
              maxLength: 6,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
                TextInputFormatter.withFunction(
                  (oldValue, newValue) => TextEditingValue(
                    text: newValue.text.toUpperCase(),
                    selection: newValue.selection,
                  ),
                ),
              ],
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: 8,
              ),
              decoration: _codeInputDecoration(),
              validator: (v) {
                if (v == null || v.trim().length != 6) {
                  return AmoL10n.of(context).loginCourseCodeLength;
                }
                if (!RegExp(r'^[A-Z0-9]{6}$').hasMatch(v.trim())) {
                  return AmoL10n.of(context).loginCourseCodeCharset;
                }
                return null;
              },
            ),
            const SizedBox(height: 18),

            // ── Full name — only after the server could not find the student
            // without it. Required once shown: it is the retry's whole point.
            if (_nameRequested) ...[
              _buildInputField(
                controller: _nameController,
                label: AmoL10n.of(context).loginNameLabel,
                hint: AmoL10n.of(context).loginNameHint,
                icon: Icons.person_outline,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return AmoL10n.of(context).loginNameRequiredNow;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 18),
            ],

            // ── Password field ────────────────────────────────────────────
            _buildInputField(
              controller: _passwordController,
              label: AmoL10n.of(context).loginPasswordLabel,
              hint: AmoL10n.of(context).loginPasswordHint,
              icon: Icons.lock_outline,
              isPassword: true,
              validator: (v) {
                if (v == null || v.isEmpty) {
                  return AmoL10n.of(context).loginPasswordRequired;
                }
                return null;
              },
            ),

            // Error
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.error.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: AppColors.error,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: AppColors.error,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),

            // Sign In button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _handleLogin,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: Colors.white.withValues(alpha: 0.25),
                  disabledForegroundColor: Colors.black.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: _isLoading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          color: Colors.black54,
                          strokeWidth: 2.5,
                        ),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.login, size: 20),
                          SizedBox(width: 8),
                          Text(
                            AmoL10n.of(context).actionSignIn,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 20),

            // Footer hint
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 14,
                  color: Colors.white.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 6),
                Text(
                  AmoL10n.of(context).loginFooter,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Placed on the login screen because it is the only surface every
            // student sees before choosing anything, and the only one they can
            // reach if the app came up in a language they do not read.
            const Center(child: LanguageToggle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  Widget _buildSectionLabel(String label, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color.withValues(alpha: 0.7)),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }

  InputDecoration _codeInputDecoration() {
    return InputDecoration(
      counterText: '',
      filled: true,
      fillColor: AppColors.surfaceDark,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.error, width: 1.5),
      ),
      hintText: '_ _ _ _ _ _',
      hintStyle: TextStyle(
        color: Colors.white.withValues(alpha: 0.15),
        fontSize: 24,
        fontWeight: FontWeight.w800,
        letterSpacing: 8,
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 16),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool isPassword = false,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          obscureText: isPassword && _obscurePassword,
          validator: validator,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              color: Colors.white.withValues(alpha: 0.2),
              fontSize: 14,
            ),
            prefixIcon: Icon(
              icon,
              size: 18,
              color: Colors.white.withValues(alpha: 0.3),
            ),
            suffixIcon: isPassword
                ? IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 18,
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  )
                : null,
            filled: true,
            fillColor: AppColors.surfaceDark,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.white, width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.error),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.error, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
          ),
        ),
      ],
    );
  }
}
