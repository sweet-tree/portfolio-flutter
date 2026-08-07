/// The statement's letters as amplifiers of the energy that reaches them.
///
/// Two halves. [TypeMaskCapture] wraps the statement and records WHERE the
/// glyphs are; [TypeGlow] sits above the whole world and adds light wherever a
/// glyph and the energy field coincide.
///
/// ⚠️ THE TEXT ITSELF IS NEVER TOUCHED. It stays the plain `Text` widget it has
/// always been — same style, same colour, rasterised from the glyph atlas at
/// full resolution — and the glow is a separate layer above it composited with
/// `BlendMode.plus`, which can only add. The crisp glyphs underneath still
/// define every edge, so nothing here can soften the one thing on the page a
/// visitor has to read.
///
/// ⚠️ AND NOT A SHADER ON THE TEXT'S OWN PAINT, which is the obvious approach
/// and is a trap. The two web renderers disagree: skwasm (the `--wasm` build,
/// desktop) passes the whole Paint through so a shader fill works, while
/// CanvasKit — the JavaScript fallback, which is what every browser on iOS
/// gets — keeps only `foreground.color` and silently drops the shader. A Paint
/// carrying only a shader defaults to opaque black, so the statement would
/// render black-on-black on an iPhone and perfectly on a Mac. Samplers and
/// blend modes, used here instead, are implemented on both renderers, and the
/// site already proves both on real hardware.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

// ── The dials ───────────────────────────────────────────────────────────────

/// How quickly a letter turns red as energy lands on it. Straight and linear.
const double kGlowGain = 6;

/// How much energy has to land before a letter reacts at all. Below this a
/// word is plain white type.
const double kGlowKnee = 0.03;

/// How far the light spills into the air around a word, as a fraction of the
/// viewport's height. 0 turns the spill off entirely.
///
/// Very slight: enough that a red word sits in a faint wash rather than being
/// cut out of the panel with scissors, not enough to read as a glow effect.
const double kGlowBloom = 0.006;

/// How much of the spill is kept.
///
/// ⚠️ THE BLOOM IS ADDITIVE EVEN THOUGH THE COLOUR IS NOT, and that is the
/// right way round. Inside a letter the red must REPLACE the white, so that
/// pass is source-over. Outside it there is only dark panel, and light in the
/// air is light — it adds. Painting the spill source-over would lay flat red
/// haze over the glass instead of lighting it.
const double kGlowBloomStrength = 0.55;

/// Resolution the glow is rendered at, and the resolution the glyph mask is
/// baked at, both as a fraction of the viewport.
///
/// ⚠️ BOTH AT FULL, and that is not caution. When the layer merely ADDED light
/// the letterform's edges came from the crisp text underneath, so a coarse
/// mask cost nothing. Now that it REPLACES the colour, the mask's edge IS the
/// red's edge — anything less than full resolution and the red spills a pixel
/// or two outside the white glyph, which on a dark panel reads as a fringe.
const double kGlowScale = 1;
const double kMaskScale = 1;

/// Where the glyphs are, in the hero panel's own coordinates. Null until the
/// first layout has been measured.
///
/// ⚠️ OPAQUE, WITH THE COVERAGE IN RED, NOT IN ALPHA. Flutter images are
/// premultiplied: a pixel holding colour beside a partial alpha is not a valid
/// premultiplied colour and what a backend does with it is undefined. Data goes
/// in a colour channel; alpha stays 1.
final ValueNotifier<ui.Image?> typeMask = ValueNotifier<ui.Image?>(null);

/// Wraps the statement and keeps [typeMask] in step with it.
///
/// Measured from the real render object rather than by re-deriving the layout.
/// The statement's position falls out of a font-size search, a bottom
/// alignment and three levels of padding; a second copy of that arithmetic
/// would have to be kept in step forever, whereas asking the render object
/// cannot drift because it IS the layout.
class TypeMaskCapture extends StatefulWidget {
  const TypeMaskCapture({
    required this.panel,
    required this.child,
    super.key,
  });

  /// The hero panel, which the block is measured against — so that travelling
  /// does not change the mask. The camera offset is applied in the shader
  /// instead, where it is a single addition.
  final GlobalKey panel;
  final Widget child;

  @override
  State<TypeMaskCapture> createState() => _TypeMaskCaptureState();
}

class _TypeMaskCaptureState extends State<TypeMaskCapture> {
  final GlobalKey _boundary = GlobalKey();
  Size? _lastViewport;
  Rect? _lastRect;

