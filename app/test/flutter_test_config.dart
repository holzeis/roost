import 'dart:async';

import 'package:google_fonts/google_fonts.dart';

// google_fonts fetches a font's file over a real HTTPS request the first
// time any given weight is used, unless told not to — under flutter_test
// there's no network, so a widget that renders text via app_theme.dart's
// GoogleFonts.* would otherwise hang/fail waiting on that fetch.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  await testMain();
}
