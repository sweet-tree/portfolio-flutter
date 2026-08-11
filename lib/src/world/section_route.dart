/// Sections as real routes, with their transitions driven by your hand.
///
/// ⚠️ THE GESTURE OWNS THE ROUTE'S ANIMATION. It does not trigger a clip and
/// wait. This is the pattern Flutter itself ships for the iOS back-swipe: a
/// [PageRoute] exposes the [AnimationController] behind its transition, and a
/// drag writes to it directly, so the section is wherever your finger has put
/// it and letting go either finishes the journey or returns it.
///
/// That is the only way to have BOTH — routes owning the pages, so the address
/// bar, the back button and deep links are the router's job rather than
/// bookkeeping we maintain, AND movement that follows a finger. A route
/// transition alone is time-based: a gesture can start it and nothing more.
///
/// ⚠️ AND A FORWARD SWIPE IS HARDER THAN A BACK SWIPE, which is why the
/// framework only ships the latter. Going back drives a route that already
/// exists underneath, so the drag can take it the instant the finger moves.
/// Going forward, the destination does not exist yet: it has to be pushed
/// first, and a route's controller is not born until it is installed. So the
/// first movement is BUFFERED and applied the moment the new route attaches.
/// One frame, and the alternative is a gesture that does nothing until the
/// route happens to be ready.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:portfolio/src/world/location_page.dart';
import 'package:portfolio/src/world/locations.dart';

/// How long a section takes when nothing is holding it — a nav click, or the
/// remainder of a throw.
const Duration kSectionTravel = Duration(milliseconds: 320);

/// How long the movement is assumed to keep going after the finger lifts.
///
/// ⚠️ THE OUTCOME IS DECIDED BY WHERE IT WOULD LAND, NOT BY TWO SEPARATE
/// THRESHOLDS. It used to ask "did it travel far enough?" OR "was it thrown
/// hard enough?", and a small quick swipe falls between the two: not far, not
/// fast, so it rolled back even though every part of it said forward.
///
/// Projecting the release velocity forward for a fraction of a second and
/// asking whether THAT is past halfway is one continuous test. A short flick
/// projects a long way; a slow deliberate drag gets there on distance alone;
/// and a hesitant one that stops short still returns, which is what a hesitant
/// gesture should do.
///
/// A quarter of a second is roughly how long a flicked thing keeps moving
/// before friction takes it, and it is the same order the framework's own page
/// physics use.
const double _kProjection = 0.25;

/// How the remainder settles once a finger lets go.
const Curve _kSettle = Curves.easeOut;

/// The route a section is shown by.
class SectionPage extends Page<void> {
  const SectionPage({
    required this.location,
    required this.drag,
    required super.key,
  });

  final Location location;

  /// The hand that may take hold of this route's transition.
  final SectionDrag drag;

  @override
  Route<void> createRoute(BuildContext context) => SectionRoute(page: this);
}

class SectionRoute extends PageRoute<void> {
  SectionRoute({required SectionPage page}) : super(settings: page);

  SectionPage get _page => settings as SectionPage;

  @override
  Duration get transitionDuration => kSectionTravel;

  /// ⚠️ OPAQUE, DESPITE THE PAGE BEING TRANSPARENT. The scene is painted by the
  /// shell, underneath the whole navigator, so nothing here needs to see the
  /// route below once it has arrived — and NOT dropping it would leave the
  /// previous section built, drawing its own statement in the margins around
  /// the one on top.
  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  /// The controller behind this route's transition, exposed so a drag can write
  /// to it.
  ///
  /// ⚠️ NOT A FIELD OF OUR OWN. [TransitionRoute] already has `controller`, and
  /// declaring another would shadow it — two names for one thing, with only one
  /// of them known to the framework. This hands out the real one, which is how
  /// Cupertino's back-swipe reaches it too.
  AnimationController? get transition => controller;

