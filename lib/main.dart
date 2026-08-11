/// Portfolio — Dmitry Sevryukov.
///
/// Web only. Routing, theme, and the single view that everything lives in.
///
/// THERE ARE NO PAGES. Every route builds the same [WorldView] over the same
/// scene; the URL only says which location is showing in front of it. That is
/// why every route here uses a `NoTransitionPage` — there is nothing to
/// transition between, and the scene must not flicker while the content over it
/// changes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/stats_overlay.dart';
import 'package:portfolio/src/world/carving.dart';
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
  // ⚠️ BOTH AWAITED, AND THE CARVING FOR A SECOND REASON. A shader arriving
  // late costs one plain frame; the carving arriving late is worse, because the
  // cube's shading is cached on first paint and would then be kept UNCARVED
  // until something else happened to invalidate it. See [Carving.bake].
  await Future.wait<void>([Shaders.load(), Carving.bake()]);
  // ⚠️ ONLY WHEN THERE IS ACTUALLY A STATEMENT COMING. Holding the frame for a
  // mask that will never be made buys nothing and costs the whole watchdog: the
  // page sits on its flat background for two seconds and then appears.
  //
  // Two cases produce no mask. `?bare=1` renders the scene alone. And only the
  // hero composes a statement — the other locations are a heading over the
  // scene, with nothing to draw twice, so there is nothing to hide.
  //
  // ⚠️ THE SECOND CASE IS NEW, and it is a consequence of the world no longer
  // travelling: every location used to be built at once, side by side, so the
  // hero's mask existed however you arrived. Now only the location you asked
  // for is built. Measured before this: the hero painted at 1.3s and /about at
  // 3.1s, which is the watchdog and nothing else.
  final holdForStatement = !bareScene && indexOfPath(_initialPath) == 0;
  if (holdForStatement) binding.deferFirstFrame();
  runApp(const PortfolioApp());
  if (holdForStatement) _releaseWhenStatementIsSet(binding);
}

/// The location the page was opened at, before the router exists.
///
/// Written to survive either URL strategy rather than assuming the current one:
/// go_router defaults to the hash on web, so the path lives in the fragment,
/// but nothing here would notice being switched to real paths later.
String get _initialPath {
  final base = Uri.base;
  if (base.fragment.startsWith('/')) return base.fragment;
  return base.path.isEmpty ? '/' : base.path;
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
