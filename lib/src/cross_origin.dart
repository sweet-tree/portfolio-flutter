/// Whether the page is cross-origin isolated.
///
/// ⚠️ THIS EXISTS SO THE TESTS CAN RUN OFF THE BROWSER. It was one line of
/// `package:web` in the stats overlay, and `package:web` reaches
/// `dart:js_interop`, which does not exist on the Dart VM — so `flutter test`
/// could not build the test at all and every widget test had to go through
/// `--platform chrome`. The browser runner swallows the framework's error dump,
/// so a failing widget test said only "Test failed. See exception logs above"
/// with nothing above it, and faults had to be guessed at instead of read.
///
/// Behind a conditional import the VM gets a stub, the browser gets the real
/// answer, and `flutter test` works on both.
library;

export 'cross_origin_stub.dart'
    if (dart.library.js_interop) 'cross_origin_web.dart';
