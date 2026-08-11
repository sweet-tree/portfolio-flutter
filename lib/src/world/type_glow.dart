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
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/query_params.dart';
import 'package:portfolio/src/world/shaders.dart';

// ── The dials ───────────────────────────────────────────────────────────────

/// How quickly a letter turns as energy lands on it.
///
/// NEUTRAL. At 1 the letters show the fog at exactly the strength it has on
/// the glass — no amplification, nothing added. The machinery is still here
/// and still wired up, because turning a letter into an amplifier is a real
/// thing to want; it is just not what is wanted now.
const double kGlowGain = 1;

/// How much energy has to land before a letter reacts at all.
///
/// NEUTRAL, for the same reason. At 0 the faintest fog already tints the type,
/// which is what "the same fog, on the letters" means. Raise it and the type
/// ignores everything below the threshold, which is what turns a wash into a
/// flare.
const double kGlowKnee = 0;

/// How far the light spills into the air around a word, as a fraction of the
/// viewport's height. 0 turns the spill off entirely.
///
/// `?bloom=0` to switch it off — the fastest way to find out whether a
/// softness or a blockiness around the letters is the spill or the type.
final double kGlowBloom = qDouble('bloom', 0.0025).clamp(0, 0.05);

/// How much of the spill is kept.
///
/// Low. At full strength every letter carries a visible halo, which reads as
/// the type being soft — and softness is the one thing this whole layer was
/// built to avoid. The spill should be noticed only where the energy is
/// strong, not as a permanent glow around the sentence.
const double kGlowBloomStrength = 0.3;

/// Resolution the COLOUR is computed at, as a fraction of a logical pixel.
///
/// ⚠️ THIS WAS THE DEVICE PIXEL RATIO AND IT COST THE PHONES EVERYTHING.
/// Rendering the colour at 2x on an iPhone 11 and 3x on a 13 Pro means four
/// and nine times the pixels of the layout — twice per frame, since the bloom
/// source is its own pass — plus a blur over an area that size. It was more
/// fill rate than the entire scene shader, and it took the 11 to 17 FPS.
///
/// The MASK is what carries the edges, and it is always at full device
/// resolution, so the letters' outlines stay sharp whatever this is set to.
///
/// ⚠️ BUT "THE COLOUR HAS NO DETAIL IN IT" IS ONLY TRUE FOR THIN TYPE, and
/// that is what this originally assumed. 0.4 of a logical pixel is one colour
/// sample per seven device pixels on a 3x phone. A hairline stroke is narrower
/// than that, so it takes a single colour and the coarseness cannot be seen —
/// which is why this was invisible with Archivo and Cinzel. Lora's strokes are
/// the fattest tested, and at a heavier weight they are fatter still: wide
/// enough to show the colour buffer's own blocks INSIDE a letter. The
/// pixellation is ours, not the typeface's.
///
/// Overridable as `?cs=` so the cost of fixing it can be measured on a real
/// phone rather than argued about — this is the one knob that took an iPhone
/// 11 to 17 FPS, so it is not free.
final double kColourScale = qDouble('cs', 0.4).clamp(0.1, 3.0);

/// The bloom source is blurred immediately afterwards, so it can be coarser
/// still. Resolution spent here is thrown away by the blur by definition.
///
/// ⚠️ THAT IS ONLY TRUE WHILE THE BLUR IS WIDER THAN THE SAMPLING, and here it
/// is not. 0.22 of a logical pixel puts one sample every ~4.5 logical pixels,
/// while the blur's sigma is about 2 — so the buffer's own blocks are LARGER
/// than the smoothing meant to hide them, and the halo can read as blocky
/// rather than soft. Heavier type throws more spill, which is why it shows up
/// at high weights first.
///
/// `?bscale=` to test the cost of fixing it on a real device.
final double kBloomScale = qDouble('bscale', 0.22).clamp(0.05, 2.0);

