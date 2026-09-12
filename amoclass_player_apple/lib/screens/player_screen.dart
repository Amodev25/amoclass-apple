import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:amo_core/amo_core.dart';
import '../core/amo_native_bridge.dart';
import '../core/audio_output_platform.dart';
import '../services/auth_service.dart';
import '../services/progress_service.dart';

class PlayerScreen extends StatefulWidget {
  final String videoPath;
  final String videoName;
  final String? originalFilePath;
  final List<String>? playlistNames;
  final List<String>? playlistPaths;
  final int currentIndex;
  final double initialSpeed;

  const PlayerScreen({
    super.key,
    required this.videoPath,
    required this.videoName,
    this.originalFilePath,
    this.playlistNames,
    this.playlistPaths,
    this.currentIndex = 0,
    this.initialSpeed = 1.0,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with TickerProviderStateMixin {
  late final Player _player;
  late final VideoController _videoController;

  // Controls state
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _playbackSpeed = 1.0;
  double _volume = 100.0;
  bool _isMuted = false;

  // Lock mode
  bool _isLocked = false;

  // Resume & progress tracking
  bool _showResumeOverlay = false;
  int _resumePositionMs = 0;
  Timer? _saveTimer;

  // Auto-play next
  bool _showAutoPlayOverlay = false;
  int _autoPlayCountdown = 5;
  Timer? _autoPlayTimer;

  // Headphone gate (courses with requireHeadphones): poll the audio output and
  // pause playback if headphones are unplugged mid-video.
  Timer? _headphoneTimer;
  bool _headphonesMissing = false;
  // Remember whether playback was active when headphones were unplugged, so we
  // only auto-resume on reconnect if the user hadn't already paused themselves.
  bool _wasPlayingBeforeUnplug = false;

  // Speed options
  final List<double> _speedOptions = [
    0.5,
    0.75,
    1.0,
    1.1,
    1.2,
    1.3,
    1.4,
    1.5,
    1.75,
    2.0,
    2.5,
    3.0,
  ];

  // Animation
  late AnimationController _controlsFadeController;
  late Animation<double> _controlsFadeAnimation;

  // Double-tap skip zones
  int _leftTapCount = 0;
  int _rightTapCount = 0;
  Timer? _leftTapTimer;
  Timer? _rightTapTimer;
  bool _showLeftSkipFx = false;
  bool _showRightSkipFx = false;
  int _leftSkipSeconds = 0;
  int _rightSkipSeconds = 0;

  // Stream subscriptions
  final List<StreamSubscription> _subscriptions = [];

  @override
  void initState() {
    super.initState();

    _playbackSpeed = widget.initialSpeed;

    // AntiCapture already enabled globally in main() — no redundant call here.

    // Landscape mode for video playback
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // Full-screen immersive mode
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _controlsFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 1.0,
    );
    _controlsFadeAnimation = CurvedAnimation(
      parent: _controlsFadeController,
      curve: Curves.easeInOut,
    );

    _initPlayer();
    _startHideTimer();
    _startHeadphoneMonitor();
  }

  // ── Headphone gate ──────────────────────────────────────────────────────────

  void _startHeadphoneMonitor() {
    if (!AuthService.activeRequireHeadphones) return;
    _headphoneTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _checkHeadphones(),
    );
  }

  Future<void> _checkHeadphones() async {
    final connected = await AudioOutputPlatform.headphonesConnected();
    if (!mounted) return;
    if (!connected && !_headphonesMissing) {
      _wasPlayingBeforeUnplug = _isPlaying;
      await _player.pause();
      if (mounted) setState(() => _headphonesMissing = true);
    } else if (connected && _headphonesMissing) {
      if (mounted) setState(() => _headphonesMissing = false);
      // Only resume if the video was actually playing when headphones dropped.
      if (_wasPlayingBeforeUnplug) await _player.play();
    }
  }

  // Throttle position UI updates to ~4Hz to reduce widget rebuilds
  // during playback. mpv fires at 10-30Hz which causes unnecessary CPU load.
  DateTime _lastPositionUpdate = DateTime(0);

  void _initPlayer() {
    _player = Player(
      configuration: const PlayerConfiguration(bufferSize: 8 * 1024 * 1024),
    );
    _videoController = VideoController(_player);

    _subscriptions.add(
      _player.stream.playing.listen((playing) {
        if (mounted) setState(() => _isPlaying = playing);
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((pos) {
        if (!mounted) return;
        _position = pos;
        // Only rebuild UI at ~4Hz when controls are visible,
        // or silently store position when hidden
        final now = DateTime.now();
        if (_controlsVisible &&
            now.difference(_lastPositionUpdate).inMilliseconds > 250) {
          _lastPositionUpdate = now;
          setState(() {});
        }
      }),
    );
    _subscriptions.add(
      _player.stream.duration.listen((dur) {
        if (mounted) setState(() => _duration = dur);
      }),
    );
    _subscriptions.add(
      _player.stream.volume.listen((vol) {
        if (mounted) setState(() => _volume = vol);
      }),
    );

    // Listen for video completion
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed && mounted) {
          _onVideoCompleted();
        }
      }),
    );

