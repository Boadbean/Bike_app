import 'dart:math';

import 'package:flutter/material.dart';

/// Arc-shaped gauge showing speed against a fixed 0–[maxSpeed] range.
class SpeedGauge extends StatelessWidget {
  const SpeedGauge({
    super.key,
    required this.speedKmh,
    this.maxSpeed = 40,
    this.size = 200,
  });

  final double speedKmh;
  final double maxSpeed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SpeedGaugePainter(
          progress: (speedKmh / maxSpeed).clamp(0, 1),
          trackColor: colorScheme.surfaceContainerHighest,
          progressColor: colorScheme.primary,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                speedKmh.toStringAsFixed(1),
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              Text('km/h', style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpeedGaugePainter extends CustomPainter {
  _SpeedGaugePainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
  });

  final double progress;
  final Color trackColor;
  final Color progressColor;

  static const _startAngle = 0.75 * pi;
  static const _sweepAngle = 1.5 * pi;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final strokeWidth = size.width * 0.08;
    final arcRect = rect.deflate(strokeWidth);

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final progressPaint = Paint()
      ..color = progressColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(arcRect, _startAngle, _sweepAngle, false, trackPaint);
    canvas.drawArc(arcRect, _startAngle, _sweepAngle * progress, false, progressPaint);
  }

  @override
  bool shouldRepaint(covariant _SpeedGaugePainter oldDelegate) =>
      oldDelegate.progress != progress;
}