/// `?glow=0` — draws no colour on the statement, leaving it as plain ink.
///
/// ⚠️ A PROFILING SWITCH IN THE FAMILY OF `?off=`, and it earned its keep the
/// day it was added. The page costs 13.3 ms of GPU a frame and the whole 3D
/// scene is only 6.0 of it — so half the frame is "everything else", which is
/// the statement's colour AND the panels AND the rail AND the navigation.
/// Deducing which by switching off the parts I could already reach had been
/// wrong three times running. With this, one number settled it: `?glow=0` and
/// `?bare=1` measure the SAME, so the panels, the rail, the nav and the hero's
/// own text cost nothing measurable, and the statement's colour is 6.1 ms.
///
/// ⚠️ AND WHAT IT LED TO: the rectangle that colour is drawn into measures
/// 2581 x 1491 device pixels — FOUR FIFTHS OF THE SCREEN — while its ink covers
/// of it. Cost is proportional to that rectangle (measured: halving it saved
/// 3.3 ms), so roughly 70% of the statement's cost is spent on empty space.
///
/// It is not a fallback and not a style — with it off the sentence is flat ink
/// and the whole idea of the page is missing.
final bool kGlowOn = qDouble('glow', 1) > 0.5;

/// `?wordbox=1` — outlines the payoff word's rectangle so it can be looked at.
///
/// ⚠️ IT EXISTS TO BE RESIZED AGAINST. The statement re-breaks per frame shape,
/// so a rectangle that fits on one screen proves nothing; the only honest check
/// is dragging the window and watching it stay on the word. A number in a log
/// cannot answer that and neither can one screenshot.
///
/// Red is the word. Blue is the whole statement's rectangle, for scale.
final bool kWordBox = qDouble('wordbox', 0) > 0.5;

/// `?word=1` — puts the energy on the PAYOFF WORD only; the rest is plain ink.
///
/// ⚠️ TWO THINGS AT ONCE, WHICH IS WHY IT IS WORTH HAVING. Cost in this layer
/// is proportional to the rectangle the effect is drawn into — measured,
/// shrinking it saved 3.3 ms of a 13.3 ms frame — and the payoff word is a
/// fraction of the sentence. It is also the shape the design is heading for:
/// the energy is meant to CHANGE as it crosses the statement rather than wash
/// evenly over all of it, arriving at the word the claim is for.
///
/// ⚠️ THE REST OF THE SENTENCE IS STILL DRAWN FROM THE SAME RASTERISATION, in
/// one flat pass. Handing it back to Flutter's own Text would be the obvious
/// shortcut and would undo the design of this whole file: two rasterisations
/// of one layout share glyph positions but not antialiasing coverage, and the
/// rim artefacts that follow have no setting that fixes them.
///
/// Four settings, because there are four questions being asked of it:
///
///   ?word=0     the whole sentence lit — how it was until 2026-08-10
///   ?word=1     the words the COPY names, in locations.dart
///   ?word=a,b   those words instead, whatever they are
///   (absent)    THE DEFAULT, and it is the copy's list
///
/// ⚠️ THE COPY'S LIST IS THE DEFAULT AS OF 2026-08-10 — his call, made on the
/// running page. The whole sentence taking the energy evenly was never the
/// intention; it was what existed before anything could point at a word.
/// `?word=0` keeps it reachable, and that is worth having: it is the fastest
/// way to see what the accent is doing, by taking it away.
///
/// ⚠️ THE LAST FORM EXISTS SO WHICH WORDS CAN BE TRIED WITHOUT A REBUILD.
/// Which part of a sentence should carry the energy is a judgement about the
/// sentence, and it is made by looking — `?word=raw data,pixel` against
/// `?word=pixel` is one refresh; editing the copy is a rebuild each time.
/// Spaces are allowed inside an entry; commas separate them.
final String _wordArg = qString('word', '1');
final bool kWordOnly = _wordArg.isNotEmpty && _wordArg != '0';

/// Words named on the URL, which stand in for the copy's own list.
final List<String> kWordOverride = (_wordArg == '1' || !kWordOnly)
    ? const []
    : _wordArg
          .split(',')
          .map((w) => w.trim())
          .where((w) => w.isNotEmpty)
          .toList();

/// The statement, rasterised once. Alpha is the glyph coverage — the real one,
/// the only one — and there is no second rasterisation anywhere.
@immutable
class TypeGlyphs {
  const TypeGlyphs({
    required this.image,
    required this.block,
    required this.payoff,
    required this.viewport,
    required this.pixelRatio,
  });

  /// White glyphs on transparent, at [pixelRatio] device pixels per logical
  /// pixel, covering exactly [block].
  final ui.Image image;

  /// Where those glyphs sit in the hero panel's coordinates.
  final Rect block;

