/// Reading tuning values out of the page URL.
///
/// These exist so the scene can be adjusted on a real device against the real
/// deployment, without a build-and-deploy cycle per experiment. Every number
/// that ended up in this project came from a measurement on hardware rather
/// than from reasoning, and that only works if trying a value is cheap.
library;

/// Integer query parameter [key], or [fallback] when absent or unparseable.
int qInt(String key, int fallback) =>
    int.tryParse(Uri.base.queryParameters[key] ?? '') ?? fallback;

/// Double query parameter [key], or [fallback] when absent or unparseable.
double qDouble(String key, double fallback) =>
    double.tryParse(Uri.base.queryParameters[key] ?? '') ?? fallback;

/// Whether query parameter [key] is present and set to `1`.
bool qFlag(String key) => Uri.base.queryParameters[key] == '1';
