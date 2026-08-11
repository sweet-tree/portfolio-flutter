/// A pane of glass with content on it, sitting between the nav and the rail.
///
/// ⚠️ THIS IS A LOOK, NOT THE MECHANISM. It uses Flutter's own
/// `BackdropFilter`, which is the fastest way to answer "does a glass card over
/// this scene read right" and commits to nothing.
///
/// What that costs, read out of the engine rather than remembered —
/// `lib/web_ui/lib/src/engine/layer/layer_visitor.dart`:
///
///   · a backdrop filter paints as `saveLayerWithFilter(paintBounds, …)`, and
///     `paintBounds` is the child's bounds EXPANDED TO THE CULL RECT. The cull
///     rect is the intersection of the enclosing clips — so the `ClipRRect`
///     below is not decoration, it is what stops this being a full-screen
///     saveLayer and a full-screen blur every frame.
///   · ⚠️ `ImageFilter.blur`'s `bounds` argument — the "bounded blur" that
///     exists precisely for frosted glass, substituting transparent black for
///     samples outside the rectangle — is SILENTLY IGNORED by both web
///     renderers. Both `createBlurImageFilter` implementations say so in a
///     comment and fall back to an unbounded blur (flutter#175899). So whatever
///     lies just outside the card bleeds into its edges, and there is no
///     setting that prevents it.
///
/// It also knows the scene only as PIXELS. It cannot know the energy, which the
/// scene renders into its own image every frame — so nothing here can be lit by
/// the field the sheet and the cube share.
///
/// ⚠️ AND THE OBVIOUS UPGRADE IS NOT AVAILABLE ON WEB. `ui.ImageFilter.shader`,
/// which hands a `.frag` the backdrop as a sampler, is Impeller-only: web_ui's
/// `painting.dart` hard-codes `isShaderFilterSupported => false` and its
/// factory throws `UnsupportedError` unconditionally. Web is skwasm or
/// CanvasKit, never Impeller, so that route does not exist at any version.
///
/// The real one therefore goes the other way: draw the card ourselves and feed
/// our OWN shader the two images the scene already renders — the composed scene
/// and the energy field — through `setImageSampler`, which is fully supported
/// and which this app already does nine times a frame. None of that is here
/// yet, on purpose.
///
/// Knobs, so the look can be driven rather than argued about:
/// `?card=0` off · `?blur=` how soft · `?tint=` how dim · `?radius=` corners.
library;

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/query_params.dart';

/// Whether content sits on glass at all. `?card=0` puts it straight on the
/// scene, which is what the other locations did before — and is the comparison
/// that decides whether the card is an improvement.
final bool kCardOn = qString('card', '1') != '0';

/// How far the scene behind is smeared, in logical pixels.
///
/// ⚠️ THE ONE NUMBER THAT DECIDES WHETHER IT READS AS GLASS OR AS A SCRIM. Too
/// little and it is a dirty window; too much and the scene behind stops being
/// legible as a scene, at which point the card may as well be opaque and the
/// whole idea is paying for nothing.
final double kCardBlur = qDouble('blur', 18);

/// How much near-black is laid over the blur, 0 to 1.
///
/// Type needs contrast against whatever the scene happens to be doing behind
/// it, and the scene is not uniform — the energy is bright in places. This is
/// what buys legibility, and it is the direct trade against seeing through.
final double kCardTint = qDouble('tint', 0.28);

final double kCardRadius = qDouble('radius', 20);

/// Fills whatever space it is given. The caller decides where the card is; this
/// only decides what it is made of.
class GlassCard extends StatelessWidget {
  const GlassCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!kCardOn) return child;
    final radius = BorderRadius.circular(kCardRadius);
    final fill = BoxDecoration(
      color: Palette.bg.withValues(alpha: kCardTint),
      borderRadius: radius,
      // A hairline, the same one the rail draws with. A cut edge that BURNS is
      // the thing that would make this read as the scene's own glass, and it
      // needs the shader — see the note at the top.
      border: Border.all(color: Palette.line),
    );
    return ClipRRect(
      // ⚠️ THE CLIP IS WHAT BOUNDS THE BLUR — and, per the engine, its COST. A
      // backdrop filter's paint bounds are its child's bounds expanded to the
      // cull rect, and the cull rect is the intersection of the enclosing
      // clips. Without this the saveLayer and the filter cover the whole
      // screen, and the nav and the rail go soft with everything else.
      borderRadius: radius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: kCardBlur, sigmaY: kCardBlur),
        child: DecoratedBox(decoration: fill, child: child),
      ),
    );
  }
}