  @override
  AnimationController createAnimationController() {
    final made = super.createAnimationController();
    // Early, and only for a push a finger is already waiting on: the drag
    // needs the controller the moment it exists, which is before the route is
    // pushed.
    _page.drag.attachExpected(this);
    return made;
  }

  /// ⚠️ WHICH SECTION IS ON TOP IS A LIFECYCLE FACT, NOT A CREATION FACT.
  ///
  /// It was recorded when a route was built, which is right exactly once. Come
  /// back down the stack — home, work, about, then back to work — and work is
  /// on top again without being created again, so nothing said so and the back
  /// swipe had nothing to take hold of. Going home from there did nothing at
  /// all, and only after a full circle, which is what made it look mysterious.
  ///
  /// A route is told when it is pushed and when the one above it pops. Those
  /// are the two ways to arrive at the top, and together they are complete.
  @override
  TickerFuture didPush() {
    _page.drag.onTop = this;
    return super.didPush();
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    _page.drag.onTop = this;
    super.didPopNext(nextRoute);
  }

  @override
  void dispose() {
    _page.drag.detach(this);
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => LocationPage(location: _page.location);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // ⚠️ LINEAR WHILE A FINGER IS ON IT. A curve applied to a dragged value
    // makes the content move at a different speed from the hand holding it,
    // which is the single thing that stops a gesture feeling attached. The
    // curve is only for the part nobody is touching.
    final arriving = _page.drag.isDriving(this)
        ? animation
        : CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
    final leaving = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeOutCubic,
    );

    return SlideTransition(
      // The section being covered gives way, moving a short distance rather
      // than the full width: it is being left behind, not thrown out.
      position: Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.25, 0),
      ).animate(leaving),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(arriving),
        child: child,
      ),
    );
  }
}

/// The hand on the transition.
///
/// Holds whichever section route is currently on top, so a drag can drive it,
/// and buffers movement that arrives before a freshly pushed route exists.
class SectionDrag {
  /// The section currently on top, and the one a back swipe takes hold of.
  ///
  /// ⚠️ MAINTAINED FROM ROUTE LIFECYCLE, NOT FROM CREATION. See
  /// [SectionRoute.didPopNext].
  SectionRoute? onTop;

  /// The one a finger is driving.
  SectionRoute? _driven;

  /// True between asking for a push and the route existing.
  bool _awaitingPush = false;

  /// Movement that arrived before there was anything to apply it to.
  double _pending = 0;

  /// ⚠️ A GESTURE CAN FINISH BEFORE ITS ROUTE EXISTS, and the short ones do.
  ///
  /// A forward swipe asks for a push, and the route's controller is not built
  /// until the frame after. A quick flick is over by then, so the release found
  /// nothing to settle and threw the whole gesture away — which is why LITTLE
  /// swipes did nothing while longer ones, which last long enough for the route
  /// to arrive, worked.
  ///
  /// So the release is buffered exactly as the movement is, and applied the
  /// moment there is something to apply it to.
  bool _releasedEarly = false;
  double _releasedAt = 0;
  bool _releasedForward = false;

  double _width = 1;

  /// A route has just been built. If a finger is waiting for it, hand it over
  /// along with the movement that happened while it was being created.
  void attachExpected(SectionRoute route) {
    if (!_awaitingPush) return;
    _awaitingPush = false;
    _driven = route;
    _advance(_pending);
    _pending = 0;
    if (!_releasedEarly) return;
    _releasedEarly = false;
    _settle(route, _releasedAt, forward: _releasedForward);
    _driven = null;
  }

  void detach(SectionRoute route) {
    if (identical(onTop, route)) onTop = null;
    if (identical(_driven, route)) _driven = null;
  }

  bool isDriving(SectionRoute route) => identical(_driven, route);

