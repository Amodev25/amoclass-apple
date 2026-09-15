import 'dart:io';

import 'package:amo_player_apple/amo_core/amo_core.dart';
import 'package:flutter/material.dart';

import '../services/course_files_service.dart';

/// Refusals that mean access to a course has ended, as opposed to a wrong
/// password or a suspension the teacher can lift.
const Set<String> courseAccessEndedCodes = {
  'COURSE_EXPIRED',
  'ENROLLMENT_EXPIRED',
};

/// Offers to delete what this device holds for a course the student can no
/// longer open.
///
/// The sign-out dialog offers this once, when access ends. This is the same
/// offer where the student meets the refusal again — at login and at
/// re-verify — so a student who kept the files can still take the space back,
/// every time they try that course, until nothing is left.
class CourseFilesPrompt {
  /// Shows nothing when the device holds no files for [serverCodes].
  static Future<void> offer(
    BuildContext context, {
    required List<String> serverCodes,
    required String message,
  }) async {
    final found = <String, List<File>>{};
    var bytes = 0;
    try {
      for (final code in serverCodes) {
        final files = await CourseFilesService.filesFor(code);
        found[code] = files;
        bytes += await CourseFilesService.totalBytes(files);
      }
    } catch (_) {
      return;
    }
    if (bytes == 0 || !context.mounted) return;

    final sizeLabel = CourseFilesService.formatBytes(bytes);
    var deleting = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.border),
            ),
            icon: const Icon(Icons.block, color: AppColors.error, size: 48),
            title: Text(
              AmoL10n.of(ctx).errAccessDeniedTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                CourseFilesSizeBox(sizeLabel: sizeLabel),
              ],
            ),
            actions: [
              CourseFilesDeleteButton(
                sizeLabel: sizeLabel,
                deleting: deleting,
                onPressed: deleting
                    ? null
                    : () async {
                        setDialogState(() => deleting = true);
                        for (final entry in found.entries) {
                          await CourseFilesService.delete(
                            entry.key,
                            entry.value,
                          );
                        }
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      },
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: deleting ? null : () => Navigator.of(ctx).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    AmoL10n.of(ctx).courseFilesKeep,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How much space a course takes here, and what deleting it costs.
class CourseFilesSizeBox extends StatelessWidget {
  const CourseFilesSizeBox({super.key, required this.sizeLabel});

  final String sizeLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.sd_storage_outlined,
                size: 18,
                color: Colors.white.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  AmoL10n.of(context).courseFilesOnDeviceLabel,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              Text(
                sizeLabel,
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            AmoL10n.of(context).courseFilesOnDeviceBody,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// The destructive choice, with a spinner while the files go.
class CourseFilesDeleteButton extends StatelessWidget {
  const CourseFilesDeleteButton({
    super.key,
    required this.sizeLabel,
    required this.deleting,
    required this.onPressed,
  });

  final String sizeLabel;
  final bool deleting;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.error,
          side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: deleting
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.error,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(AmoL10n.of(context).courseFilesDeleting),
                ],
              )
            : Text(
                AmoL10n.of(context).courseFilesDelete(sizeLabel),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
      ),
    );
  }
}
