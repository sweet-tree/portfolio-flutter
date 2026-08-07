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
import 'package:portfolio/src/world/shaders.dart';
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

/// What fraction of full resolution the scene shader renders at.
///
/// Fill rate is the cost model, so this is the one lever that reduces work
/// without changing what the shader computes — 0.7 is roughly half the pixels.
/// Only the shader softens; text is a separate layer at full resolution.
const double kSceneScale = 0.7;

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
    // ⚠️ SYNCHRONOUS. The program was loaded before the first frame — see
    // [Shaders] — so the scene is drawn properly from the very first frame
    // instead of showing flat background until an await completed.
    _shader = Shaders.scene?.fragmentShader();
    // ⚠️ Runs CONTINUOUSLY, unlike the camera's ticker. Ambient motion is the
    // point of the field, so there is no idle state — a standing cost, and the
    // reason fill rate has to be measured rather than assumed.
    _ticker = createTicker((elapsed) {
      setState(() => _time = elapsed.inMicroseconds / 1e6);
    });
    unawaited(_ticker.start());
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
    // ── Rendered below full resolution, then upscaled ───────────────────────
    //
    // The scene is a full-screen raytraced shader, so its cost is fill rate:
    // instructions × pixels × frames. Measured, the volumetric alone took the
    // frame from 75fps to 30. Pixel count is the only lever that reduces the
    // work without changing what the shader computes.
    //
    // ⚠️ It has to go through an offscreen buffer. Scaling the canvas
    // transform and drawing a smaller rect saves nothing — the same screen
    // area is still rasterised, so the same number of fragments run.
    //
    // The TEXT is unaffected: Flutter draws it as a separate layer at full
    // resolution, so only the shader softens. On a cloudy, noisy scene that is
    // close to invisible, which is why this is preferable to cutting the
    // march or the octaves.
    final low = Size(
      (size.width * kSceneScale).roundToDouble(),
      (size.height * kSceneScale).roundToDouble(),
    );
    if (low.isEmpty) return;

    // The cube belongs to the first location, so travelling moves it off
    // screen with its section. Everything is derived from the LOW size, so
    // the composition is identical once upscaled.
    final cubeX = low.width * (kCubeX - camera);
    final cubeY = low.height * kCubeY;
    final unit = low.shortestSide * kCubeSize;

    // Flat indices in declaration order from the .frag.
    shader
      ..setFloat(0, low.width)
      ..setFloat(1, low.height)
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
      ..setFloat(10, 0)  // uSky — off; the shader is still compiled in
      ..setFloat(11, 1)  // uStars — space beyond the table
      // uClouds — the flying volumetric energy. OFF. Measured at ~60% of the
      // frame (75 FPS without it against 30 with). The surface energy is
      // unaffected: the waterfall over the glass edge lives in the surface
      // shading, not in the volumetric.
      ..setFloat(12, 0);

    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(Offset.zero & low, Paint()..shader = shader);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      low.width.toInt(),
      low.height.toInt(),
    );

    canvas.drawImageRect(
      image,
      Offset.zero & low,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.high,
    );

    image.dispose();
    picture.dispose();
  }

  @override
  bool shouldRepaint(_ScenePainter old) =>
      old.time != time || old.camera != camera || old.velocity != velocity;
}
