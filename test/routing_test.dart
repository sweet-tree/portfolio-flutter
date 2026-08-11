/// The routes are the one thing worth testing at this stage.
///
/// Every URL here is meant to be pasteable into a CV and to survive a refresh,
/// so a route quietly disappearing or renaming is a real breakage — a dead link
/// on a page whose whole job is to be linked to.
///
/// ⚠️ THE CAMERA'S OWN TESTS LEFT WITH THE CAMERA — 2026-08-11. The spring, the
/// flick projection and the elastic ends are no longer in this repo; they live
/// with the extraction at `~/Documents/AI/one-world-travel`, where they still
/// run, and in the tag `one-world-v1` in place.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio/main.dart';
import 'package:portfolio/src/world/locations.dart';

void main() {
  /// The display title of a location, as opposed to the nav link that goes to
  /// it — several locations share a word with their own link.
  Finder title(Location location) => find.byKey(Key('title-${location.path}'));

  testWidgets('opens on the first location', (tester) async {
    await tester.pumpWidget(const PortfolioApp());
    expect(title(kLocations.first), findsOneWidget);
  });

  testWidgets('every location is reachable from the nav', (tester) async {
    // One app, navigated through — not a fresh pump per route. The router is a
    // top-level singleton, so re-pumping would hand a second widget tree the
    // same router and test something other than navigation.
    await tester.pumpWidget(const PortfolioApp());

    for (final location in kLocations.skip(1)) {
      await tester.tap(find.byKey(Key('nav-${location.label}')));
      // NOT pumpAndSettle: the mark's shader animates continuously, so there is
      // no idle state to settle into and pumpAndSettle would wait forever.
      // A couple of frames is now plenty — arriving is a setState, not a
      // journey.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        title(location),
        findsOneWidget,
        reason: '${location.label} is linked but never arrives',
      );
    }
  });

  testWidgets('the nav shows which location you are on', (tester) async {
    // The highlight is the only thing telling a visitor where they are, now
    // that nothing slides to show them.
    await tester.pumpWidget(const PortfolioApp());
    await tester.tap(find.byKey(const Key('nav-Work')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    final work = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('nav-Work')),
        matching: find.byType(Text),
      ),
    );
    final about = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('nav-About')),
        matching: find.byType(Text),
      ),
    );
    expect(
      work.style?.color,
      isNot(about.style?.color),
      reason: 'the location being shown is lit and the others are not',
    );
  });
}
