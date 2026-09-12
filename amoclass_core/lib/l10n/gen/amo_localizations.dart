import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'amo_localizations_ar.dart';
import 'amo_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AmoL10n
/// returned by `AmoL10n.of(context)`.
///
/// Applications need to include `AmoL10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/amo_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AmoL10n.localizationsDelegates,
///   supportedLocales: AmoL10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AmoL10n.supportedLocales
/// property.
abstract class AmoL10n {
  AmoL10n(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AmoL10n of(BuildContext context) {
    return Localizations.of<AmoL10n>(context, AmoL10n)!;
  }

  static const LocalizationsDelegate<AmoL10n> delegate = _AmoL10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en'),
  ];

  /// Window title and login header. The product name is not translated.
  ///
  /// In en, this message translates to:
  /// **'AMO Player'**
  String get appTitle;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get actionClose;

  /// No description provided for @actionRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get actionRetry;

  /// No description provided for @actionRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get actionRemove;

  /// No description provided for @actionUnderstood.
  ///
  /// In en, this message translates to:
  /// **'Understood'**
  String get actionUnderstood;

  /// No description provided for @actionOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get actionOk;

  /// No description provided for @actionYes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get actionYes;

  /// No description provided for @actionNo.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get actionNo;

  /// No description provided for @actionPleaseWait.
  ///
  /// In en, this message translates to:
  /// **'Please wait'**
  String get actionPleaseWait;

  /// No description provided for @actionLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading'**
  String get actionLoading;

  /// No description provided for @actionSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get actionSignIn;

  /// No description provided for @actionGoToLogin.
  ///
  /// In en, this message translates to:
  /// **'Go to Login'**
  String get actionGoToLogin;

  /// No description provided for @loginHeader.
  ///
  /// In en, this message translates to:
  /// **'STUDENT LOGIN'**
  String get loginHeader;

  /// No description provided for @loginSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your course code and password'**
  String get loginSubtitle;

  /// No description provided for @loginCourseCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'COURSE CODE'**
  String get loginCourseCodeLabel;

  /// No description provided for @loginCourseCodeLength.
  ///
  /// In en, this message translates to:
  /// **'Course code must be exactly 6 characters'**
  String get loginCourseCodeLength;

  /// No description provided for @loginCourseCodeCharset.
  ///
  /// In en, this message translates to:
  /// **'Course code must contain only letters and numbers'**
  String get loginCourseCodeCharset;

  /// No description provided for @loginNameLabel.
  ///
  /// In en, this message translates to:
  /// **'FULL NAME'**
  String get loginNameLabel;

  /// No description provided for @loginNameHint.
  ///
  /// In en, this message translates to:
  /// **'Your full name as your teacher registered it'**
  String get loginNameHint;

  /// No description provided for @loginNameNeeded.
  ///
  /// In en, this message translates to:
  /// **'We could not find you with that code and password alone. This happens on your first sign-in — enter your full name once, exactly as your teacher registered it.'**
  String get loginNameNeeded;

  /// No description provided for @loginNameRequiredNow.
  ///
  /// In en, this message translates to:
  /// **'Please enter your full name'**
  String get loginNameRequiredNow;

  /// No description provided for @loginPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'PASSWORD'**
  String get loginPasswordLabel;

  /// No description provided for @loginPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your password'**
  String get loginPasswordHint;

  /// No description provided for @loginPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter your password'**
  String get loginPasswordRequired;

  /// No description provided for @loginFooter.
  ///
  /// In en, this message translates to:
  /// **'Protected content · Encrypted playback'**
  String get loginFooter;

  /// No description provided for @coursesTitle.
  ///
  /// In en, this message translates to:
  /// **'My Courses'**
  String get coursesTitle;

  /// No description provided for @coursesWelcomeBack.
  ///
  /// In en, this message translates to:
  /// **'Welcome back, {name}'**
  String coursesWelcomeBack(String name);

  /// No description provided for @coursesSeatNo.
  ///
  /// In en, this message translates to:
  /// **'Seat no. {seat}'**
  String coursesSeatNo(int seat);

