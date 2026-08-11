/// The hero — the first location, and the only one composed by hand.
///
/// It is a FRAMED COMPOSITION, not a stack of centred text. Everything aligns
/// to one margin, the periphery carries the small information, and the middle
/// is left to the one dominant mass. That division is most of the difference
/// between a hero that reads as designed and one that reads as a web page with
/// a big title on it.
///
/// Two holes are deliberate and both are their own step:
///   · the shader, which fills the open area above the name
///   · the typeface — this is still Flutter's fallback Roboto
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:portfolio/src/chrome/nav.dart' show kNavHeight;
import 'package:portfolio/src/chrome/rail.dart' show railHeightOf;
import 'package:portfolio/src/design/layout.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/design/type.dart';
import 'package:portfolio/src/world/locations.dart';
import 'package:portfolio/src/world/type_glow.dart';
// For the cube's placement. The statement is positioned against the LIGHT, and
// the light's position is derived from the cube's — so the layout reads the
// same constants the shader does rather than keeping its own copy.
import 'package:portfolio/src/world/world_scene.dart';

class HeroPanel extends StatefulWidget {
  const HeroPanel({
    required this.location,
    required this.index,
    required this.onGo,
    super.key,
  });

  final Location location;

  /// Which location is showing, for the rail's position counter.
  final int index;
  final ValueChanged<int> onGo;

  @override
  State<HeroPanel> createState() => _HeroPanelState();
}

