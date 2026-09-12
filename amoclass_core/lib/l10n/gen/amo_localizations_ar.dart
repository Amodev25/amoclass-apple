// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'amo_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AmoL10nAr extends AmoL10n {
  AmoL10nAr([String locale = 'ar']) : super(locale);

  @override
  String get appTitle => 'Lockclass';

  @override
  String get actionCancel => 'إلغاء';

  @override
  String get actionClose => 'إغلاق';

  @override
  String get actionRetry => 'حاول مرة أخرى';

  @override
  String get actionRemove => 'إزالة';

  @override
  String get actionUnderstood => 'فهمت';

  @override
  String get actionOk => 'حسناً';

  @override
  String get actionYes => 'نعم';

  @override
  String get actionNo => 'لا';

  @override
  String get actionPleaseWait => 'انتظر من فضلك';

  @override
  String get actionLoading => 'جارٍ التحميل';

  @override
  String get actionSignIn => 'تسجيل الدخول';

  @override
  String get actionGoToLogin => 'اذهب إلى تسجيل الدخول';

  @override
  String get loginHeader => 'دخول الطالب';

  @override
  String get loginSubtitle => 'أدخل كود الكورس وكلمة المرور';

  @override
  String get loginCourseCodeLabel => 'كود الكورس';

  @override
  String get loginCourseCodeLength => 'كود الكورس يجب أن يكون 6 خانات بالضبط';

  @override
  String get loginCourseCodeCharset =>
      'كود الكورس يجب أن يحتوي على حروف وأرقام فقط';

  @override
  String get loginNameLabel => 'الاسم الكامل';

  @override
  String get loginNameHint => 'اسمك الكامل كما سجّله معلمك';

  @override
  String get loginNameNeeded =>
      'لم نتمكن من العثور عليك بكود الكورس وكلمة المرور وحدهما. هذا يحدث في أول مرة تسجّل فيها الدخول — أدخل اسمك الكامل مرة واحدة، كما سجّله معلمك بالضبط.';

  @override
  String get loginNameRequiredNow => 'أدخل اسمك الكامل من فضلك';

  @override
  String get loginPasswordLabel => 'كلمة المرور';

  @override
  String get loginPasswordHint => 'أدخل كلمة المرور';

  @override
  String get loginPasswordRequired => 'أدخل كلمة المرور من فضلك';

  @override
  String get loginFooter => 'محتوى محمي · تشغيل مشفَّر';

  @override
  String get coursesTitle => 'كورساتي';

  @override
  String coursesWelcomeBack(String name) {
    return 'أهلاً بعودتك، $name';
  }

  @override
  String coursesSeatNo(int seat) {
    return 'رقم الجلوس $seat';
  }

  @override
  String get coursesAddAnother => 'أضف كورساً آخر';

  @override
  String get coursesCheckingSession => 'جارٍ التحقق من الجلسة...';

  @override
  String get libraryTitle => 'المكتبة';

  @override
  String get libraryTabVideos => 'الفيديوهات';

  @override
  String get libraryTabFiles => 'الملفات';

  @override
  String get libraryMyVideos => 'فيديوهاتي';

  @override
  String get libraryMyFiles => 'ملفاتي';

  @override
  String get libraryNoVideos => 'لا توجد فيديوهات بعد';

  @override
  String get libraryNoFiles => 'لا توجد ملفات بعد';

  @override
  String get libraryNoVideosHint => 'استورد فيديوهات Lockclass المشفَّرة لتبدأ';

  @override
  String get libraryNoFilesHint => 'استورد ملفات PDF المشفَّرة لتبدأ';

  @override
  String get libraryEmptyFolderHint => 'استورد ملفات Lockclass المشفَّرة لتبدأ';

  @override
  String get libraryNoVideosInFolder => 'لا توجد فيديوهات في هذا المجلّد';

  @override
  String get libraryNoFilesInFolder => 'لا توجد ملفات في هذا المجلّد';

  @override
  String get libraryLoading => 'جارٍ تحميل المكتبة...';

  @override
  String libraryNoResults(String query) {
    return 'لا نتائج لـ \"$query\"';
  }

  @override
  String get libraryImportFiles => 'استيراد ملفات';

  @override
  String get libraryImportDialogTitle => 'استيراد ملف مشفَّر (فيديو أو PDF)';

  @override
  String get libraryImportingTitle => 'جارٍ الاستيراد';

  @override
  String libraryImportFileProgress(int index, int total) {
    return 'الملف $index من $total';
  }

  @override
  String get libraryImportNoneValid =>
      'لم يُعثر على ملفات Lockclass مشفَّرة صالحة';

  @override
  String get libraryPreparing => 'جارٍ التحضير...';

  @override
  String get libraryAnotherCourse => 'كورس آخر';

  @override
  String get libraryFocus => 'التركيز';

  @override
  String get libraryFocused => 'في وضع التركيز';

  @override
  String get libraryOffline => 'دون اتصال';

  @override
  String get libraryOnline => 'عبر الإنترنت';

  @override
  String get libraryWatched => 'تمت المشاهدة';

  @override
  String get libraryFolderTag => 'مجلد';

  @override
  String libraryItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عنصر',
      many: '$count عنصراً',
      few: '$count عناصر',
      two: 'عنصران',
      one: 'عنصر واحد',
      zero: 'لا توجد عناصر',
    );
    return '$_temp0';
  }

  @override
  String libraryVideoCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count فيديو',
      many: '$count فيديو',
      few: '$count فيديوهات',
      two: 'فيديوهان',
      one: 'فيديو واحد',
      zero: 'لا توجد فيديوهات',
    );
    return '$_temp0';
  }

  @override
  String libraryFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ملف',
      many: '$count ملفاً',
      few: '$count ملفات',
      two: 'ملفان',
      one: 'ملف واحد',
      zero: 'لا توجد ملفات',
    );
    return '$_temp0';
  }

  @override
  String libraryImportResult(int imported) {
    String _temp0 = intl.Intl.pluralLogic(
      imported,
      locale: localeName,
      other: 'تم استيراد $imported ملف بنجاح',
      many: 'تم استيراد $imported ملفاً بنجاح',
      few: 'تم استيراد $imported ملفات بنجاح',
      two: 'تم استيراد ملفين بنجاح',
      one: 'تم استيراد ملف واحد بنجاح',
    );
    return '$_temp0';
  }

  @override
  String libraryImportResultWithFailures(int imported, int failed) {
    String _temp0 = intl.Intl.pluralLogic(
      imported,
      locale: localeName,
      other: 'تم استيراد $imported ملف',
      many: 'تم استيراد $imported ملفاً',
      few: 'تم استيراد $imported ملفات',
      two: 'تم استيراد ملفين',
      one: 'تم استيراد ملف واحد',
    );
    String _temp1 = intl.Intl.pluralLogic(
      failed,
      locale: localeName,
      other: 'وفشل $failed ملف',
      many: 'وفشل $failed ملفاً',
      few: 'وفشلت $failed ملفات',
      two: 'وفشل ملفان',
      one: 'وفشل ملف واحد',
    );
    return '$_temp0، $_temp1';
  }

  @override
  String get libraryRemoveTitle => 'إزالة الملف';

  @override
  String libraryRemoveBody(String name) {
    return 'إزالة \"$name\" من المكتبة؟\n(لن يُحذف الملف نفسه)';
  }

  @override
  String get libraryNotYourCourseTitle => 'ليس ضمن كورسك';

  @override
  String get libraryNotYourCourseBody =>
      'هذا الملف مشفَّر لكورس آخر. لا يمكن فتحه بكود الكورس الحالي.';

  @override
  String get libraryNotYourCourseContact =>
      'تواصل مع معلّمك إن كنت تعتقد أن هذا خطأ.';

  @override
  String libraryWrongServerCode(String fileCode, String myCode) {
    return 'هذا الملف يخص خادماً آخر (الكود: $fileCode). أنت مسجَّل الدخول بالكود: $myCode.';
  }

  @override
  String get cloudTitle => 'السحابة';

  @override
  String get cloudRefresh => 'تحديث';

  @override
  String get cloudEmptyFolder => 'هذا المجلد فارغ';

  @override
  String get cloudNotFetchedTitle => 'المحتوى عبر الإنترنت';

  @override
  String get cloudNotFetchedBody =>
      'اضغط تحديث لتحميل الملفات التي رفعها معلّمك';

  @override
  String get cloudLoadContent => 'حمّل المحتوى';

  @override
  String get cloudDownload => 'تحميل';

  @override
  String get cloudResume => 'استئناف';

  @override
  String get cloudPlay => 'تشغيل';

  @override
  String cloudDownloadedPercentPaused(int percent) {
    return 'تم تحميل $percent% — متوقف مؤقتاً';
  }

  @override
  String cloudDownloadedPercentActive(int percent) {
    return 'تم تحميل $percent% — اضغط زر الإيقاف للتوقف مؤقتاً';
  }

  @override
  String cloudDownloadedToLibrary(String name) {
    return 'تم تحميل \"$name\" إلى المكتبة';
  }

  @override
  String cloudDownloadFailed(String reason) {
    return 'فشل التحميل: $reason';
  }

  @override
  String cloudLoadFailed(String reason) {
    return 'تعذّر تحميل المحتوى: $reason';
  }

  @override
  String cloudFolderFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ملف',
      many: '$count ملفاً',
      few: '$count ملفات',
      two: 'ملفان',
      one: 'ملف واحد',
      zero: 'لا توجد ملفات',
    );
    return '$_temp0';
  }

  @override
  String get playerHeadphonesRequiredTitle => 'السماعات مطلوبة';

  @override
  String get playerHeadphonesRequiredBody =>
      'هذا الكورس يتطلب سماعات لمشاهدة الفيديوهات.\nوصّل سماعات سلكية أو بلوتوث أو USB ثم حاول مرة أخرى.';

  @override
  String get playerHeadphonesDisconnected => 'فُصلت السماعات';

  @override
  String get playerHeadphonesReconnect =>
      'هذا الكورس يتطلب سماعات.\nأعد توصيلها لمتابعة المشاهدة.';

  @override
  String get playerWaitingForHeadphones => 'في انتظار السماعات…';

  @override
  String get playerLocked => 'مُقفل · اضغط مطولاً لفتح القفل';

  @override
  String get playerLock => 'قفل';

  @override
  String get playerScreenRecordingBlocked => 'تسجيل الشاشة ممنوع';

  @override
  String get playerZoomOut => 'تصغير (-)';

  @override
  String get playerZoomIn => 'تكبير (+)';

  @override
  String get playerZoomReset => 'إعادة الحجم (0)';

  @override
  String playerZoomLevel(String level) {
    return 'تكبير ${level}x';
  }

  @override
  String get playerPlaybackSpeed => 'سرعة التشغيل';

  @override
  String get playerSpeedNormal => 'عادية';

  @override
  String playerResumeFrom(String time) {
    return 'تكمل من $time؟';
  }

  @override
  String get playerResume => 'أكمل';

  @override
  String get playerStartOver => 'ابدأ من البداية';

  @override
  String get playerPlayNow => 'شغّل الآن';

  @override
  String playerAutoPlayCountdown(int seconds) {
    return 'التالي بعد $seconds...';
  }

  @override
  String get pdfTitle => 'عارض المستندات';

  @override
  String get pdfUnlocking => 'جارٍ فتح المستند...';

  @override
  String get pdfLoadFailed => 'تعذّر تحميل الملف. حاول مرة أخرى.';

  @override
  String get verifyTitle => 'تأكيد الاشتراك';

  @override
  String get verifySubtitle => 'اختر كورساً للتحقق من صلاحيتك';

  @override
  String get verifyAccess => 'تحقق من الصلاحية';

  @override
  String get verifyAction => 'تحقق';

  @override
  String get verifyBadge => 'تحقّق';

  @override
  String get verifyBackToCourses => 'ارجع إلى الكورسات';

  @override
  String get verifyInternetRequired => 'التحقق يتطلب اتصالاً بالإنترنت';

  @override
  String verifyCourseBy(String teacher, String student) {
    return 'كورس لـ $teacher · $student';
  }

  @override
  String get focusModeTitle => 'وضع التركيز';

  @override
  String get focusModeSubtitle => 'اقفل التطبيق لتبقى مركّزاً';

  @override
  String get focusStudyDuration => 'مدة المذاكرة';

  @override
  String get focusCustom => 'مخصص';

  @override
  String get focusMinutes => 'دقائق';

  @override
  String get focusEmergencyDuration => 'مدة الاستراحة الطارئة';

  @override
  String get focusStart => 'ابدأ التركيز';

  @override
  String get focusActiveTitle => 'وضع التركيز نشط';

  @override
  String focusActiveBody(String time) {
    return 'الوقت المتبقي: $time\n\nهل تريد إنهاء وضع التركيز؟';
  }

  @override
  String get focusKeepGoing => 'أكمل';

  @override
  String get focusStop => 'أوقف التركيز';

  @override
  String get focusEmergency => 'طوارئ';

  @override
  String focusEmergencyPrompt(String duration) {
    return 'تبدأ استراحة $duration؟';
  }

  @override
  String get focusBackToFocus => 'ارجع إلى التركيز';

  @override
  String get focusBlockNotifications => 'حظر الإشعارات';

  @override
  String get focusEnableDnd => 'تفعيل وضع عدم الإزعاج';

  @override
  String get focusCannotMinimize => 'لا يمكن تصغير النافذة أثناء وضع التركيز.';

  @override
  String get focusCannotClose =>
      'لا يمكن الإغلاق أثناء وضع التركيز. انتظر انتهاء المؤقت.';

  @override
  String get errFileCorrupted => 'الملف تالف أو غير مكتمل.';

  @override
  String get errFileCorruptedRetryImport =>
      'الملف تالف أو غير مكتمل. حاول استيراده مرة أخرى.';

  @override
  String get errFileCorruptedRedownload => 'الملف تالف — أعد تحميله.';

  @override
  String get errWrongCourse => 'هذا الملف يخص كورساً آخر.';

  @override
  String get errWrongCourseSwitch =>
      'هذا الملف يخص كورساً آخر. انتقل إلى الكورس الصحيح.';

  @override
  String get errDecryptionFailed => 'تعذّر فتح هذا الملف.';

  @override
  String get errOpenFailedSupport => 'تعذّر فتح هذا الملف. تواصل مع الدعم.';

  @override
  String get errOpenFailedRetry => 'تعذّر فتح هذا الملف. حاول مرة أخرى.';

  @override
  String get errWrongCourseContent => 'فشل فحص الأمان — محتوى كورس آخر';

  @override
  String get errVerificationFailed =>
      'فشل التحقّق من الملف. قد لا يكون تابعاً للكورس الخاص بك.';

  @override
  String get errInvalidCredentials => 'بيانات الدخول غير صحيحة';

  @override
  String get errCannotConnect =>
      'تعذّر الاتصال بالخادم. تأكد من اتصالك بالإنترنت.';

  @override
  String errConnectionFailed(String reason) {
    return 'فشل الاتصال: $reason';
  }

  @override
  String get errCannotConnectDialog =>
      'تعذّر الاتصال بالخادم.\\nتحقّق من اتصالك بالإنترنت.';

  @override
  String get errServerRetry => 'خطأ في الخادم. حاول مرة أخرى.';

  @override
  String errServerStatus(int status) {
    return 'خطأ في الخادم $status';
  }

  @override
  String get errNetwork => 'خطأ في الشبكة';

  @override
  String get errDownloadUrlFailed => 'تعذّر الحصول على رابط التحميل';

  @override
  String errDownloadHttp(int status) {
    return 'فشل التحميل: HTTP $status';
  }

  @override
  String get errDownloadNoData => 'لم ينتج عن التحميل أي بيانات';

  @override
  String errDownloadIncomplete(int got, int total) {
    return 'التحميل غير مكتمل ($got / $total بايت) — سيُستأنف';
  }

  @override
  String get errSessionExpiredLogin => 'انتهت الجلسة. سجّل الدخول مرة أخرى.';

  @override
  String get errPlatformLocked =>
      'هذا الحساب مقفل على منصة أخرى. تواصل مع معلّمك لتغيير المنصة.';

  @override
  String get errCourseAccessExpired =>
      'انتهت صلاحيتك في هذا الكورس.\nتواصل مع معلّمك.';

  @override
  String get errConnectToVerify => 'اتصل بالإنترنت للتحقق من حسابك.';

  @override
  String get errSessionExpired => 'انتهت جلستك.\nسجّل الدخول مرة أخرى.';

  @override
  String get errSessionInvalid => 'جلستك لم تعد صالحة.\nسجّل الدخول مرة أخرى.';

  @override
  String get errInternetRequiredTitle => 'الإنترنت مطلوب';

  @override
  String get errAccessDeniedTitle => 'الوصول مرفوض';

  @override
  String get srvCourseUnavailable => 'هذا الكورس غير متاح. تواصل مع معلّمك.';

  @override
  String get srvCourseExpired =>
      'انتهت مدة هذا الكورس. تواصل مع معلّمك للوصول.';

  @override
  String get srvCourseInactive => 'هذا الكورس غير نشط';

  @override
  String get srvCourseExpiredMidsession => 'انتهت مدة هذا الكورس';

  @override
  String get srvEnrollmentExpiredMidsession => 'انتهى اشتراكك';

  @override
  String get srvSeatsLapsed =>
      'الوصول موقوف. على معلّمك تجديد المقاعد لهذا الكورس.';

  @override
  String get srvStorageLapsed =>
      'انتهى اشتراك التخزين الخاص بمعلّمك. هذه الملفات غير متاحة حتى يُجدَّد.';

  @override
  String get srvStudentSuspended => 'تم إيقاف حسابك. تواصل مع معلّمك.';

  @override
  String get srvStudentNotFound => 'الطالب غير موجود';

  @override
  String get srvEnrollmentExpired => 'انتهى اشتراكك. تواصل مع معلّمك للتجديد.';

  @override
  String get srvEnrollmentSuspended => 'تم إيقاف اشتراكك';

  @override
  String get srvDeviceMismatch =>
      'هذا الحساب مرتبط بجهاز آخر بالفعل. تواصل مع معلّمك لإعادة التعيين.';

  @override
  String srvPlatformMismatch(String platform) {
    return 'هذا الحساب مسجَّل لـ $platform فقط.';
  }

  @override
  String get srvInvalidLogin => 'كود الكورس أو كلمة المرور غير صحيح.';

  @override
  String get srvMissingCredentials => 'كود الكورس وكلمة المرور مطلوبان.';

  @override
  String get srvRateLimited => 'محاولات كثيرة. حاول مرة أخرى لاحقاً.';

  @override
  String get srvRateLimitedCourse =>
      'محاولات كثيرة على هذا الكورس. حاول مرة أخرى لاحقاً.';

  @override
  String get srvSessionInvalid =>
      'انتهت صلاحية جلستك. من فضلك سجّل الدخول مرة أخرى.';

  @override
  String get srvAccessDenied => 'الوصول مرفوض';

  @override
  String get srvStorageUnconfigured => 'التخزين غير مهيأ. تواصل مع الإدارة.';

  @override
  String get srvNotFound => 'غير موجود.';

  @override
  String get srvServerError => 'خطأ داخلي في الخادم.';
}
