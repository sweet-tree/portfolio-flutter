/// The scene: field and cube in one shader, one pass.
///
/// Replaces the old pair of stacked shaders. They could not affect each other,
/// so the cube read as pasted on and a drawn ring stood in for light. Here the
/// cube's position is a uniform of the same program that draws the field, so
/// the field can actually be lit by it.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/query_params.dart';
import 'package:portfolio/src/world/shaders.dart';
import 'package:portfolio/src/world/world_camera.dart';

/// Where the cube sits inside its own location, as a fraction of the viewport.
///
/// It travels WITH its section: at camera position 1 the hero is one screen to
/// the left, so the cube is too. That falls out of the maths below rather than
/// needing to be animated.
const double kCubeX = 0.5;
const double kCubeY = 0.34;

/// The cube's own size in the world: its half-width, in the units the table is
/// built in. The ledge runs from z = -0.95 in front to 3.1 behind.
///
/// ⚠️ THIS IS THE OBJECT. [kCubeSize] below is the CAMERA — it keeps every
/// proportion identical and merely crops the view, which is the wrong lever for
/// "make the cube bigger" and was tried first.
///
/// ⚠️ AND THE SURFACE DOES NOT CHANGE WITH IT: the material is defined on a
/// cube of fixed size and scaled, so a larger cube is the same stone, larger —
/// same blocks per face, each covering more pixels. That is the point of it on
/// a phone.
///
/// ⚠️ THE LAYOUT IS DELIBERATELY UNTOUCHED. The statement is held clear of the
/// cube's BASE, and the base rests on the table at any size — growing the cube
/// extends it upward, away from the type. The energy does not move either; it
/// spreads from the world origin rather than from the cube's surface. An
/// earlier attempt "fixed" the layout to track this and was pure added risk.
///
/// Clamped below 0.95, where the ledge ends in front; larger and the cube would
/// hang over the edge. `?cube=`.
double get kCubeHalf => qDouble('cube', 0.70).clamp(0.30, 0.90);

/// The cube's resting pose, in DEGREES about the vertical axis.
///
/// ⚠️ A POSE, NOT A SPIN. Choosing where the object sits, not animating it.
///
/// It is a composition control: the camera stands about 55 degrees off the
/// cube's axes, so an unturned cube presents its two visible faces at the same
/// incidence. Turning it squares one face to the eye and lays the other down.
/// Degrees rather than radians because that is what anyone has an opinion in.
/// `?spin=`.
double get kSpin => qDouble('spin', 0);

/// The table's material: 0 the diagnostic grey, 1 real glass.
///
/// ⚠️ THE GREY IS A STAND-IN, NOT THE DESIGN. Real glass on a dark ground
/// reflecting a dark object is very nearly invisible, and we could not tell
/// whether that was the material being subtle or the plane never being hit. The
/// opaque grey answered it and then stayed.
///
/// Turning glass on is a bigger change than a material: the contact shadow and
/// the contact darkening both work by MULTIPLYING the surface, so an invisible
/// surface takes the cube's grounding with it. `?glass=`.
double get kGlass => qDouble('glass', 0);

/// Cube size as a fraction of the viewport's shortest side.
const double kCubeSize = 0.26;

/// The cube's material: 0 the plain near-black solid, 1 mossed stone.
///
/// ⚠️ NOT A TUNING DIAL. It is an A/B for a decision about what the object IS —
/// a modern abstract mark, or an artifact — and that is a decision about the
/// site's story rather than about a number. `?mat=0` puts the plain cube in the
/// current renderer so the two can be compared on one screen in one moment,
/// which is the only comparison worth making.
double get kMaterial => qDouble('mat', 1);

/// The cube's tuning knobs, live on the deployed build.
///
/// ⚠️ THEY EXIST BECAUSE THE ALTERNATIVE IS WHAT WE DID ALL DAY: change a
/// constant, rebuild for fifty seconds, look, change it again. Every one of
/// these is a number that turned out to be wrong at least once.
///
/// ⚠️ AND [kLevel] AND [kFuzz] ARE SEPARATE ON PURPOSE. The cube went too
/// bright and then too dark because both were moved together — the rim was the
/// fault and the overall level was fine, but adjusted as one they could not be
/// told apart.
double get kLevel => qDouble('lvl', 1).clamp(0.2, 3.0);
double get kFuzz => qDouble('fuzz', 1).clamp(0.0, 4.0);
double get kMoss => qDouble('moss', 1).clamp(0.0, 2.0);
double get kLichen => qDouble('lich', 1).clamp(0.0, 2.0);

/// Stones across one face.
///
/// ⚠️ THE ONLY ONE WITH A REAL FLOOR AND CEILING RATHER THAN A RANGE. A face is
/// about 55 pixels on a phone: under four stones stops reading as a wall, and
/// over eight turns the joints to mush. The clamp is the constraint, not taste.
double get kBlocks => qDouble('blocks', 3.4).clamp(3.0, 9.0);

