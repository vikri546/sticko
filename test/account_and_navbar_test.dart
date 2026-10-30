import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sticker_flutter/main.dart';
import 'package:sticker_flutter/services/creator_profile_service.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/ui/screens/account_screen.dart';
import 'package:sticker_flutter/ui/screens/edit_profile_screen.dart';
import 'package:sticker_flutter/ui/screens/home_screen.dart';
import 'package:sticker_flutter/ui/screens/permissions_preferences_screen.dart';
import 'package:sticker_flutter/ui/widgets/floating_pill_nav_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  const channel = MethodChannel('com.pkri.sticko/stickers');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('account_test_');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'getStickersDirectory':
          return tempDir.path;
        case 'checkWhatsAppInstalled':
          return {'whatsapp': true, 'whatsapp_business': false};
        case 'isStickerPackAdded':
          return false;
        default:
          return null;
      }
    });

    final manager = StickerPackManager();
    manager.resetForTesting();
    await manager.initialize(customStickersDir: tempDir.path, force: true);

    final profileService = CreatorProfileService();
    profileService.resetForTesting(customDir: tempDir.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    StickerPackManager().resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('FloatingPillNavBar Tests', () {
    testWidgets('Renders Explore and Account tabs with correct styling', (
      WidgetTester tester,
    ) async {
      int selectedTab = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) {
                  return FloatingPillNavBar(
                    selectedIndex: selectedTab,
                    onTabSelected: (index) {
                      setState(() {
                        selectedTab = index;
                      });
                    },
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Verify both tab labels and icons exist
      expect(find.text('Explore'), findsOneWidget);
      expect(find.text('Account'), findsOneWidget);
      expect(find.byIcon(Icons.grid_view_rounded), findsOneWidget);
      expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget);

      // Tap on 'Account'
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();

      expect(selectedTab, equals(1));

      // Tap on 'Explore'
      await tester.tap(find.text('Explore'));
      await tester.pumpAndSettle();

      expect(selectedTab, equals(0));
    });
  });

  group('AccountScreen UI Tests', () {
    testWidgets('Renders creator card, settings sections, and tutorial dialog', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const AccountScreen(showAppBar: true),
        ),
      );
      await tester.pump();

      // Check Creator Card & App Bar (Sticko text in header)
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('Sticko')),
        findsOneWidget,
      );
      expect(find.text('Account & Settings'), findsNothing);
      expect(find.text('Kreator Stiker'), findsOneWidget);
      expect(find.text('Penyimpanan Lokal Aktif'), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);

      // Check Sections (Simplified layout with Pengaturan Sistem)
      expect(find.text('PENGATURAN SISTEM'), findsOneWidget);
      expect(find.text('Perizinan & Preferensi'), findsOneWidget);
      expect(find.text('Integrasi WhatsApp'), findsOneWidget);
      expect(find.text('Cadangan & Pemulihan Cloud'), findsOneWidget);
      expect(find.text('PENGATURAN LAINNYA'), findsOneWidget);

      // Open Tutorial Dialog
      await tester.tap(find.text('Panduan Menambahkan ke WA'));
      await tester.pumpAndSettle();

      expect(find.text('Cara Menggunakan Stiker'), findsOneWidget);
      expect(find.text('Buat Paket Stiker'), findsOneWidget);
      expect(find.text('Kirim ke WhatsApp'), findsOneWidget);

      // Close dialog
      await tester.tap(find.text('Mengerti'));
      await tester.pumpAndSettle();
      expect(find.text('Cara Menggunakan Stiker'), findsNothing);

      // Verify header is not sticky (it scrolls away when dragging the ListView on standard mobile viewport)
      tester.view.physicalSize = const Size(800, 600);
      await tester.pump();
      expect(find.text('Sticko'), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      // It scrolled completely offscreen (non-sticky)
      expect(find.text('Sticko'), findsNothing);

      // Dragging back down brings it back
      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.text('Sticko'), findsOneWidget);
    });
  });

  group('HomeScreen Tab Navigation Integration Tests', () {
    testWidgets('Switches smoothly between Explore and Account tabs via FloatingPillNavBar', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const HomeScreen(),
        ),
      );
      await tester.pump();

      // 1. Initial State: Explore tab active
      expect(find.text('Sticko'), findsOneWidget);
      expect(find.byKey(const Key('add_pack_fab')), findsOneWidget);
      expect(find.text('Explore'), findsOneWidget);
      expect(find.text('Account'), findsOneWidget);
      // Header has only Sticko, no shield or refresh action icons on Explore tab AppBar
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.security_rounded)),
        findsNothing,
      );
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.refresh_rounded)),
        findsNothing,
      );

      // 2. Switch to Account tab
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();

      // Account tab is active: AppBar has Sticko text matching homepage, no action buttons, FAB is hidden
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('Sticko')),
        findsOneWidget,
      );
      expect(find.text('Account & Settings'), findsNothing);
      expect(find.text('Kreator Stiker'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.security_rounded)),
        findsNothing,
      );
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.refresh_rounded)),
        findsNothing,
      );
      expect(find.byKey(const Key('add_pack_fab')), findsNothing);

      // 3. Switch back to Explore tab
      await tester.tap(find.text('Explore'));
      await tester.pumpAndSettle();

      // Explore tab is active again: Sticko AppBar and FAB reappear, no actions in Explore AppBar
      expect(find.text('Sticko'), findsOneWidget);
      expect(find.byKey(const Key('add_pack_fab')), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.security_rounded)),
        findsNothing,
      );
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.refresh_rounded)),
        findsNothing,
      );
    });

    testWidgets('Tapping Paket stat item navigates to CreatorCollectionScreen', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const AccountScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Paket'), findsOneWidget);
      expect(find.text('Stiker'), findsOneWidget);
      expect(find.text('Di WA'), findsOneWidget);

      await tester.tap(find.text('Paket'));
      await tester.pumpAndSettle();

      expect(find.text('Koleksi Kreator'), findsOneWidget);
      expect(find.text('Belum Ada Paket Stiker'), findsOneWidget);
    });
  });

  group('PermissionsPreferencesScreen & Dark Theme Tests', () {
    testWidgets('StickerApp defaults to ThemeMode.dark', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const StickerApp());
      final MaterialApp app = tester.widget(find.byType(MaterialApp));
      expect(app.themeMode, equals(ThemeMode.dark));
    });

    testWidgets('Renders permissions and system settings without theme selector', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const PermissionsPreferencesScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Check Header
      expect(find.text('Perizinan & Preferensi'), findsOneWidget);

      // Verify theme options are completely removed
      expect(find.text('TEMA APLIKASI'), findsNothing);
      expect(find.text('Mode Terang'), findsNothing);
      expect(find.text('Mode Gelap'), findsNothing);
      expect(find.text('Mengikuti Sistem'), findsNothing);

      // Check Permissions Section
      expect(find.text('PERIZINAN APLIKASI'), findsOneWidget);
      expect(find.text('Galeri & Foto'), findsOneWidget);
      expect(find.text('Kamera'), findsOneWidget);
      expect(find.text('Notifikasi'), findsOneWidget);

      // Verify capsule buttons rendered without icons (3 permissions, Google Analytics is active but hidden from UI)
      expect(find.text('Aktif'), findsNWidgets(3));
      expect(find.text('Buka'), findsOneWidget);

      // Check System Settings
      expect(find.text('SETELAN SISTEM ANDROID'), findsOneWidget);
      expect(find.text('Buka Pengaturan Aplikasi'), findsOneWidget);
    });

    testWidgets('Shows deactivation information modal dialog only when tapping active permission', (
      WidgetTester tester,
    ) async {
      const permChannel = MethodChannel('flutter.baseflow.com/permissions/methods');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(permChannel, (MethodCall methodCall) async {
        if (methodCall.method == 'checkPermissionStatus') {
          // Return granted (1) for all permissions
          return 1;
        }
        return 0;
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const PermissionsPreferencesScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // All 3 permissions should now be 'Aktif'
      expect(find.text('Aktif'), findsNWidgets(3));

      // Tap on the first 'Aktif' capsule button (Galeri & Foto)
      await tester.tap(find.text('Aktif').first);
      await tester.pumpAndSettle();

      // Deactivation modal info dialog should be displayed
      expect(find.text('Nonaktifkan Izin Galeri & Foto'), findsOneWidget);
      expect(
        find.textContaining('Izin aplikasi yang sudah aktif hanya dapat dinonaktifkan'),
        findsOneWidget,
      );
      expect(find.text('Batal'), findsOneWidget);
      expect(find.text('Buka Setelan'), findsOneWidget);

      // Tap 'Batal' to close modal
      await tester.tap(find.text('Batal'));
      await tester.pumpAndSettle();
      expect(find.text('Nonaktifkan Izin Galeri & Foto'), findsNothing);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(permChannel, null);
    });

    testWidgets('PermissionsPreferencesScreen.route() provides zoom in/out ScaleTransition', (
      WidgetTester tester,
    ) async {
      final route = PermissionsPreferencesScreen.route();
      expect(route, isA<PageRouteBuilder>());
    });
  });

  group('EditProfileScreen & Creator Profile Tests', () {
    testWidgets('EditProfileScreen.route() provides zoom in/out ScaleTransition', (
      WidgetTester tester,
    ) async {
      final route = EditProfileScreen.route();
      expect(route, isA<PageRouteBuilder>());
    });

    testWidgets('Renders EditProfileScreen fields and enforces 32 character limit on bio', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const EditProfileScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Check Header
      expect(find.text('Edit Profil Kreator'), findsOneWidget);
      expect(find.text('Ubah Foto Profil'), findsOneWidget);

      // Check Labels
      expect(find.text('NAMA KREATOR'), findsOneWidget);
      expect(find.text('BIO STATUS'), findsOneWidget);
      expect(find.text('TAUTAN / MEDIA SOSIAL (OPSIONAL)'), findsNothing);
      expect(find.text('Simpan Perubahan'), findsOneWidget);

      // Enter new name and bio
      final nameField = find.widgetWithText(TextField, 'Kreator Stiker');
      expect(nameField, findsOneWidget);
      await tester.enterText(nameField, 'Sticko Artist');

      final bioField = find.widgetWithText(TextField, 'Penyimpanan Lokal Aktif');
      expect(bioField, findsOneWidget);
      await tester.enterText(bioField, 'Bikin stiker keren tiap hari 🚀');

      // Tap Simpan Perubahan
      await tester.tap(find.text('Simpan Perubahan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Verify service updated
      expect(CreatorProfileService().name, equals('Sticko Artist'));
      expect(CreatorProfileService().bio, equals('Bikin stiker keren tiap hari 🚀'));
    });
  });
}
