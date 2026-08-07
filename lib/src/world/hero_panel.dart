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
                      // Recorded as a mask so the glow layer above the world
                      // knows where the letters are. The text itself is
                      // untouched — same widget, same colour, still crisp.
                      child: TypeMaskCapture(
                        panel: _panel,
                        child: _Name(
                          title: location.title,
                          path: location.path,
                        ),
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

/// The dominant mass, sized to fill the frame it is given.
///
/// A `FittedBox` cannot do this job: it scales a pre-laid-out block, so the
/// line breaks are fixed before scaling. Breaks chosen for 16:9 leave a phone
/// with two very long lines that have to shrink to almost nothing to fit the
/// width — which is exactly what the first phone screenshot showed.
///
/// Instead the text WRAPS to the available width and the font size is solved
/// for: binary search the largest size whose wrapped block still fits the box.
/// Wide frames get two lines, tall narrow frames get four or five, and both
/// fill their space.
class _Name extends StatelessWidget {
  const _Name({required this.title, required this.path});

  final String title;
  final String path;

  /// Tracking scales with size, so it has to be recomputed per candidate.
  TextStyle _sized(TextStyle base, double size) =>
      base.copyWith(fontSize: size, letterSpacing: size * -0.035);

  /// Lays the text out at a candidate size and reports how ragged it is.
  ///
  /// 0 means every line is the same width; 1 means one line is empty next to a
  /// full one. A trailing widow — "pixel." alone on the last line — scores
  /// terribly here, which is exactly what we want it to do.
  double _rag(String text, TextStyle style, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    final lines = painter.computeLineMetrics();
    if (lines.length < 2) return 0;
    var widest = 0.0;
    var narrowest = double.infinity;
    for (final line in lines) {
      if (line.width > widest) widest = line.width;
      if (line.width < narrowest) narrowest = line.width;
    }
    return widest == 0 ? 0 : (widest - narrowest) / widest;
  }

  bool _fits(String text, TextStyle style, BoxConstraints box) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: box.maxWidth);
    return painter.height <= box.maxHeight && painter.width <= box.maxWidth;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final base = AppType.display(context);
      var lo = 12.0;
      var hi = 420.0;
      // 16 iterations resolves to well under a pixel over this range, and
      // runs once per layout — cheap next to a full-screen shader.
      for (var i = 0; i < 16; i++) {
        final mid = (lo + hi) / 2;
        if (_fits(title, _sized(base, mid), constraints)) {
          lo = mid;
        } else {
          hi = mid;
        }
      }

      // The largest size that FITS is not the best size. At the maximum the
      // wrap fell as three lines with "pixel." orphaned on the last one, which
      // reads as broken. Give up a little scale for an even block: search
      // down to 80% of the maximum and take the least ragged result.
      var best = lo;
      var bestRag = _rag(title, _sized(base, lo), constraints.maxWidth);
      for (var i = 1; i <= 20; i++) {
        final candidate = lo * (1 - i * 0.01);
        if (candidate < lo * 0.8) break;
        if (!_fits(title, _sized(base, candidate), constraints)) continue;
        final rag = _rag(title, _sized(base, candidate), constraints.maxWidth);
        // Needs to be meaningfully better, or every layout drifts smaller for
        // a rounding-error improvement.
        if (rag < bestRag - 0.04) {
          best = candidate;
          bestRag = rag;
        }
      }
      lo = best;

      return SizedBox(
        width: double.infinity,
        // Bottom-anchored so leftover vertical space collects ABOVE the type,
        // where the field lives. Centring it leaves a dead band underneath.
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Text(
            title,
            key: Key('title-$path'),
            style: _sized(base, lo),
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
