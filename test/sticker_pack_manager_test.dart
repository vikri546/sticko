import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('StickerPack WhatsApp Rule Tests', () {
    test('Pack with less than 3 stickers cannot be added to WhatsApp', () {
      final pack0 = const StickerPack(
        identifier: 'pack_test',
        name: 'Test Pack',
        stickers: [],
      );
      expect(pack0.canAddToWhatsApp, isFalse);
      expect(pack0.remainingStickersNeeded, equals(3));

      final pack1 = pack0.copyWith(
        stickers: [
          const StickerItem(imageFileName: 's1.webp'),
        ],
      );
      expect(pack1.canAddToWhatsApp, isFalse);
      expect(pack1.remainingStickersNeeded, equals(2));

      final pack2 = pack0.copyWith(
        stickers: [
          const StickerItem(imageFileName: 's1.webp'),
          const StickerItem(imageFileName: 's2.webp'),
        ],
      );
      expect(pack2.canAddToWhatsApp, isFalse);
      expect(pack2.remainingStickersNeeded, equals(1));
    });

    test('Pack with 3 to 30 stickers can be added to WhatsApp', () {
      final stickers3 = List.generate(
        3,
        (i) => StickerItem(imageFileName: 's$i.webp', emojis: ['😀']),
      );
      final pack3 = StickerPack(
        identifier: 'pack_test',
        name: 'Test Pack',
        stickers: stickers3,
      );
      expect(pack3.canAddToWhatsApp, isTrue);
      expect(pack3.remainingStickersNeeded, equals(0));

      final stickers30 = List.generate(
        30,
        (i) => StickerItem(imageFileName: 's$i.webp'),
      );
      final pack30 = StickerPack(
        identifier: 'pack_test',
        name: 'Test Pack',
        stickers: stickers30,
      );
      expect(pack30.canAddToWhatsApp, isTrue);

      final stickers31 = List.generate(
        31,
        (i) => StickerItem(imageFileName: 's$i.webp'),
      );
      final pack31 = StickerPack(
        identifier: 'pack_test',
        name: 'Test Pack',
        stickers: stickers31,
      );
      expect(pack31.canAddToWhatsApp, isFalse);
    });

    test('StickerPack serializes and deserializes correctly matching WhatsApp schema', () {
      final pack = StickerPack(
        identifier: 'sample_pack',
        name: 'Sample Name',
        publisher: 'Sample Publisher',
        trayImageFile: 'tray.png',
        imageDataVersion: '2',
        stickers: [
          const StickerItem(imageFileName: '1.webp', emojis: ['🔥', '🎉']),
          const StickerItem(imageFileName: '2.webp', emojis: ['👍']),
          const StickerItem(imageFileName: '3.webp', emojis: ['❤️']),
        ],
      );

      final jsonMap = pack.toJson();
      final jsonString = jsonEncode(jsonMap);
      final decodedMap = jsonDecode(jsonString) as Map<String, dynamic>;
      final restoredPack = StickerPack.fromJson(decodedMap);

      expect(restoredPack.identifier, equals('sample_pack'));
      expect(restoredPack.name, equals('Sample Name'));
      expect(restoredPack.publisher, equals('Sample Publisher'));
      expect(restoredPack.trayImageFile, equals('tray.png'));
      expect(restoredPack.imageDataVersion, equals('2'));
      expect(restoredPack.stickers.length, equals(3));
      expect(restoredPack.stickers[0].emojis, equals(['🔥', '🎉']));
      expect(restoredPack.canAddToWhatsApp, isTrue);
    });

    test(
        'addStickerPack and isStickerPackAdded do not hardcode WhatsApp Original by default so system chooser handles Original, Business, and Clones',
        () async {
      const channel = MethodChannel('com.pkri.sticko/stickers');
      Map<dynamic, dynamic>? capturedAddArgs;
      Map<dynamic, dynamic>? capturedCheckArgs;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'addStickerPack') {
          capturedAddArgs = call.arguments as Map<dynamic, dynamic>?;
          return {'status': 'success', 'message': 'Added via system chooser'};
        }
        if (call.method == 'isStickerPackAdded') {
          capturedCheckArgs = call.arguments as Map<dynamic, dynamic>?;
          return true;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final addResult = await WhatsAppStickersService.addStickerPack(
        identifier: 'pack_multi_wa',
        name: 'Stiker Multi WA',
      );
      expect(addResult['status'], equals('success'));
      expect(capturedAddArgs, isNotNull);
      expect(capturedAddArgs!['identifier'], equals('pack_multi_wa'));
      expect(capturedAddArgs!['name'], equals('Stiker Multi WA'));
      expect(capturedAddArgs!.containsKey('isBusiness'), isFalse);
      expect(capturedAddArgs!.containsKey('targetPackage'), isFalse);

      final isAdded =
          await WhatsAppStickersService.isStickerPackAdded('pack_multi_wa');
      expect(isAdded, isTrue);
      expect(capturedCheckArgs, isNotNull);
      expect(capturedCheckArgs!['identifier'], equals('pack_multi_wa'));
      expect(capturedCheckArgs!.containsKey('isBusiness'), isFalse);
      expect(capturedCheckArgs!.containsKey('targetPackage'), isFalse);
    });
  });
}
