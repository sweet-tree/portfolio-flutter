/// The world: one fixed viewport, one scene, and the locations shown in it.
///
/// ⚠️ THE PAGE ITSELF NEVER SCROLLS. Only the content panels do, inside their
/// own boxes. Besides being the concept, this kills a whole class of mobile
/// bugs: Safari's URL bar only collapses on document scroll, so if the
/// document never scrolls the viewport height never changes underneath us.
///
/// ⚠️ THE CAMERA NO LONGER TRAVELS — 2026-08-11. The world used to be one
/// continuous space with the locations laid side by side, and navigating slid
/// the whole thing past the window on a spring. That is retired: the scene is
/// one fixed view, and a location is simply what is shown in front of it.
///
/// The travel is not lost. It is tagged `one-world-v1` in this repo, complete
/// and working, and extracted as a standalone package at
/// `~/Documents/AI/one-world-travel` — camera, wiring, tests and the three
/// traps that made it hard.
library;

import 'package:flutter/material.dart' show Material;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:portfolio/src/chrome/nav.dart';
import 'package:portfolio/src/chrome/rail.dart';
import 'package:portfolio/src/design/layout.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/design/type.dart';
import 'package:portfolio/src/query_params.dart';
import 'package:portfolio/src/world/glass_card.dart';
import 'package:portfolio/src/world/hero_panel.dart';
import 'package:portfolio/src/world/locations.dart';
import 'package:portfolio/src/world/type_glow.dart';
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

class WorldView extends StatefulWidget {
  const WorldView({super.key});

  @override
  State<WorldView> createState() => _WorldViewState();
}

class _WorldViewState extends State<WorldView> {
  /// Which location is in front of the scene. The whole of the navigation
  /// state, now that there is no space to be part-way through.
  int _index = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Browser back/forward and pasted URLs arrive here.
    final index = indexOfPath(GoRouterState.of(context).matchedLocation);
    if (index != _index) setState(() => _index = index);
  }

  /// A nav click. The URL is written immediately rather than on arrival —
  /// there is no arrival any more.
  ///
  /// `replace`, not `go`: moving between sections of one view is not a history
  /// event, or the back button would walk back through every section visited.
  void _go(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    context.replace(kLocations[index].path);
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.bg,
    child: Stack(
      children: [
        const Positioned.fill(child: WorldScene()),
        // Everything except the scene comes off for ?bare=1.
        if (!bareScene) ...[
          // ⚠️ ONLY THE CURRENT ONE IS BUILT. Under travel all three existed at
          // once, side by side, because you could be looking at two of them.
          // Nothing is ever half-way between them now, so the other two would
          // be laid out, painted and thrown away every frame for nothing.
          Positioned.fill(
            child: _index == 0
                ? HeroPanel(
                    location: kLocations[0],
                    index: _index,
                    onGo: _go,
                  )
                : _LocationPanel(location: kLocations[_index]),
          ),
          // The light the statement throws off when the energy reaches it.
          //
          // ABOVE the panels, so it adds to the letters rather than being
          // hidden behind them, and below the nav, which is chrome and should
          // not glow. It only ever adds light — the type underneath is
          // untouched and stays crisp.
          const TypeGlow(),
          WorldNav(index: _index, onGo: _go),
          // ⚠️ CHROME SITS OVER EVERYTHING, INCLUDING A CARD. The header and
          // the rail are the frame the world is seen through — content arrives
          // BETWEEN them, never on top of them.
          WorldRail(index: _index, onGo: _go),
        ],
      ],
    ),
  );
}

/// A location that is not the hero: its content, on a pane of glass.
///
/// ⚠️ THE CARD IS BOUNDED BY THE CHROME, and that is the whole layout rule. It
/// starts under the nav and stops above the rail, so both stay legible on the
/// scene itself and the card never becomes the frame. Its left and right edges
/// land on the same margin the wordmark and the rail sit on — the composition
/// has one vertical, and a card that ignored it would be the only thing on the
/// page that did.
class _LocationPanel extends StatelessWidget {
  const _LocationPanel({required this.location});

  final Location location;

  @override
  Widget build(BuildContext context) {
    final gutter = ContentColumn.gutterOf(context);
    final inset = fluid(context.vw, min: Space.md, max: Space.lg);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        kNavHeight,
        gutter,
        // Clear of the rail by the same gap the hero leaves.
        gutter + railHeightOf(context) + gutter,
      ),
      child: GlassCard(
        child: Padding(
          padding: EdgeInsets.all(fluid(context.vw, min: Space.lg, max: 56)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(location.role, style: AppType.label(context)),
              SizedBox(height: inset),
              // Keyed because several locations share a word with their own
              // nav link, so text alone cannot tell the display title from the
              // link that goes to it.
              Text(
                location.title,
                key: Key('title-${location.path}'),
                style: AppType.display(context),
              ),
              SizedBox(height: inset),
              // ⚠️ THE PAGE STILL NEVER SCROLLS — the card does, inside itself.
              // That is the same rule the world has always had, and it is what
              // keeps Safari's URL bar from moving the viewport underneath us.
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    location.body,
                    style: AppType.body(context),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
