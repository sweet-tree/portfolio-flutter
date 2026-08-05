/// The routes are the one thing worth testing at this stage.
///
/// Every URL here is meant to be pasteable into a CV and to survive a refresh,
/// so a route quietly disappearing or renaming is a real breakage — a dead link
/// on a page whose whole job is to be linked to.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio/main.dart';

void main() {
  /// The page heading, as opposed to the nav button of the same name.
  ///
  /// Matches the keyed widget itself — `find.descendant` cannot be used here
  /// because the key is ON the Text, so it would be looking for the widget
  /// inside itself and always come back empty.
  Finder heading(String text) => find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.key == const Key('page-title') &&
        widget.data == text,
  );

  testWidgets('opens on the home page', (tester) async {
    await tester.pumpWidget(const PortfolioApp());
    expect(heading('Home'), findsOneWidget);
  });

  testWidgets('every advertised route resolves', (tester) async {
    // One app, navigated through — not a fresh pump per route. The router is a
    // top-level singleton, so re-pumping would hand a second widget tree the
    // same router and test something other than navigation.
    await tester.pumpWidget(const PortfolioApp());

    for (final label in const ['Work', 'About', 'Home']) {
      await tester.tap(find.widgetWithText(TextButton, label));
      await tester.pumpAndSettle();
      expect(
        heading(label),
        findsOneWidget,
        reason: '$label is linked but does not resolve to a page',
      );
    }
  });
}