  /// No description provided for @coursesAddAnother.
  ///
  /// In en, this message translates to:
  /// **'Add Another Course'**
  String get coursesAddAnother;

  /// No description provided for @coursesCheckingSession.
  ///
  /// In en, this message translates to:
  /// **'Checking session...'**
  String get coursesCheckingSession;

  /// No description provided for @libraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get libraryTitle;

  /// No description provided for @libraryTabVideos.
  ///
  /// In en, this message translates to:
  /// **'Videos'**
  String get libraryTabVideos;

  /// No description provided for @libraryTabFiles.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get libraryTabFiles;

  /// No description provided for @libraryMyVideos.
  ///
  /// In en, this message translates to:
  /// **'My Videos'**
  String get libraryMyVideos;

  /// No description provided for @libraryMyFiles.
  ///
  /// In en, this message translates to:
  /// **'My Files'**
  String get libraryMyFiles;

  /// No description provided for @libraryNoVideos.
  ///
  /// In en, this message translates to:
  /// **'No videos yet'**
  String get libraryNoVideos;

  /// No description provided for @libraryNoFiles.
  ///
  /// In en, this message translates to:
  /// **'No files yet'**
  String get libraryNoFiles;

  /// No description provided for @libraryNoVideosHint.
  ///
  /// In en, this message translates to:
  /// **'Import your encrypted AMO videos to get started'**
  String get libraryNoVideosHint;

  /// No description provided for @libraryNoFilesHint.
  ///
  /// In en, this message translates to:
  /// **'Import your encrypted AMO PDFs to get started'**
  String get libraryNoFilesHint;

  /// No description provided for @libraryEmptyFolderHint.
  ///
  /// In en, this message translates to:
  /// **'Import encrypted AMO files to get started'**
  String get libraryEmptyFolderHint;

  /// No description provided for @libraryNoVideosInFolder.
  ///
  /// In en, this message translates to:
  /// **'No videos in this folder'**
  String get libraryNoVideosInFolder;

  /// No description provided for @libraryNoFilesInFolder.
  ///
  /// In en, this message translates to:
  /// **'No files in this folder'**
  String get libraryNoFilesInFolder;

  /// No description provided for @libraryLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading library...'**
  String get libraryLoading;

  /// No description provided for @libraryNoResults.
  ///
  /// In en, this message translates to:
  /// **'No results for \"{query}\"'**
  String libraryNoResults(String query);

  /// No description provided for @libraryImportFiles.
  ///
  /// In en, this message translates to:
  /// **'Import Files'**
  String get libraryImportFiles;

  /// No description provided for @libraryImportDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Import Encrypted File (Video or PDF)'**
  String get libraryImportDialogTitle;

  /// No description provided for @libraryImportingTitle.
  ///
  /// In en, this message translates to:
  /// **'Importing Files'**
  String get libraryImportingTitle;

  /// No description provided for @libraryImportFileProgress.
  ///
  /// In en, this message translates to:
  /// **'File {index} of {total}'**
  String libraryImportFileProgress(int index, int total);

  /// No description provided for @libraryImportNoneValid.
  ///
  /// In en, this message translates to:
  /// **'No valid AMO encrypted files found'**
  String get libraryImportNoneValid;

  /// No description provided for @libraryPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing...'**
  String get libraryPreparing;

  /// No description provided for @libraryAnotherCourse.
  ///
  /// In en, this message translates to:
  /// **'Another Course'**
  String get libraryAnotherCourse;

  /// No description provided for @libraryFocus.
  ///
  /// In en, this message translates to:
  /// **'Focus'**
  String get libraryFocus;

  /// No description provided for @libraryFocused.
  ///
  /// In en, this message translates to:
  /// **'Focused'**
  String get libraryFocused;

  /// No description provided for @libraryOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get libraryOffline;

  /// No description provided for @libraryOnline.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get libraryOnline;

  /// No description provided for @libraryWatched.
  ///
  /// In en, this message translates to:
  /// **'WATCHED'**
  String get libraryWatched;

  /// No description provided for @libraryFolderTag.
  ///
  /// In en, this message translates to:
  /// **'FOLDER'**
  String get libraryFolderTag;

