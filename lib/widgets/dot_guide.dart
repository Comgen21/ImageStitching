import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Dotted guide that tracks pan rotation from an externally-supplied gyro stream.
/// The parent screen owns the gyro subscription and broadcasts it here,
/// eliminating duplicate sensor subscriptions.
class DotGuideWidget extends StatefulWidget {
  final int totalDots;
  final Stream<GyroscopeEvent> gyroStream;
  final VoidCallback? onComplete;

  const DotGuideWidget({
    super.key,
    this.totalDots = 7,
    required this.gyroStream,
    this.onComplete,
  });

  @override
  State<DotGuideWidget> createState() => DotGuideWidgetState();
}

class DotGuideWidgetState extends State<DotGuideWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  double _totalRotation = 0.0;
  double _currentDot = 0;
  DateTime? _lastEventTime;

  // Each dot = ~20° of rotation
  static const double _radiansPerDot = 20.0 * pi / 180.0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _subscribe();
  }

  @override
  void didUpdateWidget(DotGuideWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gyroStream != widget.gyroStream) {
      _gyroSub?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _gyroSub = widget.gyroStream.listen((event) {
      final now = DateTime.now();
      if (_lastEventTime != null) {
        final dt = now.difference(_lastEventTime!).inMicroseconds / 1e6;
        _totalRotation += event.y.abs() * dt;
        final newDot = (_totalRotation / _radiansPerDot)
            .floor()
            .clamp(0, widget.totalDots - 1);
        if (newDot != _currentDot.toInt()) {
          setState(() => _currentDot = newDot.toDouble());
          if (_currentDot >= widget.totalDots - 1) {
            widget.onComplete?.call();
          }
        }
      }
      _lastEventTime = now;
    }, onError: (_) {});
  }

  /// Reset dot progress — call this when the user taps Reset.
  void reset() {
    setState(() {
      _totalRotation = 0.0;
      _currentDot = 0;
      _lastEventTime = null;
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _gyroSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withOpacity(0.7), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.arrow_back_ios, color: Colors.white60, size: 14),
              const SizedBox(width: 6),
              Text(
                _currentDot == 0
                    ? 'Start scanning left to right'
                    : _currentDot >= widget.totalDots - 1
                        ? 'Almost done!'
                        : 'Keep going...',
                style: const TextStyle(
                    color: Colors.white70, fontSize: 12, letterSpacing: 0.3),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.arrow_forward_ios,
                  color: Colors.white60, size: 14),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(widget.totalDots, (index) {
              return Row(
                children: [
                  _buildDot(index),
                  if (index < widget.totalDots - 1) _buildConnector(index),
                ],
              );
            }),
          ),
          const SizedBox(height: 10),
          Text(
            '${_currentDot.toInt() + 1} of ${widget.totalDots}',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildDot(int index) {
    final isDone = index < _currentDot;
    final isCurrent = index == _currentDot.toInt();

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, _) {
        final pulseSize =
            isCurrent ? 14.0 + (_pulseController.value * 5.0) : 14.0;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: pulseSize,
          height: pulseSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDone
                ? const Color(0xFF22C55E)
                : isCurrent
                    ? const Color(0xFF1A73E8)
                    : Colors.transparent,
            border: Border.all(
              color: isDone
                  ? const Color(0xFF22C55E)
                  : isCurrent
                      ? const Color(0xFF1A73E8)
                      : Colors.white30,
              width: 2,
            ),
            boxShadow: isCurrent
                ? [
                    BoxShadow(
                      color: const Color(0xFF1A73E8)
                          .withOpacity(0.5 * _pulseController.value),
                      blurRadius: 10,
                      spreadRadius: 2,
                    )
                  ]
                : null,
          ),
          child: isDone
              ? const Icon(Icons.check, color: Colors.white, size: 8)
              : null,
        );
      },
    );
  }

  Widget _buildConnector(int index) {
    final isPassed = index < _currentDot;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 20,
      height: 2,
      color: isPassed ? const Color(0xFF22C55E) : Colors.white12,
    );
  }
}
