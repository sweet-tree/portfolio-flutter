/// The permanent part of the site: the scene, and the frame around it.
///
/// ⚠️ THE SCENE LIVES ABOVE THE ROUTER, AND THAT IS THE WHOLE POINT OF THIS
/// FILE. Every route used to build its own copy of the world, so navigating
/// meant tearing the scene down and standing a new one up: the shader
/// reloading, the cube's cached shading recomputed, a visible hitch on a page
/// change that should have been free. Here it is built once and never rebuilt —
/// only the CONTENT in front of it changes.
///
/// That is what a `ShellRoute` is for. Its builder is handed the current
/// route's page as a child, and the shell itself persists across all of them.
///
/// ⚠️ THE PAGES MUST NOT PAINT AN OPAQUE BACKGROUND, or they cover the thing
/// they are supposed to be standing in front of. The one background colour in
/// the app is here, underneath the scene.
///
/// ⚠️ THE PAGE ITSELF NEVER SCROLLS. Only content panels do, inside their own
/// boxes. Besides being the concept, this kills a whole class of mobile bugs:
/// Safari's URL bar only collapses on document scroll, so if the document never
/// scrolls the viewport height never changes underneath us.
library;

import 'package:flutter/material.dart' show Material;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:portfolio/src/chrome/nav.dart';
import 'package:portfolio/src/chrome/rail.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/query_params.dart';
import 'package:portfolio/src/world/locations.dart';
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

class WorldShell extends StatelessWidget {
  const WorldShell({required this.child, super.key});

  /// The current route's page.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final index = indexOfPath(GoRouterState.of(context).matchedLocation);
    // `replace`, not `go`: moving between sections of one site is not a history
    // event worth stacking, or the back button walks through every section
    // visited rather than leaving the site.
    void go(int i) => context.replace(kLocations[i].path);

    return Material(
      color: Palette.bg,
      child: Stack(
        children: [
          // Built once for the life of the page. Nothing about routing reaches
          // it.
          const Positioned.fill(child: WorldScene()),
          if (!bareScene) ...[
            Positioned.fill(child: child),
            // ⚠️ THE STATEMENT'S COLOUR LAYER IS NOT HERE — it is inside the
            // hero's page, and it has to be. The statement is drawn in two
            // halves: the ink by the page, the colour by TypeGlow. Kept in the
            // shell, the shell does not move during a transition, so the ink
            // slid away while the colour stayed exactly where it was and then
            // vanished when the page unmounted. Two halves of one sentence,
            // going separate ways. See location_page.dart.
            WorldNav(index: index, onGo: go),
            // ⚠️ CHROME SITS OVER EVERYTHING, INCLUDING A CARD. The header and
            // the rail are the frame the world is seen through — content
            // arrives between them, never on top of them.
            WorldRail(index: index, onGo: go),
          ],
        ],
      ),
    );
  }
}