/// What fraction of full resolution the scene shader renders at.
///
/// Fill rate is the cost model, so this is the one lever that reduces work
/// without changing what the shader computes — 0.7 is roughly half the pixels.
/// Only the shader softens; text is a separate layer at full resolution.
///
/// ⚠️ AND IT IS THE MEASURING INSTRUMENT. Frame rate near the display's cap
/// tells you almost nothing: everything piles up against the same ceiling and
/// differences vanish. Raising this pushes the whole scene well below the cap,
/// where a change of a few percent is a change of a few frames instead of
/// nothing at all. Profile at 1.2, decide at 0.7. `?scale=`.
double get kSceneScale => qDouble('scale', 0.7).clamp(0.3, 2.0);

class WorldScene extends StatefulWidget {
  const WorldScene({required this.camera, super.key});

  final WorldCamera camera;

  @override
  State<WorldScene> createState() => _WorldSceneState();
}

class _WorldSceneState extends State<WorldScene>
    with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  /// ⚠️ A SECOND, SEPARATE SHADER INSTANCE FOR THE LAYER PASS.
  ///
  /// A FragmentShader carries its uniforms in a buffer that is read when the
  /// picture is RASTERISED, not when it is recorded — and `toImageSync` does
  /// not promise to rasterise before it returns. So recording the layer pass,
  /// then setting the uniforms for the scene pass on the same object, let the
  /// layer be drawn with the scene's values: it sampled the empty placeholder
  /// and stored black. The cube came out perfectly shaped and perfectly black.
  ///
  /// One shader per pass, and the two can never tread on each other.
  ui.FragmentShader? _layerShader;
  /// A third instance, for the light map — same reasoning as _layerShader.
  ui.FragmentShader? _lightShader;
  /// A fourth, for the band — same reasoning again.
  ui.FragmentShader? _bandShader;
  late final Ticker _ticker;
  double _time = 0;
  final _CubeCache _cubeCache = _CubeCache();
  final _LightCache _lightCache = _LightCache();

  @override
  void initState() {
    super.initState();
    // ⚠️ SYNCHRONOUS. The program was loaded before the first frame — see
    // [Shaders] — so the scene is drawn properly from the very first frame
    // instead of showing flat background until an await completed.
    _shader = Shaders.scene?.fragmentShader();
    _layerShader = Shaders.scene?.fragmentShader();
    _lightShader = Shaders.scene?.fragmentShader();
    _bandShader = Shaders.scene?.fragmentShader();
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
    _layerShader?.dispose();
    _lightShader?.dispose();
    _bandShader?.dispose();
    _cubeCache.dispose();
    _lightCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    final layerShader = _layerShader;
    final lightShader = _lightShader;
    final bandShader = _bandShader;
    if (shader == null ||
        layerShader == null ||
        lightShader == null ||
        bandShader == null) {
      return const ColoredBox(color: Palette.bg);
    }
    return CustomPaint(
      painter: _ScenePainter(
        shader: shader,
        layerShader: layerShader,
        lightShader: lightShader,
        bandShader: bandShader,
        lightCache: _lightCache,
        time: _time,
        camera: widget.camera.position,
        velocity: widget.camera.velocity,
        cache: _cubeCache,
      ),
      size: Size.infinite,
    );
  }
}

/// The cube's shading, drawn once and kept.
///
/// ⚠️ NOTHING ABOUT THE CUBE CHANGES BETWEEN FRAMES. The camera is fixed, the
/// light is fixed, the pose and size are constants, and the material has no
/// notion of time. Its picture is therefore identical every frame, and it was
/// being recomputed sixty times a second — measured at 8.8 ms of a 41.7 ms
/// frame, the largest single item in the scene.
///
/// ⚠️ THE FAILURE MODE IS A STALE CUBE, so the signature below is the whole
/// safety argument: it lists EVERY input the cube's shading depends on, and any
/// change to any of them throws the picture away. Miss one and the cube quietly
/// stops responding to it. That is why the material knobs are in here even
/// though they only ever arrive from the URL — a value that cannot change today
/// is one refactor away from changing tomorrow.
class _CubeCache {
  ui.Image? image;
  String? signature;

  /// ⚠️ A SAMPLER THAT IS DECLARED MUST BE BOUND, ALWAYS.
  ///
  /// The shader declares the cube layer whichever pass is running, and the very
  /// first pass is the one that DRAWS that layer — so at that moment there is
  /// nothing to bind. Leaving it unbound is undefined: some backends read
  /// garbage, some fail the draw outright, and the whole frame goes with it.
  ///
  /// So there is always something bound, even if it is one black pixel that the
  /// layer pass never reads.
  ui.Image? _placeholder;

