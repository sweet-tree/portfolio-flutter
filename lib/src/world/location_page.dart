/// One location's content, standing in front of the scene.
///
/// This is what a route builds. It is transparent: the world behind it belongs
/// to the shell and outlives every navigation — see world_shell.dart.
library;

import 'package:flutter/widgets.dart';
import 'package:portfolio/src/chrome/nav.dart' show kNavHeight;
import 'package:portfolio/src/chrome/rail.dart' show railHeightOf;
import 'package:portfolio/src/design/layout.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/design/type.dart';
import 'package:portfolio/src/world/glass_card.dart';
import 'package:portfolio/src/world/hero_panel.dart';
import 'package:portfolio/src/world/locations.dart';
import 'package:portfolio/src/world/type_glow.dart';

class LocationPage extends StatelessWidget {
  const LocationPage({required this.location, super.key});

  final Location location;

  @override
  Widget build(BuildContext context) {
    if (location.path != kLocations.first.path) {
      return _CardPage(location: location);
    }
    // ⚠️ THE STATEMENT'S TWO HALVES MUST TRAVEL TOGETHER. Its ink is drawn by
    // the panel and its COLOUR by [TypeGlow], from a mask whose rectangle is
    // measured as `panel.globalToLocal(block.localToGlobal(...))` — the
    // statement's position RELATIVE TO THE PANEL. Both halves inside the same
    // page means a page transition moves them identically and that relative
    // position never changes, so they stay locked together and the sentence
    // leaves as one thing.
    //
    // With the glow in the shell, which does not move, the ink slid away and
    // the colour stayed behind until the page unmounted and it blinked out.
    //
    // ⚠️ AND THIS ONLY HOLDS FOR A TRANSLATION. Those two conversions cancel
    // exactly under a slide; under a perspective transform they do not, and the
    // sentence is drawn twice at two sizes. That was built, and looked at.
    // ⚠️ THE SCOPE IS WHAT MAKES THE MASK BELONG TO THIS STATEMENT. Both halves
    // read it from here, and it is created and destroyed with this page — so a
    // sentence cannot outlive itself and be drawn over the next section.
    return StatementScope(
      child: Stack(
        children: [
          Positioned.fill(child: HeroPanel(location: location)),
          // ABOVE the panel, so it adds to the letters rather than being hidden
          // behind them. It only ever adds light — the type underneath stays
          // crisp.
          const Positioned.fill(child: TypeGlow()),
        ],
      ),
    );
  }
}

/// A location that is not the hero: its content, on a pane of glass.
///
/// ⚠️ THE CARD IS BOUNDED BY THE CHROME, and that is the whole layout rule. It
/// starts under the nav and stops above the rail, so both stay legible on the
/// scene itself and the card never becomes the frame. Its left and right edges
/// land on the same margin the wordmark and the rail sit on — the composition
/// has one vertical, and a card that ignored it would be the only thing on the
/// page that did.
class _CardPage extends StatelessWidget {
  const _CardPage({required this.location});

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
        // ⚠️ THE WHOLE CONTENT SCROLLS, HEADING INCLUDED — and that is a fix,
        // not a preference. It used to be a fixed heading with the body in an
        // Expanded beneath it, which assumes the heading always fits. On a
        // short frame it does not: at 852 × 393, phone landscape, the display
        // title alone is taller than the card, so it was sliced in half and the
        // body never appeared at all. Nothing here may claim a fixed share of a
        // height we do not control.
        //
        // ⚠️ THE PAGE STILL NEVER SCROLLS — the card does, inside itself. That
        // is the same rule the world has always had, and it is what keeps
        // Safari's URL bar from moving the viewport underneath us.
        child: SingleChildScrollView(
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
              Text(location.body, style: AppType.body(context)),
            ],
          ),
        ),
      ),
    );
  }
}
