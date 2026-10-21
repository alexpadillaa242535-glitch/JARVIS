import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Fondo HUD: grilla, línea de escaneo y esquinas.
class HudPainter extends CustomPainter {
  final double t; // 0..1 (se repite)
  final Color color;
  HudPainter(this.t, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0, -0.1),
          radius: 1.0,
          colors: [Color(0xFF04141F), Colors.black],
        ).createShader(rect),
    );

    final grid = Paint()
      ..color = color.withOpacity(0.08)
      ..strokeWidth = 1;
    const step = 36.0;
    final off = (t * step * 4) % step;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = -step + off; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final sy = ((t * 3) % 1) * size.height;
    final band = Rect.fromLTWH(0, sy - 40, size.width, 80);
    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, color.withOpacity(0.22), Colors.transparent],
        ).createShader(band),
    );

    final br = Paint()
      ..color = color.withOpacity(0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    const m = 14.0, l = 26.0;
    final w = size.width, h = size.height;
    canvas.drawPath(Path()..moveTo(m, m + l)..lineTo(m, m)..lineTo(m + l, m), br);
    canvas.drawPath(Path()..moveTo(w - m - l, m)..lineTo(w - m, m)..lineTo(w - m, m + l), br);
    canvas.drawPath(Path()..moveTo(m, h - m - l)..lineTo(m, h - m)..lineTo(m + l, h - m), br);
    canvas.drawPath(Path()..moveTo(w - m - l, h - m)..lineTo(w - m, h - m)..lineTo(w - m, h - m - l), br);
  }

  @override
  bool shouldRepaint(HudPainter old) => true;
}

/// Botón reactor: arcos giratorios, núcleo que pulsa y color según estado.
class ReactorPainter extends CustomPainter {
  final double t;
  final Color color;
  final bool active;
  ReactorPainter(this.t, this.color, this.active);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final pulse = 0.5 + 0.5 * math.sin(t * math.pi * 2 * (active ? 60 : 12));

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withOpacity(0.30 + 0.25 * pulse), Colors.transparent],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    for (int i = 0; i < 4; i++) {
      final rad = r * (0.50 + 0.14 * i);
      final dir = i.isEven ? 1 : -1;
      final rot = dir * t * math.pi * 2 * (i + 1) * (active ? 3 : 1);
      final segs = 3 + i;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = i == 3 ? 3.0 : 2.0
        ..strokeCap = StrokeCap.round
        ..color = color.withOpacity(0.9 - i * 0.12);
      final arc = math.pi * 2 / segs;
      for (int k = 0; k < segs; k++) {
        canvas.drawArc(Rect.fromCircle(center: c, radius: rad), rot + k * arc, arc * 0.62, false, paint);
      }
    }

    final tick = Paint()
      ..color = color.withOpacity(0.6)
      ..strokeWidth = 1.5;
    for (int i = 0; i < 36; i++) {
      final a = i * math.pi * 2 / 36;
      final p1 = c + Offset(math.cos(a), math.sin(a)) * (r * 0.95);
      final p2 = c + Offset(math.cos(a), math.sin(a)) * (r * (i % 3 == 0 ? 0.88 : 0.91));
      canvas.drawLine(p1, p2, tick);
    }

    final coreR = r * 0.26 * (1 + 0.10 * pulse);
    canvas.drawCircle(
      c,
      coreR,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white, color, color.withOpacity(0.2)],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: coreR)),
    );
  }

  @override
  bool shouldRepaint(ReactorPainter old) => true;
}
