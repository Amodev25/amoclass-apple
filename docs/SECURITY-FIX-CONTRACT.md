# Security fix contract — 2026-09-13

Source: the release-readiness audit of 2026-09-13. Nothing is published yet and
every account, course and file is test data, so **no backward compatibility is
kept** with old sessions, old workers or old app builds. Anything signing- or
store-account-related (Android keystore, Apple team / notarization, Windows code
signing) is OUT of scope — it is done right before publishing.

Every component agent MUST follow this file exactly. If something here is wrong
or impossible, stop and report instead of improvising a different wire format.

---

## 1. Key delivery (fixes: student can derive every course key of a teacher)

- The content key is unchanged: `HMAC-SHA256(key = utf8(teacher.credential), msg = utf8(course.course_secret))`,
  32 bytes. Existing `.amo` files stay valid. The container format does not change.
- **The worker computes it** and sends it as `contentKey`: 64 lowercase hex chars.
- `credential` and `courseSecret` are **never** sent to a student again — not in
  `/auth/login`, not in `/auth/verify-session`, not anywhere.
- `/auth/encryptor-verify` is **deleted** (no caller exists).
- `teacherId` may still be sent (not a secret once `credential` is gone).

### Native decryptor API (all three copies of `amo_stream.c`, identical logic)

```c
/* Returns 1 if `hex` is exactly 64 hex digits and the key was stored, else 0 (key cleared). */
int  amo_set_content_key(const char *hex);
void amo_clear_content_key(void);
/* Windows DLL exports */
__declspec(dllexport) int  amo_set_content_key_ffi(const char *hex);
__declspec(dllexport) void amo_clear_content_key_ffi(void);
```

`amo_set_credentials*` / `amo_clear_credentials*` no longer exist. The key global
is guarded by a lock (SRWLOCK on Windows, pthread mutex elsewhere).

Platform glue:
- Android JNI: `AmoStreamBridge.nativeSetContentKey(hex: String): Boolean`, `nativeClearContentKey()`;
  MethodChannel methods `setContentKey` (arg `contentKey`) → bool, `clearContentKey`.
- Apple: `amo_apple_set_content_key(const char*) -> int`, `amo_apple_clear_content_key(void)`;
  MethodChannel `setContentKey` (arg `contentKey`, must be NSString) → bool, `clearContentKey`.
- Windows FFI: `AmoNativeBridge.setContentKey(String hex) -> Future<bool>`, `clearContentKey()`.
- Dart everywhere: `AmoNativeBridge.setContentKey(String) -> Future<bool>`, `clearContentKey()`.

Dart-side decryption (thumbnails, PDF, HMAC check) uses the 32 bytes decoded from
`contentKey` directly. No Dart code computes HMAC(credential, secret) any more.

## 2. Wire contract — student worker

Base URL unchanged. Every request from an app carries:

```
X-Lockclass-Build: <integer build number, the +N of pubspec version>
```

Worker var `MIN_APP_BUILD` (string integer, default `"0"`). If the header is
missing or lower → **HTTP 426** `{ success:false, error, code:"APP_UPDATE_REQUIRED" }`
on every route except `/health`.

### POST /auth/login

Request: `{ serverCode, password, deviceId, platform, name? }`
- `platform` ∈ `windows | android | ios | macos` — required.
- `deviceId` matches `^[A-Za-z0-9._:-]{8,128}$` — required.
- Either missing/invalid → 400 `DEVICE_REQUIRED`.
- `password` is trimmed server-side before every comparison (lookup AND hash).
- Course-level or student-level refusals (`COURSE_UNAVAILABLE`, `COURSE_EXPIRED`,
  `SEATS_LAPSED`, `STUDENT_SUSPENDED`, `ENROLLMENT_EXPIRED`, …) are only returned
  AFTER a password matched. Before that, the answer is always `INVALID_LOGIN`.

Success course object (fields that matter; others unchanged):
```json
{ "studentId": 1, "courseId": 1, "studentName": "…", "teacherId": 1, "teacherName": "…",
  "courseName": "…", "serverCode": "…", "requireHeadphones": false, "seatNo": 3,
  "contentKey": "<64 hex>", "accessEndsAt": "2026-12-31T00:00:00.000Z" | null,
  "sessionToken": "…" }
```
`accessEndsAt` = the earliest end of access the server knows (enrolment expiry,
course end); `null` when unbounded.

