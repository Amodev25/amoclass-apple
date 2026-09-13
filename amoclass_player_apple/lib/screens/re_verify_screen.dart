import 'package:flutter/material.dart';
import '../services/session_service.dart';
import '../services/auth_service.dart';
import '../services/library_service.dart';
import '../core/decryption_service.dart';
import '../core/amo_native_bridge.dart';
import 'library_screen.dart';
import 'package:amo_core/amo_core.dart';
import '../widgets/course_files_prompt.dart';

/// Password-only re-verification screen for Android.
///
/// Shown when the offline grace period (2 opens) is exceeded.
/// - **Single course**: displays the course name with a password field.
/// - **Multi-course**: displays the course list first; tapping one shows
///   the password field with that course's name.
class ReVerifyScreen extends StatefulWidget {
  final List<StoredCourse> courses;

  const ReVerifyScreen({super.key, required this.courses});

  @override
  State<ReVerifyScreen> createState() => _ReVerifyScreenState();
}

class _ReVerifyScreenState extends State<ReVerifyScreen>
    with SingleTickerProviderStateMixin {
  StoredCourse? _selectedCourse;
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _error;

  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
    _animCtrl.forward();

    // If only one course, auto-select it
    if (widget.courses.length == 1) {
      _selectedCourse = widget.courses.first;
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleVerify() async {
    if (_selectedCourse == null) return;
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(() => _error = AmoL10n.of(context).loginPasswordRequired);
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final error = await SessionService.reVerifyCourse(
      _selectedCourse!,
      password,
    );

    if (!mounted) return;

    if (error == null) {
      // Success — restore auth state and go directly into the course
      final storedCourses = await SessionService.getStoredCourses();
      AuthService.restoreFromSession(storedCourses);

      // Switch to the verified course
      final courseSession = AuthService.courses.firstWhere(
        (c) => c.studentId == _selectedCourse!.studentId,
        orElse: () => AuthService.courses.first,
      );
      AuthService.switchCourse(courseSession);
      // Pass credentials to native bridge for in-process decryption
      if (AuthService.activeCredential != null &&
          AuthService.activeCourseSecret != null) {
        AmoNativeBridge.setCredentials(
          AuthService.activeCredential!,
          AuthService.activeCourseSecret!,
        );
      }
      // Clear library cache + temp files for clean course isolation
      LibraryService.clearCache();
      DecryptionService.cleanupTempFiles();

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, _, _) => const LibraryScreen(),
          transitionsBuilder: (_, anim, _, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    } else {
      final message = error.message;
      setState(() {
        _isLoading = false;
        _error = message;
      });
      if (courseAccessEndedCodes.contains(error.code)) {
        await CourseFilesPrompt.offer(
          context,
          serverCodes: [_selectedCourse!.serverCode],
          message: message,
        );
      }
    }
  }

  void _selectCourse(StoredCourse course) {
    setState(() {
      _selectedCourse = course;
      _error = null;
      _passwordController.clear();
    });
    _animCtrl.reset();
    _animCtrl.forward();
  }

  void _backToCourseList() {
    setState(() {
      _selectedCourse = null;
      _error = null;
      _passwordController.clear();
    });
    _animCtrl.reset();
    _animCtrl.forward();
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
                    child: _selectedCourse != null
                        ? _buildPasswordCard()
                        : _buildCourseListCard(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Background ────────────────────────────────────────────────────────────

  Widget _buildBackground() {
    return PositionedDirectional(
      top: -120,
      end: -80,
      child: Container(
        width: 350,
        height: 350,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              AppColors.verifyAccent.withValues(alpha: 0.06),
              Colors.transparent,
            ],
          ),
        ),
      ),
    );
  }

  // ── Course list card (multi-course) ───────────────────────────────────────

  Widget _buildCourseListCard() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 440),
      padding: const EdgeInsets.all(28),
      decoration: _cardDecoration(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildIconBadge(Icons.verified_user_outlined, AppColors.verifyAccent),
          const SizedBox(height: 20),
          Text(
            AmoL10n.of(context).verifyTitle,
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AmoL10n.of(context).verifySubtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 28),
          ...widget.courses.map((course) => _buildCourseListItem(course)),
        ],
      ),
    );
  }

  Widget _buildCourseListItem(StoredCourse course) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _selectCourse(course),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: 68,
            decoration: BoxDecoration(
              color: AppColors.surfaceDark,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.menu_book_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        course.courseName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        course.teacherName,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (course.offlineCounter >= SessionService.maxOfflineOpens)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    margin: const EdgeInsetsDirectional.only(end: 8),
                    decoration: BoxDecoration(
                      color: AppColors.verifyAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      AmoL10n.of(context).verifyBadge,
                      style: TextStyle(
                        color: AppColors.verifyAccent,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: Colors.white.withValues(alpha: 0.25),
                  size: 14,
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Password card (single course selected) ────────────────────────────────

  Widget _buildPasswordCard() {
    final course = _selectedCourse!;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 440),
      padding: const EdgeInsets.all(28),
      decoration: _cardDecoration(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildIconBadge(Icons.lock_outline, Colors.white),
          const SizedBox(height: 20),
          Text(
            AmoL10n.of(context).verifyAccess,
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),

          // Course name badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.menu_book_rounded,
                  color: Colors.white,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    course.courseName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            AmoL10n.of(
              context,
            ).verifyCourseBy(course.teacherName, course.studentName),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 24),

          // Password field
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              AmoL10n.of(context).loginPasswordLabel,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(height: 6),
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            onFieldSubmitted: (_) => _handleVerify(),
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: AmoL10n.of(context).loginPasswordHint,
              hintStyle: TextStyle(
                color: Colors.white.withValues(alpha: 0.2),
                fontSize: 14,
              ),
              prefixIcon: Icon(
                Icons.lock_outline,
                size: 18,
                color: Colors.white.withValues(alpha: 0.3),
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.3),
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
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
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
            ),
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
          const SizedBox(height: 20),

          // Verify button
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _handleVerify,
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
                        Icon(Icons.verified_outlined, size: 20),
                        SizedBox(width: 8),
                        Text(
                          AmoL10n.of(context).verifyAction,
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

          // Back to course list (only for multi-course)
          if (widget.courses.length > 1) ...[
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: _backToCourseList,
              icon: Icon(
                Icons.arrow_back_rounded,
                size: 16,
                color: Colors.white.withValues(alpha: 0.5),
              ),
              label: Text(
                AmoL10n.of(context).verifyBackToCourses,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 13,
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.wifi_off_rounded,
                size: 14,
                color: AppColors.verifyAccent,
              ),
              const SizedBox(width: 6),
              Text(
                AmoL10n.of(context).verifyInternetRequired,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
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
    );
  }

  Widget _buildIconBadge(IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.12),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Icon(icon, color: color, size: 32),
    );
  }
}