    // Configure mpv cache and open media
    _startPlayback();

    // Save position every 5 seconds
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveCurrentPosition();
    });
  }

  Future<void> _startPlayback() async {
    // Register amo:// protocol BEFORE opening media — must complete first
    await AmoNativeBridge.registerProtocol(_player);

    final platform = _player.platform;
    if (platform is NativePlayer) {
      // Allow custom protocol URLs loaded via playlist files
      // (media_kit uses loadlist internally, which blocks non-standard protocols)
      await platform.setProperty('load-unsafe-playlists', 'yes');

      // ── Fast start ────────────────────────────────────────────────
      await platform.setProperty('demuxer-lavf-probesize', '512000');
      await platform.setProperty('demuxer-lavf-analyzeduration', '1');

      // ── Seek: keyframe-level (fast, like VLC) ─────────────────────
      // Default hr-seek=absolute decodes forward from keyframe to exact
      // position — can silently decode 3-10s of video per seek.
      // Keyframe-level seeking shows nearest keyframe instantly.
      await platform.setProperty('hr-seek', 'no');

      // ── Cache: disabled — mmap provides kernel page cache ─────────
      // mpv's internal cache adds flush/refill overhead on every seek.
      // With mmap, reads are already from RAM. No double-caching needed.
      await platform.setProperty('cache', 'no');
      await platform.setProperty('cache-pause-initial', 'no');
      await platform.setProperty('cache-pause', 'no');

      // ── Demuxer: minimal read-ahead for instant seeks ─────────────
      await platform.setProperty('demuxer-readahead-secs', '5');
      await platform.setProperty('demuxer-seekable-cache', 'yes');
      await platform.setProperty('demuxer-max-back-bytes', '52428800');
    }

    await _player.open(Media(widget.videoPath));
    if (!mounted) return;
    if (widget.initialSpeed != 1.0) {
      await _player.setRate(widget.initialSpeed);
    }
    _checkResume();
  }

  String get _progressKey => widget.originalFilePath ?? widget.videoPath;

  void _checkResume() {
    if (!mounted) return;
    final pos = ProgressService.getResumePosition(_progressKey);
    if (pos > 0) {
      setState(() {
        _showResumeOverlay = true;
        _resumePositionMs = pos;
      });
    }
  }

  void _resumeFromSaved() {
    _player.seek(Duration(milliseconds: _resumePositionMs));
    setState(() => _showResumeOverlay = false);
  }

  void _dismissResume() {
    setState(() => _showResumeOverlay = false);
  }

  void _saveCurrentPosition() {
    if (_duration.inMilliseconds <= 0) return;
    ProgressService.savePosition(
      _progressKey,
      positionMs: _position.inMilliseconds,
      durationMs: _duration.inMilliseconds,
    );
  }

  void _onVideoCompleted() {
    ProgressService.markWatched(_progressKey, _duration.inMilliseconds);

    final names = widget.playlistNames;
    final paths = widget.playlistPaths;
    if (names != null &&
        paths != null &&
        widget.currentIndex < names.length - 1) {
      _startAutoPlayCountdown();
    }
  }

  void _startAutoPlayCountdown() {
    setState(() {
      _showAutoPlayOverlay = true;
      _autoPlayCountdown = 5;
    });
    _autoPlayTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _autoPlayCountdown--);
      if (_autoPlayCountdown <= 0) {
        timer.cancel();
        _playNext();
      }
    });
  }

  void _cancelAutoPlay() {
    _autoPlayTimer?.cancel();
    setState(() => _showAutoPlayOverlay = false);
  }

  void _playNext() {
    _autoPlayTimer?.cancel();
    Navigator.pop(context, {
      'playNext': true,
      'nextIndex': widget.currentIndex + 1,
      'speed': _playbackSpeed,
    });
  }

  @override
  void dispose() {
    _saveCurrentPosition();
    _hideControlsTimer?.cancel();
    _saveTimer?.cancel();
    _autoPlayTimer?.cancel();
    _headphoneTimer?.cancel();
    _leftTapTimer?.cancel();
    _rightTapTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _player.dispose();
    _controlsFadeController.dispose();
    _cleanupTempFile();

    // Restore portrait and system UI
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    super.dispose();
  }

  void _cleanupTempFile() {
    try {
      final file = File(widget.videoPath);
      if (file.existsSync() && widget.videoPath.contains('amo_play_')) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  void _startHideTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (_isPlaying && !_isLocked && mounted) {
        setState(() => _controlsVisible = false);
        _controlsFadeController.reverse();
      }
    });
  }

  void _showControls() {
    if (_isLocked) return;
    setState(() => _controlsVisible = true);
    _controlsFadeController.forward();
    _startHideTimer();
  }

  void _togglePlayPause() {
    if (_isLocked) return;
    _player.playOrPause();
    _showControls();
  }

  void _seek(Duration position) {
    if (_isLocked) return;
    _player.seek(position);
    _showControls();
  }

  void _skipForward() {
    if (_isLocked) return;
    final platform = _player.platform;
    if (platform is NativePlayer) {
      // Force exact relative seek to bypass the hr-seek=no keyframe snapping
      platform.command(['seek', '10', 'relative+exact']);
    } else {
      final newPos = _player.state.position + const Duration(seconds: 10);
      _seek(newPos > _player.state.duration ? _player.state.duration : newPos);
    }
    _showControls();
  }

  void _skipBackward() {
    if (_isLocked) return;
    final platform = _player.platform;
    if (platform is NativePlayer) {
      // Force exact relative seek to bypass the hr-seek=no keyframe snapping
      platform.command(['seek', '-10', 'relative+exact']);
    } else {
      final newPos = _player.state.position - const Duration(seconds: 10);
      _seek(newPos < Duration.zero ? Duration.zero : newPos);
    }
    _showControls();
  }

  void _setSpeed(double speed) {
    if (_isLocked) return;
    setState(() => _playbackSpeed = speed);
    _player.setRate(speed);
    _showControls();
  }

  void _toggleMute() {
    if (_isLocked) return;
    setState(() {
      _isMuted = !_isMuted;
      _player.setVolume(_isMuted ? 0 : _volume);
    });
    _showControls();
  }

  void _toggleLock() {
    setState(() {
      _isLocked = !_isLocked;
      if (_isLocked) {
        _controlsVisible = false;
        _controlsFadeController.reverse();
      } else {
        _controlsVisible = true;
        _controlsFadeController.forward();
        _startHideTimer();
      }
    });
  }

  static const _kTapWindow = Duration(milliseconds: 300);

  void _onLeftZoneTap() {
    if (_isLocked) return;
    _showControls();
    // Reset accumulated seconds at the start of a new gesture sequence so the
    // fade-out always shows the last real value, never "-0s".
    if (_leftTapCount == 0) _leftSkipSeconds = 0;
    _leftTapCount++;
    _leftTapTimer?.cancel();
    if (_leftTapCount >= 2) {
      _skipBackward();
      _leftSkipSeconds += 10;
      setState(() => _showLeftSkipFx = true);
    }
    _leftTapTimer = Timer(_kTapWindow, () {
      if (mounted) {
        setState(() {
          _leftTapCount = 0;
          _showLeftSkipFx = false;
          // _leftSkipSeconds intentionally NOT reset here — keeps the last
          // displayed value visible while AnimatedOpacity fades out.
        });
      }
    });
  }

  void _onRightZoneTap() {
    if (_isLocked) return;
    _showControls();
    if (_rightTapCount == 0) _rightSkipSeconds = 0;
    _rightTapCount++;
    _rightTapTimer?.cancel();
    if (_rightTapCount >= 2) {
      _skipForward();
      _rightSkipSeconds += 10;
      setState(() => _showRightSkipFx = true);
    }
    _rightTapTimer = Timer(_kTapWindow, () {
      if (mounted) {
        setState(() {
          _rightTapCount = 0;
          _showRightSkipFx = false;
        });
      }
    });
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Video
          Center(
            child: Video(
              controller: _videoController,
              controls: (state) => const SizedBox.shrink(),
            ),
          ),

          // Left / right tap zones (below all overlays so controls intercept first)
          Positioned.fill(
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _onLeftZoneTap,
                    child: const SizedBox.expand(),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _onRightZoneTap,
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),

          // Left skip ripple — width = half screen so it reaches the skip buttons
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: MediaQuery.of(context).size.width / 2,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _showLeftSkipFx ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 180),
                child: _buildSkipEffect(isLeft: true),
              ),
            ),
          ),

          // Right skip ripple
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: MediaQuery.of(context).size.width / 2,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _showRightSkipFx ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 180),
                child: _buildSkipEffect(isLeft: false),
              ),
            ),
          ),

          // Lock indicator
          if (_isLocked) _buildLockOverlay(),

          // Controls overlay
          if (!_isLocked)
            FadeTransition(
              opacity: _controlsFadeAnimation,
              child: _controlsVisible
                  ? _buildControlsOverlay()
                  : const SizedBox.shrink(),
            ),

          // Resume overlay
          if (_showResumeOverlay) _buildResumeOverlay(),

          // Auto-play next overlay
          if (_showAutoPlayOverlay) _buildAutoPlayOverlay(),

          // Headphone-disconnected overlay (requireHeadphones courses)
          if (_headphonesMissing) _buildHeadphonesOverlay(),
        ],
      ),
    );
  }

  Widget _buildHeadphonesOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.92),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.headset_off, color: AppColors.error, size: 64),
              const SizedBox(height: 20),
              Text(
                AmoL10n.of(context).playerHeadphonesDisconnected,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                AmoL10n.of(context).playerHeadphonesReconnect,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 15,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                AmoL10n.of(context).playerWaitingForHeadphones,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSkipEffect({required bool isLeft}) {
    final seconds = isLeft ? _leftSkipSeconds : _rightSkipSeconds;
    return CustomPaint(
      painter: _HalfCirclePainter(isLeft: isLeft),
      child: Center(
        child: Text(
          isLeft ? '-${seconds}s' : '+${seconds}s',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
            shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
          ),
        ),
      ),
    );
  }

  Widget _buildLockOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        onTap: () {},
        child: Container(
          color: Colors.transparent,
          child: Stack(
            children: [
              Positioned(
                bottom: 40,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    onLongPress: _toggleLock,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: AppColors.error.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.lock, color: AppColors.error, size: 18),
                          SizedBox(width: 8),
                          Text(
                            AmoL10n.of(context).playerLocked,
                            style: TextStyle(
                              color: AppColors.error,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
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

  Widget _buildControlsOverlay() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Top gradient — IgnorePointer so taps fall through to skip zones
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 100,
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.7),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
        // Bottom gradient — IgnorePointer so taps fall through to skip zones
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 200,
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.85),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),

        // Top bar
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(child: _buildTopBar()),
        ),

        // Center controls (play/pause, skip)
        Center(child: _buildCenterControls()),

        // Bottom controls
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(child: _buildBottomControls()),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Back button
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.arrow_back,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Video title
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.videoName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.drmAccent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.shield,
                            size: 10,
                            color: AppColors.drmAccent,
                          ),
                          SizedBox(width: 4),
                          Text(
                            AmoL10n.of(context).playerScreenRecordingBlocked,
                            style: TextStyle(
                              color: AppColors.drmAccent,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Lock button
          _buildControlButton(
            icon: Icons.lock_outline,
            label: 'Lock',
            onTap: _toggleLock,
            color: AppColors.error,
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCenterControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Rewind 10s
        _buildCircularButton(
          icon: Icons.replay_10,
          size: 48,
          iconSize: 26,
          onTap: _skipBackward,
          color: Colors.white.withValues(alpha: 0.8),
        ),
        const SizedBox(width: 32),
        // Play/Pause
        _buildCircularButton(
          icon: _isPlaying ? Icons.pause : Icons.play_arrow,
          size: 64,
          iconSize: 36,
          onTap: _togglePlayPause,
          color: Colors.white,
          hasGlow: true,
        ),
        const SizedBox(width: 32),
        // Forward 10s
        _buildCircularButton(
          icon: Icons.forward_10,
          size: 48,
          iconSize: 26,
          onTap: _skipForward,
          color: Colors.white.withValues(alpha: 0.8),
        ),
      ],
    );
  }

  Widget _buildCircularButton({
    required IconData icon,
    required double size,
    required double iconSize,
    required VoidCallback onTap,
    Color color = Colors.white,
    bool hasGlow = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: hasGlow ? 0.15 : 0.1),
            boxShadow: hasGlow
                ? [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.2),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                  ]
                : null,
          ),
          child: Icon(icon, color: color, size: iconSize),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress bar
          _buildProgressBar(),
          const SizedBox(height: 4),
          // Bottom row
          Row(
            children: [
              // Time
              Text(
                '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
              const Spacer(),
              // Mute button
              IconButton(
                onPressed: _toggleMute,
                icon: Icon(
                  _isMuted || _volume == 0 ? Icons.volume_off : Icons.volume_up,
                  color: Colors.white70,
                  size: 20,
                ),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
              ),
              const SizedBox(width: 8),
              // Speed selector
              _buildSpeedSelector(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    final totalMs = _duration.inMilliseconds.toDouble();
    final currentMs = _position.inMilliseconds.toDouble();
    final progress = totalMs > 0 ? (currentMs / totalMs).clamp(0.0, 1.0) : 0.0;

    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        activeTrackColor: Colors.white,
        inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
        thumbColor: Colors.white,
        overlayColor: Colors.white.withValues(alpha: 0.2),
      ),
      child: Slider(
        value: progress,
        onChanged: (v) {
          final newPos = Duration(milliseconds: (v * totalMs).toInt());
          _seek(newPos);
        },
      ),
    );
  }

  Widget _buildSpeedSelector() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showSpeedPicker(),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.speed, color: Colors.white70, size: 16),
              const SizedBox(width: 4),
              Text(
                '${_playbackSpeed}x',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResumeOverlay() {
    final dur = Duration(milliseconds: _resumePositionMs);
    final timeStr = _formatDuration(dur);
    return Positioned(
      bottom: 80,
      left: 16,
      right: 16,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.replay, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(
                AmoL10n.of(context).playerResumeFrom(timeStr),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _resumeFromSaved,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    AmoL10n.of(context).playerResume,
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _dismissResume,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    AmoL10n.of(context).playerStartOver,
                    style: TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAutoPlayOverlay() {
    final nextName = widget.playlistNames![widget.currentIndex + 1];
    return Positioned(
      bottom: 80,
      left: 16,
      right: 16,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.drmAccent.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.skip_next, color: AppColors.drmAccent, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AmoL10n.of(
                        context,
                      ).playerAutoPlayCountdown(_autoPlayCountdown),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                      ),
                    ),
                    Text(
                      nextName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _playNext,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.drmAccent,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    AmoL10n.of(context).playerPlayNow,
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _cancelAutoPlay,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    AmoL10n.of(context).actionCancel,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSpeedPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AmoL10n.of(ctx).playerPlaybackSpeed,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _speedOptions.map((speed) {
                final isSelected = _playbackSpeed == speed;
                return GestureDetector(
                  onTap: () {
                    _setSpeed(speed);
                    Navigator.pop(ctx);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Text(
                      '${speed}x',
                      style: TextStyle(
                        color: isSelected ? Colors.black : Colors.white70,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        fontSize: 14,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

/// Paints a semi-circle flush against the left or right screen edge.
/// The flat (diameter) side is at the edge; the curve extends inward.
class _HalfCirclePainter extends CustomPainter {
  final bool isLeft;
  const _HalfCirclePainter({required this.isLeft});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;

    // Use the widget width as the radius so the arc reaches the far edge
    // of the half-screen zone (where the existing skip buttons live).
    final radius = size.width;
    final cx = isLeft ? 0.0 : size.width;
    final cy = size.height / 2;

    final path = Path()
      ..moveTo(cx, cy - radius)
      ..arcToPoint(
        Offset(cx, cy + radius),
        radius: Radius.circular(radius),
        clockwise: isLeft,
      )
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _HalfCirclePainter old) => old.isLeft != isLeft;
}