class _HeroPanelState extends State<HeroPanel> {
  /// The statement's position is measured against this rather than against the
  /// screen.
  ///
  /// ⚠️ IT HAS TO LIVE IN STATE. As a field on a StatelessWidget it would be a
  /// new key on every rebuild, and a changed GlobalKey tears the subtree down
  /// and builds it again.
  final GlobalKey _panel = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final location = widget.location;
    // The same margin the nav uses. Read from one place so the wordmark, the
    // role line, the name and the bottom rail all sit on a single vertical.
    final gutter = ContentColumn.gutterOf(context);
    // How much of the frame the statement may claim. The rest is FIELD, and
    // it is deliberate space rather than leftover — letting the type fill
    // everything squeezed the shader to a strip and the composition went flat.
    // A phone gets a bigger share because a tall frame has room to spare and
    // the statement needs the width.
    final statementShare = context.isCompact ? 0.74 : 0.54;
    return Padding(
      key: _panel,
      // ⚠️ THE RAIL'S SPACE IS RESERVED, NOT OCCUPIED. The rail is chrome and
      // draws itself over the whole world now, so this panel has to leave room
      // for it instead of ending with it: its own bottom margin, the rail, and
      // the gap that used to sit above it.
      padding: EdgeInsets.fromLTRB(
        gutter,
        kNavHeight,
        gutter,
        gutter + railHeightOf(context) + gutter,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ⚠️ ONE LINE AT EVERY WIDTH. The role line is a keyword list, and
            // a keyword list that wraps orphans its last item — "FLUTTER"
            // alone on a second line on an iPhone SE, which reads as an
            // accident. Shrinking it slightly is invisible; the orphan is not.
            //
            // scaleDown only ever reduces, so nothing changes on a frame where
            // it already fits, and no breakpoint has to be guessed at.
            SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  location.role,
                  style: AppType.label(context),
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  // The mark occupies the space above the statement — the
                  // space that was previously empty and, as you put it, was
                  // asking for something.
                  // The cube is no longer a layer here — it lives in the
                  // scene shader with the field, so that it can light it.
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * statementShare,
                      ),
                      child: _Name(
                        // Every arrangement the copy allows. The layout solves
                        // them all against this frame and takes the one that
                        // sets the largest leading line — no breakpoint.
                        arrangements: location.statement,
                        payoff: location.payoff,
                        path: location.path,
                        panel: _panel,
                        // Flush left, like everything else in the hero. Each
                        // line is set to the measure anyway, so this only
                        // decides where the lines that fall short of it sit —
                        // and the composition aligns to one margin.
                        align: TextAlign.start,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// railHeightOf moved to chrome/rail.dart with the rail it measures.

/// Leading, as a fraction of the size of the line it belongs to.
///
/// Below 1 because display type set flush wants to sit close, or the block
/// reads as separate sentences stacked rather than as one statement.
///
/// ⚠️ IT IS PER LINE, AND THAT IS ONLY RIGHT BECAUSE EVERY LINE FILLS THE
/// MEASURE. In ordinary setting leading belongs to the paragraph — one
/// baseline-to-baseline distance for the block — because lines of running text
/// are the same size and a varying gap would read as broken rhythm. Here each
/// line is scaled until it spans the column, so the block is a stack of masses
/// of differing scale, and the gap has to scale with them: a fixed gap taken
/// from the largest line leaves the smaller one floating away from the mass it
/// belongs to. Scaling the gap keeps the density even, which is what the eye
/// reads as one block.
const double kLeading = 0.92;

/// The space between the SUBJECT and the QUALIFIER, as a fraction of a leading.
///
/// ⚠️ THIS IS GROUPING, NOT DECORATION. Elements closer together are read as
/// belonging together, so a gap larger than the one between lines is what makes
/// the eye see one claim plus its qualification instead of four equal lines.
/// Space is the cheapest device that does it: it changes nothing about the
/// letters, survives every screen size, and — unlike tone — the energy cannot
/// argue with it.
///
/// ⚠️ AND IT IS SMALL ON PURPOSE. Chosen against 0, 0.12, 0.18 and 0.30 at
/// full size on the real scene. The threshold where two lines stop reading as
/// one block is much lower than it looks like it should be, and past it the
/// extra distance adds no meaning — it just pushes the parts away from each
/// other. Expressed as a RATIO so it scales: 0.08 of a leading is the same
/// relationship on a phone as on a 1920 display.
const double kPartGap = 0.08;

/// How far the block sits clear of the rail, in leadings of its last line.
///
/// ⚠️ IT IS ABOUT THE CUBE, NOT THE RAIL. This started as a full phantom line,
/// which reads fine on a phone and is wrong on a tall frame: the statement is
/// bottom-anchored, so every pixel of clearance underneath pushes the block UP,
/// into the space the cube needs. Set by hand on a 1920 frame and measured back
/// at a third of a leading — 77px lower than the phantom-line version.
const double kBottomClearance = 0.33;

/// ⚠️ THE STATEMENT IS POSITIONED AGAINST THE LIGHT, NOT AGAINST THE RAIL.
///
/// The letters take their colour from the energy behind them, so a block that
/// sits below the light is not merely lower — the entire effect is switched
/// off. Bottom-anchoring alone got this right on a desktop by luck, because the
/// energy there happens to fall low in the frame, and got it wrong on a phone,
/// where the light sits at 40-50% of the height and the block was landing at
/// 66-86%. Measured, not guessed: see the luminance profiles taken from the
/// rendered scene.
///
/// ⚠️ AND IT IS DERIVED FROM THE CUBE, WHICH IS WHY IT NEEDS NO BREAKPOINTS.
/// The energy pools a fixed distance from the cube in WORLD units, and
/// [kCubeSize] is exactly the world-to-screen scale. Measured across four frame
/// shapes, the bright band's centre sits 0.88-1.00 of a cube-unit below the
/// cube's centre — so one ratio covers every viewport, including the ones
/// nobody has looked at yet.
const double kEnergyBelowCube = 0.95;

/// How far a capital rises above its own line box, as a fraction of the size.
///
/// A line box at [kLeading] is tighter than the em, so ink escapes it at both
/// ends — descenders below (which is what was slicing the p in the mask) and
/// capitals above. Anything positioning the block against something in the
/// SCENE has to allow for it, or the type collides with an object the maths
/// says it clears.
const double kInkOvershoot = 0.25;

/// Where the cube's base falls, in cube-units below its centre.
///
/// The other end of the clamp: the statement must not climb over the object it
/// is lit by. Only bites on short frames — in phone landscape the cube's base
/// and the rail leave the type about a quarter of the frame to live in.
const double kCubeBase = 0.5;

/// ⚠️ THERE IS NO WIDTH AXIS ANY MORE, AND THAT IS A DELIBERATE TRADE.
///
/// Archivo carried a `wdth` axis and the fitting used it. Cinzel has weight
/// only — it was chosen for its voice, not its axes, and this is the bill.
///
/// Worth recording why the axis mattered, in case a future face brings one
/// back: it is the difference between fitting a line by changing the SIZE and
/// fitting it by changing the letterforms' PROPORTIONS. What it must never be
/// used for is justifying each line separately — at one size, an 18-character
/// line and a 13-character one need proportions 25% apart to fill the same
/// column, and a block whose lines have different proportions reads as two
/// typefaces. That fault is what made "Production Systems" look small next to
/// "from raw data" on a phone.
///
/// So the axis was already down to one value for the whole block. Losing it
/// costs only that one value, and size absorbs the work — which on narrow
/// frames means smaller type. Measured: about 13% smaller on a phone.
const double kDisplayWidth = 100;

/// A size to measure at. Nothing is set at it; width is linear in size for a
/// fixed axis value, so one measurement at any size gives every other by ratio.
const double kProbeSize = 100;

/// The dominant mass. ONE WIDTH ALWAYS; the size either fits or does not.
///
/// ⚠️ THE ONE RULE UNDERNEATH ALL OF THIS: SIZE MAY VARY BETWEEN LINES, WIDTH
/// MAY NOT.
///
/// Both are ways to make a line span the column, and they are not equivalent.
/// Changing a line's SIZE keeps the letterforms the designer drew and reads as
/// deliberate hierarchy — it is how display type has been set since metal.
/// Changing a line's WIDTH changes the proportions of the letters themselves,
/// and the eye reads two proportions in one sentence as two typefaces; that is
/// the fault that made "Production Systems" look small next to "from raw data"
/// on a phone. See [kDisplayWidth] — the current face has no width axis at all,
/// which makes the rule moot but not wrong.
///
/// So the size is the only thing allowed to vary between lines — and only where
/// varying it says something true about the sentence, which is what the two
/// settings below decide between.
///
/// ⚠️ WHICH SETTING IS USED IS DECIDED BY THE COPY, NOT BY THE VIEWPORT.
///
///   FLUSH — every line scaled until it fills the column, so the block is
///   square on both edges. Only used when the lines get LONGER as you read
///   down, because then the sizes come out getting smaller as you read down,
///   and that agrees with the sentence: the subject dominates and the span
///   qualifies it. Wide frames get this, since "Production Systems" (18
///   characters) sits above "from raw data to the last pixel." (32).
///
///   RAGGED — one size for every line, the width taken from the longest, and
///   the short lines simply end early. Used whenever scaling to the measure
///   would NOT agree with the sentence. A phone gets this: its middle line
///   "from raw data" is the shortest of the three, so filling the column would
///   make it the largest thing in the statement and the loudest phrase would be
///   the least important one.
///
/// Deriving it from the copy rather than from a breakpoint means a change to
/// the sentence cannot silently produce a setting that emphasises the wrong
/// words — the block re-decides.
///
/// The copy carries authored breaks (one set per frame shape), so no wrap
/// decision is ever left to chance, which is also what makes it impossible for
/// a word to be broken: no line is ever asked to wrap at all.
/// One arrangement, solved against one frame.
@immutable
class _Fit {
  const _Fit({
    required this.parts,
    required this.lines,
    required this.weights,
    required this.sizes,
    required this.gaps,
  });

  final List<List<String>> parts;
  final List<String> lines;
  final List<double> weights;
  final List<double> sizes;

  /// Total gap between parts, in leadings.
  final double gaps;

  /// The size of the largest line — what the arrangements are ranked on.
  double get biggest => sizes.reduce(math.max);

  double get blockHeight =>
      sizes.fold<double>(0, (sum, s) => sum + s * kLeading) +
      gaps * sizes[parts.first.length - 1] * kLeading;
}

class _Name extends StatelessWidget {
  const _Name({
    required this.arrangements,
    required this.payoff,
    required this.path,
    required this.panel,
    required this.align,
  });

  /// Every arrangement the copy allows. The frame picks one.
  final List<List<List<String>>> arrangements;

  /// The words the sentence answers to — the copy's call. See Location.payoff.
  final List<String> payoff;
  final String path;
  final TextAlign align;

  /// The hero panel, which the mask measures the block's position against.
  final GlobalKey panel;

  /// One line's style at a given size.
  ///
  /// ⚠️ NO letterSpacing ANYWHERE. Tracking is applied on top of the font's own
  /// kerning, so it eats the adjustment the typeface already made for each
  /// pair — the tightest pair goes first, which is exactly how "Sy" collided.
  /// Fitting is done with size instead, which leaves the letterforms alone.
  TextStyle _line(
    TextStyle base,
    double size, {
    double? height,
    double? weight,
  }) => base.copyWith(
        fontSize: size,
        height: height,
        // ⚠️ THE AXES ARE DRIVEN BY THE SIZE THIS LINE IS ACTUALLY SET AT, not
        // by the style's nominal size — which matters here more than anywhere
        // else on the site, because the fitting solves for a size and only then
        // knows what optical size to ask for. See displayAxes.
        fontVariations: displayAxes(size, weight: weight),
        // ⚠️ AND fontWeight IS KEPT IN AGREEMENT WITH THE AXIS.
        //
        // A TextStyle can describe weight twice — once as `fontWeight` and once
        // as a `wght` variation — and when the two disagree the engine is under
        // no obligation to pick the one you meant. It doesn't: the style
        // inherited `FontWeight.w600` from the display scale, so every line
        // rendered at 600 no matter what the axis said, and the subject and the
        // qualifier came out identical. Measured, not guessed — the stem
        // stayed 11px across a 400-to-600 sweep that the font file itself
        // renders as 42% thicker.
        fontWeight: _nearestWeight(weight ?? kDisplayWeight),
      );

  /// The named weight closest to a continuous axis value.
  ///
  /// Exists only to stop `fontWeight` contradicting `wght`. The axis is the
  /// real setting; this is the same number rounded to the nine values the
  /// enum can express.
  FontWeight _nearestWeight(double weight) =>
      FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)];

  /// How wide one line sets, with no wrapping allowed.
  ///
  /// ⚠️ MEASURED THE WAY THE WIDGET WILL LAY IT OUT, not with a bare painter.
  /// A `Text` applies the ambient textScaler and merges the DefaultTextStyle;
  /// a painter given only the explicit style answers a slightly different
  /// question. Since every line is fitted to within a hair of the measure,
  /// "slightly different" is the difference between two lines and three: the
  /// line overflows by a fraction of a pixel and Flutter wraps it.
  double _widthOf(String text, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// Solves one arrangement against the frame: what size does every line take.
  _Fit _solve(
    List<List<String>> parts, {
    required TextStyle base,
    required TextScaler scaler,
    required double measure,
    required double allowance,
    required double subjectWeight,
  }) {
    final lines = [for (final part in parts) ...part];
    final gaps = (parts.length - 1) * kPartGap;
    final leadings = lines.length + gaps + kBottomClearance;

    // ⚠️ EVERY LINE IS MEASURED AT THE WEIGHT IT WILL ACTUALLY BE SET AT.
    //
    // The subject is heavier than the qualifier, and a heavier cut is WIDER —
    // same letters, more ink, more advance. Measuring the whole block at one
    // weight and then setting the first part at another is how "Production
    // Systems" ended up fitting the column in the arithmetic and wrapping on
    // screen: it was solved at 400 and drawn at 500.
    //
    // Width is linear in size for a fixed set of axes, so one measurement per
    // line at the reference size gives every ratio the fitting needs.
    final weights = [
      for (var p = 0; p < parts.length; p++)
        for (var i = 0; i < parts[p].length; i++)
          p == 0 ? subjectWeight : kDisplayWeight,
    ];
    final natural = [
      for (var i = 0; i < lines.length; i++)
        math.max(
          _widthOf(
            lines[i],
            _line(base, kProbeSize, weight: weights[i]),
            scaler,
          ),
          1,
        ),
    ];

    // ⚠️ THE COPY DECIDES THE SETTING. Scaling each line to the column is only
    // honest when it makes the sizes DESCEND as you read — see the class
    // comment. That is true exactly when the lines get longer as you read, so
    // the copy is asked rather than the viewport.
    var flush = true;
    for (var i = 1; i < natural.length; i++) {
      if (natural[i] < natural[i - 1]) flush = false;
    }

    final List<double> sizes;

    if (flush) {
      // ── FLUSH: each line scaled until it spans the column ─────────────────
      final wanted = [
        for (final w in natural) kProbeSize * measure / w,
      ];

      // ⚠️ THEN CHECKED BY MEASUREMENT, because the arithmetic above assumes
      // width is exactly linear in size and it is not quite — rounding in the
      // shaper puts a line a fraction of a pixel either side. A fraction over
      // does not overhang the column by a fraction: it WRAPS, and the block
      // silently gains a line. Cheap to just ask.
      for (var i = 0; i < wanted.length; i++) {
        for (var pass = 0; pass < 2; pass++) {
          final actual = _widthOf(
            lines[i],
            _line(base, wanted[i], weight: weights[i]),
            scaler,
          );
          if (actual > measure) wanted[i] *= measure / actual;
        }
      }
      // Then the whole block scaled down together if it is taller than the
      // space it is allowed. Together, so the relationship between the lines —
      // which is the composition — survives the constraint.
      final tall = wanted.fold<double>(0, (sum, s) => sum + s * kLeading) +
          (gaps + kBottomClearance) * wanted.last * kLeading;
      final scale = tall > allowance ? allowance / tall : 1.0;
      sizes = [for (final s in wanted) s * scale];
    } else {
      // ── RAGGED: ONE size for the block, set by the longest line ───────────
      //
      // The longest line is the only one that can collide with the column, so
      // it sets the size for everything; the others end where the copy ends
      // them. Two constraints, and whichever binds first wins: the height the
      // block is allowed, and the column the longest line has to fit.
      final widest = natural.indexOf(natural.reduce(math.max));
      final longest = lines[widest];
      final byHeight = allowance / (leadings * kLeading);
      final byMeasure = kProbeSize * measure / natural[widest];
      var one = math.min(byHeight, byMeasure);

      // Then verified by measurement, for the same reason as the flush path.
      for (var pass = 0; pass < 2; pass++) {
        final actual = _widthOf(
          longest,
          _line(base, one, weight: weights[widest]),
          scaler,
        );
        if (actual > measure) one *= measure / actual;
      }
      sizes = [for (var i = 0; i < lines.length; i++) one];
    }

    return _Fit(
      parts: parts,
      lines: lines,
      weights: weights,
      sizes: sizes,
      gaps: gaps,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    // ⚠️ THE FIT HAS TO BE RE-SOLVED WHEN THE FACE ARRIVES.
    //
    // The size and the width are MEASURED, and the bundled faces load
    // asynchronously. Win the race and the block is solved against Archivo;
    // lose it and it is solved against the fallback, whose glyphs are a
    // different width — so a different size and a different width-axis value
    // get baked in and then never revisited. Flutter re-lays the text out when
    // a font lands, which is why nothing looks broken, but it does not re-run
    // this search, so the setting quietly differed from one refresh to the
    // next depending on whether the font beat the first layout.
    //
    // systemFonts fires on exactly that event. Rebuilding re-measures against
    // the real face, and the setting is the same every time.
    animation: PaintingBinding.instance.systemFonts,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
      // ⚠️ THE DEFAULT STYLE IS MERGED HERE, ONCE, and letterSpacing pinned to
      // zero. A `Text` merges the ambient DefaultTextStyle into whatever it is
      // given, so anything this style leaves unset arrives from the Material
      // theme — including its tracking. Measuring without that merge answers a
      // different question from the one the widget will ask.
      final base = DefaultTextStyle.of(context).style
          .merge(AppType.display(context))
          .copyWith(letterSpacing: 0);
      final scaler = MediaQuery.textScalerOf(context);

      // ⚠️ FIT TO SLIGHTLY LESS THAN THE MEASURE. Fitting exactly leaves zero
      // margin, and a line that comes out a fraction of a pixel over does not
      // sit a fraction over — it WRAPS, and the whole block gains a line. The
      // hair given up here is invisible; the wrap is not.
      final measure = constraints.maxWidth * 0.995;

      final allowance = constraints.maxHeight;

      // ⚠️ EVERY ARRANGEMENT IS SOLVED, AND THE FRAME PICKS ONE. There is no
      // width breakpoint left anywhere in this layout.
      //
      // A width threshold cannot tell a phone in landscape (852 × 393) from a
      // tablet in portrait (834 × 1194), and those two want opposite settings —
      // two lines against four. Solving all of them and taking the one that
      // sets the LARGEST leading line gets both right, and reproduces every
      // choice made by hand: two lines on a desktop, four on a phone.
      //
      // Ties break on presence, which is what makes a phone take four lines
      // over three: the longest line is the same in both, so the size is the
      // same, and the extra line is free height.
      // ⚠️ THE SUBJECT'S WEIGHT DEPENDS ON THE FRAME, and it is resolved here,
      // once, BEFORE anything is measured. A weight step is only as visible as
      // the stroke it lives in, so a phone needs a bigger one than a desktop —
      // but every measurement below has to use whatever value that turns out to
      // be, or the block is solved at one weight and drawn at another. That is
      // exactly the bug that wrapped "Production Systems" onto two lines.
      final subjectWeight = subjectWeightFor(MediaQuery.sizeOf(context));

      final fits = [
        for (final candidate in arrangements)
          _solve(
            candidate,
            base: base,
            scaler: scaler,
            measure: measure,
            allowance: allowance,
            subjectWeight: subjectWeight,
          ),
      ]..sort((a, b) {
          if ((a.biggest - b.biggest).abs() > 0.5) {
            return b.biggest.compareTo(a.biggest);
          }
          return b.blockHeight.compareTo(a.blockHeight);
        });

      final fit = fits.first;
      final parts = fit.parts;
      final sizes = fit.sizes;
      final gaps = fit.gaps;

      // ── WHERE THE BLOCK SITS, solved against the light ────────────────────
      //
      // Everything below is in VIEWPORT coordinates, because that is the space
      // the scene is composed in. The block is bottom-anchored in its box, so
      // the only thing to compute is how far to hold it off that bottom.
      final viewport = MediaQuery.sizeOf(context);
      final fieldBottom = viewport.height -
          ContentColumn.gutterOf(context) -
          railHeightOf(context);

      final unit = math.min(viewport.width, viewport.height) * kCubeSize;
      final cubeCentre = viewport.height * kCubeY;
      final cubeBase = cubeCentre + unit * kCubeBase;
      final energyCentre = cubeCentre + unit * kEnergyBelowCube;

      var blockHeight = sizes.fold<double>(0, (sum, s) => sum + s * kLeading) +
          gaps * sizes[parts.first.length - 1] * kLeading;
      final clearance = sizes.last * kLeading * kBottomClearance;

      // Preferred position: hanging off the bottom, as before. Then clamped so
      // it reaches UP into the light and never climbs over the cube.
      //
      // ⚠️ THE CEILING IS AGAINST INK, NOT AGAINST THE LINE BOX. Leading is
      // 0.92 — deliberately tighter than the em — so the box is SMALLER than
      // the letters and the capitals rise above its top edge. Clamping the box
      // to the cube's base still let the type graze the cube by about a quarter
      // of its size, which on a phone in landscape is the whole problem.
      final overshoot = sizes.first * kInkOvershoot;
      final resting = fieldBottom - clearance - blockHeight;
      final ceiling = math.min(cubeBase + overshoot, energyCentre);
      var top = resting.clamp(ceiling, math.max(ceiling, energyCentre));

      // On a short frame the cube's base and the rail can leave less room than
      // the block needs — landscape on a phone is the case. Shrink to fit
      // rather than overlap either of them.
      final room = fieldBottom - clearance - top;
      if (blockHeight > room && room > 0) {
        final shrink = room / blockHeight;
        for (var i = 0; i < sizes.length; i++) {
          sizes[i] = sizes[i] * shrink;
        }
        blockHeight *= shrink;
        top = fieldBottom - clearance - blockHeight;
        top = top.clamp(ceiling, math.max(ceiling, energyCentre));
      }

      final float = math.max(fieldBottom - (top + blockHeight), clearance);

      // One paragraph with a style per line — NOT a Column of Texts. The mask
      // has to be a single rasterisation of the whole statement, and separate
      // widgets would mean tracking each one's position and reconciling them,
      // which is the exact problem the single rasterisation exists to avoid.
      //
      // ⚠️ THE GAP BETWEEN PARTS IS AN EMPTY LINE, not padding. There is no
      // padding inside a paragraph, and the whole statement has to stay one
      // paragraph — so the space is a line of its own, carrying no characters,
      // whose height IS the gap. It costs one newline and keeps the single
      // rasterisation intact.
      TextSpan span(Color colour) {
        final children = <TextSpan>[];
        var index = 0;
        for (var p = 0; p < parts.length; p++) {
          // The subject is set heavier than what follows it. Weight is the
          // hierarchy device; see kSubjectWeight for why it beat tone here.
          // ⚠️ THE SAME VALUE THE FITTING MEASURED WITH, not the constant.
          final weight = fit.weights[index];
          for (var i = 0; i < parts[p].length; i++) {
            final last = p == parts.length - 1 && i == parts[p].length - 1;
            children.add(
              TextSpan(
                text: last ? parts[p][i] : '${parts[p][i]}\n',
                style: _line(
                  base,
                  sizes[index],
                  height: kLeading,
                  weight: weight,
                ).copyWith(color: colour),
              ),
            );
            index++;
          }
          if (p < parts.length - 1) {
            final gap = sizes[index - 1] * kLeading * kPartGap;
            children.add(
              TextSpan(
                text: '\n',
                style: base.copyWith(fontSize: gap, height: 1),
              ),
            );
          }
        }
        return TextSpan(children: children);
      }

      return SizedBox(
        width: double.infinity,
        // Bottom-anchored so leftover vertical space collects ABOVE the type,
        // where the field lives. Centring it leaves a dead band underneath.
        child: Align(
          alignment: Alignment.bottomLeft,
          // The phantom line, held open. The statement now floats one leading
          // clear of the rail instead of sitting on it — and because the slot
          // was reserved before the size was chosen, this takes nothing away
          // from the type.
          child: Padding(
            padding: EdgeInsets.only(bottom: float),
            // The mask is built from EXACTLY what the visible text is built
            // from — the same span, the same measure, the same alignment.
            // Anything derived or approximate here is what puts the light out
            // of register with the letters.
            child: TypeMaskCapture(
              panel: panel,
              // Which word the sentence is about — the copy's call, not the
              // renderer's. See Location.payoff.
              payoff: payoff,
              span: span(const Color(0xFFFFFFFF)),
              signature: Object.hash(
                Object.hashAll(fit.lines),
                Object.hashAll(sizes),
                Object.hashAll(fit.weights),
                measure,
              ),
              maxWidth: measure,
              textAlign: align,
              // The text still lays the statement out and still carries it for
              // a screen reader — but once the glow is drawing the letters it
              // paints transparent, so they are never rasterised twice. Until
              // then it paints normally, so the sentence is never missing: not
              // while the shader loads, not if it fails to load at all.
              builder: (context, {required visible}) => Text.rich(
                span(visible ? Palette.ink : const Color(0x00000000)),
                key: Key('title-$path'),
                textAlign: align,
              ),
            ),
          ),
        ),
      );
      },
    ),
  );
}

// The bottom rail used to live here, as the last row of this panel's column.
// It is chrome, not hero, and now sits beside the nav — see chrome/rail.dart.