  /// No description provided for @libraryItemCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No items} =1{1 item} other{{count} items}}'**
  String libraryItemCount(int count);

  /// No description provided for @libraryVideoCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No videos} =1{1 video} other{{count} videos}}'**
  String libraryVideoCount(int count);

  /// No description provided for @libraryFileCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No files} =1{1 file} other{{count} files}}'**
  String libraryFileCount(int count);

  /// No description provided for @libraryImportResult.
  ///
  /// In en, this message translates to:
  /// **'{imported, plural, =1{1 file imported successfully} other{{imported} files imported successfully}}'**
  String libraryImportResult(int imported);

  /// No description provided for @libraryImportResultWithFailures.
  ///
  /// In en, this message translates to:
  /// **'{imported, plural, =1{1 file imported} other{{imported} files imported}}, {failed, plural, =1{1 failed} other{{failed} failed}}'**
  String libraryImportResultWithFailures(int imported, int failed);

  /// No description provided for @libraryRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove File'**
  String get libraryRemoveTitle;

  /// No description provided for @libraryRemoveBody.
  ///
  /// In en, this message translates to:
  /// **'Remove \"{name}\" from library?\n(The file won\'t be deleted)'**
  String libraryRemoveBody(String name);

  /// No description provided for @libraryNotYourCourseTitle.
  ///
  /// In en, this message translates to:
  /// **'Not In Your Course'**
  String get libraryNotYourCourseTitle;

  /// No description provided for @libraryNotYourCourseBody.
  ///
  /// In en, this message translates to:
  /// **'This file was encrypted for a different course. It cannot be opened with your current server code.'**
  String get libraryNotYourCourseBody;

  /// No description provided for @libraryNotYourCourseContact.
  ///
  /// In en, this message translates to:
  /// **'Please contact your instructor if you believe this is an error.'**
  String get libraryNotYourCourseContact;

  /// No description provided for @libraryWrongServerCode.
  ///
  /// In en, this message translates to:
  /// **'This file belongs to a different server (code: {fileCode}). You are logged in with code: {myCode}.'**
  String libraryWrongServerCode(String fileCode, String myCode);

  /// No description provided for @cloudTitle.
  ///
  /// In en, this message translates to:
  /// **'Cloud'**
  String get cloudTitle;

  /// No description provided for @cloudRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get cloudRefresh;

  /// No description provided for @cloudEmptyFolder.
  ///
  /// In en, this message translates to:
  /// **'This folder is empty'**
  String get cloudEmptyFolder;

  /// No description provided for @cloudNotFetchedTitle.
  ///
  /// In en, this message translates to:
  /// **'Online Content'**
  String get cloudNotFetchedTitle;

  /// No description provided for @cloudNotFetchedBody.
  ///
  /// In en, this message translates to:
  /// **'Click Refresh to load your teacher\'s uploaded files'**
  String get cloudNotFetchedBody;

  /// No description provided for @cloudLoadContent.
  ///
  /// In en, this message translates to:
  /// **'Load Content'**
  String get cloudLoadContent;

  /// No description provided for @cloudDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get cloudDownload;

  /// No description provided for @cloudResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get cloudResume;

  /// No description provided for @cloudPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get cloudPlay;

  /// No description provided for @cloudDownloadedPercentPaused.
  ///
  /// In en, this message translates to:
  /// **'{percent}% downloaded — Paused'**
  String cloudDownloadedPercentPaused(int percent);

  /// No description provided for @cloudDownloadedPercentActive.
  ///
  /// In en, this message translates to:
  /// **'{percent}% downloaded — click pause icon to pause'**
  String cloudDownloadedPercentActive(int percent);

  /// No description provided for @cloudDownloadedToLibrary.
  ///
  /// In en, this message translates to:
  /// **'\"{name}\" downloaded to library'**
  String cloudDownloadedToLibrary(String name);

  /// No description provided for @cloudDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed: {reason}'**
  String cloudDownloadFailed(String reason);

  /// No description provided for @cloudLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load online content: {reason}'**
  String cloudLoadFailed(String reason);

  /// No description provided for @cloudFolderFileCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No files} =1{1 file} other{{count} files}}'**
  String cloudFolderFileCount(int count);

