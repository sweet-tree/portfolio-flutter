/// The statement, drawn ONCE and coloured by the energy that reaches it.
///
/// ⚠️ THE WHOLE DESIGN IS "ONE RASTERISATION", and everything else follows.
///
/// The obvious build — leave Flutter drawing white text and lay a coloured
/// layer over it — cannot be made exact, and no amount of pixel alignment
/// helps. It rasterises the letters twice: once by the engine onto the screen,
/// once by us into a mask. Two rasterisations of the same layout share glyph
/// POSITIONS but need not share antialiasing COVERAGE, and reconciling them
/// afterwards only trades artefacts. Cover slightly less than the text and the
/// outermost pixel of every letter never gets coloured — a white rim. Cover
/// slightly more and the colour lands on the panel, which is not black but
/// dark BLUE, so it strips the blue and leaves a dark rim instead.
///
/// So the type is rasterised exactly once, into an image whose alpha IS the
/// glyph coverage. A shader supplies what colour that coverage should be
/// filled with, and the two are composited a single time. There is no second
/// edge to disagree with the first, so it is exact by construction rather than
/// by tuning.
///
/// The `Text` widget stays in the tree — it still does the layout and it still
/// carries the sentence for a screen reader — but it paints transparent once
/// this is ready, so nothing is drawn twice.
///
/// ⚠️ AND NOT A SHADER ON THE TEXT'S OWN PAINT, which is the other obvious
/// build and is a trap. skwasm (the `--wasm` desktop build) passes the whole
/// Paint through so a shader fill works, while CanvasKit — the JavaScript
/// fallback every browser on iOS uses — keeps only `foreground.color` and
/// silently drops the shader (canvaskit/text.dart:563). A Paint carrying only
/// a shader defaults to opaque black, so the statement would have rendered
/// black on a dark panel on the phone and perfectly on a Mac.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

// ── The dials ───────────────────────────────────────────────────────────────

/// How quickly a letter turns as energy lands on it.
const double kGlowGain = 6;

/// How much energy has to land before a letter reacts at all. Below this a
/// word is plain white type.
const double kGlowKnee = 0.03;

/// How far the light spills into the air around a word, as a fraction of the
/// viewport's height. 0 turns the spill off entirely.
const double kGlowBloom = 0.006;

/// How much of the spill is kept.
const double kGlowBloomStrength = 0.55;

/// The statement, rasterised once. Alpha is the glyph coverage — the real one,
/// the only one — and there is no second rasterisation anywhere.
@immutable
class TypeGlyphs {
  const TypeGlyphs({
    required this.image,
    required this.block,
    required this.viewport,
    required this.pixelRatio,
  });

  /// White glyphs on transparent, at [pixelRatio] device pixels per logical
  /// pixel, covering exactly [block].
  final ui.Image image;

  /// Where those glyphs sit in the hero panel's coordinates. Measured against
  /// the panel rather than the screen so that travelling does not change it —
  /// the camera offset is applied in the shader, where it is one subtraction.
  final Rect block;
  final Size viewport;
  final double pixelRatio;
}

/// The current rasterisation, or null before the first layout.
final ValueNotifier<TypeGlyphs?> typeGlyphs = ValueNotifier<TypeGlyphs?>(null);

/// True once the glow can draw the statement itself.
///
/// Until then the `Text` widget paints normally, so the sentence is never
/// invisible — not while the shader loads, not if it fails to load at all.
final ValueNotifier<bool> typeGlowReady = ValueNotifier<bool>(false);

/// Wraps the statement: lays out the mask exactly as the text is laid out, and
/// hides the text once the glow is drawing it.
class TypeMaskCapture extends StatefulWidget {
  const TypeMaskCapture({
    required this.panel,
    required this.text,
    required this.style,
    required this.maxWidth,
    required this.builder,
    super.key,
  });

  /// The hero panel, which the block's position is measured against.
  final GlobalKey panel;

  /// Exactly what the visible text is given. Any divergence here is a
  /// divergence between the colour and the letters.
  final String text;
  final TextStyle style;
  final double maxWidth;

  /// Builds the text. `visible` is false once the glow has taken over drawing
  /// it, at which point the widget should paint nothing while still laying out
  /// and still carrying its semantics.
  final Widget Function(BuildContext context, {required bool visible}) builder;

  @override
  State<TypeMaskCapture> createState() => _TypeMaskCaptureState();
}

class _TypeMaskCaptureState extends State<TypeMaskCapture> {
  final GlobalKey _block = GlobalKey();
  Size? _lastViewport;
  Offset? _lastOrigin;
  TextStyle? _lastStyle;
  double? _lastRatio;