  /// Takes hold of the section already on top, to drive it BACKWARDS. This is
  /// the framework's own back-swipe: the route exists, so the finger owns it
  /// from the first pixel.
  void beginBack(double width) {
    _width = width <= 0 ? 1 : width;
    _pending = 0;
    _awaitingPush = false;
    _driven = onTop;
    onTop?.navigator?.didStartUserGesture();
  }

  /// Takes hold of a section that is about to be pushed, to drive it FORWARDS.
  ///
  /// Its controller does not exist yet — a route builds one when it is
  /// installed — so movement is stored and applied by [attachExpected].
  void beginForward(double width) {
    _width = width <= 0 ? 1 : width;
    _pending = 0;
    _awaitingPush = true;
    _driven = null;
    onTop?.navigator?.didStartUserGesture();
  }

  /// Moves the section by [dx] logical pixels of finger.
  void update(double dx) {
    final progress = dx / _width;
    if (_driven?.transition == null) {
      if (_awaitingPush) _pending += progress;
      return;
    }
    _advance(progress);
  }

  void _advance(double progress) {
    final transition = _driven?.transition;
    if (transition == null) return;
    transition.value = (transition.value + progress).clamp(0.0, 1.0);
  }

  /// Lets go, and either finishes the journey or takes it back.
  ///
  /// A throw decides on its own; otherwise how far through it got decides, so
  /// a slow drag past the point of no return still lands.
  ///
  /// ⚠️ THE TWO DIRECTIONS SETTLE TO OPPOSITE ENDS. Driving a section IN, the
  /// journey completes at 1. Driving one OUT — a back swipe — the journey
  /// completes at 0, and the route is then gone. Both are the same controller
  /// moving; only which end means "done" differs.
  void release(double velocity, {required bool forward}) {
    final route = _driven;
    onTop?.navigator?.didStopUserGesture();

    // The route has been asked for but does not exist yet. Keep the decision;
    // attachExpected will carry it out.
    if (route == null && _awaitingPush) {
      _releasedEarly = true;
      _releasedAt = velocity;
      _releasedForward = forward;
      return;
    }

    _driven = null;
    _awaitingPush = false;
    _pending = 0;
    if (route == null) return;
    _settle(route, velocity, forward: forward);
  }

  /// Finishes the journey or takes it back.
  ///
  /// ⚠️ DECIDED BY WHERE IT WOULD LAND, NOT BY TWO SEPARATE THRESHOLDS. It used
  /// to ask "did it travel far enough?" OR "was it thrown hard enough?", and a
  /// small quick swipe falls between the two: not far, not fast, so it rolled
  /// back even though every part of it said forward. Projecting the release
  /// velocity forward and asking whether THAT is past halfway is one continuous
  /// test that both kinds of gesture pass.
  void _settle(SectionRoute route, double velocity, {required bool forward}) {
    final transition = route.transition;
    if (transition == null) return;

    // A leftward throw is negative pixels and drives the transition UP, so the
    // sign turns over.
    final perSecond = -velocity / _width;
    final landing = transition.value + perSecond * _kProjection;
    // Forwards completes at 1, backwards at 0 — so the same halfway line means
    // opposite outcomes.
    final complete = forward ? landing > 0.5 : landing < 0.5;

    if (forward == complete) {
      unawaited(
        transition.animateTo(1, duration: kSectionTravel, curve: _kSettle),
      );
      return;
    }

    // ⚠️ POP IT — DO NOT REMOVE IT, AND DO NOT ANIMATE IT OUT BY HAND.
    //
    // The pages are declarative: the router owns the list and the Navigator
    // renders it. Taking a route out of the Navigator directly leaves the
    // router still holding it, so the address bar and the nav went on saying
    // "about" while the screen showed Work — and with the two stacks
    // disagreeing, nothing navigated afterwards.
    //
    // A pop is the one action both understand. The Navigator animates the route
    // out from wherever the finger left it, using this same controller, and the
    // router sees the page go and writes the address to match.
    route.navigator?.pop();
  }
}
