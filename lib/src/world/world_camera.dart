/// Where the visitor is in the world.
///
/// This is the ENTIRE state of the site: one position, one velocity, one
/// target. The shader reads it, the content reads it, the nav reads it, and
/// the router writes to it. Nothing else holds navigation state, which is why
/// there is no state-management package here — a single Listenable does it.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Position is measured in LOCATIONS, not pixels: 0 is the first stop, 1.5 is
/// exactly halfway between the second and third. Keeping the unit abstract is
/// what lets the same number drive a horizontal layout, a shader coordinate
/// and the nav highlight without any of them knowing about the others.
class WorldCamera extends ChangeNotifier {
  WorldCamera({required this.count});

  final int count;

  double position = 0;
  double velocity = 0;
  double _target = 0;
  bool _dragging = false;

  /// Slight overshoot allowance so the ends feel elastic rather than walled.
  static const double _slack = 0.12;

  double get target => _target;

  set target(double value) {
    _target = value.clamp(0, (count - 1).toDouble());
    notifyListeners();
  }

  /// The stop the camera would settle on, for the nav highlight and the URL.
  int get nearest => position.round().clamp(0, count - 1);

  /// True while travelling, which the world uses to decide how hard to smear.
  bool get moving =>
      velocity.abs() > 0.01 || (_target - position).abs() > 0.002;

  void beginDrag() {
    _dragging = true;
    velocity = 0;
  }

  void dragBy(double locations) {
    position = (position + locations).clamp(-_slack, count - 1 + _slack);
    notifyListeners();
  }

  /// Ends a drag by throwing the camera, then letting the spring catch it.
  ///
  /// The landing stop is projected from the release velocity rather than taken
  /// from the finger's last position, so a fast flick travels further than a
  /// slow one. That projection is most of what makes a drag feel physical.
  void endDrag(double velocityInLocations) {
    _dragging = false;
    velocity = velocityInLocations;
    final projected = position + velocityInLocations * 0.22;
    target = projected.roundToDouble();
  }

  /// Continuous nudge from a wheel or trackpad, in fractions of a location.
  void nudge(double locations) {
    target = _target + locations;
  }

  void jumpTo(int index) => target = index.toDouble();

  /// Critically-ish damped spring. Slightly under 1.0 damping so arrivals
  /// settle rather than stop dead, which is what reads as mass.
  void tick(double dt) {
    if (_dragging) return;

    // Landing. [moving] is the ONLY threshold — an independent snap threshold
    // here was smaller than it, which left a dead band where the camera had
    // stopped moving but had not arrived, parking the world a fraction of a
    // location off every stop. One predicate, no gap.
    if (!moving) {
      if (position != _target) {
        position = _target;
        velocity = 0;
        notifyListeners();
      }
      return;
    }

    final step = math.min(dt, 1 / 30);
    const k = 120.0;
    final d = 2 * math.sqrt(k) * 0.92;
    final a = (_target - position) * k - velocity * d;
    velocity += a * step;
    position += velocity * step;
    notifyListeners();
  }
}