  void _rebuild() {
    if (!mounted) return;
    final block = _block.currentContext?.findRenderObject();
    final panel = widget.panel.currentContext?.findRenderObject();
    if (block is! RenderBox || panel is! RenderBox) return;
    if (!block.hasSize || !panel.hasSize) return;

    final viewport = MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final origin = panel.globalToLocal(block.localToGlobal(Offset.zero));
    if (viewport == _lastViewport &&
        origin == _lastOrigin &&
        widget.style == _lastStyle &&
        ratio == _lastRatio) {
      return;
    }
    if (viewport.isEmpty || block.size.isEmpty) return;
    _lastViewport = viewport;
    _lastOrigin = origin;
    _lastStyle = widget.style;
    _lastRatio = ratio;

    // ⚠️ THE STYLE PASSED IN IS NOT THE STYLE THE TEXT IS DRAWN WITH.
    //
    // A `Text` widget merges the ambient DefaultTextStyle into whatever style
    // it is given, then hands the result to a TextPainter along with the
    // textScaler, directionality, width basis and height behaviour it reads
    // from context. Feed a TextPainter only the explicit style and it lays the
    // same string out with slightly different metrics — close enough to look
    // right, wrong by pixels, which is exactly what this cannot afford. So the
    // same inputs are reconstructed here. Anything `Text` starts reading from
    // context in future has to be added to this list.
    final defaults = DefaultTextStyle.of(context);
    var effective = widget.style;
    if (effective.inherit) effective = defaults.style.merge(effective);

    final painter = TextPainter(
      text: TextSpan(
        // White: the rasterisation is a SHAPE. What colour the statement ends
        // up is decided per pixel by the shader.
        text: widget.text,
        style: effective.copyWith(color: const Color(0xFFFFFFFF)),
      ),
      textAlign: defaults.textAlign ?? TextAlign.start,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: defaults.maxLines,
      textWidthBasis: defaults.textWidthBasis,
      textHeightBehavior:
          defaults.textHeightBehavior ??
          DefaultTextHeightBehavior.maybeOf(context),
    )..layout(maxWidth: widget.maxWidth);

    // The painter's own height, not the render object's. The letterforms hang
    // BELOW their line box — the display style sets a line height of 1.02
    // while Roboto's ink is about 1.17 em tall — so every descender lives
    // outside the widget's box. Sizing to the box is what cut the bottom off
    // every p and y in a dead straight line.
    final block2 = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      block.size.width,
      painter.height,
    );

    // Snapped to the pixel grid so one image pixel is one screen pixel: the
    // block's origin is fractional, falling out of a font-size search and a
    // bottom alignment, and drawing an integer-sized image into a fractional
    // rectangle resamples the whole thing by a fraction of a pixel.
    final area = Rect.fromLTRB(
      block2.left.floorToDouble(),
      block2.top.floorToDouble(),
      block2.right.ceilToDouble(),
      block2.bottom.ceilToDouble(),
    );

    final width = (area.width * ratio).round();
    final height = (area.height * ratio).round();
    if (width <= 0 || height <= 0) {
      painter.dispose();
      return;
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    painter
      ..paint(canvas, origin - area.topLeft)
      ..dispose();

    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    picture.dispose();

    typeGlyphs.value?.image.dispose();
    typeGlyphs.value = TypeGlyphs(
      image: image,
      block: area,
      viewport: viewport,
      pixelRatio: ratio,
    );
  }

  @override
  Widget build(BuildContext context) {
    // After layout — the render object has no size or position until then.
    WidgetsBinding.instance.addPostFrameCallback((_) => _rebuild());
    return ValueListenableBuilder<bool>(
      valueListenable: typeGlowReady,
      builder: (context, ready, _) => ValueListenableBuilder<TypeGlyphs?>(
        valueListenable: typeGlyphs,
        builder: (context, glyphs, _) => KeyedSubtree(
          key: _block,
          child: widget.builder(
            context,
            visible: !(ready && glyphs != null),
          ),
        ),
      ),
    );
  }
}

/// Draws the statement, coloured by the energy that reaches it.
class TypeGlow extends StatefulWidget {
  const TypeGlow({required this.camera, super.key});

