import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sticker_flutter/services/duplicate_stickers_service.dart';
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

  testWidgets(
      'Holding a sticker for 1.5 seconds in PackDetailScreen activates drag-and-drop and reorders sticker position without altering sticker format or duplicate detection',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    expect(
      PackDetailScreen.stickerDragHoldDuration,
      equals(const Duration(milliseconds: 1500)),
    );

    const packId = 'pack_reorder_test';
    final packDir = Directory('${tempDir.path}/$packId')..createSync(recursive: true);

    final trayImg = img.Image(width: 96, height: 96);
    img.fill(trayImg, color: img.ColorRgba8(18, 140, 126, 255));
    File('${packDir.path}/tray.png').writeAsBytesSync(img.encodePng(trayImg));

    final stickerImg = img.Image(width: 512, height: 512);
    img.fill(stickerImg, color: img.ColorRgba8(37, 211, 102, 255));
    final webpBytes = img.encodeWebP(stickerImg);

    final stickerItems = <StickerItem>[
      const StickerItem(imageFileName: 'sticker_1.webp', emojis: ['1️⃣']),
      const StickerItem(imageFileName: 'sticker_2.webp', emojis: ['2️⃣']),
      const StickerItem(imageFileName: 'sticker_3.webp', emojis: ['3️⃣']),
    ];
    for (final item in stickerItems) {
      File('${packDir.path}/${item.imageFileName}').writeAsBytesSync(webpBytes);
    }

    final pack = StickerPack(
      identifier: packId,
      name: 'Paket Urutan',
      publisher: 'Kreator',
      trayImageFile: 'tray.png',
      imageDataVersion: '1',
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

    final duplicateService = DuplicateStickersService()..resetForTesting();
    final initialGroups = await duplicateService.scanDuplicates();
    expect(initialGroups.length, equals(1));
    final initialHash = initialGroups.first.hash;

    await tester.pumpWidget(
      MaterialApp(home: PackDetailScreen(packIdentifier: pack.identifier)),
    );
    await tester.pump();

    final firstStickerFinder = find.byKey(const ValueKey('sticker_draggable_sticker_1.webp'));
    final thirdStickerFinder = find.byKey(const ValueKey('sticker_drag_target_sticker_3.webp'));
    expect(firstStickerFinder, findsOneWidget);
    expect(thirdStickerFinder, findsOneWidget);

    final firstCenter = tester.getCenter(firstStickerFinder);
    final thirdCenter = tester.getCenter(thirdStickerFinder);

    // 1. Holding for only 500 ms (< 1.5 seconds) should NOT activate drag reorder
    final shortGesture = await tester.startGesture(firstCenter);
    await tester.pump(const Duration(milliseconds: 500));
    await shortGesture.moveTo(thirdCenter);
    await tester.pump();
    await shortGesture.up();
    await tester.pumpAndSettle();

    expect(
      StickerPackManager()
          .getPack(packId)!
          .stickers
          .map((s) => s.imageFileName)
          .toList(),
      equals(['sticker_1.webp', 'sticker_2.webp', 'sticker_3.webp']),
    );

    // 2. Holding for 1.5 seconds activates drag mode and drops sticker_1 onto sticker_3's position
    final holdGesture = await tester.startGesture(firstCenter);
    await tester.pump(PackDetailScreen.stickerDragHoldDuration + const Duration(milliseconds: 100));
    await holdGesture.moveTo(thirdCenter);
    await tester.pump();
    await holdGesture.up();
    await tester.pumpAndSettle();

    final reorderedPack = StickerPackManager().getPack(packId)!;
    expect(
      reorderedPack.stickers.map((s) => s.imageFileName).toList(),
      equals(['sticker_2.webp', 'sticker_3.webp', 'sticker_1.webp']),
    );
    expect(reorderedPack.imageDataVersion, equals('2'));

    // 3. Verify sticker file bytes/format and duplicate detection hash are 100% unchanged
    final postReorderGroups = await duplicateService.scanDuplicates();
    expect(postReorderGroups.length, equals(1));
    expect(postReorderGroups.first.hash, equals(initialHash));
    expect(postReorderGroups.first.occurrences.length, equals(3));
    expect(
      File('${packDir.path}/sticker_1.webp').readAsBytesSync(),
      equals(webpBytes),
    );
  });

  testWidgets(
      'Single-tapping a sticker in PackDetailScreen opens editor with Simpan Perubahan and Informasi button (Format, Size, Waktu Simpan, Waktu Perubahan)',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    const packId = 'pack_edit_info_test';
    final packDir =
        Directory('${tempDir.path}/$packId')..createSync(recursive: true);

    final trayImg = img.Image(width: 96, height: 96);
    img.fill(trayImg, color: img.ColorRgba8(18, 140, 126, 255));
    File('${packDir.path}/tray.png').writeAsBytesSync(img.encodePng(trayImg));

    final stickerImg = img.Image(width: 512, height: 512);
    img.fill(stickerImg, color: img.ColorRgba8(37, 211, 102, 255));
    final webpBytes = Uint8List.fromList(img.encodeWebP(stickerImg));

    final initialCreatedTime = DateTime(2026, 11, 10, 9, 30, 15);
    final initialUpdatedTime = DateTime(2026, 11, 10, 10, 45, 0);

    final stickerItems = <StickerItem>[
      StickerItem(
        imageFileName: 'sticker_1.webp',
        emojis: const ['😀'],
        createdAt: initialCreatedTime,
        updatedAt: initialUpdatedTime,
      ),
      StickerItem(
        imageFileName: 'sticker_2.webp',
        emojis: const ['😂'],
        createdAt: initialCreatedTime,
        updatedAt: initialUpdatedTime,
      ),
      StickerItem(
        imageFileName: 'sticker_3.webp',
        emojis: const ['❤️'],
        createdAt: initialCreatedTime,
        updatedAt: initialUpdatedTime,
      ),
    ];
    for (final item in stickerItems) {
      File('${packDir.path}/${item.imageFileName}').writeAsBytesSync(webpBytes);
    }

    final pack = StickerPack(
      identifier: packId,
      name: 'Paket Edit & Info',
      publisher: 'Kreator',
      trayImageFile: 'tray.png',
      imageDataVersion: '1',
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

    await tester.pumpWidget(
      MaterialApp(home: PackDetailScreen(packIdentifier: pack.identifier)),
    );
    await tester.pump();

    // 1. One-touch (single tap) on sticker_1 opens AddStickerSheet in edit mode
    final stickerTapFinder =
        find.byKey(const ValueKey('sticker_tile_tap_sticker_1.webp'));
    expect(stickerTapFinder, findsOneWidget);

    await tester.tap(stickerTapFinder);
    await tester.pumpAndSettle();

    // Verify editor title and buttons ("Informasi" & "Simpan Perubahan")
    expect(find.text('Edit Stiker'), findsOneWidget);
    final infoBtnFinder = find.byKey(const Key('sticker_info_button'));
    final saveChangesBtnFinder =
        find.byKey(const Key('save_sticker_changes_button'));
    expect(infoBtnFinder, findsOneWidget);
    expect(saveChangesBtnFinder, findsOneWidget);
    expect(find.text('Informasi'), findsOneWidget);
    expect(find.text('Simpan Perubahan'), findsOneWidget);

    // 2. Tap "Informasi" button -> shows sticker detail dialog (Format, Size, Waktu Simpan, Waktu Perubahan)
    await tester.ensureVisible(infoBtnFinder);
    await tester.pumpAndSettle();
    await tester.tap(infoBtnFinder);
    await tester.pumpAndSettle();

    expect(find.text('Informasi Stiker'), findsOneWidget);
    expect(find.text('Format'), findsOneWidget);
    expect(find.text('WEBP (Statis • 512 × 512 px)'), findsOneWidget);
    expect(find.text('Size'), findsOneWidget);
    expect(find.textContaining('Bytes)'), findsOneWidget);
    expect(find.text('Waktu Simpan'), findsOneWidget);
    expect(find.text('10 Nov 2026, 09:30:15'), findsOneWidget);
    expect(find.text('Waktu Perubahan'), findsOneWidget);
    expect(find.text('10 Nov 2026, 10:45:00'), findsOneWidget);

    // Close info dialog
    await tester.tap(find.text('Tutup'));
    await tester.pumpAndSettle();

    // 3. Edit emoji and tap "Simpan Perubahan"
    final fireEmojiFinder = find.text('🔥');
    await tester.ensureVisible(fireEmojiFinder);
    await tester.pumpAndSettle();
    await tester.tap(fireEmojiFinder);
    await tester.pump();

    await tester.ensureVisible(saveChangesBtnFinder);
    await tester.pumpAndSettle();
    await tester.tap(saveChangesBtnFinder);
    await tester.pumpAndSettle();

    // Let notification overlay timer complete
    await tester.pump(const Duration(seconds: 5));

    // Verify sticker in pack was updated in-place, preserving Waktu Simpan (createdAt) and updating Waktu Perubahan (updatedAt)
    final updatedPack = StickerPackManager().getPack(packId)!;
    expect(updatedPack.stickers.length, equals(3));
    final editedSticker = updatedPack.stickers.first;
    expect(editedSticker.emojis, contains('🔥'));
    expect(editedSticker.createdAt, equals(initialCreatedTime));
    expect(editedSticker.updatedAt, isNotNull);
    expect(editedSticker.updatedAt!.isAfter(initialUpdatedTime), isTrue);
  });
}
