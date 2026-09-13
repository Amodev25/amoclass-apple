/// The build number this app reports to the student worker.
///
/// It MUST equal the `+N` of `version:` in pubspec.yaml;
/// `test/app_build_test.dart` fails when the two drift. The worker compares it
/// with its `MIN_APP_BUILD` and answers an older (or missing) build with
/// HTTP 426 `APP_UPDATE_REQUIRED` on every route except `/health`.
const int kAppBuild = 2;

/// Header carrying [kAppBuild] on every request to the student worker.
const String kAppBuildHeader = 'X-Lockclass-Build';

/// Ready to spread into a request's headers.
const Map<String, String> kAppBuildHeaders = {kAppBuildHeader: '$kAppBuild'};
