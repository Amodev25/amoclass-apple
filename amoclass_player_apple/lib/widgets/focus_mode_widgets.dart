import 'package:flutter/material.dart';
import '../services/focus_mode_service.dart';
import '../core/focus_mode_platform.dart';
import 'package:amo_core/amo_core.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Helper
// ═══════════════════════════════════════════════════════════════════════════════

String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

// ═══════════════════════════════════════════════════════════════════════════════
// Focus Mode Overlay — floating bar shown globally during focus mode
// ═══════════════════════════════════════════════════════════════════════════════

class FocusModeOverlay extends StatefulWidget {
  const FocusModeOverlay({super.key});

  @override
  State<FocusModeOverlay> createState() => _FocusModeOverlayState();
}

class _FocusModeOverlayState extends State<FocusModeOverlay> {
  bool _confirming = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FocusModeService.instance,
      builder: (context, _) {
        final svc = FocusModeService.instance;
        if (!svc.isActive) {
          _confirming = false;
          return const SizedBox.shrink();
        }
        if (svc.isEmergencyActive && _confirming) _confirming = false;

        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom + 16,
            left: 16,
            right: 16,
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _confirming
                ? _buildConfirmBar(svc)
                : svc.isEmergencyActive
                ? _buildEmergencyBar(svc)
                : _buildFocusBar(svc),
          ),
        );
      },
    );
  }

  // ── Normal focus bar ───────────────────────────────────────────────────────

  Widget _buildFocusBar(FocusModeService svc) {
    return Container(
      key: const ValueKey('focus'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.iconChipBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.center_focus_strong, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(
            _fmt(svc.remainingFocusTime),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          if (svc.isDndEnabled) ...[
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notifications_off, color: Colors.white, size: 12),
                  SizedBox(width: 3),
                  Text(
                    'DND',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => setState(() => _confirming = true),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.focusGradientStart.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                  SizedBox(width: 4),
                  Text(
                    AmoL10n.of(context).focusEmergency,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Emergency confirmation bar ─────────────────────────────────────────────

  Widget _buildConfirmBar(FocusModeService svc) {
    return Container(
      key: const ValueKey('confirm'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.focusGradientStart, AppColors.focusGradientEnd],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.focusGradientStart.withValues(alpha: 0.4),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.white,
            size: 18,
          ),
          const SizedBox(width: 8),
          Text(
            AmoL10n.of(
              context,
            ).focusEmergencyPrompt(_fmt(svc.emergencyDuration)),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          _barButton(AmoL10n.of(context).actionYes, () {
            setState(() => _confirming = false);
            svc.startEmergency();
          }, bold: true),
          const SizedBox(width: 6),
          _barButton(
            AmoL10n.of(context).actionNo,
            () => setState(() => _confirming = false),
          ),
        ],
      ),
    );
  }

  // ── Emergency active bar ───────────────────────────────────────────────────

  Widget _buildEmergencyBar(FocusModeService svc) {
    return Container(
      key: const ValueKey('emergency'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.focusGradientStart, AppColors.focusGradientEnd],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.focusGradientStart.withValues(alpha: 0.4),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.white,
            size: 18,
          ),
          const SizedBox(width: 8),
          Text(
            AmoL10n.of(context).focusEmergency,
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _fmt(svc.remainingEmergencyTime),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => svc.endEmergency(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.replay, color: Colors.white, size: 14),
                  SizedBox(width: 4),
                  Text(
                    AmoL10n.of(context).focusBackToFocus,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _barButton(String label, VoidCallback onTap, {bool bold = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: bold ? 0.25 : 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Show Focus Mode Dialog — activation or stop
// ═══════════════════════════════════════════════════════════════════════════════

Future<void> showFocusModeDialog(BuildContext context) async {
  if (FocusModeService.instance.isActive) {
    final stop = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border),
        ),
        title: Row(
          children: [
            Icon(Icons.center_focus_strong, color: Colors.white, size: 22),
            SizedBox(width: 8),
            Text(
              AmoL10n.of(context).focusActiveTitle,
              style: TextStyle(color: Colors.white, fontSize: 17),
            ),
          ],
        ),
        content: Text(
          AmoL10n.of(
            context,
          ).focusActiveBody(_fmt(FocusModeService.instance.remainingFocusTime)),
          style: const TextStyle(color: AppColors.mutedGray, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AmoL10n.of(context).focusKeepGoing),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: Text(AmoL10n.of(context).focusStop),
          ),
        ],
      ),
    );
    if (stop == true) await FocusModeService.instance.stopFocusMode();
    return;
  }

  await showDialog(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => const _FocusModeSetupDialog(),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Focus Mode Setup Dialog
// ═══════════════════════════════════════════════════════════════════════════════

class _FocusModeSetupDialog extends StatefulWidget {
  const _FocusModeSetupDialog();
  @override
  State<_FocusModeSetupDialog> createState() => _FocusModeSetupDialogState();
}

class _FocusModeSetupDialogState extends State<_FocusModeSetupDialog> {
  int _focusIdx = 1; // default 30 min
  int _emergencyIdx = 1; // default 5 min
  bool _enableDnd = false;
  bool _showCustom = false;
  final _customCtrl = TextEditingController();

  static const _focusOpts = [
    (label: '15m', duration: Duration(minutes: 15)),
    (label: '30m', duration: Duration(minutes: 30)),
    (label: '45m', duration: Duration(minutes: 45)),
    (label: '1h', duration: Duration(hours: 1)),
    (label: '1.5h', duration: Duration(minutes: 90)),
    (label: '2h', duration: Duration(hours: 2)),
    (label: '3h', duration: Duration(hours: 3)),
  ];

  static const _emergencyOpts = [
    (label: '2m', duration: Duration(minutes: 2)),
    (label: '5m', duration: Duration(minutes: 5)),
    (label: '10m', duration: Duration(minutes: 10)),
    (label: '15m', duration: Duration(minutes: 15)),
  ];

  Duration get _focusDuration {
    if (_showCustom) {
      final mins = int.tryParse(_customCtrl.text) ?? 30;
      return Duration(minutes: mins.clamp(1, 480));
    }
    return _focusOpts[_focusIdx].duration;
  }

  Duration get _emergencyDuration => _emergencyOpts[_emergencyIdx].duration;

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ─────────────────────────────────────────────────
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.center_focus_strong,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AmoL10n.of(context).focusModeTitle,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        AmoL10n.of(context).focusModeSubtitle,
                        style: TextStyle(
                          color: AppColors.mutedGray,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // ── Study duration ─────────────────────────────────────────
              Text(
                AmoL10n.of(context).focusStudyDuration,
                style: TextStyle(
                  color: AppColors.mutedGray,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (int i = 0; i < _focusOpts.length; i++)
                    _chip(
                      _focusOpts[i].label,
                      isSelected: !_showCustom && _focusIdx == i,
                      onTap: () => setState(() {
                        _focusIdx = i;
                        _showCustom = false;
                      }),
                    ),
                  _chip(
                    AmoL10n.of(context).focusCustom,
                    isSelected: _showCustom,
                    onTap: () => setState(() => _showCustom = !_showCustom),
                    icon: Icons.edit,
                  ),
                ],
              ),
              if (_showCustom) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _customCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: AmoL10n.of(context).focusMinutes,
                      hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
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
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),

              // ── Emergency duration ─────────────────────────────────────
              Text(
                AmoL10n.of(context).focusEmergencyDuration,
                style: TextStyle(
                  color: AppColors.mutedGray,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (int i = 0; i < _emergencyOpts.length; i++)
                    _chip(
                      _emergencyOpts[i].label,
                      isSelected: _emergencyIdx == i,
                      onTap: () => setState(() => _emergencyIdx = i),
                    ),
                ],
              ),

              // ── DND toggle (platform-conditional) ──────────────────────
              if (FocusModePlatform.supportsDnd) ...[
                const SizedBox(height: 20),
                _buildDndToggle(),
              ],

              const SizedBox(height: 24),

              // ── Buttons ────────────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      AmoL10n.of(context).actionCancel,
                      style: TextStyle(color: AppColors.mutedGray),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _startFocus,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_arrow, size: 18),
                        SizedBox(width: 6),
                        Text(
                          AmoL10n.of(context).focusStart,
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Chip button ────────────────────────────────────────────────────────────

  Widget _chip(
    String label, {
    required bool isSelected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : AppColors.pillUnselectedBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? Colors.white : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 13,
                color: isSelected ? Colors.black : AppColors.mutedGray,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.black : AppColors.mutedGray,
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── DND toggle ─────────────────────────────────────────────────────────────

  Widget _buildDndToggle() {
    return GestureDetector(
      onTap: _toggleDnd,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _enableDnd
              ? Colors.white.withValues(alpha: 0.08)
              : AppColors.surfaceDark,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _enableDnd ? Colors.white : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            Icon(
              _enableDnd ? Icons.notifications_off : Icons.notifications_active,
              color: _enableDnd ? Colors.white : AppColors.mutedGray,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AmoL10n.of(context).focusBlockNotifications,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    AmoL10n.of(context).focusEnableDnd,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: _enableDnd,
              onChanged: (_) => _toggleDnd(),
              activeTrackColor: Colors.white,
              activeColor: Colors.black,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleDnd() async {
    if (!_enableDnd) {
      final hasPerm = await FocusModePlatform.hasDndPermission();
      if (!hasPerm) {
        await FocusModePlatform.requestDndPermission();
        await Future.delayed(const Duration(milliseconds: 500));
        final granted = await FocusModePlatform.hasDndPermission();
        if (!granted) return;
      }
    }
    setState(() => _enableDnd = !_enableDnd);
  }

  void _startFocus() {
    Navigator.pop(context);
    FocusModeService.instance.startFocusMode(
      duration: _focusDuration,
      emergencyDuration: _emergencyDuration,
      enableDnd: _enableDnd,
    );
  }
}