  /// Where the named words sit, in the SAME coordinates as [block]. Empty when
  /// the copy names none, or when none of them is in the sentence.
  ///
  /// ⚠️ THEY COME FROM THE LAYOUT, NOT FROM MEASURING THE SCREEN. The statement
  /// is set to a different arrangement on every frame shape — two lines wide,
  /// four narrow — so any rectangle worked out from sizes and offsets is a
  /// rectangle for one screen. The text layout already knows where every
  /// character landed; asking it which boxes a range of characters occupies is
  /// automatically right at any size, any wrap, any font.
  ///
  /// One entry per line fragment, in reading order, so a phrase broken across
  /// two lines is two rectangles rather than one box spanning the gap between
  /// them — that gap belongs to other words.
  final List<Rect> payoff;
  final Size viewport;
  final double pixelRatio;
}

/// One statement's rasterisation, owned by the statement it belongs to.
///
/// ⚠️ NOT A GLOBAL. It was, and the whole class of bug that followed came from
/// that: a mask left behind after its sentence was gone kept being drawn, so
/// the hero's statement painted over the next section; and clearing it meant
/// reaching into a notifier other statements might also be using, which needed
/// an identity check to be safe and a deferral to be legal.
///
/// Scoped, none of that exists. The mask is created with the statement and
/// disposed with it, by the same widget, in the ordinary way.
class StatementMask extends ChangeNotifier {
  TypeGlyphs? _glyphs;
  TypeGlyphs? get glyphs => _glyphs;

  set glyphs(TypeGlyphs? value) {
    if (identical(_glyphs, value)) return;
    _glyphs?.image.dispose();
    _glyphs = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _glyphs?.image.dispose();
    _glyphs = null;
    super.dispose();
  }
}

/// Hands the statement's mask to everything inside it.
class StatementScope extends StatefulWidget {
  const StatementScope({required this.child, super.key});

  final Widget child;

  static StatementMask of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_StatementScope>();
    assert(scope != null, 'No StatementScope above this widget.');
    return scope!.notifier!;
  }

  @override
  State<StatementScope> createState() => _StatementScopeState();
}

class _StatementScopeState extends State<StatementScope> {
  final StatementMask _mask = StatementMask();

