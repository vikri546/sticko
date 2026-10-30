import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sticker_flutter/ui/screens/account_screen.dart';
import 'package:sticker_flutter/ui/widgets/app_notification.dart';
import 'package:sticker_flutter/ui/widgets/social_media_buttons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SocialMediaButtonsRow Widget Tests', () {
    testWidgets('Renders all 5 circular social icon buttons with tooltips and handles taps', (
      WidgetTester tester,
    ) async {
      bool tappedIg = false;
      bool tappedFb = false;
      bool tappedTt = false;
      bool tappedTw = false;
      bool tappedLi = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SocialMediaButtonsRow(
              isDark: true,
              onTapInstagram: () => tappedIg = true,
              onTapFacebook: () => tappedFb = true,
              onTapTikTok: () => tappedTt = true,
              onTapTwitter: () => tappedTw = true,
              onTapLinkedIn: () => tappedLi = true,
            ),
          ),
        ),
      );
      await tester.pump();

      // Check tooltips exist
      expect(find.byTooltip('Instagram'), findsOneWidget);
      expect(find.byTooltip('Facebook'), findsOneWidget);
      expect(find.byTooltip('TikTok'), findsOneWidget);
      expect(find.byTooltip('Twitter / X'), findsOneWidget);
      expect(find.byTooltip('LinkedIn'), findsOneWidget);

      // Tap Instagram
      await tester.tap(find.byTooltip('Instagram'));
      await tester.pump();
      expect(tappedIg, isTrue);

      // Tap Facebook
      await tester.tap(find.byTooltip('Facebook'));
      await tester.pump();
      expect(tappedFb, isTrue);

      // Tap TikTok
      await tester.tap(find.byTooltip('TikTok'));
      await tester.pump();
      expect(tappedTt, isTrue);

      // Tap Twitter / X
      await tester.tap(find.byTooltip('Twitter / X'));
      await tester.pump();
      expect(tappedTw, isTrue);

      // Tap LinkedIn
      await tester.tap(find.byTooltip('LinkedIn'));
      await tester.pump();
      expect(tappedLi, isTrue);
    });
  });

  group('AccountScreen Social Buttons & Footer Replacement Tests', () {
    testWidgets('Replaces old footer text with SocialMediaButtonsRow in AccountScreen', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          home: AccountScreen(showAppBar: true),
        ),
      );
      await tester.pump();

      // Verify old text is completely removed
      expect(find.text('Sticker Maker v1.0.0+1 • Made with Flutter'), findsNothing);
      expect(find.textContaining('Made with Flutter'), findsNothing);

      // Verify SocialMediaButtonsRow is present
      expect(find.byType(SocialMediaButtonsRow), findsOneWidget);
      expect(find.byTooltip('Instagram'), findsOneWidget);
      expect(find.byTooltip('Facebook'), findsOneWidget);
      expect(find.byTooltip('TikTok'), findsOneWidget);
      expect(find.byTooltip('Twitter / X'), findsOneWidget);
      expect(find.byTooltip('LinkedIn'), findsOneWidget);

      // Tapping an empty social link displays feedback notification
      await tester.tap(find.byTooltip('Instagram'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(NotificationIconButton), findsOneWidget);

      // Tap NotificationIconButton to expand and reveal message text
      await tester.tap(find.byType(NotificationIconButton));
      await tester.pumpAndSettle();

      expect(find.text('Tautan Instagram belum diisi.'), findsOneWidget);

      // Clean up overlay timer
      AppNotification.dismiss();
      await tester.pumpAndSettle();
    });
  });
}
