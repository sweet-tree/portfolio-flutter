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
import 'package:portfolio/src/design/layout.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/design/type.dart';
import 'package:portfolio/src/world/locations.dart';
import 'package:portfolio/src/world/type_glow.dart';
import 'package:portfolio/src/world/world_camera.dart';

class HeroPanel extends StatefulWidget {
  const HeroPanel({required this.location, required this.camera, super.key});

  final Location location;
  final WorldCamera camera;

  @override
  State<HeroPanel> createState() => _HeroPanelState();
}

class _HeroPanelState extends State<HeroPanel> {
  /// The statement's position is measured against this rather than against the
  /// screen, so that travelling does not change it — the camera offset is
  /// applied in the shader, where it is one addition.
  ///
  /// ⚠️ IT HAS TO LIVE IN STATE. As a field on a StatelessWidget it would be a
  /// new key on every rebuild, and this panel rebuilds every frame the camera
  /// moves; a changed GlobalKey tears the subtree down and builds it again.
  final GlobalKey _panel = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final location = widget.location;
    final camera = widget.camera;
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
      padding: EdgeInsets.fromLTRB(gutter, kNavHeight, gutter, gutter),
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
                        // Breaks authored per frame shape: a wide frame gets
                        // the subject and the span, a narrow one splits the
                        // span again so the last line stays readable.
                        lines: context.isCompact
                            ? location.titleCompact
                            : location.titleWide,
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
            SizedBox(height: gutter),
            _BottomRail(camera: camera),
          ],
        ),
      ),
    );
  }
}

/// Baseline-to-baseline distance, as a fraction of the LARGEST line's size.
///
/// ⚠️ ONE VALUE FOR THE WHOLE BLOCK, not a multiple of each line's own size.
/// Leading is a property of a paragraph, not of a line: setting it per line
/// means the smaller line gets a proportionally smaller gap, so a stack of
/// differently-sized lines ends up unevenly spaced. Each line's height
/// multiplier is derived from this and its own size, which is what keeps the
/// baselines evenly spaced whatever the sizes turn out to be.
///
/// Below 1 because display type set flush wants to sit close, or the block
/// reads as separate sentences stacked rather than as one statement.
const double kLeading = 0.92;

/// How far the width axis may be pushed to fit a line to the measure.
///
/// ⚠️ FITTING IS DONE WITH WIDTH, NOT SIZE, and that is the whole change.
///
/// Setting each line to its own size is the pre-variable-font method: the size
/// is then decided by the character count, so a line's proportions are an
/// accident of how the sentence divides, and a ratio cap has to be invented to
/// rescue it. With a width axis the size stays constant across the block and
/// the LINES change shape instead — the longer one sets a little narrower, the
/// shorter one a little wider, and both fill the column exactly. One size, one
/// weight, one voice.
///
/// The range is deliberately narrow. Archivo goes to 62 and 125, and the file
/// is trimmed to 75-112, but past roughly ten percent either way the
/// letterforms stop reading as fitted and start reading as stretched. A line
/// that needs more than this is a line that is broken in the wrong place, and
/// the axis should not be used to rescue a bad break.
const double kWidthMin = 88;
const double kWidthMax = 110;

/// The dominant mass: every line SET TO THE MEASURE.
///
/// ⚠️ THE BREAKS ARE AUTHORED AND EACH LINE IS SIZED SEPARATELY, which is not
/// how this started and is the only version that survives a phone.
///
/// It used to pick one size for the whole statement and let the text wrap
/// wherever the width ran out. Two things were wrong with that. On a narrow
/// frame the wrap chose five lines of small type; and the fit test only asked
/// whether the BLOCK fitted, never whether a WORD did — so at some sizes
/// "Production" was wider than the column and Flutter broke it down the
/// middle. A size that splits a word must be unreachable, not unlikely.
///
/// So the copy carries its own breaks (one set per frame shape) and each line
/// is solved independently for the size that makes it exactly fill the column.
/// A line with more characters comes out smaller, the block is flush on both
/// edges without any justification trickery, and no wrap decision is left to
/// chance — which also means no word can ever be broken, because no line is
/// ever asked to wrap at all.
class _Name extends StatelessWidget {
  const _Name({
    required this.lines,
    required this.path,
    required this.panel,
    required this.align,
  });

