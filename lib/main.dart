/// Portfolio — Dmitry Sevryukov.
///
/// Web only. Routing, theme, and the single view that everything lives in.
///
/// THERE ARE NO PAGES. Every route builds the same [WorldView]; the URL only
/// says which location the camera should travel to. That is why every route
/// here uses a `NoTransitionPage` — a page transition would fight the travel
/// animation, and there is nothing to transition between anyway.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/stats_overlay.dart';
import 'package:portfolio/src/world/locations.dart';
import 'package:portfolio/src/world/world_view.dart';

void main() => runApp(const PortfolioApp());

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