  ui.Image get placeholder {
    final existing = _placeholder;
    if (existing != null) return existing;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 1, 1),
      Paint()..color = const Color(0xFF000000),
    );
    final picture = recorder.endRecording();
    final made = picture.toImageSync(1, 1);
    picture.dispose();
    _placeholder = made;
    return made;
  }

  /// Everything the cube's shading depends on. `time` is deliberately absent:
  /// that is the entire reason this works.
  static String signatureFor(Size low, double camera) => [
    low.width, low.height, camera,
    kCubeSize, kCubeHalf, kSpin, kMaterial, kLevel, kFuzz, kMoss, kLichen,
    kBlocks, kGlass, qDouble('off', 0),
  ].join(',');

  void dispose() {
    image?.dispose();
    image = null;
    _placeholder?.dispose();
    _placeholder = null;
    signature = null;
  }
}

/// The cast shadow and the contact darkening, baked over the table's surface.
///
/// ⚠️ IT DEPENDS ON THE CUBE ALONE — not on the camera, not on the viewport,
/// not on the window size. Fixed light, fixed occluder, fixed floor. So unlike
/// the cube's layer, travelling does not invalidate this at all, and neither
/// does resizing the browser.
///
/// Stored in the surface's own coordinate rather than on screen. The table
/// stretches away from the camera, so a screen-shaped map would be dense where
/// it is near and starved where it is far; in surface space the resolution is
/// even everywhere it matters.
class _LightCache {
  ui.Image? image;
  String? signature;

  /// 512 over eight world units: about 64 texels per unit, and the sharpest
  /// thing in it — the contact darkening right at the cube's foot — is a few
  /// texels across. Costs one megabyte, once.
  static const int size = 512;

  static String signatureFor() =>
      [kCubeHalf, kSpin, qDouble('off', 0)].join(',');

  void dispose() {
    image?.dispose();
    image = null;
    signature = null;
  }
}

class _ScenePainter extends CustomPainter {
  const _ScenePainter({
    required this.shader,
    required this.layerShader,
    required this.lightShader,
    required this.bandShader,
    required this.lightCache,
    required this.time,
    required this.camera,
    required this.velocity,
    required this.cache,
  });


  final ui.FragmentShader shader;
  final ui.FragmentShader layerShader;
  final ui.FragmentShader lightShader;
  final ui.FragmentShader bandShader;
  final double time;
  final double camera;
  final double velocity;
  final _CubeCache cache;
  final _LightCache lightCache;

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
    // screen with its section — which falls out of the maths in configure()
    // rather than needing to be animated. Everything there is derived from the
    // size of the pass being configured, so the composition is identical at any
    // of them once upscaled.

    // Every uniform except the layer mode, which the caller supplies. Written
    // once and applied to both shaders so the two passes cannot drift apart.
    void configure(ui.FragmentShader s, double layer, [Size? at]) {
      final target = at ?? low;
      // ⚠️ DERIVED FROM THIS PASS'S OWN SIZE. The ray for a pixel is built from
      // where the cube's origin lands and how many pixels a world unit spans,
      // both in the CURRENT target's pixels. A smaller pass that inherited the
      // full-size numbers would aim every ray somewhere else.
      final tCubeX = target.width * (kCubeX - camera);
      final tCubeY = target.height * kCubeY;
      final tUnit = target.shortestSide * kCubeSize;
      // Flat indices in declaration order from the .frag.
      s
        ..setFloat(0, target.width)
        ..setFloat(1, target.height)
        ..setFloat(2, time)
        ..setFloat(3, camera)
        ..setFloat(4, velocity)
        ..setFloat(5, tCubeX)
        ..setFloat(6, tCubeY)
        ..setFloat(7, tUnit)
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
        ..setFloat(12, 0)
        // uMaterial — the cube's surface. `?mat=0` for the plain cube.
        ..setFloat(13, kMaterial)
        ..setFloat(14, kLevel)
        ..setFloat(15, kFuzz)
        ..setFloat(16, kMoss)
        ..setFloat(17, kLichen)
        ..setFloat(18, kBlocks)
        ..setFloat(19, kCubeHalf)
        ..setFloat(20, kSpin * math.pi / 180.0)
        ..setFloat(21, kGlass)
        // uSpinCS — the pose as (cos, sin), turned once here rather than a
        // hundred times per pixel in the shader. See spinInto().
        ..setFloat(22, math.cos(kSpin * math.pi / 180.0))
        ..setFloat(23, math.sin(kSpin * math.pi / 180.0))
        // uOff — TEMPORARY profiling switches. `?off=`. Remove with the
        // shader's.
        ..setFloat(24, qDouble('off', 0))
        ..setFloat(25, layer);
    }

