import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter/foundation.dart';
import '../widgets/dot_guide.dart';
import '../widgets/focus_indicator.dart';
import '../services/stitch_service.dart';
import '../services/frame_analysis_isolate.dart';
import 'panorama_screen.dart';

// Auto-capture: one frame per 15° of pan rotation
const double _kAutoCaptureDeg = 15.0;
const double _kAutoCaptureRad = _kAutoCaptureDeg * pi / 180.0;

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  CameraController? _controller;
  bool _initialized = false;
  bool _isCapturing = false;
  bool _isProcessing = false;
  bool _autoMode = false;
  bool _showFlash = false;
  final List<String> _frames = [];
  Offset? _focusPoint;

  // Single broadcast gyro stream shared by auto-capture and DotGuide
  late final StreamController<GyroscopeEvent> _gyroController;
  StreamSubscription<GyroscopeEvent>? _rawGyroSub;
  StreamSubscription<GyroscopeEvent>? _autoCaptSub;
  DateTime? _lastGyroTime;
  double _rotationSinceCapture = 0;

  // DotGuide key for programmatic reset
  final _dotGuideKey = GlobalKey<DotGuideWidgetState>();

  // Frame analysis results
  bool _isAnalyzing = false;
  double? _overlapPercent;    // shown after each capture
  bool _lastFrameBlurry = false;

  // Exposure offset
  double _exposureOffset = 0.0;
  double _minExposure = -2.0;
  double _maxExposure = 2.0;

  // ── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _gyroController = StreamController<GyroscopeEvent>.broadcast();
    _rawGyroSub = gyroscopeEventStream(
      samplingPeriod: SensorInterval.uiInterval,
    ).listen((e) => _gyroController.add(e), onError: (_) {});
    _initCamera();
  }

  @override
  void dispose() {
    _autoCaptSub?.cancel();
    _rawGyroSub?.cancel();
    _gyroController.close();
    _controller?.dispose();
    super.dispose();
  }

  // ── Camera ───────────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      final ctrl = CameraController(
        cameras[0],
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await ctrl.initialize();
      if (!mounted) return;

      double minExp = -2.0, maxExp = 2.0;
      try {
        minExp = await ctrl.getMinExposureOffset();
        maxExp = await ctrl.getMaxExposureOffset();
      } catch (_) {}

      setState(() {
        _controller = ctrl;
        _initialized = true;
        _minExposure = minExp;
        _maxExposure = maxExp;
      });
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  // ── Tap-to-focus ─────────────────────────────────────────────────────────

  Future<void> _onTapFocus(TapDownDetails details) async {
    if (_controller == null || !_initialized || _isProcessing) return;

    final size = MediaQuery.of(context).size;
    final x = (details.localPosition.dx / size.width).clamp(0.0, 1.0);
    final y = (details.localPosition.dy / size.height).clamp(0.0, 1.0);

    setState(() => _focusPoint = details.localPosition);

    try {
      await _controller!.setFocusMode(FocusMode.auto);
      await _controller!.setFocusPoint(Offset(x, y));
      if (!_autoMode) {
        await _controller!.setExposureMode(ExposureMode.auto);
        await _controller!.setExposurePoint(Offset(x, y));
      }
    } catch (_) {}
  }

  // ── Exposure ─────────────────────────────────────────────────────────────

  Future<void> _setExposureOffset(double value) async {
    setState(() => _exposureOffset = value);
    try {
      await _controller?.setExposureOffset(value);
    } catch (_) {}
  }

  // ── Auto-capture mode ────────────────────────────────────────────────────

  void _toggleAuto() => _autoMode ? _stopAuto() : _startAuto();

  void _startAuto() {
    _rotationSinceCapture = 0;
    _lastGyroTime = null;

    // Lock exposure so all frames have the same brightness
    _controller?.setExposureMode(ExposureMode.locked);

    _autoCaptSub = _gyroController.stream.listen((event) {
      if (!_autoMode || !mounted) return;
      final now = DateTime.now();
      if (_lastGyroTime != null) {
        final dt = now.difference(_lastGyroTime!).inMicroseconds / 1e6;
        _rotationSinceCapture += event.y.abs() * dt;
        if (_rotationSinceCapture >= _kAutoCaptureRad) {
          _rotationSinceCapture = 0;
          _captureFrame();
        }
      }
      _lastGyroTime = now;
    });

    setState(() => _autoMode = true);

    // Snap first frame immediately
    _captureFrame();
  }

  void _stopAuto() {
    _autoCaptSub?.cancel();
    _autoCaptSub = null;
    _controller?.setExposureMode(ExposureMode.auto);
    setState(() {
      _autoMode = false;
      _rotationSinceCapture = 0;
    });
  }

  // ── Capture ──────────────────────────────────────────────────────────────

  Future<void> _captureFrame() async {
    if (!_initialized || _isCapturing || _isProcessing || _controller == null) return;
    setState(() => _isCapturing = true);
    _triggerFlash();

    try {
      final XFile photo = await _controller!.takePicture();
      final dir = await getTemporaryDirectory();
      final dest =
          '${dir.path}/shelf_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(photo.path).copy(dest);

      if (!mounted) return;

      // Run blur + overlap analysis in isolate (non-blocking)
      setState(() => _isAnalyzing = true);
      final prevPath = _frames.isNotEmpty ? _frames.last : null;
      final analysis = await compute(FrameAnalysisIsolate.run, {
        'newPath': dest,
        'prevPath': prevPath,
      });

      if (!mounted) return;

      final isBlurry = analysis['isBlurry'] as bool;
      final overlapPct = analysis['overlapPercent'] as double?;

      if (isBlurry) {
        // Discard blurry frame — don't add to list
        setState(() {
          _isAnalyzing = false;
          _lastFrameBlurry = true;
          _overlapPercent = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Frame too blurry — hold steady and try again'),
            backgroundColor: Color(0xFFEF4444),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        setState(() {
          _frames.add(dest);
          _isAnalyzing = false;
          _lastFrameBlurry = false;
          _overlapPercent = overlapPct;
        });
        // Hide the overlap badge after 3 seconds
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _overlapPercent = null);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Capture failed: $e'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  void _triggerFlash() {
    setState(() => _showFlash = true);
    Future.delayed(const Duration(milliseconds: 90), () {
      if (mounted) setState(() => _showFlash = false);
    });
  }

  // ── Stitch ───────────────────────────────────────────────────────────────

  Future<void> _stitch() async {
    if (_frames.length < 2 || _isProcessing) return;
    if (_autoMode) _stopAuto();

    if (_frames.length < 5 && mounted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A2535),
          title: const Text('Few Frames Captured',
              style: TextStyle(color: Colors.white)),
          content: Text(
            'You have ${_frames.length} frame(s).\n'
            'For best quality, capture 6–10 frames with good overlap.\n\n'
            'Continue anyway?',
            style: const TextStyle(color: Colors.white70, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Capture More'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A73E8)),
              child: const Text('Stitch Now',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (go != true) return;
    }

    setState(() => _isProcessing = true);
    try {
      final path = await StitchService.stitch(_frames);
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => PanoramaScreen(panoramaPath: path)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  // ── Reset ────────────────────────────────────────────────────────────────

  void _reset() {
    if (_autoMode) _stopAuto();
    _dotGuideKey.currentState?.reset();
    setState(() {
      _frames.clear();
      _overlapPercent = null;
      _lastFrameBlurry = false;
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Camera preview + tap-to-focus
            if (_initialized && _controller != null)
              TapToFocusHandler(
                onTap: _onTapFocus,
                child: _FullscreenCamera(controller: _controller!),
              )
            else
              const Center(
                  child: CircularProgressIndicator(color: Color(0xFF1A73E8))),

            // Focus indicator
            if (_focusPoint != null)
              Positioned(
                left: _focusPoint!.dx - 34,
                top: _focusPoint!.dy - 34,
                child: FocusIndicator(
                  key: ValueKey(_focusPoint),
                  onDismiss: () => setState(() => _focusPoint = null),
                ),
              ),

            // Capture flash
            if (_showFlash)
              IgnorePointer(
                child: Container(color: Colors.white.withOpacity(0.35)),
              ),

            // Processing overlay
            if (_isProcessing) _buildProcessingOverlay(),

            // Exposure slider — right edge, between top bar and bottom controls
            if (!_isProcessing && _initialized)
              Positioned(
                right: 12,
                top: 80,
                bottom: 180,
                child: _ExposureSlider(
                  value: _exposureOffset,
                  min: _minExposure,
                  max: _maxExposure,
                  onChanged: _setExposureOffset,
                ),
              ),

            // Top bar
            if (!_isProcessing)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _TopBar(
                  frameCount: _frames.length,
                  autoMode: _autoMode,
                  onBack: () {
                    if (_autoMode) _stopAuto();
                    Navigator.pop(context);
                  },
                ),
              ),

            // Overlap / analyzing badge — centred above the dot guide
            if (!_isProcessing)
              Positioned(
                bottom: 170,
                left: 0,
                right: 0,
                child: Center(
                  child: _isAnalyzing
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                    color: Colors.white70, strokeWidth: 2),
                              ),
                              SizedBox(width: 8),
                              Text('Analysing...',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 12)),
                            ],
                          ),
                        )
                      : _overlapPercent != null
                          ? _OverlapBadge(percent: _overlapPercent!)
                          : const SizedBox.shrink(),
                ),
              ),

            // Bottom: dot guide + controls
            if (!_isProcessing)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DotGuideWidget(
                      key: _dotGuideKey,
                      gyroStream: _gyroController.stream,
                      totalDots: 7,
                    ),
                    _BottomControls(
                      frameCount: _frames.length,
                      isCapturing: _isCapturing,
                      autoMode: _autoMode,
                      onCapture: _captureFrame,
                      onToggleAuto: _toggleAuto,
                      onStitch: _frames.length >= 2 ? _stitch : null,
                      onReset: _frames.isNotEmpty ? _reset : null,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.92),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(
                  color: Color(0xFF1A73E8), strokeWidth: 3),
            ),
            const SizedBox(height: 24),
            const Text('Stitching panorama...',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Text('OpenCV · ${_frames.length} frames',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.5), fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

// ── Exposure slider ─────────────────────────────────────────────────────────

class _ExposureSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _ExposureSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final label = value >= 0
        ? '+${value.toStringAsFixed(1)}'
        : value.toStringAsFixed(1);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.wb_sunny_outlined, color: Colors.white54, size: 16),
        const SizedBox(height: 4),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: Colors.white70,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: Colors.white24,
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 10)),
      ],
    );
  }
}