  /// The camera's position in locations, so the colour travels with the panel.
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
    final program = await ui.FragmentProgram.fromAsset(
      'shaders/type_glow.frag',
    );
    if (!mounted) return;
    setState(() => _shader = program.fragmentShader());
    typeGlowReady.value = true;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _shader?.dispose();
    typeGlowReady.value = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (shader == null) return const SizedBox.shrink();
    return ValueListenableBuilder<TypeGlyphs?>(
      valueListenable: typeGlyphs,
      builder: (context, glyphs, _) => glyphs == null
          ? const SizedBox.shrink()
          : IgnorePointer(
              child: CustomPaint(
                painter: _GlowPainter(
                  shader: shader,
                  glyphs: glyphs,
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
    required this.glyphs,
    required this.time,
    required this.camera,
  });

  final ui.FragmentShader shader;
  final TypeGlyphs glyphs;
  final double time;
  final double camera;

  /// Renders the shader into its own buffer.
  ///
  /// Through an offscreen picture rather than straight onto the canvas inside
  /// a saveLayer, because FlutterFragCoord is the position in the CURRENT
  /// render target — inside a layer it would be relative to that layer, which
  /// is not something to guess at. Here the buffer's size and origin are both
  /// known and passed in.
  ui.Image _render(Size buffer, Rect area, double mode) {
    shader
      ..setFloat(0, buffer.width)
      ..setFloat(1, buffer.height)
      ..setFloat(2, area.left)
      ..setFloat(3, area.top)
      ..setFloat(4, glyphs.viewport.width)
      ..setFloat(5, glyphs.viewport.height)
      ..setFloat(6, glyphs.pixelRatio)
      ..setFloat(7, time)
      ..setFloat(8, camera)
      ..setFloat(9, kGlowGain)
      ..setFloat(10, kGlowKnee)
      ..setFloat(11, mode);

    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(Offset.zero & buffer, Paint()..shader = shader);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      buffer.width.toInt(),
      buffer.height.toInt(),
    );
    picture.dispose();
    return image;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final area = glyphs.block;
    if (area.isEmpty) return;

    final buffer = Size(
      (area.width * glyphs.pixelRatio).roundToDouble(),
      (area.height * glyphs.pixelRatio).roundToDouble(),
    );
    if (buffer.isEmpty) return;

    final src = Offset.zero & buffer;
    final glyphSrc = Offset.zero &
        Size(glyphs.image.width.toDouble(), glyphs.image.height.toDouble());
    // Panel coordinates back to screen: the panel travels one viewport width
    // per location.
    final dst = area.translate(-camera * glyphs.viewport.width, 0);

    // ── The spill, first and underneath ─────────────────────────────────────
    //
    // Additive, because outside a letter there is only dark panel and light in
    // the air adds. Only the driven parts of a word contribute, so a word at
    // rest throws nothing.
    final sigma = size.height * kGlowBloom;
    if (sigma > 0.01) {
      final bloom = _render(buffer, area, 1);
      canvas
        ..saveLayer(
          dst.inflate(sigma * 4),
          Paint()
            ..blendMode = BlendMode.plus
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
        )
        ..drawImageRect(bloom, src, dst, Paint()..isAntiAlias = false)
        // Kept only where the glyphs are — the same single rasterisation.
        ..drawImageRect(
          glyphs.image,
          glyphSrc,
          dst,
          Paint()
            ..blendMode = BlendMode.dstIn
            ..isAntiAlias = false,
        )
        ..restore();
      bloom.dispose();
    }

    // ── The statement itself ────────────────────────────────────────────────
    //
    // Colour everywhere, then cut to the glyph coverage, then composited once.
    // The letters' edges are the rasterisation's own edges because there is
    // only one rasterisation — nothing here can disagree with anything.
    // ⚠️ ANTIALIASING OFF ON BOTH DRAWS, and it is not an optimisation.
    //
    // drawImageRect antialiases the RECTANGLE's own boundary. The first draw
    // fills the block with opaque colour; the second cuts it down to the glyph
    // coverage with dstIn — but on the outermost row of pixels that cut is
    // only partially applied, because the cutting rectangle's edge is itself
    // antialiased. What survives is a one-pixel ring of uncut colour: a frame
    // drawn neatly around the statement.
    //
    // Both rectangles are already snapped to whole pixels, so there is nothing
    // for antialiasing to do here except cause exactly this.
    final colour = _render(buffer, area, 0);
    canvas
      ..saveLayer(dst, Paint())
      ..drawImageRect(
        colour,
        src,
        dst,
        Paint()
          ..filterQuality = FilterQuality.none
          ..isAntiAlias = false,
      )
      ..drawImageRect(
        glyphs.image,
        glyphSrc,
        dst,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..filterQuality = FilterQuality.none
          ..isAntiAlias = false,
      )
      ..restore();
    colour.dispose();
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.time != time || old.camera != camera || old.glyphs != glyphs;
}
