/// Portfolio — Dmitry Sevryukov.
///
/// Web only. Routing, theme, and the single view that everything lives in.
///
/// THERE ARE NO PAGES. Every route builds the same [WorldView]; the URL only
/// says which location the camera should travel to. That is why every route
/// here uses a `NoTransitionPage` — a page transition would fight the travel
/// animation, and there is nothing to transition between anyway.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/stats_overlay.dart';
import 'package:portfolio/src/world/locations.dart';
import 'package:portfolio/src/world/shaders.dart';
import 'package:portfolio/src/world/type_glow.dart';
import 'package:portfolio/src/world/world_view.dart';

/// ⚠️ THE FIRST FRAME THE VISITOR SEES IS THE FINISHED ONE. Nothing arrives
/// afterwards, because nothing is still loading by then.
///
/// This site used to assemble itself in front of the visitor. The shaders were
/// loaded by the widgets that use them, so the first frames had no scene and no
/// glow; the statement was drawn by Flutter as flat ink and then redrawn by the
/// glow, tinted, once its program arrived. Each of those was one visible change
/// per page load, at a moment the network decided — which is precisely the
/// twitch you get on refresh, and it cannot be tuned away, only removed.
///
/// So the frame is held until the app can actually draw itself:
///
///   1. the shader programs are compiled — an await, before anything is built
///   2. the first frame is DEFERRED. The framework still builds, lays out and
///      paints; the result is simply not sent to the engine, so the page keeps
///      showing the background `web/index.html` painted
///   3. that withheld frame is what rasterises the statement into its mask
///   4. the mask lands, the frame is allowed, and the first thing composited
///      is the complete composition
Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  await Shaders.load();
  binding.deferFirstFrame();
  runApp(const PortfolioApp());
  _releaseWhenStatementIsSet(binding);
}

/// Releases the held frame once the statement has been rasterised.
///
/// The mask is captured in a post-frame callback, so it exists at the end of
/// the first withheld frame — see [TypeMaskCapture]. Waiting for it, rather
/// than for a duration, is what makes the first composited frame complete by
/// construction rather than by hoping the timing holds on a slower device.
void _releaseWhenStatementIsSet(WidgetsBinding binding) {
  var released = false;
  void release() {
    if (released) return;
    released = true;
    typeGlyphs.removeListener(release);
    // Off the frame: the notifier fires from inside a post-frame callback, and
    // allowFirstFrame wants the scheduler idle.
    Timer.run(binding.allowFirstFrame);
  }

  // ⚠️ A WATCHDOG, NOT A TIMEOUT TO TUNE. If the hero ever stops producing a
  // mask — a route that does not build it, a layout that never gets a size, a
  // thrown exception — this is what guarantees the visitor still gets a page
  // instead of an eternally blank one. It should never fire.
  Timer(const Duration(seconds: 2), release);
  typeGlyphs.addListener(release);
  if (typeGlyphs.value != null) release();
}

/// Routes are generated from the location list, so a stop can never exist
/// without a URL and a URL can never point at a stop that isn't there.
final GoRouter _router = GoRouter(
  routes: [
    for (final location in kLocations)
      GoRoute(
        path: location.path,
        pageBuilder: (context, state) =>
            const NoTransitionPage<void>(child: WorldView()),
      ),
  ],
);

class PortfolioApp extends StatelessWidget {
  const PortfolioApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Dmitry Sevryukov — Developer',
    debugShowCheckedModeBanner: false,
    routerConfig: _router,
    // Material supplies routing, gestures and text plumbing only. Nothing
    // visible comes from its widget vocabulary — AppBar, Card and
    // NavigationRail read as "an Android app in a browser", which is the one
    // impression a portfolio cannot afford.
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: Palette.bg,
      useMaterial3: true,
    ),
    builder: (context, child) => Stack(
      children: [
        child ?? const SizedBox.shrink(),
        // Opt-in via ?stats=1. A URL switch rather than a debug-build flag,
        // because the numbers that matter — frame rate, which build is running,
        // payload behaviour — can only be read off a real phone hitting the
        // real deployment.
        if (statsRequested) const StatsOverlay(),
      ],
    ),
  );
}