  @override
  void dispose() {
    _mask.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _StatementScope(notifier: _mask, child: widget.child);
}

class _StatementScope extends InheritedNotifier<StatementMask> {
  const _StatementScope({required super.notifier, required super.child});
}

/// Set once, when a statement has been rasterised for the first time.
///
/// ⚠️ THIS IS GENUINELY GLOBAL AND WRITE-ONCE, which is why it is safe where a
/// shared mask was not. It answers one question — has the page got something
/// complete to show yet — asked by main() while holding the first frame. It is
/// never cleared, so nothing can be torn down through it.
final ValueNotifier<bool> statementPainted = ValueNotifier<bool>(false);

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
    required this.payoff,
    required this.span,
    required this.signature,
    required this.maxWidth,
    required this.textAlign,
    required this.builder,
    super.key,
  });

  /// The hero panel, which the block's position is measured against.
  final GlobalKey panel;

  /// The words the sentence answers to, named by the copy. See
  /// Location.payoff — empty means the whole statement is one region.
  final List<String> payoff;

  /// Exactly what the visible text is given. Any divergence here is a
  /// divergence between the colour and the letters.
  ///
  /// A SPAN, not a string with a style: the statement is set with a different
  /// size per line, so it is one paragraph carrying several styles, and a
  /// single style could not describe it.
  final TextSpan span;
  final double maxWidth;
  final TextAlign textAlign;

  /// Changes whenever the setting does. Spans do not compare usefully and
  /// rebuilding the rasterisation every frame would be waste, so the caller
  /// hands over something cheap that identifies this particular setting.
  final Object signature;

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
  Object? _lastSignature;
  double? _lastRatio;

  @override
  void initState() {
    super.initState();
    // ⚠️ THE RASTERISATION IS OF WHATEVER FACE WAS LOADED AT THE TIME.
    //
    // The bundled faces arrive asynchronously, so a capture taken before
    // Archivo lands is a picture of the fallback — right size, wrong glyphs —
    // and the caller's signature need not change when the real face arrives,
    // so nothing would ever ask for a new one. This forces it.
    PaintingBinding.instance.systemFonts.addListener(_onFontsChanged);
  }

  /// The mask this statement writes into. Owned by [StatementScope], created
  /// with the statement and disposed with it — so nothing here has to reach
  /// into shared state, check whether what it finds is its own, or clean up
  /// after itself on the way out.
  StatementMask get _mask => StatementScope.of(context);

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_onFontsChanged);
    super.dispose();
  }

  void _onFontsChanged() {
    _lastSignature = null;
    // After the frame that re-lays the text out with the new face, not this
    // one — the render object is still carrying the old layout right now.
    WidgetsBinding.instance.addPostFrameCallback((_) => _rebuild());
  }

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
        widget.signature == _lastSignature &&
        ratio == _lastRatio) {
      return;
    }
    if (viewport.isEmpty || block.size.isEmpty) return;
    _lastViewport = viewport;
    _lastOrigin = origin;
    _lastSignature = widget.signature;
    _lastRatio = ratio;

    // ⚠️ THE SPAN PASSED IN IS NOT WHAT THE TEXT IS DRAWN FROM.
    //
    // `Text.rich` wraps the span in the ambient DefaultTextStyle and hands the
    // result to a TextPainter along with the textScaler, directionality, width
    // basis and height behaviour it reads from context. Give a bare
    // TextPainter only the explicit span and it lays the same statement out
    // with slightly different metrics — close enough to look right, wrong by
    // pixels, which is exactly what this cannot afford. So the same inputs are
    // reconstructed here. Anything `Text` starts reading from context in
    // future has to be added to this list.
    final defaults = DefaultTextStyle.of(context);

    final painter = TextPainter(
      // The span is already white: the rasterisation is a SHAPE, and what
      // colour the statement ends up is decided per pixel by the shader.
      text: TextSpan(style: defaults.style, children: [widget.span]),
      textAlign: widget.textAlign,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: defaults.maxLines,
      textWidthBasis: defaults.textWidthBasis,
      textHeightBehavior:
          defaults.textHeightBehavior ??
          DefaultTextHeightBehavior.maybeOf(context),
    )..layout(maxWidth: widget.maxWidth);

    // ⚠️ THE CAPTURE IS SIZED BY INK, NOT BY LAYOUT, and the difference is a
    // sliced-off descender.
    //
    // A line box is not a bounding box. The block is set with a leading of 0.92
    // — deliberately TIGHTER than the em, because display type set flush wants
    // to sit close — so the boxes overlap the ink by design and the last line's
    // descenders hang below the paragraph entirely. Sizing the capture to
    // `painter.height` therefore cuts every p, y and comma off in a dead
    // straight line. It survived three typefaces and failed on the fourth,
    // because how far a descender reaches is a property of the face: Lora's is
    // about 0.21em where the others were shallower.
    //
    // So the area is padded by half the tallest line box, which is more than
    // any Latin face's ink can escape by. The cost is a few transparent pixels
    // in the mask, which `dstIn` removes for free. Guessing the exact overhang
    // per face would be smaller and wrong the next time the face changes.
    final metrics = painter.computeLineMetrics();
    final tallest = metrics.isEmpty
        ? painter.height
        : metrics.map((m) => m.height).reduce(math.max);
    final padY = tallest * 0.5;
    // Sideways too, though by less: side bearings and the odd overhanging
    // terminal put ink a little outside the advance width.
    final padX = tallest * 0.1;

    // Snapped to the pixel grid so one image pixel is one screen pixel: the
    // block's origin is fractional, falling out of a font-size search and a
    // bottom alignment, and drawing an integer-sized image into a fractional
    // rectangle resamples the whole thing by a fraction of a pixel.
    final area = Rect.fromLTRB(
      (origin.dx - padX).floorToDouble(),
      (origin.dy - padY).floorToDouble(),
      (origin.dx + block.size.width + padX).ceilToDouble(),
      (origin.dy + painter.height + padY).ceilToDouble(),
    );

    final width = (area.width * ratio).round();
    final height = (area.height * ratio).round();
    if (width <= 0 || height <= 0) {
      painter.dispose();
      return;
    }

    // ⚠️ ASKED OF THE LAYOUT, AND OF THIS ONE. It has to be the same painter
    // that rasterises the mask below — same span, same measure, same scaler —
    // or the rectangle describes a sentence that is not on screen. This file
    // already learned that for the mask itself: a text laid out from "the same"
    // inputs, reconstructed separately, is right by eye and wrong by pixels.
    //
    // Taken BEFORE the painter is disposed, which is why it sits here.
    final payoffAreas = _payoffRects(painter, origin, area);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    painter
      ..paint(canvas, origin - area.topLeft)
      ..dispose();

    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    picture.dispose();

    // The mask disposes whatever it held; it owns these images.
    _mask.glyphs = TypeGlyphs(
      image: image,
      block: area,
      payoff: payoffAreas,
      viewport: viewport,
      pixelRatio: ratio,
    );
    statementPainted.value = true;
  }

  /// Where each named word landed, in the panel's coordinates and in reading
  /// order. Empty when the copy names none or the sentence contains none.
  List<Rect> _payoffRects(TextPainter painter, Offset origin, Rect area) {
    // The URL's list stands in for the copy's when one is given — see
    // kWordOverride. The copy stays the default so a plain load is the design.
    final words = kWordOverride.isNotEmpty ? kWordOverride : widget.payoff;
    if (words.isEmpty) return const [];

    final plain = painter.plainText;
    final metrics = painter.computeLineMetrics();
    final found = <Rect>[];

    for (final word in words) {
      if (word.trim().isEmpty) continue;
      // ⚠️ ON WORD BOUNDARIES, AND EVERY OCCURRENCE. "pixel" is a stem — it
      // sits inside "pixels" — and a substring match would put the accent on a
      // fragment of another word. Every occurrence, because a word repeated in
      // the sentence is repeated on purpose.
      //
      // ⚠️ AND SPACES ARE LOOSE, so a phrase still matches when the layout
      // broke it across a line: the newline the setting inserts stands where
      // the author wrote a space.
      final pattern = RegExp.escape(word.trim()).replaceAll(r'\ ', r'\s+');
      for (final hit in RegExp(
        '\\b$pattern\\b',
        caseSensitive: false,
      ).allMatches(plain)) {
        // ⚠️ ONE RECTANGLE PER LINE FRAGMENT, NOT ONE BOX AROUND THEM ALL. A
        // phrase that straddles a break comes back as a piece per line, and
        // their union would swallow the whole width between — which is other
        // words. Keeping them apart is also what lets each be padded against
        // its own line's metrics below.
        for (final box in painter.getBoxesForSelection(
          TextSelection(baseOffset: hit.start, extentOffset: hit.end),
        )) {
          final rect = _padToLine(box.toRect(), metrics);
          final placed = rect.shift(origin).intersect(area);
          if (!placed.isEmpty) found.add(placed);
        }
      }
    }

    found.sort((a, b) {
      final byLine = a.top.compareTo(b.top);
      return byLine != 0 ? byLine : a.left.compareTo(b.left);
    });
    return found;
  }

  /// Grows a line fragment by what its own ink can escape by, and no further.
  ///
  /// ⚠️ THE BLOCK PADS BY HALF THE TALLEST LINE BOX, which is right for the
  /// outside of a paragraph and far too big for a word inside one. Leading
  /// here is 0.92 — tighter than the letters on purpose — so consecutive line
  /// boxes sit CLOSER together than the type is tall, and line two's box begins
  /// above where line one's letters end. Padding a word by what ink escapes
  /// therefore reaches into the line above and takes the underside of its
  /// letters with it. The wide arrangement hides that behind the part-gap; the
  /// narrow one, where lines are adjacent, shows it at once.
  ///
  /// So the padding is bounded by the neighbouring line boxes: it may spend
  /// whatever room exists at the top and bottom of the paragraph and none where
  /// another line is. There is no setting that gives both, and taking a
  /// neighbour's ink is the worse of the two — a rectangle that means "this
  /// word" must not contain another one.
  Rect _padToLine(Rect box, List<LineMetrics> metrics) {
    var pad = box.height * 0.12;
    var ceiling = double.negativeInfinity;
    var floor = double.infinity;
    for (var i = 0; i < metrics.length; i++) {
      final m = metrics[i];
      final top = m.baseline - m.ascent;
      if (box.center.dy < top || box.center.dy > top + m.height) continue;
      // What the line box does NOT cover of its own em, halved so it is shared
      // between the top and the bottom.
      pad = math.max(0, (m.ascent + m.descent) - m.height) * 0.5;
      if (i > 0) {
        final above = metrics[i - 1];
        ceiling = above.baseline - above.ascent + above.height;
      }
      if (i < metrics.length - 1) {
        final below = metrics[i + 1];
        floor = below.baseline - below.ascent;
      }
      break;
    }
    return Rect.fromLTRB(
      (box.left - pad).floorToDouble(),
      math.max(box.top - pad, ceiling).floorToDouble(),
      (box.right + pad).ceilToDouble(),
      math.min(box.bottom + pad, floor).ceilToDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    // After layout — the render object has no size or position until then.
    WidgetsBinding.instance.addPostFrameCallback((_) => _rebuild());
    final mask = StatementScope.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: typeGlowReady,
      builder: (context, ready, _) => AnimatedBuilder(
        animation: mask,
        builder: (context, _) => KeyedSubtree(
          key: _block,
          child: widget.builder(
            context,
            visible: !(ready && mask.glyphs != null),
          ),
        ),
      ),
    );
  }
}

