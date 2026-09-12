// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'amo_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AmoL10nEn extends AmoL10n {
  AmoL10nEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'AMO Player';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionClose => 'Close';

  @override
  String get actionRetry => 'Retry';

  @override
  String get actionRemove => 'Remove';

  @override
  String get actionUnderstood => 'Understood';

  @override
  String get actionOk => 'OK';

  @override
  String get actionYes => 'Yes';

  @override
  String get actionNo => 'No';

  @override
  String get actionPleaseWait => 'Please wait';

  @override
  String get actionLoading => 'Loading';

  @override
  String get actionSignIn => 'Sign In';

  @override
  String get actionGoToLogin => 'Go to Login';

  @override
  String get loginHeader => 'STUDENT LOGIN';

  @override
  String get loginSubtitle => 'Enter your course code and password';

  @override
  String get loginCourseCodeLabel => 'COURSE CODE';

  @override
  String get loginCourseCodeLength =>
      'Course code must be exactly 6 characters';

  @override
  String get loginCourseCodeCharset =>
      'Course code must contain only letters and numbers';

  @override
  String get loginNameLabel => 'FULL NAME';

  @override
  String get loginNameHint => 'Your full name as your teacher registered it';

  @override
  String get loginNameNeeded =>
      'We could not find you with that code and password alone. This happens on your first sign-in — enter your full name once, exactly as your teacher registered it.';

  @override
  String get loginNameRequiredNow => 'Please enter your full name';

  @override
  String get loginPasswordLabel => 'PASSWORD';

  @override
  String get loginPasswordHint => 'Enter your password';

  @override
  String get loginPasswordRequired => 'Please enter your password';

  @override
  String get loginFooter => 'Protected content · Encrypted playback';

  @override
  String get coursesTitle => 'My Courses';

  @override
  String coursesWelcomeBack(String name) {
    return 'Welcome back, $name';
  }

  @override
  String coursesSeatNo(int seat) {
    return 'Seat no. $seat';
  }

  @override
  String get coursesAddAnother => 'Add Another Course';

  @override
  String get coursesCheckingSession => 'Checking session...';

  @override
  String get libraryTitle => 'Library';

  @override
  String get libraryTabVideos => 'Videos';

  @override
  String get libraryTabFiles => 'Files';

  @override
  String get libraryMyVideos => 'My Videos';

  @override
  String get libraryMyFiles => 'My Files';

  @override
  String get libraryNoVideos => 'No videos yet';

  @override
  String get libraryNoFiles => 'No files yet';

  @override
  String get libraryNoVideosHint =>
      'Import your encrypted AMO videos to get started';

  @override
  String get libraryNoFilesHint =>
      'Import your encrypted AMO PDFs to get started';

  @override
  String get libraryEmptyFolderHint =>
      'Import encrypted AMO files to get started';

  @override
  String get libraryNoVideosInFolder => 'No videos in this folder';

  @override
  String get libraryNoFilesInFolder => 'No files in this folder';

  @override
  String get libraryLoading => 'Loading library...';

  @override
  String libraryNoResults(String query) {
    return 'No results for \"$query\"';
  }

  @override
  String get libraryImportFiles => 'Import Files';

  @override
  String get libraryImportDialogTitle => 'Import Encrypted File (Video or PDF)';

  @override
  String get libraryImportingTitle => 'Importing Files';

  @override
  String libraryImportFileProgress(int index, int total) {
    return 'File $index of $total';
  }

  @override
  String get libraryImportNoneValid => 'No valid AMO encrypted files found';

  @override
  String get libraryPreparing => 'Preparing...';

  @override
  String get libraryAnotherCourse => 'Another Course';

  @override
  String get libraryFocus => 'Focus';

  @override
  String get libraryFocused => 'Focused';

  @override
  String get libraryOffline => 'Offline';

  @override
  String get libraryOnline => 'Online';

  @override
  String get libraryWatched => 'WATCHED';

  @override
  String get libraryFolderTag => 'FOLDER';

  @override
  String libraryItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
      zero: 'No items',
    );
    return '$_temp0';
  }

  @override
  String libraryVideoCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count videos',
      one: '1 video',
      zero: 'No videos',
    );
    return '$_temp0';
  }

  @override
  String libraryFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
      zero: 'No files',
    );
    return '$_temp0';
  }

  @override
  String libraryImportResult(int imported) {
    String _temp0 = intl.Intl.pluralLogic(
      imported,
      locale: localeName,
      other: '$imported files imported successfully',
      one: '1 file imported successfully',
    );
    return '$_temp0';
  }

  @override
  String libraryImportResultWithFailures(int imported, int failed) {
    String _temp0 = intl.Intl.pluralLogic(
      imported,
      locale: localeName,
      other: '$imported files imported',
      one: '1 file imported',
    );
    String _temp1 = intl.Intl.pluralLogic(
      failed,
      locale: localeName,
      other: '$failed failed',
      one: '1 failed',
    );
    return '$_temp0, $_temp1';
  }

  @override
  String get libraryRemoveTitle => 'Remove File';

  @override
  String libraryRemoveBody(String name) {
    return 'Remove \"$name\" from library?\n(The file won\'t be deleted)';
  }

  @override
  String get libraryNotYourCourseTitle => 'Not In Your Course';

  @override
  String get libraryNotYourCourseBody =>
      'This file was encrypted for a different course. It cannot be opened with your current server code.';

  @override
  String get libraryNotYourCourseContact =>
      'Please contact your instructor if you believe this is an error.';

  @override
  String libraryWrongServerCode(String fileCode, String myCode) {
    return 'This file belongs to a different server (code: $fileCode). You are logged in with code: $myCode.';
  }

  @override
  String get cloudTitle => 'Cloud';

  @override
  String get cloudRefresh => 'Refresh';

  @override
  String get cloudEmptyFolder => 'This folder is empty';

  @override
  String get cloudNotFetchedTitle => 'Online Content';

  @override
  String get cloudNotFetchedBody =>
      'Click Refresh to load your teacher\'s uploaded files';

  @override
  String get cloudLoadContent => 'Load Content';

  @override
  String get cloudDownload => 'Download';

  @override
  String get cloudResume => 'Resume';

  @override
  String get cloudPlay => 'Play';

  @override
  String cloudDownloadedPercentPaused(int percent) {
    return '$percent% downloaded — Paused';
  }

  @override
  String cloudDownloadedPercentActive(int percent) {
    return '$percent% downloaded — click pause icon to pause';
  }

  @override
  String cloudDownloadedToLibrary(String name) {
    return '\"$name\" downloaded to library';
  }

  @override
  String cloudDownloadFailed(String reason) {
    return 'Download failed: $reason';
  }

  @override
  String cloudLoadFailed(String reason) {
    return 'Failed to load online content: $reason';
  }

  @override
  String cloudFolderFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
      zero: 'No files',
    );
    return '$_temp0';
  }

  @override
  String get playerHeadphonesRequiredTitle => 'Headphones required';

  @override
  String get playerHeadphonesRequiredBody =>
      'This course requires headphones to watch videos.\nConnect wired, Bluetooth, or USB headphones and try again.';

  @override
  String get playerHeadphonesDisconnected => 'Headphones disconnected';

  @override
  String get playerHeadphonesReconnect =>
      'This course requires headphones.\nReconnect them to continue watching.';

  @override
  String get playerWaitingForHeadphones => 'Waiting for headphones…';

  @override
  String get playerLocked => 'Locked · Long press to unlock';

  @override
  String get playerLock => 'Lock';

  @override
  String get playerScreenRecordingBlocked => 'Screen Recording Blocked';

  @override
  String get playerZoomOut => 'Zoom Out (-)';

  @override
  String get playerZoomIn => 'Zoom In (+)';

  @override
  String get playerZoomReset => 'Reset Zoom (0)';

  @override
  String playerZoomLevel(String level) {
    return '${level}x zoom';
  }

  @override
  String get playerPlaybackSpeed => 'Playback Speed';

  @override
  String get playerSpeedNormal => 'Normal';

  @override
  String playerResumeFrom(String time) {
    return 'Resume from $time?';
  }

  @override
  String get playerResume => 'Resume';

  @override
  String get playerStartOver => 'Start Over';

  @override
  String get playerPlayNow => 'Play Now';

  @override
  String playerAutoPlayCountdown(int seconds) {
    return 'Playing next in $seconds...';
  }

  @override
  String get pdfTitle => 'Premium Document Viewer';

  @override
  String get pdfUnlocking => 'Unlocking Document...';

  @override
  String get pdfLoadFailed => 'Unable to load PDF. Please try again.';

  @override
  String get verifyTitle => 'Verify Subscription';

  @override
  String get verifySubtitle => 'Select a course to verify your access';

  @override
  String get verifyAccess => 'Verify Access';

  @override
  String get verifyAction => 'Verify';

  @override
  String get verifyBadge => 'VERIFY';

  @override
  String get verifyBackToCourses => 'Back to courses';

  @override
  String get verifyInternetRequired => 'Internet verification required';

  @override
  String verifyCourseBy(String teacher, String student) {
    return 'Course by $teacher · $student';
  }

  @override
  String get focusModeTitle => 'Focus Mode';

  @override
  String get focusModeSubtitle => 'Lock the app to stay focused';

  @override
  String get focusStudyDuration => 'Study Duration';

  @override
  String get focusCustom => 'Custom';

  @override
  String get focusMinutes => 'Minutes';

  @override
  String get focusEmergencyDuration => 'Emergency Break Duration';

  @override
  String get focusStart => 'Start Focus';

  @override
  String get focusActiveTitle => 'Focus Mode Active';

  @override
  String focusActiveBody(String time) {
    return 'Time remaining: $time\n\nDo you want to end focus mode?';
  }

  @override
  String get focusKeepGoing => 'Keep Going';

  @override
  String get focusStop => 'Stop Focus';

  @override
  String get focusEmergency => 'Emergency';

  @override
  String focusEmergencyPrompt(String duration) {
    return 'Start $duration break?';
  }

  @override
  String get focusBackToFocus => 'Back to Focus';

  @override
  String get focusBlockNotifications => 'Block Notifications';

  @override
  String get focusEnableDnd => 'Enable Do Not Disturb mode';

  @override
  String get focusCannotMinimize =>
      'Cannot minimize while Focus Mode is active.';

  @override
  String get focusCannotClose =>
      'Cannot close while Focus Mode is active. Wait for timer to end.';

  @override
  String get errFileCorrupted => 'File is damaged or incomplete.';

  @override
  String get errFileCorruptedRetryImport =>
      'This file is damaged or incomplete. Try importing it again.';

  @override
  String get errFileCorruptedRedownload =>
      'File is damaged — please re-download.';

  @override
  String get errWrongCourse => 'This file belongs to a different course.';

  @override
  String get errWrongCourseSwitch =>
      'This file belongs to a different course. Please switch to the correct course.';

  @override
  String get errDecryptionFailed => 'Unable to decrypt this file.';

  @override
  String get errOpenFailedSupport =>
      'Unable to open this file. Please contact support.';

  @override
  String get errOpenFailedRetry =>
      'Unable to open this file. Please try again.';

  @override
  String get errWrongCourseContent =>
      'File security check failed — wrong course content';

  @override
  String get errVerificationFailed =>
      'File verification failed. It may not belong to your course.';

  @override
  String get errInvalidCredentials => 'Invalid credentials';

  @override
  String get errCannotConnect =>
      'Cannot connect to server. Please check your internet connection.';

  @override
  String errConnectionFailed(String reason) {
    return 'Connection failed: $reason';
  }

  @override
  String get errCannotConnectDialog =>
      'Cannot connect to server.\\nPlease check your internet connection.';

  @override
  String get errServerRetry => 'Server error. Please try again.';

  @override
  String errServerStatus(int status) {
    return 'Server error $status';
  }

  @override
  String get errNetwork => 'Network error';

  @override
  String get errDownloadUrlFailed => 'Failed to get download URL';

  @override
  String errDownloadHttp(int status) {
    return 'Failed to download: HTTP $status';
  }

  @override
  String get errDownloadNoData => 'Download produced no data';

  @override
  String errDownloadIncomplete(int got, int total) {
    return 'Download incomplete ($got / $total bytes) — will resume';
  }

  @override
  String get errSessionExpiredLogin => 'Session expired. Please log in again.';

  @override
  String get errPlatformLocked =>
      'This account is locked to another platform. Contact your teacher to switch platforms.';

  @override
  String get errCourseAccessExpired =>
      'Your course access has expired.\nPlease contact your teacher.';

  @override
  String get errConnectToVerify =>
      'Please connect to the internet to verify your account.';

  @override
  String get errSessionExpired =>
      'Your session has expired.\nPlease log in again.';

  @override
  String get errSessionInvalid =>
      'Your session is no longer valid.\nPlease log in again.';

  @override
  String get errInternetRequiredTitle => 'Internet Required';

  @override
  String get errAccessDeniedTitle => 'Access Denied';

  @override
  String get srvCourseUnavailable =>
      'This course is unavailable. Contact your teacher.';

  @override
  String get srvCourseExpired =>
      'This course has expired. Contact your teacher for access.';

  @override
  String get srvCourseInactive => 'This course is not active';

  @override
  String get srvCourseExpiredMidsession => 'This course has expired';

  @override
  String get srvEnrollmentExpiredMidsession => 'Your enrollment has expired';

  @override
  String get srvSeatsLapsed =>
      'Access suspended. Your teacher must renew seats for this course.';

  @override
  String get srvStorageLapsed =>
      'Your teacher\'s storage subscription has lapsed. These files are unavailable until it is renewed.';

  @override
  String get srvStudentSuspended =>
      'Your account has been suspended. Contact your teacher.';

  @override
  String get srvStudentNotFound => 'Student not found';

  @override
  String get srvEnrollmentExpired =>
      'Your enrollment has expired. Contact your teacher to renew.';

  @override
  String get srvEnrollmentSuspended => 'Your enrollment has been suspended';

  @override
  String get srvDeviceMismatch =>
      'This account is already linked to another device. Contact your teacher to reset.';

  @override
  String srvPlatformMismatch(String platform) {
    return 'This account is registered for $platform only.';
  }

  @override
  String get srvInvalidLogin => 'Wrong course code or password.';

  @override
  String get srvMissingCredentials => 'Server code and password are required.';

  @override
  String get srvRateLimited => 'Too many attempts. Try again later.';

  @override
  String get srvRateLimitedCourse =>
      'Too many attempts for this course. Try again later.';

  @override
  String get srvSessionInvalid =>
      'Your session has expired. Please sign in again.';

  @override
  String get srvAccessDenied => 'Access denied';

  @override
  String get srvStorageUnconfigured =>
      'Storage not configured. Contact administrator.';

  @override
  String get srvNotFound => 'Not found.';

  @override
  String get srvServerError => 'Internal server error.';
}