// ── Subwidgets ─────────────────────────────────────────────────────────────

class _FullscreenCamera extends StatelessWidget {
  final CameraController controller;
  const _FullscreenCamera({required this.controller});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    var scale = size.aspectRatio * controller.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;
    return Transform.scale(
      scale: scale,
      alignment: Alignment.center,
      child: CameraPreview(controller),
    );
  }
}

class _TopBar extends StatelessWidget {
  final int frameCount;
  final bool autoMode;
  final VoidCallback onBack;

  const _TopBar({
    required this.frameCount,
    required this.autoMode,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: onBack,
          ),
          const Expanded(
            child: Text('Scan Shelf',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.only(right: 12),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: frameCount == 0
                  ? Colors.white24
                  : autoMode
                      ? const Color(0xFFEF4444)
                      : const Color(0xFF1A73E8),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  autoMode
                      ? Icons.fiber_manual_record
                      : Icons.photo_library_outlined,
                  color: Colors.white,
                  size: 13,
                ),
                const SizedBox(width: 5),
                Text('$frameCount',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomControls extends StatelessWidget {
  final int frameCount;
  final bool isCapturing;
  final bool autoMode;
  final VoidCallback onCapture;
  final VoidCallback onToggleAuto;
  final VoidCallback? onStitch;
  final VoidCallback? onReset;

  const _BottomControls({
    required this.frameCount,
    required this.isCapturing,
    required this.autoMode,
    required this.onCapture,
    required this.onToggleAuto,
    required this.onStitch,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withOpacity(0.9), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Main controls row
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Auto toggle
                _ControlButton(
                  icon: autoMode
                      ? Icons.stop_rounded
                      : Icons.play_arrow_rounded,
                  label: autoMode ? 'Stop' : 'Auto',
                  color: autoMode
                      ? const Color(0xFFEF4444)
                      : const Color(0xFF1A73E8),
                  onTap: onToggleAuto,
                ),

                // Capture button (disabled in auto mode)
                GestureDetector(
                  onTap: autoMode ? null : onCapture,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: autoMode
                          ? Colors.grey.shade700
                          : isCapturing
                              ? Colors.grey.shade400
                              : Colors.white,
                      border: Border.all(color: Colors.white54, width: 3),
                      boxShadow: autoMode
                          ? null
                          : [
                              BoxShadow(
                                color: Colors.white.withOpacity(0.2),
                                blurRadius: 12,
                                spreadRadius: 2,
                              ),
                            ],
                    ),
                    child: isCapturing
                        ? const Padding(
                            padding: EdgeInsets.all(18),
                            child: CircularProgressIndicator(
                                color: Colors.black54, strokeWidth: 2.5),
                          )
                        : null,
                  ),
                ),

                // Reset button
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  opacity: frameCount > 0 ? 1.0 : 0.0,
                  child: _ControlButton(
                    icon: Icons.refresh_rounded,
                    label: 'Reset',
                    color: Colors.white24,
                    onTap: onReset ?? () {},
                  ),
                ),
              ],
            ),
          ),

