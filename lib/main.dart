/// Portfolio — Dmitry Sevryukov.
///
/// Web only. This file is the app shell and nothing else: routing, theme, and
/// the page scaffold. Content lives under `lib/src/`.
///
/// Current stage: skeleton. The routes exist and the URLs work; the pages are
/// placeholders.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:portfolio/src/stats_overlay.dart';

void main() => runApp(const PortfolioApp());

/// The site's routes.
///
/// These are real URLs, which is the whole reason a router is here: `/work` has
/// to survive a refresh, work with the back button, and be pasteable into a CV.
final GoRouter _router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const _Placeholder(title: 'Home'),
    ),
    GoRoute(
      path: '/work',
      builder: (context, state) => const _Placeholder(title: 'Work'),
    ),
    GoRoute(
      path: '/about',
      builder: (context, state) => const _Placeholder(title: 'About'),
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
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0B0B0F),
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

/// Stands in until the real pages exist. Deliberately plain: the layout and
/// type decisions are not made yet, and a half-designed placeholder would only
/// anchor them badly.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            // Keyed so a test can tell the heading from the nav button of the
            // same name.
            key: const Key('page-title'),
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final route in const [
                ('Home', '/'),
                ('Work', '/work'),
                ('About', '/about'),
              ])
                TextButton(
                  onPressed: () => context.go(route.$2),
                  child: Text(route.$1),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