  /// No description provided for @playerHeadphonesRequiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Headphones required'**
  String get playerHeadphonesRequiredTitle;

  /// No description provided for @playerHeadphonesRequiredBody.
  ///
  /// In en, this message translates to:
  /// **'This course requires headphones to watch videos.\nConnect wired, Bluetooth, or USB headphones and try again.'**
  String get playerHeadphonesRequiredBody;

  /// No description provided for @playerHeadphonesDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Headphones disconnected'**
  String get playerHeadphonesDisconnected;

  /// No description provided for @playerHeadphonesReconnect.
  ///
  /// In en, this message translates to:
  /// **'This course requires headphones.\nReconnect them to continue watching.'**
  String get playerHeadphonesReconnect;

  /// No description provided for @playerWaitingForHeadphones.
  ///
  /// In en, this message translates to:
  /// **'Waiting for headphones…'**
  String get playerWaitingForHeadphones;

  /// No description provided for @playerLocked.
  ///
  /// In en, this message translates to:
  /// **'Locked · Long press to unlock'**
  String get playerLocked;

  /// No description provided for @playerLock.
  ///
  /// In en, this message translates to:
  /// **'Lock'**
  String get playerLock;

  /// No description provided for @playerScreenRecordingBlocked.
  ///
  /// In en, this message translates to:
  /// **'Screen Recording Blocked'**
  String get playerScreenRecordingBlocked;

  /// No description provided for @playerZoomOut.
  ///
  /// In en, this message translates to:
  /// **'Zoom Out (-)'**
  String get playerZoomOut;

  /// No description provided for @playerZoomIn.
  ///
  /// In en, this message translates to:
  /// **'Zoom In (+)'**
  String get playerZoomIn;

  /// No description provided for @playerZoomReset.
  ///
  /// In en, this message translates to:
  /// **'Reset Zoom (0)'**
  String get playerZoomReset;

  /// No description provided for @playerZoomLevel.
  ///
  /// In en, this message translates to:
  /// **'{level}x zoom'**
  String playerZoomLevel(String level);

  /// No description provided for @playerPlaybackSpeed.
  ///
  /// In en, this message translates to:
  /// **'Playback Speed'**
  String get playerPlaybackSpeed;

  /// No description provided for @playerSpeedNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get playerSpeedNormal;

  /// No description provided for @playerResumeFrom.
  ///
  /// In en, this message translates to:
  /// **'Resume from {time}?'**
  String playerResumeFrom(String time);

  /// No description provided for @playerResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get playerResume;

  /// No description provided for @playerStartOver.
  ///
  /// In en, this message translates to:
  /// **'Start Over'**
  String get playerStartOver;

  /// No description provided for @playerPlayNow.
  ///
  /// In en, this message translates to:
  /// **'Play Now'**
  String get playerPlayNow;

  /// No description provided for @playerAutoPlayCountdown.
  ///
  /// In en, this message translates to:
  /// **'Playing next in {seconds}...'**
  String playerAutoPlayCountdown(int seconds);

  /// No description provided for @pdfTitle.
  ///
  /// In en, this message translates to:
  /// **'Premium Document Viewer'**
  String get pdfTitle;

  /// No description provided for @pdfUnlocking.
  ///
  /// In en, this message translates to:
  /// **'Unlocking Document...'**
  String get pdfUnlocking;

  /// No description provided for @pdfLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to load PDF. Please try again.'**
  String get pdfLoadFailed;

  /// No description provided for @verifyTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify Subscription'**
  String get verifyTitle;

  /// No description provided for @verifySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Select a course to verify your access'**
  String get verifySubtitle;

  /// No description provided for @verifyAccess.
  ///
  /// In en, this message translates to:
  /// **'Verify Access'**
  String get verifyAccess;

  /// No description provided for @verifyAction.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get verifyAction;

  /// No description provided for @verifyBadge.
  ///
  /// In en, this message translates to:
  /// **'VERIFY'**
  String get verifyBadge;

  /// No description provided for @verifyBackToCourses.
  ///
  /// In en, this message translates to:
  /// **'Back to courses'**
  String get verifyBackToCourses;