  /// The statement, already broken for this frame.
  final List<String> lines;
  final String path;
  final TextAlign align;

  /// The hero panel, which the mask measures the block's position against.
  final GlobalKey panel;

  /// One line's style at a given size and width-axis setting.
  ///
  /// ⚠️ NO letterSpacing ANYWHERE. Tracking is applied on top of the font's own
  /// kerning, so it eats the adjustment the typeface already made for each
  /// pair — the tightest pair goes first, which is exactly how "Sy" collided.
  /// Archivo's spacing at this weight is display spacing already; fitting is
  /// done with the width axis instead, which changes the letterforms rather
  /// than the gaps between them.
  TextStyle _line(
    TextStyle base,
    double size,
    double width, [
    double? height,
  ]) => base.copyWith(
        fontSize: size,
        height: height,
        fontVariations: [
          const FontVariation('wght', kDisplayWeight),
          FontVariation('wdth', width),
        ],
      );

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

  /// The width-axis value at which [text] fills [measure] at [size].
  ///
  /// Searched rather than calculated: width does not scale linearly with the
  /// axis — the designer drew intermediate masters, which is the entire point
  /// of a variable font — so the only honest way to hit the measure is to ask
  /// the font.
  double _fitWidth(
    String text,
    TextStyle base,
    double size,
    double measure,
    TextScaler scaler,
  ) {
    var lo = kWidthMin;
    var hi = kWidthMax;
    if (_widthOf(text, _line(base, size, hi), scaler) <= measure) return hi;
    if (_widthOf(text, _line(base, size, lo), scaler) >= measure) return lo;
    for (var i = 0; i < 12; i++) {
      final mid = (lo + hi) / 2;
      if (_widthOf(text, _line(base, size, mid), scaler) <= measure) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
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

      // ONE SIZE for the whole statement, taken from the height it is allowed
      // and the number of lines. Nothing about the copy decides it.
      var size = constraints.maxHeight / (lines.length * kLeading);

      // Then reduced if any line cannot be squeezed into the measure even at
      // the narrowest width the axis is allowed to go. Three passes: width is
      // close enough to linear in size for the first correction to land, and
      // the rest converge.
      for (var pass = 0; pass < 3; pass++) {
        var worst = 1.0;
        for (final line in lines) {
          final atNarrowest = _widthOf(
            line,
            _line(base, size, kWidthMin),
            scaler,
          );
          if (atNarrowest > measure) {
            worst = math.min(worst, measure / atNarrowest);
          }
        }
        if (worst < 1) size *= worst;
      }

      // Each line then fitted to the measure by WIDTH. A line that already
      // fits at the widest setting simply sets there and falls short, which is
      // an honest ragged right rather than a stretched letterform.
      final widths = [
        for (final line in lines)
          _fitWidth(line, base, size, measure, scaler),
      ];

      // Leading is one distance for the block — and with a single size that is
      // simply the size times the ratio, which is what having one size buys.
      final leading = size * kLeading;
      final height = leading / size;

      // One paragraph with a style per line — NOT a Column of Texts. The mask
      // has to be a single rasterisation of the whole statement, and separate
      // widgets would mean tracking each one's position and reconciling them,
      // which is the exact problem the single rasterisation exists to avoid.
      TextSpan span(Color colour) => TextSpan(
        children: [
          for (var i = 0; i < lines.length; i++)
            TextSpan(
              text: i == lines.length - 1 ? lines[i] : '${lines[i]}\n',
              style: _line(
                base,
                size,
                widths[i],
                height,
              ).copyWith(color: colour),
            ),
        ],
      );

      return SizedBox(
        width: double.infinity,
        // Bottom-anchored so leftover vertical space collects ABOVE the type,
        // where the field lives. Centring it leaves a dead band underneath.
        child: Align(
          alignment: Alignment.bottomLeft,
          // The mask is built from EXACTLY what the visible text is built
          // from — the same span, the same measure, the same alignment.
          // Anything derived or approximate here is what puts the light out of
          // register with the letters.
          child: TypeMaskCapture(
            panel: panel,
            span: span(const Color(0xFFFFFFFF)),
            signature: Object.hash(
              Object.hashAll(lines),
              Object.hashAll(widths),
              size,
              measure,
            ),
            maxWidth: measure,
            textAlign: align,
            // The text still lays the statement out and still carries it for a
            // screen reader — but once the glow is drawing the letters it
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
      );
    },
  );
}

/// The bottom rail: status on the left, position in the world on the right.
///
/// The position indicator replaces the scroll cue a normal site would have.
/// Nothing here scrolls, so a first-time visitor has no way to guess the site
/// goes sideways unless something tells them — this is that something.
class _BottomRail extends StatelessWidget {
  const _BottomRail({required this.camera});

  final WorldCamera camera;

  @override
  Widget build(BuildContext context) {
    final next = camera.nearest + 1;
    final hasNext = next < kLocations.length;
    return Column(
      children: [
        const ColoredBox(
          color: Palette.line,
          child: SizedBox(height: 1, width: double.infinity),
        ),
        const SizedBox(height: Space.md),
        // Four items do not fit in one row at 390px — the first phone build
        // pushed the index and the next-link clean off the right edge. On a
        // narrow frame the rail becomes two rows instead of overflowing.
        if (context.isCompact)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _status(context, tight: false),
              const SizedBox(height: Space.sm),
              Row(
                children: _position(context, next: next, hasNext: hasNext),
              ),
            ],
          )
        else
          Row(
            children: [
              _status(context),
              const Spacer(),
              ..._position(context, next: next, hasNext: hasNext),
            ],
          ),
      ],
    );
  }

