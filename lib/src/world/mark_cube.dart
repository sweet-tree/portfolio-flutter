/// The mark: a lit cube, rendered by `shaders/mark.frag`.
///
/// The light follows the pointer, so the highlight travels round the edges
/// depending on which side you approach from. On a touch device there is no
/// pointer, so it keeps its resting key light and simply drifts.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

class MarkCube extends StatefulWidget {
  const MarkCube({
    this.center = const Alignment(0, -0.34),
    this.sizeFraction = 0.30,
    super.key,
  });

  /// Where the cube sits within the painted area, as an [Alignment].
  final Alignment center;

  /// Cube size as a fraction of the painted area's shortest side.
  final double sizeFraction;

  @override
  State<MarkCube> createState() => _MarkCubeState();
}

class _MarkCubeState extends State<MarkCube>
    with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  late final Ticker _ticker;
  double _time = 0;

  /// Pointer position in widget space, 0..1 with y up.
  Offset _pointer = const Offset(0.5, 0.5);

  /// Eased hover weight. Snapping the light on entry looks like a bug; easing
  /// it reads as the light being moved.
  double _hover = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => _time = elapsed.inMicroseconds / 1e6);
    });
    unawaited(_ticker.start());
    unawaited(_load());
  }

  Future<void> _load() async {
    final program = await ui.FragmentProgram.fromAsset('shaders/mark.frag');
    if (!mounted) return;
    setState(() => _shader = program.fragmentShader());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _shader?.dispose();
    super.dispose();
  }

  void _track(PointerEvent event, Size size) {
    if (size.isEmpty) return;
    setState(() {
      _pointer = Offset(
        (event.localPosition.dx / size.width).clamp(0.0, 1.0),
        1 - (event.localPosition.dy / size.height).clamp(0.0, 1.0),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (shader == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // Eased toward the hover target every frame. The ticker is already
        // running for the drift, so this costs nothing extra.
        final target = _hover;
        final center = widget.center.alongSize(size);
        final unit = size.shortestSide * widget.sizeFraction;
        return MouseRegion(
          onEnter: (_) => setState(() => _hover = 1),
          onExit: (_) => setState(() => _hover = 0),
          onHover: (event) => _track(event, size),
          child: CustomPaint(
            painter: _MarkPainter(
              shader: shader,
              time: _time,
              pointer: _pointer,
              hover: target,
              center: center,
              unit: unit,
            ),
            size: size,
          ),
        );
      },
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter({
    required this.shader,
    required this.time,
    required this.pointer,
    required this.hover,
    required this.center,
    required this.unit,
  });

  final ui.FragmentShader shader;
  final double time;
  final Offset pointer;
  final double hover;
  final Offset center;
  final double unit;

  @override
  void paint(Canvas canvas, Size size) {
    // Flat indices, in declaration order from the .frag: vec2 uSize takes
    // 0 and 1, then uTime, then vec2 uPointer, then uHover.
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, time)
      ..setFloat(3, pointer.dx)
      ..setFloat(4, pointer.dy)
      ..setFloat(5, hover)
      ..setFloat(6, center.dx)
      ..setFloat(7, center.dy)
      ..setFloat(8, unit);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.time != time ||
      old.pointer != pointer ||
      old.hover != hover ||
      old.center != center ||
      old.unit != unit;
}
