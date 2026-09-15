import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import '../core/platform_ui.dart';
import '../services/auth_service.dart';
import '../services/session_service.dart';
import '../services/library_service.dart';
import '../core/decryption_service.dart';
import '../core/amo_native_bridge.dart';
import 'library_screen.dart';
import 'login_screen.dart';
import 'package:amo_player_apple/amo_core/amo_core.dart';

/// Always shown when the app opens with a valid session.
/// Displays course names (teacher names) — user taps one to enter.
/// Verification runs AFTER the user taps a course, not before.
class CourseSelectScreen extends StatefulWidget {
  final List<StoredCourse> storedCourses;

  const CourseSelectScreen({super.key, required this.storedCourses});

  @override
  State<CourseSelectScreen> createState() => _CourseSelectScreenState();
}

class _CourseSelectScreenState extends State<CourseSelectScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  bool _isVerifying = false;
  int? _verifyingIndex;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  /// When user taps a course: verify, then navigate based on result.
  Future<void> _enterCourse(StoredCourse storedCourse, int index) async {
    if (_isVerifying) return;

    setState(() {
      _isVerifying = true;
      _verifyingIndex = index;
    });

    final check = await SessionService.verifySingleCourse(storedCourse);

    if (!mounted) return;

    setState(() {
      _isVerifying = false;
      _verifyingIndex = null;
    });

    // Re-verify, forced logout, or the update dialog (already shown).
    if (!SessionService.handleCheck(context, check)) return;

    // Restore auth + switch to this course
    AuthService.restoreFromSession(check.storedCourses);
    final courseSession = AuthService.courses.firstWhere(
      (c) => c.studentId == storedCourse.studentId,
      orElse: () => AuthService.courses.first,
    );
    AuthService.switchCourse(courseSession);
    // Hand the course content key to the native decryptor. Playback checks
    // the result again before opening a video.
    await AmoNativeBridge.setContentKey(AuthService.activeContentKey ?? '');
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
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  /// Pushed (not replaced), so the login screen's back control pops straight
  /// back here. On iOS a Cupertino route, which gives the edge swipe-back.
  void _addAnotherCourse() {
    const screen = LoginScreen(isAddingCourse: true);
    if (PlatformUi.isMobile) {
      Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => screen));
      return;
    }
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, _, _) => screen,
        transitionsBuilder: (_, anim, _, child) => SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
          child: FadeTransition(opacity: anim, child: child),
        ),
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBg,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header icon
                  _buildHeaderIcon(),
                  const SizedBox(height: 20),
                  Text(
                    AmoL10n.of(context).coursesTitle,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    AmoL10n.of(
                      context,
                    ).coursesWelcomeBack(AuthService.loggedInStudentName ?? ''),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 36),

                  // Course cards
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Column(
                      children: [
                        ...widget.storedCourses.asMap().entries.map((entry) {
                          return _CourseCard(
                            course: entry.value,
                            index: entry.key,
                            isVerifying: _verifyingIndex == entry.key,
                            onTap: () => _enterCourse(entry.value, entry.key),
                          );
                        }),
                        const SizedBox(height: 20),
                        // Add another course button
                        _buildAddCourseButton(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderIcon() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.iconChipBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.06),
            blurRadius: 24,
            spreadRadius: 2,
          ),
        ],
      ),
      child: const Icon(Icons.school_rounded, color: Colors.white, size: 36),
    );
  }

  Widget _buildAddCourseButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _addAnotherCourse,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          height: 54,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border, width: 1.5),
            borderRadius: BorderRadius.circular(14),
            color: Colors.white.withValues(alpha: 0.03),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.add_circle_outline_rounded,
                color: Colors.white.withValues(alpha: 0.7),
                size: 20,
              ),
              const SizedBox(width: 10),
              Text(
                AmoL10n.of(context).coursesAddAnother,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Course card ────────────────────────────────────────────────────────────

class _CourseCard extends StatelessWidget {
  final StoredCourse course;
  final int index;
  final bool isVerifying;
  final VoidCallback onTap;

  const _CourseCard({
    required this.course,
    required this.index,
    required this.isVerifying,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: isVerifying ? null : onTap,
        child: Container(
          height: 76,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              // Left accent bar
              Container(
                width: 3,
                margin: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: const BorderRadiusDirectional.horizontal(
                    end: Radius.circular(4),
                  ).resolve(Directionality.of(context)),
                ),
              ),
              const SizedBox(width: 16),
              // Course icon
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.menu_book_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              // Course name prominent, teacher name below
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
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            course.teacherName,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // D7. Omitted, never shown as a zero, when the server has no
                        // seat for this row or the session file predates T11.
                        if (course.seatNo != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.07),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              AmoL10n.of(context).coursesSeatNo(course.seatNo!),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.55),
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // Loading indicator or arrow
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 16),
                child: isVerifying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: Colors.white.withValues(alpha: 0.25),
                        size: 16,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
