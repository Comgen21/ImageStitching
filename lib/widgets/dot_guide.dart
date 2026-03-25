import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Dotted guide overlay that tracks how far the user has panned
/// the camera using the gyroscope, and lights up dots accordingly.
class DotGuideWidget extends StatefulWidget {
  final int totalDots;
  final VoidCallback? onComplete;

  const DotGuideWidget({
    super.key,
    this.totalDots = 7,
    this.onComplete,
  });

  @override
  State<DotGuideWidget> createState() => _DotGuideWidgetState();
}

class _DotGuideWidgetState extends State<DotGuideWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  double _totalRotation = 0.0; // cumulative rotation in radians
  int _currentDot = 0;
  DateTime? _lastEventTime;

  // Each dot = ~20 degrees of rotation
  static const double _radiansPerDot = 20.0 * pi / 180.0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _startTracking();
  }

  void _startTracking() {
    _gyroSub = gyroscopeEventStream(
      samplingPeriod: SensorInterval.uiInterval,
    ).listen((GyroscopeEvent event) {
      final now = DateTime.now();
      if (_lastEventTime != null) {
        final dt = now.difference(_lastEventTime!).inMicroseconds / 1e6;
        // event.y = angular velocity around Y axis (left-right pan)
        _totalRotation += event.y.abs() * dt;

        final newDot = (_totalRotation / _radiansPerDot)
            .floor()
            .clamp(0, widget.totalDots - 1);

        if (newDot != _currentDot) {
          setState(() => _currentDot = newDot);
          if (_currentDot >= widget.totalDots - 1) {
            widget.onComplete?.call();
          }
        }
      }
      _lastEventTime = now;
    }, onError: (_) {});
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
          // Direction hint
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.arrow_back_ios,
                  color: Colors.white60, size: 14),
              const SizedBox(width: 6),
              Text(
                _currentDot == 0
                    ? 'Start scanning left to right'
                    : _currentDot >= widget.totalDots - 1
                        ? 'Almost done!'
                        : 'Keep going...',
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    letterSpacing: 0.3),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.arrow_forward_ios,
                  color: Colors.white60, size: 14),
            ],
          ),

          const SizedBox(height: 14),

          // Dots row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ...List.generate(widget.totalDots, (index) {
                return Row(
                  children: [
                    _buildDot(index),
                    // Connector line between dots
                    if (index < widget.totalDots - 1)
                      _buildConnector(index),
                  ],
                );
              }),
            ],
          ),

          const SizedBox(height: 10),

          // Progress text
          Text(
            '${_currentDot + 1} of ${widget.totalDots}',
            style: const TextStyle(
                color: Colors.white38,
                fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildDot(int index) {
    final isDone = index < _currentDot;
    final isCurrent = index == _currentDot;

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, _) {
        final pulseSize = isCurrent ? 14.0 + (_pulseController.value * 5.0) : 14.0;

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
      color: isPassed
          ? const Color(0xFF22C55E)
          : Colors.white12,
    );
  }
}
