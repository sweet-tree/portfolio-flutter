import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:portfolio/src/cross_origin.dart' as platform;
import 'package:portfolio/src/query_params.dart';

/// True when the page was opened with `?stats=1`.
///
/// A URL switch rather than a debug build flag, so the numbers can be read off
/// a real phone hitting the real deployment — which is the only place some of
/// them (cross-origin isolation, the JS-vs-WebAssembly path) mean anything.
final bool statsRequested = qFlag('stats');

/// True when compiled by dart2js rather than dart2wasm.
///
/// JavaScript has one number type, so int and double literals are identical;
/// dart2wasm keeps them distinct. Evaluated at compile time.
///
/// Matters because iOS has no WasmGC: every browser there is WebKit, so an
/// iPhone always gets the slower JavaScript build no matter what we ship.
const bool kIsJavaScript = identical(1, 1.0);

/// A small always-on-top readout: frame rate, worst frame rate, which build is
/// running, and whether cross-origin isolation actually took effect.
class StatsOverlay extends StatefulWidget {
  const StatsOverlay({super.key});

  @override
  State<StatsOverlay> createState() => _StatsOverlayState();
}

class _StatsOverlayState extends State<StatsOverlay>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  int _frames = 0;
  Duration _windowStart = Duration.zero;
  double _fps = 0;
  double _worst = double.infinity;

  @override
  void initState() {
    super.initState();
    // start() returns a TickerFuture that only completes if the ticker stops;
    // this one runs for the lifetime of the widget.
    _ticker = createTicker(_onTick);
    unawaited(_ticker!.start());
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    _frames++;
    final span = elapsed - _windowStart;
    if (span.inMilliseconds < 1000) return;

    _fps = _frames * 1000 / span.inMilliseconds;
    // Ignore the first few seconds: the scene is still warming up and the
    // early numbers would libel the steady state.
    if (elapsed.inSeconds > 4 && _fps < _worst) _worst = _fps;
    _frames = 0;
    _windowStart = elapsed;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final good = _fps >= 55
        ? const Color(0xFF4ADE80)
        : _fps >= 35
        ? const Color(0xFFFACC15)
        : const Color(0xFFF87171);

    return IgnorePointer(
      child: Padding(
        padding: EdgeInsets.only(top: media.padding.top + 10, left: 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 14, 11),
            child: DefaultTextStyle(
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.4,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_fps.toStringAsFixed(1)} FPS',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      color: good,
                    ),
                  ),
                  Text(
                    'worst '
                    '${_worst.isFinite ? _worst.toStringAsFixed(1) : "–"}',
                    style: const TextStyle(color: Color(0x99FFFFFF)),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    kIsJavaScript ? 'JavaScript build' : 'WebAssembly build',
                    style: TextStyle(
                      color: kIsJavaScript
                          ? Color(0xFFFACC15)
                          : Color(0xFF4ADE80),
                    ),
                  ),
                  Text(
                    'isolated: ${platform.crossOriginIsolated}',
                    style: TextStyle(
                      color: platform.crossOriginIsolated
                          ? const Color(0xFF4ADE80)
                          : const Color(0xFFF87171),
                    ),
                  ),
                  Text(
                    '${size.width.round()}×${size.height.round()} '
                    '@ ${media.devicePixelRatio.toStringAsFixed(1)}x',
                    style: const TextStyle(color: Color(0x99FFFFFF)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