/// Draws the statement, coloured by the energy that reaches it.
class TypeGlow extends StatefulWidget {
  const TypeGlow({super.key});

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
    // ⚠️ SYNCHRONOUS, and that is what stops the statement being drawn twice.
    //
    // Loading the program here would mean the first frames had no glow, so
    // Flutter drew the letters as plain ink and the glow replaced them a
    // moment later — one visible change per page load. The program is resolved
    // before the first frame now (see [Shaders]), so the statement's first
    // appearance is already its final one.
    _shader = Shaders.typeGlow?.fragmentShader();
    typeGlowReady.value = _shader != null;
    _ticker = createTicker((elapsed) {
      setState(() => _time = elapsed.inMicroseconds / 1e6);
    });
    unawaited(_ticker.start());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _followRoute(ModalRoute.of(context));
  }

  ModalRoute<dynamic>? _route;

  /// ⚠️ A SECTION ON ITS WAY OUT DOES NOT NEED TO KEEP ANIMATING, and this is
  /// the most expensive layer on the site: the statement's colour is computed
  /// per pixel every frame and measured at roughly half a frame on a desktop.
  ///
  /// While a swipe carries the hero away, the hero and the section arriving are
  /// both live, and the hero was still paying that every frame — on the one
  /// gesture that can least afford it, because slow frames mean few pointer
  /// samples, a poor velocity estimate and a swipe that feels stuck. Leaving
  /// home was noticeably heavier than moving between two cards, which cost
  /// nothing like it.
  ///
  /// So the energy runs while the statement is the section you are on, and
  /// holds still while it is leaving. It is moving across the screen at the
  /// time; nobody is reading the flow in it.
  void _followRoute(ModalRoute<dynamic>? route) {
    if (identical(route, _route)) return;
    _route?.animation?.removeListener(_onRouteMoved);
    _route = route;
    _route?.animation?.addListener(_onRouteMoved);
    _onRouteMoved();
  }

  void _onRouteMoved() {
    final showing = _route?.isCurrent ?? true;
    if (showing == _ticker.isActive) return;
    if (showing) {
      unawaited(_ticker.start());
    } else {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _route?.animation?.removeListener(_onRouteMoved);
    _ticker.dispose();
    _shader?.dispose();
    typeGlowReady.value = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (shader == null) return const SizedBox.shrink();
    final mask = StatementScope.of(context);
    return AnimatedBuilder(
      animation: mask,
      builder: (context, _) {
        final glyphs = mask.glyphs;
        if (glyphs == null) return const SizedBox.shrink();
        return IgnorePointer(
          child: CustomPaint(
            painter: _GlowPainter(shader: shader, glyphs: glyphs, time: _time),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

class _GlowPainter extends CustomPainter {
  const _GlowPainter({
    required this.shader,
    required this.glyphs,
    required this.time,
  });

  final ui.FragmentShader shader;
  final TypeGlyphs glyphs;
  final double time;

  /// Renders the shader into its own buffer.
  ///
  /// Through an offscreen picture rather than straight onto the canvas inside
  /// a saveLayer, because FlutterFragCoord is the position in the CURRENT
  /// render target — inside a layer it would be relative to that layer, which
  /// is not something to guess at. Here the buffer's size and origin are both
  /// known and passed in.
  ui.Image _render(Size buffer, Rect area, double scale, double mode) {
    shader
      ..setFloat(0, buffer.width)
      ..setFloat(1, buffer.height)
      ..setFloat(2, area.left)
      ..setFloat(3, area.top)
      ..setFloat(4, glyphs.viewport.width)
      ..setFloat(5, glyphs.viewport.height)
      // Buffer pixels per logical pixel — NOT the device ratio. The shader
      // works in the layout's coordinates and divides this out; what it must
      // be told is how this particular buffer relates to them.
      ..setFloat(6, scale)
      ..setFloat(7, time)
      // uCamera. Zero, and the uniform stays DECLARED in the .frag: indices
      // follow declaration order including uniforms nothing reads, so deleting
      // it would silently shift every index after it.
      ..setFloat(8, 0)
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
    if (area.isEmpty || !kGlowOn) return;

    final glyphSize =
        Size(glyphs.image.width.toDouble(), glyphs.image.height.toDouble());

    // ⚠️ WHICH RECTANGLES THE EFFECT COVERS. The whole statement is the default
    // and is simply the one-region case — the sentence does not divide into a
    // special word and the rest, so the general shape is a LIST of regions and
    // "all of it" is a list of one. `?word=1` switches to the words the copy
    // names; `?word=raw data,pixel` names them from the URL instead.
    //
    // It is also the largest saving available to this layer: cost here is
    // proportional to the rectangle drawn into — measured, shrinking it saved
    // 3.3 ms of a 13.3 ms frame — and the named words are a fraction of the
    // sentence.
    final regions = _regions(area);
    final wholeStatement = regions.length == 1 && regions.first == area;

    if (kWordBox) {
      _outline(canvas, area);
    }

    // ⚠️ THE REST OF THE SENTENCE IS DRAWN FROM THE SAME RASTERISATION, in one
    // flat pass, whenever the effect does not cover all of it. Handing the
    // untouched part back to Flutter's own Text is the obvious shortcut and
    // would undo the design of this whole file: two rasterisations of one
    // layout share glyph positions but not antialiasing coverage, and the rim
    // artefacts that follow have no setting that fixes them.
    //
    // One textured draw and no layer — the image is white with the coverage in
    // its alpha, so a srcIn filter colours it without touching that edge.
    //
    // ⚠️ AND THE ACCENTED REGIONS ARE CLIPPED OUT OF IT, which is not tidiness.
    // Drawn underneath and painted over, every letter in an accented word would
    // be composited TWICE: the energy arrives with the glyph coverage as its
    // alpha, so at an antialiased edge — where coverage is a fraction — the ink
    // beneath shows through it. The edge comes out heavier than either draw
    // intends, which reads as the word being soft and slightly doubled. He saw
    // it immediately: "pixel" went blurry the moment it stopped being lit like
    // the rest of the sentence.
    if (!wholeStatement) {
      canvas.save();
      for (final region in regions) {
        canvas.clipRect(region, clipOp: ui.ClipOp.difference);
      }
      canvas
        ..drawImageRect(
          glyphs.image,
          Offset.zero & glyphSize,
          area,
          Paint()
            ..colorFilter = const ui.ColorFilter.mode(
              Palette.ink,
              BlendMode.srcIn,
            )
            ..filterQuality = FilterQuality.none
            ..isAntiAlias = false,
        )
        ..restore();
    }

    for (final region in regions) {
      _drawRegion(canvas, region, area, size.height);
    }
  }

  /// The rectangles the energy is drawn into, in reading order.
  List<Rect> _regions(Rect area) {
    if (!kWordOnly || glyphs.payoff.isEmpty) return [area];
    return glyphs.payoff;
  }

  /// The diagnostic outlines — `?wordbox=1`.
  ///
  /// ⚠️ UNDER THE LETTERS, NOT OVER THEM, so the sentence stays readable while
  /// the rectangles are being judged against it. Blue is the whole statement,
  /// red is each named word.
  void _outline(Canvas canvas, Rect area) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(area, stroke..color = const Color(0xFF3D7BFF));
    for (final r in glyphs.payoff) {
      canvas.drawRect(r, stroke..color = const Color(0xFFFF3B30));
    }
  }

  /// One region: its spill, then its letters.
  void _drawRegion(
    Canvas canvas,
    Rect region,
    Rect area,
    double viewportHeight,
  ) {
    // The part of the rasterisation lying under this region.
    //
    // ⚠️ SCALED BY THE IMAGE'S OWN SIZE OVER THE BLOCK'S, NOT BY THE PIXEL
    // RATIO. The capture ROUNDS its dimensions to whole device pixels, so the
    // mask is up to half a pixel off the block times the ratio — and using the
    // ratio asks for a source rectangle slightly wider than the image really
    // is. Drawn into a destination of the true size, that is a fractional
    // RESAMPLE of the whole mask, and it softens every letter in the sentence.
    // It cost the statement its edges for an hour, and he caught it at
    // `?word=0`, where the error lands on all of the type at once.
    //
    // The image's own dimensions over the block's are the exact scale between
    // the two spaces, by definition. For the whole block this returns precisely
    // the whole image, which is what it used to be handed literally.
    final sx = glyphs.image.width / area.width;
    final sy = glyphs.image.height / area.height;

    // ⚠️ AND SNAPPED TO WHOLE TEXELS, with everything else derived from the
    // snapped rectangle. A crop landing between texels is resampled by that
    // fraction — the same fault again, confined to one word. Rounding the
    // SOURCE and deriving the destination from it keeps the two exactly
    // proportional; the cost is the region's boundary moving by under a pixel,
    // which nothing can see because the boundary is never drawn.
    final glyphSrc = Rect.fromLTRB(
      ((region.left - area.left) * sx).roundToDouble(),
      ((region.top - area.top) * sy).roundToDouble(),
      ((region.right - area.left) * sx).roundToDouble(),
      ((region.bottom - area.top) * sy).roundToDouble(),
    );
    final snapped = Rect.fromLTRB(
      area.left + glyphSrc.left / sx,
      area.top + glyphSrc.top / sy,
      area.left + glyphSrc.right / sx,
      area.top + glyphSrc.bottom / sy,
    );
    final dst = snapped;

    // ⚠️ SIZED IN LOGICAL PIXELS, NOT DEVICE PIXELS. See kColourScale — these
    // hold a smooth gradient, and the sharpness of the result comes entirely
    // from the glyph image, which IS at device resolution. Sized against the
    // SNAPPED rectangle, because that is the one being drawn into.
    Size bufferFor(double scale) => Size(
      (snapped.width * scale).roundToDouble().clamp(1, double.infinity),
      (snapped.height * scale).roundToDouble().clamp(1, double.infinity),
    );

    final colourBuffer = bufferFor(kColourScale);
    final bloomBuffer = bufferFor(kBloomScale);

    // ── The spill, first and underneath ─────────────────────────────────────
    //
    // Additive, because outside a letter there is only dark panel and light in
    // the air adds. Only the driven parts of a word contribute, so a word at
    // rest throws nothing.
    final sigma = viewportHeight * kGlowBloom;
    if (sigma > 0.01) {
      final bloom = _render(bloomBuffer, snapped, kBloomScale, 1);
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
        ..drawImageRect(
          bloom,
          Offset.zero & bloomBuffer,
          dst,
          // Bilinear on the way up: this is a coarse buffer being enlarged,
          // and it is about to be blurred anyway.
          Paint()
            ..filterQuality = FilterQuality.low
            ..isAntiAlias = false,
        )
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

    // ── The letters ─────────────────────────────────────────────────────────
    //
    // Colour everywhere, then cut to the glyph coverage, then composited once.
    // The letters' edges are the rasterisation's own edges because there is
    // only one rasterisation — nothing here can disagree with anything.
    //
    // ⚠️ ANTIALIASING OFF ON BOTH DRAWS, and it is not an optimisation.
    // drawImageRect antialiases the RECTANGLE's own boundary. The first draw
    // fills with opaque colour; the second cuts it down to the glyph coverage
    // with dstIn — but on the outermost row of pixels that cut is only
    // partially applied, because the cutting rectangle's edge is itself
    // antialiased. What survives is a one-pixel ring of uncut colour: a frame
    // drawn neatly around the statement. Every rectangle here is already
    // snapped to whole pixels, so there is nothing else for it to do.
    final colour = _render(colourBuffer, snapped, kColourScale, 0);
    canvas
      ..saveLayer(dst, Paint())
      ..drawImageRect(
        colour,
        Offset.zero & colourBuffer,
        dst,
        // Bilinear, because this buffer is smaller than the region and is being
        // enlarged. Safe: it holds a smooth gradient with no edges in it, and
        // the frame this used to cause came from the RECTANGLE's antialiasing,
        // which is off, not from the image filtering.
        Paint()
          ..filterQuality = FilterQuality.low
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
      old.time != time || old.glyphs != glyphs;
}
