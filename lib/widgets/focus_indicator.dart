import 'package:flutter/material.dart';

/// Tap-to-focus overlay.
/// Usage: wrap the camera preview with [TapToFocusHandler] and overlay
/// [FocusIndicator] at the tapped position.
class TapToFocusHandler extends StatelessWidget {
  final Widget child;
  final void Function(TapDownDetails) onTap;

  const TapToFocusHandler({
    super.key,
    required this.child,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: onTap,
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}

/// Animated corner-bracket focus square — shown at the tapped position.
/// Calls [onDismiss] when the animation completes so the parent can
/// remove it from the tree.
class FocusIndicator extends StatefulWidget {
  final VoidCallback onDismiss;

  const FocusIndicator({super.key, required this.onDismiss});

  @override
  State<FocusIndicator> createState() => _FocusIndicatorState();
}

class _FocusIndicatorState extends State<FocusIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );

    // Scale: zooms in from 1.6 → 1.0, then holds, then slightly shrinks
    _scale = TweenSequence([
      TweenSequenceItem(
          tween: Tween(begin: 1.6, end: 1.0)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 25),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 50),
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.85)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 25),
    ]).animate(_ctrl);

    // Opacity: fully visible, then fades out in the last 30%
    _opacity = TweenSequence([
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 70),
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.0)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 30),
    ]).animate(_ctrl);

    _ctrl.forward().then((_) {
      if (mounted) widget.onDismiss();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Opacity(
        opacity: _opacity.value,
        child: Transform.scale(
          scale: _scale.value,
          child: const _FocusSquare(size: 68),
        ),
      ),
    );
  }
}

class _FocusSquare extends StatelessWidget {
  final double size;
  const _FocusSquare({required this.size});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _CornerBracketPainter(),
    );
  }
}

class _CornerBracketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;

    const arm = 14.0; // length of each bracket arm

    final w = size.width;
    final h = size.height;

    // Top-left
    canvas.drawLine(const Offset(0, arm), const Offset(0, 0), paint);
    canvas.drawLine(const Offset(0, 0), Offset(arm, 0), paint);

    // Top-right
    canvas.drawLine(Offset(w - arm, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, arm), paint);

    // Bottom-left
    canvas.drawLine(Offset(0, h - arm), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(arm, h), paint);

    // Bottom-right
    canvas.drawLine(Offset(w - arm, h), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w, h - arm), paint);

    // Centre dot
    canvas.drawCircle(
      Offset(w / 2, h / 2),
      2.0,
      paint..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_) => false;
}