          // Stitch button (full width, appears after 2+ frames)
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: frameCount >= 2
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: onStitch,
                        icon: const Icon(Icons.auto_awesome, size: 18),
                        label: Text(
                          autoMode
                              ? 'Stop & Stitch  •  $frameCount frames'
                              : 'Stitch  •  $frameCount frames',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF22C55E),
                          foregroundColor: Colors.white,
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          textStyle: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  )
                : const SizedBox(height: 20),
          ),
        ],
      ),
    );
  }
}

// ── Overlap badge ───────────────────────────────────────────────────────────

class _OverlapBadge extends StatelessWidget {
  final double percent;
  const _OverlapBadge({required this.percent});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String advice;
    if (percent < 20) {
      color = const Color(0xFFEF4444); // red — gap, may miss content
      advice = 'Pan slower';
    } else if (percent < 35) {
      color = const Color(0xFFF97316); // orange — borderline
      advice = 'A little more overlap';
    } else if (percent <= 70) {
      color = const Color(0xFF22C55E); // green — ideal
      advice = 'Good overlap';
    } else if (percent <= 85) {
      color = const Color(0xFFF97316); // orange — too much
      advice = 'Pan a bit faster';
    } else {
      color = const Color(0xFFEF4444); // red — near duplicate
      advice = 'Pan faster';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: color.withOpacity(0.4), blurRadius: 8, spreadRadius: 1)
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${percent.round()}% overlap',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 6),
          Text(
            '· $advice',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 4),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(color: Colors.white54, fontSize: 11)),
        ],
      ),
    );
  }
}
