/// The scene: field and cube in one shader, one pass.
///
/// Replaces the old pair of stacked shaders. They could not affect each other,
/// so the cube read as pasted on and a drawn ring stood in for light. Here the
/// cube's position is a uniform of the same program that draws the field, so
/// the field can actually be lit by it.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/world/world_camera.dart';

/// Where the cube sits inside its own location, as a fraction of the viewport.
///
/// It travels WITH its section: at camera position 1 the hero is one screen to
/// the left, so the cube is too. That falls out of the maths below rather than
/// needing to be animated.
const double kCubeX = 0.5;
const double kCubeY = 0.34;

/// Cube size as a fraction of the viewport's shortest side.
const double kCubeSize = 0.26;

class WorldScene extends StatefulWidget {
  const WorldScene({required this.camera, super.key});

  final WorldCamera camera;

  @override
  State<WorldScene> createState() => _WorldSceneState();
}

class _WorldSceneState extends State<WorldScene>
    with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  late final Ticker _ticker;
  double _time = 0;

  @override
  void initState() {
    super.initState();
    // ⚠️ Runs CONTINUOUSLY, unlike the camera's ticker. Ambient motion is the
    // point of the field, so there is no idle state — a standing cost, and the
    // reason fill rate has to be measured rather than assumed.
    _ticker = createTicker((elapsed) {
      setState(() => _time = elapsed.inMicroseconds / 1e6);
    });
    unawaited(_ticker.start());
    unawaited(_load());
  }

  Future<void> _load() async {
    final program = await ui.FragmentProgram.fromAsset('shaders/scene.frag');
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
    if (shader == null) return const ColoredBox(color: Palette.bg);
    return CustomPaint(
      painter: _ScenePainter(
        shader: shader,
        time: _time,
        camera: widget.camera.position,
        velocity: widget.camera.velocity,
      ),
      size: Size.infinite,
    );
  }
}

class _ScenePainter extends CustomPainter {
  const _ScenePainter({
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
    // The cube belongs to the first location, so travelling moves it off
    // screen with its section.
    final cubeX = size.width * (kCubeX - camera);
    final cubeY = size.height * kCubeY;
    final unit = size.shortestSide * kCubeSize;

    // Flat indices in declaration order from the .frag.
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, time)
      ..setFloat(3, camera)
      ..setFloat(4, velocity)
      ..setFloat(5, cubeX)
      ..setFloat(6, cubeY)
      ..setFloat(7, unit)
      // Indices follow scene.frag's declaration order, including uniforms
      // that are currently unused — the layout keeps them, so deleting one
      // silently shifts every index after it.
      ..setFloat(8, 0)   // uCubeGlow
      ..setFloat(9, 1)   // uSurface
      ..setFloat(10, 0); // uSky — off; the shader is still compiled in
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_ScenePainter old) =>
      old.time != time || old.camera != camera || old.velocity != velocity;
}
