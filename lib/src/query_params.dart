/// Reading tuning values out of the page URL.
///
/// These exist so the scene can be adjusted on a real device against the real
/// deployment, without a build-and-deploy cycle per experiment. Every number
/// that ended up in this project came from a measurement on hardware rather
/// than from reasoning, and that only works if trying a value is cheap.
///
/// ⚠️ EVERY ONE OF THESE IS EXPENSIVE, SO READ IT ONCE AND KEEP IT.
///
/// `Uri.base` does not return a cached object: it reads the browser's location
/// and parses the whole URL afresh on every call, and `.queryParameters` then
/// builds a new map out of it. A knob written as a getter therefore re-parses
/// the page's address every single time it is mentioned.
///
/// That is invisible until something in the frame loop mentions one. The
/// scene's uniforms are written three times a frame from a dozen knobs each,
/// and two cache signatures list a dozen more — about fifty full URL parses per
/// frame, three thousand a second, for values that CANNOT CHANGE while the page
/// is open. Changing the URL is a page load.
///
/// So every knob in this project is declared `final`, not `get`. A top-level
/// `final` in Dart is initialised on first use and cached from then on, which
/// is exactly the wanted behaviour and costs nothing at the call site.
library;

/// Integer query parameter [key], or [fallback] when absent or unparseable.
int qInt(String key, int fallback) =>
    int.tryParse(Uri.base.queryParameters[key] ?? '') ?? fallback;

/// Double query parameter [key], or [fallback] when absent or unparseable.
double qDouble(String key, double fallback) =>
    double.tryParse(Uri.base.queryParameters[key] ?? '') ?? fallback;

/// Whether query parameter [key] is present and set to `1`.
bool qFlag(String key) => Uri.base.queryParameters[key] == '1';

/// String query parameter [key], or [fallback] when absent or empty.
String qString(String key, String fallback) {
  final value = Uri.base.queryParameters[key];
  return value == null || value.isEmpty ? fallback : value;
}
