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
            Text(location.role, style: AppType.label(context)),
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

/// How much larger the biggest line may be set than the smallest.
///
/// ⚠️ THE SIZE RATIO HAS TO BE A DECISION. Setting every line to the measure
/// means the size is decided by the character count — eighteen characters
/// against thirty-two puts the first line at nearly 1.8x the second, which is
/// not a ratio anyone would choose. Past this cap a line stops filling the
/// measure and simply sets flush left with a ragged right, which is ordinary
/// editorial setting; the alternative is a headline whose proportions are an
/// accident of how the sentence happens to divide.
const double kMaxLineRatio = 1.32;

/// Optical tracking, as a fraction of the em, at the ends of the display range.
///
/// ⚠️ TRACKING IS NOT ONE CONSTANT. Large type can carry more negative
/// tracking than small type — the counters and sidebearings are relatively
/// larger, so tightening reads as confidence rather than as collision. A flat
/// -3.5% across a 2:1 size range was too tight at both ends: it collided the
/// S and the y in "Systems" at the large end and closed up the small line at
/// the other.
// ⚠️ THESE ARE APPLIED ON TOP OF THE FONT'S OWN KERNING, not instead of it.
// The typeface has already decided how close "Sy" should sit — the y's arm
// tucks under the S — and letterSpacing then removes more space from that
// pair uniformly. So tracking does not merely tighten the average; it eats the
// adjustment the font had already made, and the tightest pairs collide first.
// Roboto's default spacing is close to begin with and does not want much.
const double kTrackTight = -0.014; // at kTrackLarge and above
const double kTrackLoose = -0.006; // at kTrackSmall and below
const double kTrackSmall = 40;
const double kTrackLarge = 220;

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

  /// Optical tracking for a given size, on a curve rather than a constant.
  ///
  /// Large type carries more negative tracking than small type does — its
  /// counters and sidebearings are relatively larger, so tightening reads as
  /// confidence rather than as letters colliding.
  double _tracking(double size) {
    final t = ((size - kTrackSmall) / (kTrackLarge - kTrackSmall)).clamp(
      0.0,
      1.0,
    );
    return size * (kTrackLoose + (kTrackTight - kTrackLoose) * t);
  }

  /// [height] is left null while measuring — leading cannot be decided until
  /// every line's size is known, because it belongs to the block.
  TextStyle _sized(TextStyle base, double size, [double? height]) =>
      base.copyWith(
        fontSize: size,
        letterSpacing: _tracking(size),
        height: height,
        // Kerning asked for explicitly rather than assumed. It is the one
        // thing standing between the S and the y, and a display setting is
        // where its absence shows first.
        fontFeatures: const [FontFeature.enable('kern')],
      );

  /// How wide one line sets in [style], with no wrapping allowed.
  double _widthOf(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// The size at which [text] exactly fills [measure].
  double _solve(String text, TextStyle base, double measure) {
    var lo = 8.0;
    var hi = 520.0;
    for (var i = 0; i < 18; i++) {
      final mid = (lo + hi) / 2;
      if (_widthOf(text, _sized(base, mid)) <= measure) {
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
      final base = AppType.display(context);
      final measure = constraints.maxWidth;

      // Every line to the measure...
      var sizes = [for (final line in lines) _solve(line, base, measure)];

      // ...then the spread capped, so the proportions are chosen rather than
      // inherited from how the sentence happens to divide. A line held back by
      // the cap stops filling the measure and sets ragged right.
      final smallest = sizes.reduce((a, b) => a < b ? a : b);
      sizes = [
        for (final size in sizes)
          size > smallest * kMaxLineRatio ? smallest * kMaxLineRatio : size,
      ];

      // Leading is ONE distance for the block, taken from the largest line.
      var largest = sizes.reduce((a, b) => a > b ? a : b);
      var leading = largest * kLeading;

      // The stack is exactly that distance per line, so fitting the box is a
      // single scale of everything rather than a per-line adjustment.
      final stack = leading * sizes.length;
      if (stack > constraints.maxHeight && stack > 0) {
        final shrink = constraints.maxHeight / stack;
        sizes = [for (final size in sizes) size * shrink];
        largest *= shrink;
        leading *= shrink;
      }

      // Each line's multiplier is whatever makes ITS box that one distance,
      // which is what keeps the baselines evenly spaced across sizes.
      final heights = [for (final size in sizes) leading / size];

      // One paragraph with a style per line — NOT a Column of Texts. The mask
      // has to be a single rasterisation of the whole statement, and separate
      // widgets would mean tracking each one's position and reconciling them,
      // which is the exact problem the single rasterisation exists to avoid.
      TextSpan span(Color colour) => TextSpan(
        children: [
          for (var i = 0; i < lines.length; i++)
            TextSpan(
              text: i == lines.length - 1 ? lines[i] : '${lines[i]}\n',
              style: _sized(base, sizes[i], heights[i]).copyWith(color: colour),
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
            signature: Object.hash(Object.hashAll(lines), Object.hashAll(sizes),
                measure, align),
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
  /// [tight] sizes the row to its content, which the desktop layout needs so
  /// the Spacer after it can push the index right. On a phone it must be the
  /// full width instead — otherwise the Flexible has no bound to ellipsis
  /// against and the availability text runs off the edge.
  Widget _status(BuildContext context, {bool tight = true}) => Row(
    mainAxisSize: tight ? MainAxisSize.min : MainAxisSize.max,
    children: [
      Text(
        'DMITRY SEVRYUKOV',
        style: AppType.label(context).copyWith(color: Palette.ink),
      ),
      const SizedBox(width: Space.lg),
      const _StatusDot(),
      const SizedBox(width: Space.sm),
      Flexible(
        child: Text(
          // Shortened rather than ellipsised on a phone. A truncated
          // "AVAILABLE FOR REMOT…" looks broken; the short form is the same
          // information and fits.
          context.isCompact
              ? 'AVAILABLE · REMOTE'
              : 'AVAILABLE FOR REMOTE WORK',
          style: AppType.label(context),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );

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
