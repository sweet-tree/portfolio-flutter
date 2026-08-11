/// The permanent part of the site: the scene, and the frame around it.
///
/// ⚠️ THE SCENE LIVES ABOVE THE ROUTER, AND THAT IS THE WHOLE POINT OF THIS
/// FILE. Every route used to build its own copy of the world, so navigating
/// meant tearing the scene down and standing a new one up: the shader
/// reloading, the cube's cached shading recomputed, a visible hitch on a page
/// change that should have been free. Here it is built once and never
/// rebuilt — only the CONTENT in front of it changes.
///
/// ⚠️ AND THE SECTIONS ARE A STACK OF REAL ROUTES, dragged by hand. The
/// gesture here does not trigger an animation and step back; it takes hold of
/// the route's own transition and writes to it, so a section is wherever your
/// finger has put it. See section_route.dart for how, and for why going
/// forwards is harder than going back.
///
/// ⚠️ THE PAGES MUST NOT PAINT AN OPAQUE BACKGROUND, or they cover the thing
/// they are supposed to be standing in front of. The one background colour in
/// the app is here, underneath the scene.
///
/// ⚠️ THE DOCUMENT ITSELF NEVER SCROLLS. Only content inside a card does.
/// Besides being the concept, this kills a whole class of mobile bugs:
/// Safari's URL bar only collapses on document scroll, so if the document
/// never scrolls the viewport height never changes underneath us.
library;

import 'dart:async';

import 'package:flutter/material.dart' show Material;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:portfolio/src/chrome/nav.dart';
import 'package:portfolio/src/chrome/rail.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/query_params.dart';
import 'package:portfolio/src/world/locations.dart';
import 'package:portfolio/src/world/section_route.dart';
import 'package:portfolio/src/world/world_scene.dart';

/// `?bare=1` — the scene and nothing else: no panels, no nav, no statement.
///
/// It exists for DESIGN WORK. The layout is designed in Figma on top of a still
/// of this scene, and that still has to be free of type — otherwise the old
/// statement ghosts behind whatever is being drawn over it, and every judgement
/// about where a line can go is made against a picture of the answer we already
/// have.
///
/// It also has to be a real render rather than a flat dark rectangle: the
/// statement's legibility depends on where the bright energy actually falls,
/// so type positioned against grey would be positioned against a fiction.
final bool bareScene = qFlag('bare');

/// How far a finger has to move before it is a swipe rather than a twitch.
const double _kIntent = 8;

class WorldShell extends StatefulWidget {
  const WorldShell({required this.drag, required this.child, super.key});

  /// The hand that takes hold of a section's transition.
  final SectionDrag drag;

  /// The current route's page.
  final Widget child;

  @override
  State<WorldShell> createState() => _WorldShellState();
}

class _WorldShellState extends State<WorldShell> {
  /// Null until this drag has decided what it is doing.
  bool? _forward;
  double _travelled = 0;

  /// Which section is on top.
  ///
  /// ⚠️ READ FROM THE ROUTER'S DELEGATE, AND REBUILT WITH IT. Taken from
  /// `GoRouterState.of(context)` in the shell's own build, this was the state
  /// of the SHELL's match — which does not change when a section is pushed on
  /// top of it, so the shell never rebuilt and the nav highlight and the rail's
  /// counter stayed on whatever was showing first.
  ///
  /// The delegate is a Listenable precisely so that anything outside the page
  /// stack can follow it.
  int get _index => indexOfPath(GoRouter.of(context).state.matchedLocation);

  void _start() {
    _forward = null;
    _travelled = 0;
  }

  void _update(DragUpdateDetails details) {
    final width = context.size?.width ?? 1;
    // Which way this is going is decided once, on the first real movement, and
    // then held: a drag that wavered would otherwise flip mid-flight.
    if (_forward == null) {
      _travelled += details.delta.dx;
      if (_travelled.abs() < _kIntent) return;
      final forward = _travelled < 0;
      final index = _index;
      if (forward) {
        if (index + 1 >= kLocations.length) return;
        _forward = true;
        // The destination does not exist yet. Asking for it and taking hold of
        // it are two steps — see SectionDrag.beginForward.
        widget.drag.beginForward(width);
        unawaited(context.push(kLocations[index + 1].path));
      } else {
        if (index == 0) return;
        _forward = false;
        widget.drag.beginBack(width);
      }
      // The movement that decided the direction is part of the gesture.
      widget.drag.update(-_travelled);
      return;
    }
    widget.drag.update(-details.delta.dx);
  }

  void _end(DragEndDetails details) {
    final forward = _forward;
    _forward = null;
    _travelled = 0;
    if (forward == null) return;
    widget.drag.release(
      details.velocity.pixelsPerSecond.dx,
      forward: forward,
    );
  }

  /// A nav click or the rail's next link.
  void _go(int index) {
    final current = _index;
    if (index == current) return;
    if (index > current) {
      unawaited(context.push(kLocations[index].path));
    } else {
      // Going back up the stack is a pop, so the section leaves the way it
      // arrived rather than being replaced by a copy of where it came from.
      context.go(kLocations[index].path);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.bg,
    child: Stack(
      children: [
        // Built once for the life of the page. Nothing about routing reaches
        // it.
        const Positioned.fill(child: WorldScene()),
        if (!bareScene) ...[
          Positioned.fill(
            child: GestureDetector(
              // Sideways only. A vertical drag belongs to whatever is under
              // it, which is the card scrolling its own text.
              onHorizontalDragStart: (_) => _start(),
              onHorizontalDragUpdate: _update,
              onHorizontalDragEnd: _end,
              child: widget.child,
            ),
          ),
          // ⚠️ CHROME SITS OVER EVERYTHING AND DOES NOT MOVE. The header and
          // the rail are the frame the world is seen through — sections travel
          // between them, and their staying still is what that is measured
          // against.
          //
          // (The statement's colour layer is NOT here: it is inside the hero's
          // page, because the mask's rectangle is measured relative to that
          // panel and the two halves of the sentence have to move together.
          // See location_page.dart.)
          // Rebuilt whenever the router moves, so the highlight and the
          // counter follow a push as well as a go.
          AnimatedBuilder(
            animation: GoRouter.of(context).routerDelegate,
            builder: (context, _) => Stack(
              children: [
                WorldNav(index: _index, onGo: _go),
                WorldRail(index: _index, onGo: _go),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}