  /// No description provided for @verifyInternetRequired.
  ///
  /// In en, this message translates to:
  /// **'Internet verification required'**
  String get verifyInternetRequired;

  /// No description provided for @verifyCourseBy.
  ///
  /// In en, this message translates to:
  /// **'Course by {teacher} · {student}'**
  String verifyCourseBy(String teacher, String student);

  /// No description provided for @focusModeTitle.
  ///
  /// In en, this message translates to:
  /// **'Focus Mode'**
  String get focusModeTitle;

  /// No description provided for @focusModeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Lock the app to stay focused'**
  String get focusModeSubtitle;

  /// No description provided for @focusStudyDuration.
  ///
  /// In en, this message translates to:
  /// **'Study Duration'**
  String get focusStudyDuration;

  /// No description provided for @focusCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get focusCustom;

  /// No description provided for @focusMinutes.
  ///
  /// In en, this message translates to:
  /// **'Minutes'**
  String get focusMinutes;

  /// No description provided for @focusEmergencyDuration.
  ///
  /// In en, this message translates to:
  /// **'Emergency Break Duration'**
  String get focusEmergencyDuration;

  /// No description provided for @focusStart.
  ///
  /// In en, this message translates to:
  /// **'Start Focus'**
  String get focusStart;

  /// No description provided for @focusActiveTitle.
  ///
  /// In en, this message translates to:
  /// **'Focus Mode Active'**
  String get focusActiveTitle;

  /// No description provided for @focusActiveBody.
  ///
  /// In en, this message translates to:
  /// **'Time remaining: {time}\n\nDo you want to end focus mode?'**
  String focusActiveBody(String time);

  /// No description provided for @focusKeepGoing.
  ///
  /// In en, this message translates to:
  /// **'Keep Going'**
  String get focusKeepGoing;

  /// No description provided for @focusStop.
  ///
  /// In en, this message translates to:
  /// **'Stop Focus'**
  String get focusStop;

  /// No description provided for @focusEmergency.
  ///
  /// In en, this message translates to:
  /// **'Emergency'**
  String get focusEmergency;

  /// No description provided for @focusEmergencyPrompt.
  ///
  /// In en, this message translates to:
  /// **'Start {duration} break?'**
  String focusEmergencyPrompt(String duration);

  /// No description provided for @focusBackToFocus.
  ///
  /// In en, this message translates to:
  /// **'Back to Focus'**
  String get focusBackToFocus;

  /// No description provided for @focusBlockNotifications.
  ///
  /// In en, this message translates to:
  /// **'Block Notifications'**
  String get focusBlockNotifications;

  /// No description provided for @focusEnableDnd.
  ///
  /// In en, this message translates to:
  /// **'Enable Do Not Disturb mode'**
  String get focusEnableDnd;

  /// No description provided for @focusCannotMinimize.
  ///
  /// In en, this message translates to:
  /// **'Cannot minimize while Focus Mode is active.'**
  String get focusCannotMinimize;

  /// No description provided for @focusCannotClose.
  ///
  /// In en, this message translates to:
  /// **'Cannot close while Focus Mode is active. Wait for timer to end.'**
  String get focusCannotClose;

  /// No description provided for @errFileCorrupted.
  ///
  /// In en, this message translates to:
  /// **'File is damaged or incomplete.'**
  String get errFileCorrupted;

  /// No description provided for @errFileCorruptedRetryImport.
  ///
  /// In en, this message translates to:
  /// **'This file is damaged or incomplete. Try importing it again.'**
  String get errFileCorruptedRetryImport;

  /// No description provided for @errFileCorruptedRedownload.
  ///
  /// In en, this message translates to:
  /// **'File is damaged — please re-download.'**
  String get errFileCorruptedRedownload;

  /// No description provided for @errWrongCourse.
  ///
  /// In en, this message translates to:
  /// **'This file belongs to a different course.'**
  String get errWrongCourse;

  /// No description provided for @errWrongCourseSwitch.
  ///
  /// In en, this message translates to:
  /// **'This file belongs to a different course. Please switch to the correct course.'**
  String get errWrongCourseSwitch;

  /// No description provided for @errDecryptionFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to decrypt this file.'**
  String get errDecryptionFailed;

