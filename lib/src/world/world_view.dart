/// The world: one fixed viewport, the locations in it, and how you travel
/// between them.
///
/// ⚠️ THE PAGE ITSELF NEVER SCROLLS. Only the content panels do, inside their
/// own boxes. Besides being the concept, this kills a whole class of mobile
/// bugs: Safari's URL bar only collapses on document scroll, so if the
/// document never scrolls the viewport height never changes underneath us.
library;

import 'dart:async';

import 'package:flutter/material.dart' show Material;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:portfolio/src/chrome/nav.dart';
import 'package:portfolio/src/design/layout.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/design/type.dart';
import 'package:portfolio/src/world/hero_panel.dart';
import 'package:portfolio/src/world/locations.dart';
import 'package:portfolio/src/world/world_camera.dart';
import 'package:portfolio/src/world/world_field.dart';

class WorldView extends StatefulWidget {
  const WorldView({super.key});

  @override
  State<WorldView> createState() => _WorldViewState();
}

class _WorldViewState extends State<WorldView>
    with SingleTickerProviderStateMixin {
  late final WorldCamera _camera = WorldCamera(count: kLocations.length);
  late final Ticker _ticker;
  Duration? _last;

  /// The stop the URL currently names. Kept so the camera settling can rewrite
  /// the URL without that rewrite bouncing back and re-targeting the camera.
  int _urlIndex = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _camera.addListener(_onCameraChanged);
  }

  /// The ticker only runs while the camera actually has somewhere to go.
  ///
  /// Leaving it running permanently pins the site at 60fps forever — it drains
  /// a phone battery for nothing, and it makes `pumpAndSettle` in a widget
  /// test wait forever, which is how this was caught.
  void _wake() {
    if (!_ticker.isActive) {
      _last = null;
      unawaited(_ticker.start());
    }
  }

  void _onCameraChanged() {
    _wake();
    _syncUrl();
  }

  void _onTick(Duration elapsed) {
    final previous = _last;
    _last = elapsed;
    final dt = previous == null
        ? 1 / 60
        : (elapsed - previous).inMicroseconds / 1e6;
    if (dt > 0) _camera.tick(dt);
    if (!_camera.moving) _ticker.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Browser back/forward and pasted URLs arrive here. Travel to them rather
    // than cutting, so history navigation looks the same as clicking.
    final path = GoRouterState.of(context).matchedLocation;
    final index = indexOfPath(path);
    if (index != _urlIndex) {
      _urlIndex = index;
      _camera.target = index.toDouble();
    }
  }

  /// Rewrites the URL once the camera has actually settled somewhere new.
  ///
  /// `replace`, not `go`: travelling is not a history event, or the back
  /// button would walk back through every stop the visitor drifted past.
  void _syncUrl() {
    if (_camera.moving) return;
    final index = _camera.nearest;
    if (index == _urlIndex) return;
    _urlIndex = index;
    if (mounted) context.replace(kLocations[index].path);
  }

  @override
  void dispose() {
    _camera
      ..removeListener(_onCameraChanged)
      ..dispose();
    _ticker.dispose();
    super.dispose();
  }

  // ── input ──────────────────────────────────────────────────────────────────
  //
  // NAV CLICKS ONLY, on purpose. Drag, wheel, the panel-edge handoff and the
  // keyboard were all written at once and none of them was verified on its
  // own; the drag was wrong. They come back one at a time, each proven before
  // the next is added.

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.bg,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return AnimatedBuilder(
          animation: _camera,
          builder: (context, _) => Stack(
            children: [
              Positioned.fill(child: WorldField(camera: _camera)),
              for (var i = 0; i < kLocations.length; i++)
                Positioned(
                  left: (i - _camera.position) * width,
                  top: 0,
                  width: width,
                  height: constraints.maxHeight,
                  // Only the hero is composed by hand so far. The others keep
                  // the plain panel until their turn comes.
                  child: i == 0
                      ? HeroPanel(location: kLocations[i], camera: _camera)
                      : _LocationPanel(location: kLocations[i]),
                ),
              WorldNav(camera: _camera),
            ],
          ),
        );
      },
    ),
  );
}

class _LocationPanel extends StatelessWidget {
  const _LocationPanel({required this.location});

  final Location location;

  @override
  Widget build(BuildContext context) {
    final top = fluid(context.vw, min: 96, max: 152);
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: Space.xl),
      // Full frame width, not the 720px prose column: the heading is the
      // dominant mass of the composition, and a mass constrained to reading
      // width is just a large paragraph.
      child: ContentColumn(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(location.role, style: AppType.label(context)),
            // Anchors the heading to the bottom of the frame. A mass sitting
            // on the lower edge reads as planted; floated in the middle it
            // reads as undecided.
            const Spacer(),
            // Keyed because several locations share a word with their own nav
            // link, so text alone cannot tell the display title from the link
            // that travels to it.
            Text(
              location.title,
              key: Key('title-${location.path}'),
              style: AppType.display(context),
            ),
          ],
        ),
      ),
    );
  }
}
