import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sticker_flutter/config/developer_sticker_packs.dart';
import 'package:sticker_flutter/services/duplicate_stickers_service.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_sticker_validator.dart';
import 'package:sticker_flutter/ui/screens/home_screen.dart';
import 'package:sticker_flutter/ui/screens/pack_detail_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  const channel = MethodChannel('com.pkri.sticko/stickers');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dev_packs_test_');
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

    StickerPackManager().resetForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    StickerPackManager().resetForTesting();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('DeveloperStickerPacks (template-1 -> Stiker-Kucing-1)', () {
    test(
      'Seeds all 30 real images from lib/images/template-1 into valid WhatsApp pack Stiker-Kucing-1 by pkri',
      () async {
        final manager = StickerPackManager();
        await manager.initialize(
          customStickersDir: tempDir.path,
          force: true,
          seedDeveloperPacks: true,
        );

        expect(manager.packs.length, equals(1));
        final devPack = manager.getPack('dev_stiker_kucing_1');
        expect(devPack, isNotNull);
        expect(devPack!.name, equals('Stiker-Kucing-1'));
        expect(devPack.publisher, equals('pkri'));
        expect(devPack.isDeveloperPack, isTrue);
        expect(devPack.animatedStickerPack, isFalse);
        expect(devPack.stickers.length, equals(30));
        expect(devPack.canAddToWhatsApp, isTrue);

        // Must pass official WhatsAppStickerValidator (512x512 WebP <= 100 KB, tray 96x96 <= 50 KB)
        final validation = await WhatsAppStickerValidator.validatePack(
          devPack,
          stickersDirectoryPath: tempDir.path,
        );
        expect(validation.isValid, isTrue, reason: validation.errorMessage);
        expect(validation.errors, isEmpty);

        // Re-initializing must not duplicate or overwrite existing developer pack
        await manager.initialize(
          customStickersDir: tempDir.path,
          force: true,
          seedDeveloperPacks: true,
        );
        expect(manager.packs.length, equals(1));
        expect(manager.getPack('dev_stiker_kucing_1')!.stickers.length, equals(30));
      },
    );

    test(
      'Developer pack and its stickers cannot be deleted, can be edited/reordered, while user packs can be deleted',
      () async {
        final manager = StickerPackManager();
        await manager.initialize(
          customStickersDir: tempDir.path,
          force: true,
          seedDeveloperPacks: true,
        );

        final devPack = manager.getPack('dev_stiker_kucing_1')!;
        final firstSticker = devPack.stickers.first;
        final secondSticker = devPack.stickers[1];

        // 1. Deleting developer pack is blocked
        await expectLater(
          () => manager.deletePack(devPack.identifier),
          throwsA(isA<Exception>()),
        );
        expect(manager.getPack(devPack.identifier), isNotNull);

        // 2. Deleting individual sticker inside developer pack is blocked
        await expectLater(
          () => manager.removeStickerFromPack(
            packIdentifier: devPack.identifier,
            fileName: firstSticker.imageFileName,
          ),
          throwsA(isA<Exception>()),
        );
        expect(manager.getPack(devPack.identifier)!.stickers.length, equals(30));

        // 3. Reordering stickers inside developer pack is allowed
        await manager.reorderStickerInPack(
          packIdentifier: devPack.identifier,
          oldIndex: 0,
          newIndex: 1,
        );
        expect(
          manager.getPack(devPack.identifier)!.stickers.first.imageFileName,
          equals(secondSticker.imageFileName),
        );

        // 4. Editing/replacing sticker inside developer pack is allowed & persists across re-init
        final editedImg = img.Image(width: 200, height: 200);
        img.fill(editedImg, color: img.ColorRgb8(240, 154, 6));
        final editedBytes = Uint8List.fromList(img.encodePng(editedImg));

        final targetFile =
            manager.getPack(devPack.identifier)!.stickers.first.imageFileName;
        final replaced = await manager.replaceStickerInPack(
          packIdentifier: devPack.identifier,
          oldFileName: targetFile,
          newImageBytes: editedBytes,
          newEmojis: ['🔥', '🐱'],
        );
        expect(replaced.emojis, equals(['🔥', '🐱']));

        await manager.initialize(
          customStickersDir: tempDir.path,
          force: true,
          seedDeveloperPacks: true,
        );
        expect(
          manager.getPack(devPack.identifier)!.stickers.first.emojis,
          equals(['🔥', '🐱']),
        );

        // 5. Duplicate cleaner cannot delete stickers belonging to developer pack
        final dupService = DuplicateStickersService();
        final devOccurrence = DuplicateStickerOccurrence(
          packIdentifier: devPack.identifier,
          packName: devPack.name,
          sticker: manager.getPack(devPack.identifier)!.stickers.first,
          filePath: manager.getStickerFilePath(
            devPack.identifier,
            manager.getPack(devPack.identifier)!.stickers.first.imageFileName,
          )!,
          fileSizeBytes: 1000,
        );
        final dupDeleted = await dupService.deleteDuplicate(
          devOccurrence,
          packManager: manager,
        );
        expect(dupDeleted, isFalse);

        // 6. Regular user-created pack and its stickers CAN still be deleted normally
        final userPack = await manager.createPack(name: 'Paket User', publisher: 'User');
        final addedUserSticker = await manager.addStickerToPack(
          packIdentifier: userPack.identifier,
          imageBytes: editedBytes,
        );
        await manager.removeStickerFromPack(
          packIdentifier: userPack.identifier,
          fileName: addedUserSticker.imageFileName,
        );
        expect(manager.getPack(userPack.identifier)!.stickers, isEmpty);

        await manager.deletePack(userPack.identifier);
        expect(manager.getPack(userPack.identifier), isNull);
      },
    );

    testWidgets(
      'Explore (HomeScreen) displays Stiker-Kucing-1 and PackDetailScreen hides delete controls while allowing edit',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(430, 932);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        // Seed a lightweight developer pack using first 3 real template-1 assets for fast widget test
        final manager = StickerPackManager();
        await tester.runAsync(() async {
          await manager.initialize(
            customStickersDir: tempDir.path,
            force: true,
            seedDeveloperPacks: true,
            developerTemplates: const [
              DeveloperStickerPackTemplate(
                identifier: 'dev_stiker_kucing_1',
                name: 'Stiker-Kucing-1',
                publisher: 'pkri',
                assetFolder: 'lib/images/template-1',
                defaultEmojis: ['🐱'],
                assetFiles: [
                  'lib/images/template-1/FB_IMG_1703990372881.jpg',
                  'lib/images/template-1/FB_IMG_1704016140272.jpg',
                  'lib/images/template-1/FB_IMG_1704456208378.jpg',
                ],
              ),
            ],
          );
        });

        // 1. Verify Explore screen displays Stiker-Kucing-1 with author pkri and Bawaan badge
        await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
        await tester.pump();

        expect(find.text('Stiker-Kucing-1'), findsOneWidget);
        expect(find.text('3/30 Stiker • Oleh pkri'), findsOneWidget);
        expect(find.text('Bawaan'), findsOneWidget);
        expect(find.text('Siap Ditambahkan'), findsOneWidget);

        // 2. Open PackDetailScreen for developer pack: NO delete pack or delete sticker buttons
        await tester.pumpWidget(
          const MaterialApp(
            home: PackDetailScreen(packIdentifier: 'dev_stiker_kucing_1'),
          ),
        );
        await tester.pump();

        expect(find.text('Stiker-Kucing-1'), findsOneWidget);
        expect(find.text('Oleh pkri'), findsOneWidget);
        expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
        expect(find.byIcon(Icons.close_rounded), findsNothing);

        // 3. Tapping a sticker inside developer pack still opens Edit Stiker sheet
        final firstStickerName =
            manager.getPack('dev_stiker_kucing_1')!.stickers.first.imageFileName;
        await tester.tap(find.byKey(ValueKey('sticker_tile_tap_$firstStickerName')));
        await tester.pumpAndSettle();

        expect(find.text('Edit Stiker'), findsOneWidget);
        expect(find.text('Simpan Perubahan'), findsOneWidget);

        // Close edit sheet
        Navigator.of(tester.element(find.text('Edit Stiker'))).pop();
        await tester.pumpAndSettle();

        // 4. Verify normal user pack STILL shows delete pack & delete sticker buttons
        late final String userPackId;
        await tester.runAsync(() async {
          final userPack = await manager.createPack(name: 'Paket Pribadi', publisher: 'Aku');
          userPackId = userPack.identifier;
          final dummy = img.Image(width: 64, height: 64);
          img.fill(dummy, color: img.ColorRgb8(37, 211, 102));
          await manager.addStickerToPack(
            packIdentifier: userPackId,
            imageBytes: Uint8List.fromList(img.encodePng(dummy)),
          );
        });

        await tester.pumpWidget(
          MaterialApp(
            home: PackDetailScreen(packIdentifier: userPackId),
          ),
        );
        await tester.pump();

        expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
        expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      },
    );
  });
}