  /// No description provided for @errOpenFailedSupport.
  ///
  /// In en, this message translates to:
  /// **'Unable to open this file. Please contact support.'**
  String get errOpenFailedSupport;

  /// No description provided for @errOpenFailedRetry.
  ///
  /// In en, this message translates to:
  /// **'Unable to open this file. Please try again.'**
  String get errOpenFailedRetry;

  /// No description provided for @errWrongCourseContent.
  ///
  /// In en, this message translates to:
  /// **'File security check failed — wrong course content'**
  String get errWrongCourseContent;

  /// No description provided for @errVerificationFailed.
  ///
  /// In en, this message translates to:
  /// **'File verification failed. It may not belong to your course.'**
  String get errVerificationFailed;

  /// No description provided for @errInvalidCredentials.
  ///
  /// In en, this message translates to:
  /// **'Invalid credentials'**
  String get errInvalidCredentials;

  /// No description provided for @errCannotConnect.
  ///
  /// In en, this message translates to:
  /// **'Cannot connect to server. Please check your internet connection.'**
  String get errCannotConnect;

  /// No description provided for @errConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed: {reason}'**
  String errConnectionFailed(String reason);

  /// No description provided for @errCannotConnectDialog.
  ///
  /// In en, this message translates to:
  /// **'Cannot connect to server.\\nPlease check your internet connection.'**
  String get errCannotConnectDialog;

  /// No description provided for @errServerRetry.
  ///
  /// In en, this message translates to:
  /// **'Server error. Please try again.'**
  String get errServerRetry;

  /// No description provided for @errServerStatus.
  ///
  /// In en, this message translates to:
  /// **'Server error {status}'**
  String errServerStatus(int status);

  /// No description provided for @errNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network error'**
  String get errNetwork;

  /// No description provided for @errDownloadUrlFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to get download URL'**
  String get errDownloadUrlFailed;

  /// No description provided for @errDownloadHttp.
  ///
  /// In en, this message translates to:
  /// **'Failed to download: HTTP {status}'**
  String errDownloadHttp(int status);

  /// No description provided for @errDownloadNoData.
  ///
  /// In en, this message translates to:
  /// **'Download produced no data'**
  String get errDownloadNoData;

  /// No description provided for @errDownloadIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Download incomplete ({got} / {total} bytes) — will resume'**
  String errDownloadIncomplete(int got, int total);

  /// No description provided for @errSessionExpiredLogin.
  ///
  /// In en, this message translates to:
  /// **'Session expired. Please log in again.'**
  String get errSessionExpiredLogin;

  /// No description provided for @errPlatformLocked.
  ///
  /// In en, this message translates to:
  /// **'This account is locked to another platform. Contact your teacher to switch platforms.'**
  String get errPlatformLocked;

  /// No description provided for @errCourseAccessExpired.
  ///
  /// In en, this message translates to:
  /// **'Your course access has expired.\nPlease contact your teacher.'**
  String get errCourseAccessExpired;

  /// No description provided for @errConnectToVerify.
  ///
  /// In en, this message translates to:
  /// **'Please connect to the internet to verify your account.'**
  String get errConnectToVerify;

  /// No description provided for @errSessionExpired.
  ///
  /// In en, this message translates to:
  /// **'Your session has expired.\nPlease log in again.'**
  String get errSessionExpired;

  /// No description provided for @errSessionInvalid.
  ///
  /// In en, this message translates to:
  /// **'Your session is no longer valid.\nPlease log in again.'**
  String get errSessionInvalid;

  /// No description provided for @errInternetRequiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Internet Required'**
  String get errInternetRequiredTitle;

  /// No description provided for @errAccessDeniedTitle.
  ///
  /// In en, this message translates to:
  /// **'Access Denied'**
  String get errAccessDeniedTitle;

  /// Server code COURSE_UNAVAILABLE. The srv* keys mirror amo-student-worker/src/errors.ts one-for-one; the key suffix is the code in lowerCamelCase.
  ///
  /// In en, this message translates to:
  /// **'This course is unavailable. Contact your teacher.'**
  String get srvCourseUnavailable;

