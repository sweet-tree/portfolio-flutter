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

/// The resolutions the scene may render at, sharpest first.
///
/// Fill rate is the cost model, so pixel count is the one lever that reduces
/// work without changing what the shader computes. Only the shader softens;
/// text is a separate layer at full resolution.
///
/// A FIXED value cannot serve both machines: measured on the deployed build,
/// a desktop ran 65 FPS at 0.7 while an iPhone 11 ran 25. The phone is drawing
/// roughly a fifth of the pixels and still managing a third of the frame rate,
/// because its GPU is simply far weaker. So the scale is chosen at runtime.
const List<double> kSceneScales = [1.0, 0.85, 0.7, 0.58, 0.48, 0.38, 0.3];

/// Where a new session starts. Middle of the range, so a weak device needs
/// two steps down rather than five, and a strong one two steps up.
const int kInitialScaleStep = 2;

/// Step down below this, up above the other. The gap between them is the
/// hysteresis that stops it oscillating: dropping the resolution raises the
/// frame rate, which would otherwise immediately raise the resolution again.
const double kScaleDownBelowFps = 50;
const double kScaleUpAboveFps = 58;

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

  // ── Adaptive resolution ────────────────────────────────────────────────────
  int _step = kInitialScaleStep;
  int _frames = 0;
  Duration _windowStart = Duration.zero;
  int _goodWindows = 0;

  double get _scale => kSceneScales[_step];

  /// Chooses the resolution from the frame rate the device actually achieves.
  ///
  /// Asymmetric on purpose: one bad window steps down immediately, but
  /// stepping back up needs several consecutive good ones. Dropping the
  /// resolution is what RAISED the frame rate, so a symmetric rule would
  /// climb straight back to a resolution it already knows is too expensive
  /// and oscillate there.
  void _adapt(Duration elapsed) {
    _frames++;
    final span = elapsed - _windowStart;
    if (span.inMilliseconds < 500) return;

    final fps = _frames * 1000 / span.inMilliseconds;
    _frames = 0;
    _windowStart = elapsed;

    // Ignore the first couple of seconds — shader compilation and the first
    // frames are not representative, and reacting to them lands every device
    // on the lowest setting.
    if (elapsed.inMilliseconds < 2000) return;

    if (fps < kScaleDownBelowFps && _step < kSceneScales.length - 1) {
      _goodWindows = 0;
      _step++;
    } else if (fps > kScaleUpAboveFps && _step > 0) {
      _goodWindows++;
      if (_goodWindows >= 6) {
        _goodWindows = 0;
        _step--;
      }
    } else {
      _goodWindows = 0;
    }
  }

  @override
  void initState() {
    super.initState();
    // ⚠️ Runs CONTINUOUSLY, unlike the camera's ticker. Ambient motion is the
    // point of the field, so there is no idle state — a standing cost, and the
    // reason fill rate has to be measured rather than assumed.
    _ticker = createTicker((elapsed) {
      _adapt(elapsed);
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
        scale: _scale,
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
    required this.scale,
    required this.camera,
    required this.velocity,
  });

  final ui.FragmentShader shader;
  final double time;
  final double scale;
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
      (size.width * scale).roundToDouble(),
      (size.height * scale).roundToDouble(),
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
      ..setFloat(8, 0) // uCubeGlow
      ..setFloat(9, 1) // uSurface
      ..setFloat(10, 0) // uSky — off; the shader is still compiled in
      ..setFloat(11, 1) // uStars — space beyond the table
      ..setFloat(12, 1); // uClouds — the flying volumetric energy

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
      old.time != time ||
      old.camera != camera ||
      old.velocity != velocity ||
      old.scale != scale;
}