  void _capture() {
    if (!mounted) return;
    final block = _boundary.currentContext?.findRenderObject();
    final panel = widget.panel.currentContext?.findRenderObject();
    if (block is! RenderRepaintBoundary || panel is! RenderBox) return;
    if (!block.hasSize || !panel.hasSize) return;

    final viewport = MediaQuery.sizeOf(context);
    final origin = panel.globalToLocal(block.localToGlobal(Offset.zero));
    final rect = origin & block.size;
    if (viewport == _lastViewport && rect == _lastRect) return;
    if (viewport.isEmpty || block.size.isEmpty) return;
    _lastViewport = viewport;
    _lastRect = rect;

    final width = (viewport.width * kMaskScale).round();
    final height = (viewport.height * kMaskScale).round();
    if (width <= 0 || height <= 0) return;

    // kMaskScale is 1, which is also toImageSync's default — passing it
    // explicitly trips avoid_redundant_argument_values, so the coupling is
    // asserted instead of written. If the mask ever goes below full
    // resolution again, this is the line that has to change with it.
    assert(kMaskScale == 1, 'pass pixelRatio: kMaskScale below');
    final glyphs = block.toImageSync();

    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = const Color(0xFF000000),
      )
      // srcIn against white keeps the glyph COVERAGE and discards the colour
      // the type happens to be drawn in — the mask is a shape, not a picture.
      ..drawImage(
        glyphs,
        Offset(origin.dx * kMaskScale, origin.dy * kMaskScale),
        Paint()
          ..colorFilter = const ColorFilter.mode(
            Color(0xFFFFFFFF),
            BlendMode.srcIn,
          ),
      );

    final picture = recorder.endRecording();
    final mask = picture.toImageSync(width, height);
    picture.dispose();
    glyphs.dispose();

    typeMask.value?.dispose();
    typeMask.value = mask;
  }

  @override
  Widget build(BuildContext context) {
    // After layout — the render object has no size or position until then.
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
    return RepaintBoundary(key: _boundary, child: widget.child);
  }
}

/// The light the letters throw off. Sits above the whole world.
class TypeGlow extends StatefulWidget {
  const TypeGlow({required this.camera, super.key});

  /// The camera's position in locations, so the glow travels with the panel.
  final double camera;

  @override
  State<TypeGlow> createState() => _TypeGlowState();
}

class _TypeGlowState extends State<TypeGlow>
    with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  late final Ticker _ticker;
  double _time = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => _time = elapsed.inMicroseconds / 1e6);
    });
    unawaited(_ticker.start());
    unawaited(_load());
  }

  Future<void> _load() async {
    final program = await ui.FragmentProgram.fromAsset('shaders/type_glow.frag');
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
    if (shader == null) return const SizedBox.shrink();
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: typeMask,
      builder: (context, mask, _) => mask == null
          ? const SizedBox.shrink()
          : IgnorePointer(
              child: CustomPaint(
                painter: _GlowPainter(
                  shader: shader,
                  mask: mask,
                  time: _time,
                  camera: widget.camera,
                ),
                size: Size.infinite,
              ),
            ),
    );
  }
}

class _GlowPainter extends CustomPainter {
  const _GlowPainter({
    required this.shader,
    required this.mask,
    required this.time,
    required this.camera,
  });

  final ui.FragmentShader shader;
  final ui.Image mask;
  final double time;
  final double camera;

  @override
  void paint(Canvas canvas, Size size) {
    final low = Size(
      (size.width * kGlowScale).roundToDouble(),
      (size.height * kGlowScale).roundToDouble(),
    );
    if (low.isEmpty) return;

    shader
      ..setFloat(0, low.width)
      ..setFloat(1, low.height)
      ..setFloat(2, time)
      ..setFloat(3, camera)
      ..setFloat(4, kGlowGain)
      ..setFloat(5, kGlowKnee)
      // Bilinear, not the FilterQuality.none default — nearest would turn the
      // mask into visible steps along every letter's edge.
      ..setImageSampler(0, mask, filterQuality: FilterQuality.low);

    // Rendered once into its own buffer, then composited twice: sharp for the
    // flare inside the letters, blurred for the light spilling around them.
    // Rendering it twice would double the shader's cost for no gain.
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(Offset.zero & low, Paint()..shader = shader);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(low.width.toInt(), low.height.toInt());

    final src = Offset.zero & low;
    final dst = Offset.zero & size;

    // THE BLOOM, under the flare — light in the air around the word. Skipped
    // entirely at zero rather than blurred by nothing: a full-screen blur is
    // the most expensive thing in this painter.
    final sigma = size.height * kGlowBloom;
    if (sigma > 0.01) {
      canvas.drawImageRect(
        image,
        src,
        dst,
        Paint()
          ..blendMode = BlendMode.plus
          ..filterQuality = FilterQuality.high
          ..color = Color.fromRGBO(
            255,
            255,
            255,
            kGlowBloomStrength.clamp(0.0, 1.0),
          )
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.decal,
          ),
      );
    }

    // THE COLOUR ITSELF, over the letterforms.
    //
    // ⚠️ SOURCE-OVER, NOT PLUS. The statement is white, and adding to white
    // does nothing — every channel is already at the top. A white letter can
    // only turn red if something is painted OVER it. The shader confines this
    // to the glyph coverage, so nothing outside a letter is touched.
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.high,
    );

    image.dispose();
    picture.dispose();
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.time != time || old.camera != camera || old.mask != mask;
}
