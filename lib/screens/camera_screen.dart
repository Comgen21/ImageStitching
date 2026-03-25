import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../services/stitch_service.dart';
import 'panorama_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  final List<Uint8List> _capturedFrames = [];
  bool _isInitialized = false;
  bool _isStitching = false;
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;

      _controller = CameraController(
        _cameras[0],
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _controller!.initialize();
      if (mounted) setState(() => _isInitialized = true);
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  Future<void> _captureFrame() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_isCapturing) return;

    setState(() => _isCapturing = true);

    try {
      final file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();
      setState(() {
        _capturedFrames.add(bytes);
        _isCapturing = false;
      });
    } catch (e) {
      setState(() => _isCapturing = false);
      debugPrint('Capture error: $e');
    }
  }

  Future<void> _stitchFrames() async {
    if (_capturedFrames.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Capture at least 2 frames first')),
      );
      return;
    }

    setState(() => _isStitching = true);

    try {
      final result = await StitchService.stitch(_capturedFrames);
      if (!mounted) return;

      if (result != null) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PanoramaScreen(
              panoramaBytes: result,
              frameCount: _capturedFrames.length,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isStitching = false);
    }
  }

  void _reset() {
    setState(() => _capturedFrames.clear());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            _buildTopBar(),

            // Camera preview
            Expanded(
              child: _isInitialized
                  ? Stack(
                      alignment: Alignment.center,
                      children: [
                        CameraPreview(_controller!),
                        // Capture guide overlay
                        _buildGuideOverlay(),
                        // Flash effect
                        if (_isCapturing)
                          Container(color: Colors.white.withOpacity(0.4)),
                      ],
                    )
                  : const Center(
                      child: CircularProgressIndicator(
                          color: Color(0xFF1A73E8))),
            ),

            // Bottom controls
            _buildBottomControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.black87,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          const Expanded(
            child: Text('Capture Shelf',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ),
          // Frame counter badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _capturedFrames.isEmpty
                  ? Colors.white12
                  : const Color(0xFF1A73E8),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${_capturedFrames.length} frames',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuideOverlay() {
    return Positioned(
      bottom: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          _capturedFrames.isEmpty
              ? 'Move LEFT to RIGHT along the shelf'
              : 'Overlap 30% with previous shot',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.all(24),
      color: Colors.black87,
      child: Column(
        children: [
          // Thumbnail strip of captured frames
          if (_capturedFrames.isNotEmpty) ...[
            SizedBox(
              height: 60,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _capturedFrames.length,
                itemBuilder: (context, index) => Container(
                  margin: const EdgeInsets.only(right: 8),
                  width: 60,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    image: DecorationImage(
                      image: MemoryImage(_capturedFrames[index]),
                      fit: BoxFit.cover,
                    ),
                    border: index == _capturedFrames.length - 1
                        ? Border.all(color: const Color(0xFF1A73E8), width: 2)
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Reset button
              _ControlButton(
                icon: Icons.refresh,
                label: 'Reset',
                color: Colors.white24,
                onPressed: _capturedFrames.isEmpty ? null : _reset,
              ),

              // Capture button
              GestureDetector(
                onTap: _captureFrame,
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    color: _isCapturing
                        ? Colors.white30
                        : Colors.transparent,
                  ),
                  child: Center(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),

              // Stitch button
              _ControlButton(
                icon: Icons.auto_awesome,
                label: 'Stitch',
                color: _capturedFrames.length >= 2
                    ? const Color(0xFF1A73E8)
                    : Colors.white24,
                onPressed: _capturedFrames.length >= 2 && !_isStitching
                    ? _stitchFrames
                    : null,
                isLoading: _isStitching,
              ),
            ],
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
  final VoidCallback? onPressed;
  final bool isLoading;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.color,
    this.onPressed,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
            child: isLoading
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 4),
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ],
      ),
    );
  }
}
