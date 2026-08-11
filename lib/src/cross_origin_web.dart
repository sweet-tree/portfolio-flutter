import 'package:web/web.dart' as web;

/// True when the page got the COOP/COEP headers and Flutter can use the
/// multi-threaded renderer.
///
/// Only meaningful on a real device against the real deployment: it can never
/// be true over plain HTTP on a LAN address, so a local `false` says nothing
/// about production.
bool get crossOriginIsolated => web.window.crossOriginIsolated;
