import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';
import 'package:sticker_flutter/ui/screens/home_screen.dart';
import 'package:sticker_flutter/ui/screens/pack_detail_screen.dart';
import 'package:sticker_flutter/ui/widgets/app_notification.dart';
import 'package:sticker_flutter/ui/widgets/create_pack_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  const channel = MethodChannel('com.pkri.sticko/stickers');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('flow_test_');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'getStickersDirectory':
          return tempDir.path;
        case 'checkWhatsAppInstalled':
          return {'whatsapp': true, 'whatsapp_business': false};
        case 'isStickerPackAdded':
          return false;
        case 'addStickerPack':
          return {'status': 'success', 'message': 'Pack added'};
        default:
          return null;
      }
    });

    final manager = StickerPackManager();
    manager.resetForTesting();
    await manager.initialize(customStickersDir: tempDir.path, force: true);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    StickerPackManager().resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('HomeScreen renders empty state and FAB', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();

    expect(find.text('Sticko'), findsOneWidget);
    expect(find.text('Belum Ada Paket Stiker'), findsOneWidget);
    expect(find.byKey(const Key('add_pack_fab')), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsWidgets);
  });

  testWidgets('CreatePackDialog validates input and creates pack', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: CreatePackDialog())));
    await tester.pump();

    expect(find.text('Buat Paket Stiker'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Stiker Test');
    await tester.pump();

    await tester.tap(find.text('Buat Paket'));
    await tester.pumpAndSettle();

    expect(StickerPackManager().packs.length, equals(1));
    expect(StickerPackManager().packs.first.name, equals('Stiker Test'));
  });

  testWidgets('PackDetailScreen correctly enforces WhatsApp min 3 rules in UI', (WidgetTester tester) async {
    final pack = await StickerPackManager().createPack(name: 'Paket Kucing', publisher: 'Budi');

    await tester.pumpWidget(MaterialApp(home: PackDetailScreen(packIdentifier: pack.identifier)));
    await tester.pump();

    // Verify header and disabled button
    expect(find.text('Paket Kucing'), findsOneWidget);
    expect(find.text('Oleh Budi'), findsOneWidget);
    expect(find.textContaining('minimal 3 stiker'), findsOneWidget);

    final buttonFinder = find.widgetWithText(
      ElevatedButton,
      'Butuh 3 Stiker Lagi untuk Simpan ke WA',
    );
    expect(buttonFinder, findsOneWidget);
    final button = tester.widget<ElevatedButton>(buttonFinder);
    expect(button.onPressed, isNull); // Disabled!
  });

  testWidgets(
      'Offline pack creation succeeds, adding/updating to WhatsApp is rejected with red failure notification when offline, and succeeds when Wi-Fi/data quota is active',
      (WidgetTester tester) async {
    // 1. Device is offline (no Wi-Fi / cellular data quota)
    WhatsAppStickersService.mockConnectivityChecker = () async => false;

    // User creates a sticker pack with 3 compliant stickers while offline
    const packId = 'pack_offline_test';
    final packDir = Directory('${tempDir.path}/$packId')..createSync(recursive: true);

    final trayImg = img.Image(width: 96, height: 96);
    img.fill(trayImg, color: img.ColorRgba8(18, 140, 126, 255));
    File('${packDir.path}/tray.png').writeAsBytesSync(img.encodePng(trayImg));

    final stickerImg = img.Image(width: 512, height: 512);
    img.fill(stickerImg, color: img.ColorRgba8(37, 211, 102, 255));
    final webpBytes = img.encodeWebP(stickerImg);

    final stickerItems = <StickerItem>[];
    for (int i = 1; i <= 3; i++) {
      final fileName = 'sticker_$i.webp';
      File('${packDir.path}/$fileName').writeAsBytesSync(webpBytes);
      stickerItems.add(StickerItem(imageFileName: fileName, emojis: const ['😀']));
    }

    final pack = StickerPack(
      identifier: packId,
      name: 'Paket Offline',
      publisher: 'Kreator',
      trayImageFile: 'tray.png',
      stickers: stickerItems,
    );
    await WhatsAppStickersService.saveContentsJson(
      [pack],
      directoryPath: tempDir.path,
    );
    await StickerPackManager().initialize(
      customStickersDir: tempDir.path,
      force: true,
    );

    expect(StickerPackManager().getPack(pack.identifier)!.canAddToWhatsApp, isTrue);

    await tester.pumpWidget(
      MaterialApp(home: PackDetailScreen(packIdentifier: pack.identifier)),
    );
    await tester.pump();

    // Green button "Tambahkan ke WhatsApp" is enabled
    final addBtnFinder = find.widgetWithText(
      ElevatedButton,
      'Tambahkan ke WhatsApp',
    );
    expect(addBtnFinder, findsOneWidget);

    // 2. User taps green button while still offline -> rejected with red failure AppNotification
    await tester.tap(addBtnFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(StickerPackManager().isPackInstalled(pack.identifier), isFalse);

    // Verify red failure notification icon button (isSuccess: false, Icons.close_rounded) is shown
    final notifFinder = find.byType(NotificationIconButton);
    expect(notifFinder, findsOneWidget);
    final notifWidget = tester.widget<NotificationIconButton>(notifFinder);
    expect(notifWidget.isSuccess, isFalse);
    expect(notifWidget.message, contains('Aktifkan Wi-Fi atau data seluler (kuota)'));
    expect(
      find.descendant(
        of: notifFinder,
        matching: find.byIcon(Icons.close_rounded),
      ),
      findsOneWidget,
    );

    // Let overlay notification auto-dismiss
    await tester.pump(const Duration(seconds: 5));

    // 3. User turns on Wi-Fi / mobile data with active quota -> adding to WhatsApp succeeds
    WhatsAppStickersService.mockConnectivityChecker = () async => true;

    await tester.tap(addBtnFinder);
    await tester.pumpAndSettle();

    expect(StickerPackManager().isPackInstalled(pack.identifier), isTrue);
    expect(find.text('Stiker Tersimpan!'), findsOneWidget);

    // Close the success dialog
    await tester.tap(find.text('Oke, Mengerti'));
    await tester.pumpAndSettle();

    // Button now shows "Perbarui Stiker di WhatsApp"
    final updateBtnFinder = find.widgetWithText(
      ElevatedButton,
      'Perbarui Stiker di WhatsApp',
    );
    expect(updateBtnFinder, findsOneWidget);

    // 4. User goes offline again and tries to update stickers in WhatsApp -> rejected with red failure notification
    WhatsAppStickersService.mockConnectivityChecker = () async => false;

    await tester.tap(updateBtnFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final updateNotifFinder = find.byType(NotificationIconButton);
    expect(updateNotifFinder, findsOneWidget);
    final updateNotifWidget =
        tester.widget<NotificationIconButton>(updateNotifFinder);
    expect(updateNotifWidget.isSuccess, isFalse);
    expect(
      updateNotifWidget.message,
      contains('Gagal memperbarui stiker ke WhatsApp'),
    );

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'Double-pressing system Back button on HomeScreen shows native exit toast on first press and exits APK on second press within 2 seconds',
      (WidgetTester tester) async {
    final List<String> toastMessages = [];
    int cancelToastCount = 0;
    int systemPopCount = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'getStickersDirectory':
          return tempDir.path;
        case 'checkWhatsAppInstalled':
          return {'whatsapp': true, 'whatsapp_business': false};
        case 'isStickerPackAdded':
          return false;
        case 'showExitToast':
          final msg = (methodCall.arguments as Map?)?['message']?.toString() ?? '';
          toastMessages.add(msg);
          return true;
        case 'cancelExitToast':
          cancelToastCount++;
          return true;
        default:
          return null;
      }
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'SystemNavigator.pop') {
        systemPopCount++;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();

    // 1. First back press -> shows native system toast, does NOT exit app
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(toastMessages, equals(['Tekan sekali lagi untuk keluar']));
    expect(systemPopCount, equals(0));

    // 2. Wait > 2 seconds -> double-press window expires
    await tester.pump(const Duration(seconds: 3));

    // Next back press is treated as a new first press -> shows toast again, does NOT exit
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(toastMessages.length, equals(2));
    expect(systemPopCount, equals(0));

    // 3. Second back press within 2 seconds -> cancels toast and exits APK via SystemNavigator.pop
    await tester.pump(const Duration(milliseconds: 400));
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(cancelToastCount, equals(1));
    expect(systemPopCount, equals(1));
  });
}
