/// The nav. Pinned, never travels, and reads the camera directly.
///
/// The active indicator tracks the camera's CONTINUOUS position rather than
/// the nearest stop, so it slides while you travel instead of snapping when
/// you arrive. That one detail is most of what makes the nav feel attached to
/// the world rather than laid on top of it.
library;

import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/layout.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/design/type.dart';
import 'package:portfolio/src/world/locations.dart';
import 'package:portfolio/src/world/world_camera.dart';

const double kNavHeight = 72;

class WorldNav extends StatelessWidget {
  const WorldNav({required this.camera, super.key});

  final WorldCamera camera;

  @override
  Widget build(BuildContext context) => Positioned(
    top: 0,
    left: 0,
    right: 0,
    height: kNavHeight,
    child: ContentColumn(
      child: Row(
        children: [
          _Wordmark(camera: camera),
          const Spacer(),
          for (var i = 1; i < kLocations.length; i++)
            Padding(
              padding: const EdgeInsets.only(left: Space.lg),
              child: _NavLink(
                label: kLocations[i].label,
                // Full strength at the stop, fading out by the time you are
                // one location away.
                proximity: (1 - (camera.position - i).abs()).clamp(0.0, 1.0),
                onTap: () => camera.jumpTo(i),
              ),
            ),
        ],
      ),
    ),
  );
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.camera});

  final WorldCamera camera;

  @override
  Widget build(BuildContext context) => _NavLink(
    label: 'DS',
    proximity: (1 - camera.position.abs()).clamp(0.0, 1.0),
    bold: true,
    onTap: () => camera.jumpTo(0),
  );
}

class _NavLink extends StatefulWidget {
  const _NavLink({
    required this.label,
    required this.proximity,
    required this.onTap,
    this.bold = false,
  });

  final String label;

  /// 0 when the camera is a location away or more, 1 when it is here.
  final double proximity;
  final VoidCallback onTap;
  final bool bold;

  @override
  State<_NavLink> createState() => _NavLinkState();
}

class _NavLinkState extends State<_NavLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final lit = widget.proximity.clamp(0.0, 1.0);
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