### POST /auth/verify-session (Bearer)

Request `{ deviceId, platform }`. Token without a non-empty `did`, or `did !== deviceId`
→ refused. Success: `{ valid:true, contentKey, accessEndsAt, courseName, serverCode, sessionToken }`.
Failure keeps `reason` and ADDS `code` (one of the existing codes).

### Storage & progress endpoints (Bearer)

`/storage/files`, `/storage/download-url`, `/storage/thumbnail`, `GET/POST /api/progress`
all run one shared entitlement check: enrolment exists, student not suspended,
enrolment not expired, course active and not expired, teacher not suspended,
seats not lapsed, and the row's `device_id` equals the token's `did`. A failure
returns the matching existing code with 403, except a device mismatch / reset
seat which returns **401 `SESSION_INVALID`** (app must re-login).

Hidden files (`files.hidden_from_students = 1`) never appear in the catalog and
are refused by download-url / thumbnail (404 `NOT_FOUND`).

### New error codes (errors.ts + apps' server_errors.dart)

| code | HTTP | English |
|---|---|---|
| `DEVICE_REQUIRED` | 400 | This app could not identify your device. Update the app and try again. |
| `APP_UPDATE_REQUIRED` | 426 | A newer version of Lockclass is required. Update the app to continue. |
| `INVALID_REQUEST` | 400 | The request could not be processed. Update the app and try again. |

Every error response is JSON with `code` and CORS headers — including crashes
(router must `await` handlers inside its try/catch).

## 3. App behaviour contract (Windows, Android, iOS, macOS)

1. Store `contentKey` + `accessEndsAt` per course instead of `credential` + `courseSecret`.
   A stored session missing `contentKey` is discarded (student signs in again).
2. Always send `deviceId` and `platform`. The literal `'unknown'` is forbidden: if
   the OS id is unavailable, generate a random UUID v4 once and persist it in the
   app's secure store.
3. Send `X-Lockclass-Build` on every worker request. The number lives in
   `lib/core/app_build.dart` (`const int kAppBuild`) and a unit test asserts it
   equals the `+N` in `pubspec.yaml`.
4. `APP_UPDATE_REQUIRED` anywhere → blocking dialog `srvAppUpdateRequired`.
5. HTTP 401 / `SESSION_INVALID` is **never** treated as "offline". The course is
   sent to the re-verify (password) screen. A successful re-verify saves the new
   `sessionToken`, `contentKey`, `accessEndsAt` to memory AND storage and calls
   `AmoNativeBridge.setContentKey`.
6. Offline policy (all must hold to play without the server). **Owner decision
   2026-09-13: the limit is 3 openings, not a number of days** — there is NO
   time-since-lastVerified rule:
   - the existing offline open counter (`maxOfflineOpens = 3`, reset only by a
     successful online verify) → when exhausted, `offlineTooLong` and the
     re-verify flow
   - `accessEndsAt == null || now < accessEndsAt` → else `srvEnrollmentExpired`
   - persisted `lastSeenAt` (max wall-clock ever observed); if `now < lastSeenAt − 10 min`
     → `clockChanged` until a successful online verify.
7. The pre-content check runs before opening ANY lesson (video or PDF).
8. Online downloads live in `AmoOnlineFiles/<courseId>/`, never one shared folder.
   Free-space check before every download.
9. PDFs are decrypted in memory only (no temp file), with text selection and
   hyperlink navigation disabled.
10. The Dart header parser checks `metadataLength`, `thumbnailLength`, video length
    against the real file size BEFORE allocating.
11. Passwords are trimmed before sending.
12. Progress sync keys never contain an absolute local path.

New core strings (already added in `amoclass_core`): `srvDeviceRequired`,
`srvAppUpdateRequired`, `srvInvalidRequest`, `offlineTooLong`, `clockChanged`.

## 4. Decisions still owed by the owner (do not implement yet)

- Email provider → email verification + password reset for teachers. **Postponed by owner.**
- Privacy policy / terms text, store links, API custom domain.

Decided 2026-09-13: Windows/Android repos pushed to private GitHub remotes;
iOS is **iPhone only** (TARGETED_DEVICE_FAMILY = 1); offline = 3 openings (§3.6).
