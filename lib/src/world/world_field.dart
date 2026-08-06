/// The shader field — the world itself, full bleed behind everything.
///
/// Loads `shaders/world.frag` and paints it over the whole viewport once per
/// frame, feeding it the camera position so that travelling moves the sample
/// window through a continuous field rather than transitioning between images.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/world/world_camera.dart';

class WorldField extends StatefulWidget {
  const WorldField({required this.camera, super.key});

  final WorldCamera camera;

  @override
  State<WorldField> createState() => _WorldFieldState();
}

class _WorldFieldState extends State<WorldField>
    with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  late final Ticker _ticker;
  double _time = 0;

  @override
  void initState() {
    super.initState();
    // ⚠️ This ticker runs CONTINUOUSLY, unlike the camera's, which sleeps when
    // nothing is moving. Ambient motion is the point of the field, so there is
    // no idle state to fall back to — it is a standing cost, and the reason
    // fill rate has to be measured rather than assumed.
    _ticker = createTicker((elapsed) {
      setState(() => _time = elapsed.inMicroseconds / 1e6);
    });
    unawaited(_ticker.start());
    unawaited(_load());
  }

  Future<void> _load() async {
    final program = await ui.FragmentProgram.fromAsset('shaders/world.frag');
    if (!mounted) return;
    setState(() => _shader = program.fragmentShader());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    // Flat background until the program is compiled. It arrives within a
    // frame or two, and a flash of the site's own background is invisible.
    if (shader == null) {
      return const ColoredBox(color: Palette.bg);
    }
    return CustomPaint(
      painter: _FieldPainter(
        shader: shader,
        time: _time,
        camera: widget.camera.position,
        velocity: widget.camera.velocity,
      ),
      size: Size.infinite,
    );
  }
}

class _FieldPainter extends CustomPainter {
  const _FieldPainter({
    required this.shader,
    required this.time,
    required this.camera,
    required this.velocity,
  });

  final ui.FragmentShader shader;
  final double time;
  final double camera;
  final double velocity;

  @override
  void paint(Canvas canvas, Size size) {
    // Uniforms are set by FLAT INDEX, in declaration order from the .frag —
    // vec2 uSize takes 0 and 1, then the scalars follow. Reordering the
    // declarations without changing these is a silent, very confusing bug.
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, time)
      ..setFloat(3, camera)
      ..setFloat(4, velocity);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_FieldPainter old) =>
      old.time != time || old.camera != camera || old.velocity != velocity;
}
