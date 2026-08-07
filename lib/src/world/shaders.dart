/// The compiled shader programs, resolved BEFORE the first frame.
///
/// ⚠️ THIS EXISTS TO KILL A VISIBLE TWITCH, and the twitch was structural.
///
/// `FragmentProgram.fromAsset` is asynchronous, so a widget that loads its own
/// program cannot draw with it on the frame it is first built. Both the scene
/// and the statement did exactly that, which meant the first painted frame was
/// never the finished one: the scene showed flat background until its program
/// arrived, and the statement was drawn by Flutter as plain ink until the glow
/// took over and redrew it tinted. Two handoffs, each at a moment decided by
/// the network, so the page visibly changed once on every load — at a slightly
/// different instant every time.
///
/// There is no amount of fading that fixes that honestly; the fix is to stop
/// starting before the app is ready. The engine already works this way — it
/// awaits every bundled font inside `initializeEngineServices` before the
/// framework runs, which is why type never reflows on this site. Shaders are
/// the same kind of dependency and get the same treatment: loaded in `main`,
/// read synchronously afterwards.
///
/// A program that fails to load stays null rather than throwing, because a
/// missing decoration must not cost the visitor the page. Everything that uses
/// one already has a path for not having it.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

abstract final class Shaders {
  /// The world: field, glass, cube, stars.
  static ui.FragmentProgram? scene;

  /// The statement's colour.
  static ui.FragmentProgram? typeGlow;

  /// Loads every program. Awaited in `main`, before `runApp`.
  static Future<void> load() async {
    final loaded = await Future.wait([
      _tryLoad('shaders/scene.frag'),
      _tryLoad('shaders/type_glow.frag'),
    ]);
    scene = loaded[0];
    typeGlow = loaded[1];
  }

  static Future<ui.FragmentProgram?> _tryLoad(String asset) async {
    try {
      return await ui.FragmentProgram.fromAsset(asset);
    } on Object catch (error, stack) {
      // Reported rather than swallowed: a shader that fails to compile is a
      // real defect, and it must be loud in the console even though the site
      // deliberately survives it.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'portfolio',
          context: ErrorDescription('loading $asset'),
        ),
      );
      return null;
    }
  }
}