    // ── The light map, baked only when the cube itself changes ──────────────
    //
    // Nothing about the camera reaches this: it is the shadow an object casts
    // on a floor under a fixed light, in the surface's own coordinates. So it
    // survives travelling and window resizes untouched, and in practice is
    // computed exactly once for the life of the page.
    final wantLight = _LightCache.signatureFor();
    if (lightCache.signature != wantLight || lightCache.image == null) {
      final lightLow = Size(
        _LightCache.size.toDouble(),
        _LightCache.size.toDouble(),
      );
      configure(lightShader, 3, lightLow);
      lightShader
        ..setImageSampler(0, cache.image ?? cache.placeholder,
            filterQuality: FilterQuality.low)
        ..setImageSampler(1, lightCache.image ?? cache.placeholder,
            filterQuality: FilterQuality.low)
        ..setImageSampler(2, cache.placeholder,
            filterQuality: FilterQuality.low);
      final rec = ui.PictureRecorder();
      Canvas(rec)
          .drawRect(Offset.zero & lightLow, Paint()..shader = lightShader);
      final pic = rec.endRecording();
      final fresh = pic.toImageSync(_LightCache.size, _LightCache.size);
      pic.dispose();
      lightCache.image?.dispose();
      lightCache.image = fresh;
      lightCache.signature = wantLight;
    }

    // ── The galaxy band, at a quarter of each side ──────────────────────────
    //
    // ⚠️ REDRAWN EVERY FRAME, UNLIKE THE OTHER TWO. The sky turns, slowly, so
    // this is not a thing that can be cached — it is a thing that does not need
    // resolution. A sixteenth of the pixels, and no edge anywhere in it to give
    // that away.
    final bandLow = Size(
      (low.width * 0.25).roundToDouble(),
      (low.height * 0.25).roundToDouble(),
    );
    configure(bandShader, 4, bandLow);
    bandShader
      ..setImageSampler(0, cache.image ?? cache.placeholder,
          filterQuality: FilterQuality.low)
      ..setImageSampler(1, lightCache.image ?? cache.placeholder,
          filterQuality: FilterQuality.low)
      ..setImageSampler(2, cache.placeholder, filterQuality: FilterQuality.low);
    final bandRec = ui.PictureRecorder();
    Canvas(bandRec)
        .drawRect(Offset.zero & bandLow, Paint()..shader = bandShader);
    final bandPic = bandRec.endRecording();
    final bandImage =
        bandPic.toImageSync(bandLow.width.toInt(), bandLow.height.toInt());
    bandPic.dispose();

    // ── The cube's shading, redrawn only when something it depends on moves ──
    //
    // In production that means once, on load, and then never: the camera only
    // moves while travelling between sections, which is a couple of seconds of
    // a visit. During that motion the cube is redrawn every frame — correctly,
    // because panning changes which rays strike it — and it is sliding off the
    // screen anyway.
    final want = _CubeCache.signatureFor(low, camera);
    if (cache.signature != want || cache.image == null) {
      configure(layerShader, 1); // uLayer: the cube's shading alone
      // Bound but unread — see _CubeCache.placeholder.
      layerShader
        ..setImageSampler(0, cache.image ?? cache.placeholder,
            filterQuality: FilterQuality.low)
        ..setImageSampler(1, lightCache.image!,
            filterQuality: FilterQuality.low)
        ..setImageSampler(2, bandImage, filterQuality: FilterQuality.low);
      final layerRecorder = ui.PictureRecorder();
      Canvas(layerRecorder)
          .drawRect(Offset.zero & low, Paint()..shader = layerShader);
      final layerPicture = layerRecorder.endRecording();
      final fresh =
          layerPicture.toImageSync(low.width.toInt(), low.height.toInt());
      layerPicture.dispose();
      // Replace, then dispose the old one — an image held across frames is a
      // real allocation, and dropping the reference does not release it.
      cache.image?.dispose();
      cache.image = fresh;
      cache.signature = want;
    }

    // ⚠️ ASKED FOR EXPLICITLY. Flutter hands an image to a shader with
    // nearest-neighbour sampling by default, which would put hard pixel steps
    // on the cube — the one surface in this scene that must not have them.
    configure(shader, 2); // uLayer: read the cube and the light from textures
    shader
      ..setImageSampler(0, cache.image!, filterQuality: FilterQuality.low)
      ..setImageSampler(1, lightCache.image!, filterQuality: FilterQuality.low)
      ..setImageSampler(2, bandImage, filterQuality: FilterQuality.low);

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
    bandImage.dispose();
  }

  @override
  bool shouldRepaint(_ScenePainter old) =>
      old.time != time || old.camera != camera || old.velocity != velocity;
}