  /// No description provided for @srvCourseExpired.
  ///
  /// In en, this message translates to:
  /// **'This course has expired. Contact your teacher for access.'**
  String get srvCourseExpired;

  /// No description provided for @srvCourseInactive.
  ///
  /// In en, this message translates to:
  /// **'This course is not active'**
  String get srvCourseInactive;

  /// No description provided for @srvCourseExpiredMidsession.
  ///
  /// In en, this message translates to:
  /// **'This course has expired'**
  String get srvCourseExpiredMidsession;

  /// No description provided for @srvEnrollmentExpiredMidsession.
  ///
  /// In en, this message translates to:
  /// **'Your enrollment has expired'**
  String get srvEnrollmentExpiredMidsession;

  /// No description provided for @srvSeatsLapsed.
  ///
  /// In en, this message translates to:
  /// **'Access suspended. Your teacher must renew seats for this course.'**
  String get srvSeatsLapsed;

  /// No description provided for @srvStorageLapsed.
  ///
  /// In en, this message translates to:
  /// **'Your teacher\'s storage subscription has lapsed. These files are unavailable until it is renewed.'**
  String get srvStorageLapsed;

  /// No description provided for @srvStudentSuspended.
  ///
  /// In en, this message translates to:
  /// **'Your account has been suspended. Contact your teacher.'**
  String get srvStudentSuspended;

  /// No description provided for @srvStudentNotFound.
  ///
  /// In en, this message translates to:
  /// **'Student not found'**
  String get srvStudentNotFound;

  /// No description provided for @srvEnrollmentExpired.
  ///
  /// In en, this message translates to:
  /// **'Your enrollment has expired. Contact your teacher to renew.'**
  String get srvEnrollmentExpired;

  /// No description provided for @srvEnrollmentSuspended.
  ///
  /// In en, this message translates to:
  /// **'Your enrollment has been suspended'**
  String get srvEnrollmentSuspended;

  /// No description provided for @srvDeviceMismatch.
  ///
  /// In en, this message translates to:
  /// **'This account is already linked to another device. Contact your teacher to reset.'**
  String get srvDeviceMismatch;

  /// No description provided for @srvPlatformMismatch.
  ///
  /// In en, this message translates to:
  /// **'This account is registered for {platform} only.'**
  String srvPlatformMismatch(String platform);

  /// No description provided for @srvInvalidLogin.
  ///
  /// In en, this message translates to:
  /// **'Wrong course code or password.'**
  String get srvInvalidLogin;

  /// No description provided for @srvMissingCredentials.
  ///
  /// In en, this message translates to:
  /// **'Server code and password are required.'**
  String get srvMissingCredentials;

  /// No description provided for @srvRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Try again later.'**
  String get srvRateLimited;

  /// No description provided for @srvRateLimitedCourse.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts for this course. Try again later.'**
  String get srvRateLimitedCourse;

  /// No description provided for @srvSessionInvalid.
  ///
  /// In en, this message translates to:
  /// **'Your session has expired. Please sign in again.'**
  String get srvSessionInvalid;

  /// No description provided for @srvAccessDenied.
  ///
  /// In en, this message translates to:
  /// **'Access denied'**
  String get srvAccessDenied;

  /// No description provided for @srvStorageUnconfigured.
  ///
  /// In en, this message translates to:
  /// **'Storage not configured. Contact administrator.'**
  String get srvStorageUnconfigured;

  /// No description provided for @srvNotFound.
  ///
  /// In en, this message translates to:
  /// **'Not found.'**
  String get srvNotFound;

  /// No description provided for @srvServerError.
  ///
  /// In en, this message translates to:
  /// **'Internal server error.'**
  String get srvServerError;
}

class _AmoL10nDelegate extends LocalizationsDelegate<AmoL10n> {
  const _AmoL10nDelegate();

  @override
  Future<AmoL10n> load(Locale locale) {
    return SynchronousFuture<AmoL10n>(lookupAmoL10n(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AmoL10nDelegate old) => false;
}

AmoL10n lookupAmoL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AmoL10nAr();
    case 'en':
      return AmoL10nEn();
  }

  throw FlutterError(
    'AmoL10n.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
