import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../widgets/focus_indicator.dart';
import '../services/stitch_service.dart';
import 'panorama_screen.dart';

class VideoCaptureScreen extends StatefulWidget {
  const VideoCaptureScreen({super.key});

  @override
  State<VideoCaptureScreen> createState() => _VideoCaptureScreenState();
}

class _VideoCaptureScreenState extends State<VideoCaptureScreen> {
  CameraController? _controller;
  bool _initialized = false;
  bool _isRecording = false;
  bool _isProcessing = false;
  int _recordSeconds = 0;
  Timer? _timer;
  String? _processingStatus;
  Offset? _focusPoint;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      final ctrl = CameraController(
        cameras[0],
        ResolutionPreset.high, // 720p — good balance for video stitching
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await ctrl.initialize();
      if (!mounted) return;
      setState(() {
        _controller = ctrl;
        _initialized = true;
      });
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  Future<void> _startRecording() async {
    if (_controller == null || !_initialized || _isRecording) return;

    // Lock exposure for consistent lighting across all frames
    await _controller!.setExposureMode(ExposureMode.locked);

    await _controller!.startVideoRecording();
    _recordSeconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordSeconds++);
    });
    setState(() => _isRecording = true);
  }

  Future<void> _stopAndProcess() async {
    if (!_isRecording || _controller == null) return;

    _timer?.cancel();
    setState(() {
      _isRecording = false;
      _isProcessing = true;
      _processingStatus = 'Saving video...';
    });

    try {
      final XFile videoFile = await _controller!.stopVideoRecording();
      await _controller!.setExposureMode(ExposureMode.auto);

      if (mounted) setState(() => _processingStatus = 'Extracting frames...');

      // Short delay so status shows before compute() blocks the main isolate
      await Future.delayed(const Duration(milliseconds: 100));

      if (mounted) setState(() => _processingStatus = 'Stitching with OpenCV...');

      final path = await StitchService.stitchVideo(videoFile.path);

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

  Future<void> _onTapFocus(TapDownDetails details) async {
    if (_controller == null || !_initialized || _isProcessing) return;

    final size = MediaQuery.of(context).size;
    final x = (details.localPosition.dx / size.width).clamp(0.0, 1.0);
    final y = (details.localPosition.dy / size.height).clamp(0.0, 1.0);

    setState(() => _focusPoint = details.localPosition);

    try {
      await _controller!.setFocusMode(FocusMode.auto);
      await _controller!.setFocusPoint(Offset(x, y));
      // Only adjust exposure when not recording (exposure is locked during recording)
      if (!_isRecording) {
        await _controller!.setExposureMode(ExposureMode.auto);
        await _controller!.setExposurePoint(Offset(x, y));
      }
    } catch (_) {}
  }

  String get _timerText {
    final m = (_recordSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_recordSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

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

            // Processing overlay
            if (_isProcessing)
              Container(
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
                      Text(
                        _processingStatus ?? 'Processing...',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Extracting ~22 frames · OpenCV Stitcher',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),

            // Top bar
            if (!_isProcessing)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildTopBar(),
              ),

            // Scan guide lines (only when not recording yet)
            if (!_isRecording && !_isProcessing && _initialized)
              const Positioned.fill(child: _ScanGuide()),

            // Bottom controls
            if (!_isProcessing)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _buildBottomControls(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
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
            onPressed: () {
              if (_isRecording) _stopAndProcess();
              Navigator.pop(context);
            },
          ),
          const Expanded(
            child: Text('Video Scan',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ),
          // Recording timer badge
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: _isRecording
                  ? const Color(0xFFEF4444)
                  : Colors.white24,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isRecording)
                  const Icon(Icons.fiber_manual_record,
                      color: Colors.white, size: 10),
                if (_isRecording) const SizedBox(width: 5),
                Text(
                  _isRecording ? _timerText : 'REC',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
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
          // Hint text
          Text(
            _isRecording
                ? 'Pan slowly left → right  •  keep shelf centred'
                : 'Press record, then pan across the shelf',
            style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 13,
                letterSpacing: 0.2),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),

          // Record / Stop button
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: _isRecording ? _stopAndProcess : _startRecording,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.transparent,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: _isRecording ? 28 : 56,
                      height: _isRecording ? 28 : 56,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444),
                        borderRadius:
                            BorderRadius.circular(_isRecording ? 6 : 28),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),
          Text(
            _isRecording ? 'Tap to stop & stitch' : 'Tap to start recording',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ── Full-screen camera preview ─────────────────────────────────────────────

class _FullscreenCamera extends StatelessWidget {
  final CameraController controller;
  const _FullscreenCamera({required this.controller});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final scale = 1.0 / (controller.value.aspectRatio * size.aspectRatio);
    return Transform.scale(
      scale: scale < 1 ? 1.0 / scale : scale,
      alignment: Alignment.center,
      child: CameraPreview(controller),
    );
  }
}

// ── Scan guide overlay ─────────────────────────────────────────────────────

class _ScanGuide extends StatelessWidget {
  const _ScanGuide();

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return CustomPaint(
      painter: _GuideLinePainter(centerY: h * 0.5),
    );
  }
}

class _GuideLinePainter extends CustomPainter {
  final double centerY;
  _GuideLinePainter({required this.centerY});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.18)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Horizontal centre guide (keep shelf on this line)
    canvas.drawLine(
      Offset(20, centerY),
      Offset(size.width - 20, centerY),
      paint,
    );

    // Arrow indicating pan direction
    const arrowY = 80.0;
    final arrowPaint = Paint()
      ..color = Colors.white.withOpacity(0.4)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final cx = size.width / 2;
    canvas.drawLine(Offset(cx - 40, arrowY), Offset(cx + 40, arrowY), arrowPaint);
    canvas.drawLine(Offset(cx + 25, arrowY - 10), Offset(cx + 40, arrowY), arrowPaint);
    canvas.drawLine(Offset(cx + 25, arrowY + 10), Offset(cx + 40, arrowY), arrowPaint);
  }

  @override
  bool shouldRepaint(_) => false;
}
