/// The routes are the one thing worth testing at this stage.
///
/// Every URL here is meant to be pasteable into a CV and to survive a refresh,
/// so a route quietly disappearing or renaming is a real breakage — a dead link
/// on a page whose whole job is to be linked to.
///
/// Note what is NOT tested: how travel feels. The spring, the fling projection
/// and the wheel handoff cannot be asserted meaningfully — they are judged by
/// driving the real thing in a browser.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio/main.dart';
import 'package:portfolio/src/world/locations.dart';
import 'package:portfolio/src/world/world_camera.dart';

void main() {
  /// The display title of a location, as opposed to the nav link that travels
  /// to it — several locations share a word with their own link.
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
      // NOT pumpAndSettle: the mark's shader animates continuously, so there
      // is no idle state to settle into and pumpAndSettle would wait forever.
      // Pump past the camera's travel instead — it is a spring, so a second
      // of frames is far more than it needs.
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        title(location),
        findsOneWidget,
        reason: '${location.label} is linked but never arrives',
      );
    }
  });

  test('the camera settles exactly on a location', () {
    // A camera that stops at 1.9998 would leave the URL and the nav highlight
    // disagreeing with what is on screen, so the settle threshold matters.
    final camera = WorldCamera(count: kLocations.length)..jumpTo(2);
    for (var i = 0; i < 600; i++) {
      camera.tick(1 / 60);
    }
    expect(camera.position, 2.0);
    expect(camera.moving, isFalse);
    expect(camera.nearest, 2);
  });

  test('a fast flick travels further than a slow one', () {
    // The fling projection is what makes a drag feel physical rather than
    // like a slider, so it is worth pinning down.
    WorldCamera thrown(double velocity) => WorldCamera(count: kLocations.length)
      ..beginDrag()
      ..dragBy(0.2)
      ..endDrag(velocity);

    expect(thrown(0.5).target, 0.0);
    expect(thrown(6).target, greaterThan(0.0));
  });

  test('travel cannot leave the world', () {
    final camera = WorldCamera(count: kLocations.length)..nudge(99);
    expect(camera.target, (kLocations.length - 1).toDouble());
    camera.nudge(-99);
    expect(camera.target, 0.0);
  });
}
