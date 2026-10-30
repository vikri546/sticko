import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sticker_flutter/services/app_update_notification_service.dart';
import 'package:sticker_flutter/services/app_update_service.dart';
import 'package:sticker_flutter/services/google_analytics_service.dart';
import 'package:sticker_flutter/ui/screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await GoogleAnalyticsService().initialize();
  GoogleAnalyticsService().logAppOpen();

  // Initialize status bar notification channel strictly for APK updates
  // and run real-time background check
  AppUpdateNotificationService().initialize();
  AppUpdateService.checkForUpdateInBackground();

  runApp(const StickerApp());
}

class StickerApp extends StatelessWidget {
  const StickerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sticko',
      debugShowCheckedModeBanner: false,
      navigatorObservers: [
        AnalyticsRouteObserver(),
      ],
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        splashFactory: InkRipple.splashFactory,
        textTheme: GoogleFonts.plusJakartaSansTextTheme(ThemeData.light().textTheme),
        colorSchemeSeed: const Color(0xFF128C7E),
        scaffoldBackgroundColor: const Color(0xFFF9FBFB),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          backgroundColor: Color(0xFFF9FBFB),
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        splashFactory: InkRipple.splashFactory,
        textTheme: GoogleFonts.plusJakartaSansTextTheme(ThemeData.dark().textTheme),
        colorSchemeSeed: const Color(0xFF25D366),
        scaffoldBackgroundColor: const Color(0xFF111B21),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          backgroundColor: Color(0xFF111B21),
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFF202C33),
          elevation: 0,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
