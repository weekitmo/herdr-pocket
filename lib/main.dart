import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdr_pocket/app/herdr_pocket_app.dart';
import 'package:herdr_pocket/data/providers/hosts.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  // Preferences are read BEFORE the first frame and injected as an override,
  // rather than loaded in a notifier. A board that renders "connecting" and
  // then swaps to the host the user actually picked is a visible glitch for no
  // gain; the read is a few milliseconds.
  WidgetsFlutterBinding.ensureInitialized();
  // EDGE TO EDGE, and this is a product decision rather than a default: the
  // pages are meant to run to the top of the screen with the status bar drawn
  // over them (see `top_bar.dart`), and an app that stops at the status bar
  // instead gets a strip of the system's colour above every page. Android 15
  // and later enforce this anyway; asking for it explicitly is what makes the
  // older ones behave the same way.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const HerdrPocketApp(),
    ),
  );
}