  /// The name lives here, as metadata. It is the least useful fact on the page
  /// for someone deciding whether to call him, so it does not get to be the
  /// biggest thing on it.
  ///
  /// ⚠️ IT WRAPS RATHER THAN TRUNCATES on a narrow frame. Ellipsising it read
  /// as "AVAILABLE…" on an iPhone SE, which is worse than useless: the one
  /// word that got cut is the one that matters, and a truncated line looks
  /// like a bug rather than a decision. A Wrap moves the whole phrase to its
  /// own run instead, so the information survives at any width.
  ///
  /// [tight] sizes the row to its content, which the desktop layout needs so
  /// the Spacer after it can push the index right.
  Widget _status(BuildContext context, {bool tight = true}) {
    final name = Text(
      'DMITRY SEVRYUKOV',
      style: AppType.label(context).copyWith(color: Palette.ink),
    );
    final availability = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _StatusDot(),
        const SizedBox(width: Space.sm),
        Text(
          // Shortened rather than ellipsised on a phone: the short form is the
          // same information and fits.
          context.isCompact
              ? 'AVAILABLE · REMOTE'
              : 'AVAILABLE FOR REMOTE WORK',
          style: AppType.label(context),
        ),
      ],
    );

    if (tight) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [name, const SizedBox(width: Space.lg), availability],
      );
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: Space.lg,
      runSpacing: Space.xs,
      children: [name, availability],
    );
  }

  List<Widget> _position(
    BuildContext context, {
    required int next,
    required bool hasNext,
  }) => [
    Text(
      '${_two(camera.nearest + 1)} / ${_two(kLocations.length)}',
      style: AppType.label(context),
    ),
    if (hasNext) ...[
      const SizedBox(width: Space.lg),
      _NextLink(
        label: kLocations[next].label,
        onTap: () => camera.jumpTo(next),
      ),
    ],
  ];

  static String _two(int n) => n.toString().padLeft(2, '0');
}

class _StatusDot extends StatelessWidget {
  const _StatusDot();

  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: const BoxDecoration(
      color: Palette.accent,
      shape: BoxShape.circle,
    ),
  );
}

/// Points at the next location. Doubles as the cue that the world continues
/// past the right edge of the frame.
class _NextLink extends StatefulWidget {
  const _NextLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_NextLink> createState() => _NextLinkState();
}

class _NextLinkState extends State<_NextLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'NEXT · ${widget.label.toUpperCase()}',
            style: AppType.label(
              context,
            ).copyWith(color: _hovered ? Palette.ink : Palette.inkMuted),
          ),
          const SizedBox(width: Space.sm),
          // Nudges right on hover — the direction you are about to travel.
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(_hovered ? 4 : 0, 0, 0),
            child: Text(
              '→',
              style: AppType.label(
                context,
              ).copyWith(color: _hovered ? Palette.accent : Palette.inkMuted),
            ),
          ),
        ],
      ),
    ),
  );
}
