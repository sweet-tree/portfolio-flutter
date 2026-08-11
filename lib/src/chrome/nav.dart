/// The nav. Pinned, and reads which location is showing.
///
/// ⚠️ THE INDICATOR USED TO BE CONTINUOUS, and that is worth knowing before
/// anyone calls the current one crude. The world travelled on a spring, so the
/// underline could track a position BETWEEN stops and slide as you went, which
/// was most of what made the nav feel attached to the world rather than laid on
/// top of it. There is no between any more — a location is showing or it is
/// not — so the highlight is a state, not a distance.
///
/// Whatever replaces travel gets to decide whether it earns a transition again.
library;

import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/layout.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/design/type.dart';
import 'package:portfolio/src/world/locations.dart';

const double kNavHeight = 72;

class WorldNav extends StatelessWidget {
  const WorldNav({required this.index, required this.onGo, super.key});

  /// Which location is showing.
  final int index;
  final ValueChanged<int> onGo;

  @override
  Widget build(BuildContext context) => Positioned(
    top: 0,
    left: 0,
    right: 0,
    height: kNavHeight,
    child: ContentColumn(
      child: Row(
        children: [
          _NavLink(
            label: 'DS',
            active: index == 0,
            bold: true,
            onTap: () => onGo(0),
          ),
          const Spacer(),
          for (var i = 1; i < kLocations.length; i++)
            Padding(
              padding: const EdgeInsets.only(left: Space.lg),
              child: _NavLink(
                label: kLocations[i].label,
                active: index == i,
                onTap: () => onGo(i),
              ),
            ),
        ],
      ),
    ),
  );
}

class _NavLink extends StatefulWidget {
  const _NavLink({
    required this.label,
    required this.active,
    required this.onTap,
    this.bold = false,
  });

  final String label;

  /// Whether this is the location currently showing.
  final bool active;
  final VoidCallback onTap;
  final bool bold;

  @override
  State<_NavLink> createState() => _NavLinkState();
}

class _NavLinkState extends State<_NavLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final lit = widget.active ? 1.0 : 0.0;
    final base = AppType.ui(context).copyWith(
      fontWeight: widget.bold ? FontWeight.w700 : null,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          key: Key('nav-${widget.label}'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.label,
              style: base.copyWith(
                color: Color.lerp(
                  _hovered ? Palette.ink : Palette.inkMuted,
                  Palette.ink,
                  lit,
                ),
              ),
            ),
            const SizedBox(height: Space.xs),
            // Width tracks proximity, so the underline grows as you approach
            // and shrinks as you leave.
            Container(
              height: 1.5,
              width: 18 * (_hovered ? 1.0 : lit),
              color: Color.lerp(Palette.ink, Palette.accent, lit),
            ),
          ],
        ),
      ),
    );
  }
}
