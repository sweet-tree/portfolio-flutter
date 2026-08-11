/// The bottom rail: status on the left, position in the world on the right.
///
/// The position indicator replaces the scroll cue a normal site would have.
/// Nothing here scrolls, so a first-time visitor has no way to guess there is
/// more than this screen unless something tells them — this is that something.
///
/// ⚠️ IT IS CHROME, NOT PART OF THE HERO — moved out of `hero_panel.dart`
/// 2026-08-11. It used to be the last row of the hero's own column, which was
/// fine while the hero was the only composed location. It is not fine now: the
/// rail has to stay visible over every section, and content arriving in front
/// of the scene must sit BETWEEN this and the nav. So it belongs beside the
/// nav, in the world, and the panels no longer know about it.
///
/// Everything below is the hero's rail moved verbatim. Only its name changed.
library;

import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/layout.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/design/type.dart';
import 'package:portfolio/src/world/locations.dart';

/// How tall the bottom rail is, without having to lay it out to find out.
///
/// The statement's placement is solved against the VIEWPORT — where the light
/// is, where the cube's base is — so it needs to know where the field it lives
/// in actually ends, and that is the rail's top edge. Derived from the same
/// constants the rail is built from rather than measured, because the answer is
/// needed while deciding a font size, which is well before anything has been
/// laid out.
///
/// Compact frames stack the rail into two rows; wide ones keep it on one.
double railHeightOf(BuildContext context) {
  const line = 12 * 1.2; // AppType.label: 12px at a height of 1.2
  return context.isCompact
      ? 1 + Space.md + line + Space.sm + line
      : 1 + Space.md + line;
}

class WorldRail extends StatelessWidget {
  const WorldRail({required this.index, required this.onGo, super.key});

  final int index;
  final ValueChanged<int> onGo;

  @override
  Widget build(BuildContext context) {
    final gutter = ContentColumn.gutterOf(context);
    final next = index + 1;
    final hasNext = next < kLocations.length;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      // ⚠️ PLAIN GUTTERS, NOT A ContentColumn. The nav is capped at the content
      // width; this runs the full frame, which is how it has always drawn. It
      // is a rule at the bottom of the composition, and a rule that stops short
      // of the margins reads as a stray line rather than an edge.
      child: Padding(
        padding: EdgeInsets.fromLTRB(gutter, 0, gutter, gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
        ),
      ),
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
      '${_two(index + 1)} / ${_two(kLocations.length)}',
      style: AppType.label(context),
    ),
    if (hasNext) ...[
      const SizedBox(width: Space.lg),
      _NextLink(label: kLocations[next].label, onTap: () => onGo(next)),
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

/// Points at the next location. Doubles as the cue that there is more than
/// this screen.
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
          // Nudges right on hover — the direction reading takes you.
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
