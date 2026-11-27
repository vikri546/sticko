import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sticker_flutter/services/audio_sticker_bot_service.dart';
import 'package:sticker_flutter/services/backup_restore_service.dart';
import 'package:sticker_flutter/services/sticker_image_processor.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_sticker_validator.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';
import 'package:sticker_flutter/ui/screens/home_screen.dart';
import 'package:sticker_flutter/ui/screens/pack_detail_screen.dart';
import 'package:sticker_flutter/ui/widgets/add_sticker_sheet.dart';
import 'package:sticker_flutter/ui/widgets/create_pack_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory backupDir;
  const channel = MethodChannel('com.pkri.sticko/stickers');
  final List<String> playedAudioPaths = [];
  int stopAudioCallCount = 0;

  List<Uint8List> buildDummyVideoFrames(int count) {
    final frames = <Uint8List>[];
    for (int i = 0; i < count; i++) {
      final frame = img.Image(width: 120, height: 120, numChannels: 4);
      img.fill(
        frame,
        color: img.ColorRgba8((40 * i) % 255, (90 + 30 * i) % 255, 180, 255),
      );
      frames.add(Uint8List.fromList(img.encodePng(frame)));
    }
    return frames;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('video_audio_stickers_test_');
    backupDir = await Directory.systemTemp.createTemp('video_audio_backup_test_');
    playedAudioPaths.clear();
    stopAudioCallCount = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'getStickersDirectory':
          return tempDir.path;
        case 'checkWhatsAppInstalled':
          return {'whatsapp': true, 'whatsapp_business': false};
        case 'isStickerPackAdded':
          return false;
        case 'playStickerAudio':
          final path = (call.arguments as Map?)?['audioPath']?.toString() ?? '';
          playedAudioPaths.add(path);
          return true;
        case 'stopStickerAudio':
          stopAudioCallCount++;
          return true;
        case 'extractVideoStickerWithAudio':
          final args = call.arguments as Map<dynamic, dynamic>;
          final videoPath = args['videoPath'] as String;
          final outDir = args['outputDirPath'] as String;
          if (videoPath.contains('silent')) {
            return {
              'ok': false,
              'errorCode': 'NO_AUDIO',
              'errorMessage': 'Video tidak memiliki suara (audio).',
              'originalDurationMs': 4000,
            };
          }
          if (videoPath.contains('toolong')) {
            return {
              'ok': false,
              'errorCode': 'DURATION_EXCEEDED',
              'errorMessage': 'Durasi video melebihi batas maksimal 10 detik.',
              'originalDurationMs': 14500,
            };
          }

          final audioOut = File(
            '$outDir/extracted_${DateTime.now().microsecondsSinceEpoch}.m4a',
          );
          audioOut.parent.createSync(recursive: true);
          audioOut.writeAsBytesSync([0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70]);

          return {
            'ok': true,
            'hasAudio': true,
            'frames': buildDummyVideoFrames(6),
            'frameDurationMs': 120,
            'totalDurationMs': 3600,
            'originalDurationMs': 3600,
            'audioFilePath': audioOut.path,
            'audioExtension': 'm4a',
          };
        default:
          return null;
      }
    });

    final manager = StickerPackManager();
    manager.resetForTesting();
    await manager.initialize(customStickersDir: tempDir.path, force: true);
    AudioStickerBotService().resetForTesting(customDir: tempDir.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    StickerPackManager().resetForTesting();
    AudioStickerBotService().resetForTesting();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
    if (backupDir.existsSync()) {
      backupDir.deleteSync(recursive: true);
    }
  });

  group('Video + Audio Sticker Pack Tests', () {
    testWidgets(
      'CreatePackDialog renders 3 pack types (Statis, Animasi, Video Audio) and creates videoAudioStickerPack',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(430, 932);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: CreatePackDialog())),
        );
        await tester.pump();

        expect(find.byKey(const Key('pack_type_static')), findsOneWidget);
        expect(find.byKey(const Key('pack_type_gif')), findsOneWidget);
        expect(find.byKey(const Key('pack_type_video_audio')), findsOneWidget);
        expect(find.text('Statis'), findsOneWidget);
        expect(find.text('Animasi'), findsOneWidget);
        expect(find.text('Video Audio'), findsOneWidget);
        expect(find.text('MP4 + Suara (≤ 10s)'), findsOneWidget);

        await tester.enterText(find.byType(TextField).first, 'Paket Video Suara');
        await tester.tap(find.byKey(const Key('pack_type_video_audio')));
        await tester.pump();

        expect(
          find.textContaining('Mendukung video .mp4 dsb. maks 10 detik yang memiliki suara'),
          findsOneWidget,
        );

        await tester.tap(find.text('Buat Paket'));
        await tester.pumpAndSettle();

        final packs = StickerPackManager().packs;
        expect(packs.length, equals(1));
        expect(packs.first.name, equals('Paket Video Suara'));
        expect(packs.first.videoAudioStickerPack, isTrue);
        expect(packs.first.animatedStickerPack, isTrue);
      },
    );

    test(
      'processVideoToStickerWithAudio rejects silent or >10s videos and converts <=10s video with audio to 512x512 WebP + audio',
      () async {
        expect(StickerImageProcessor.isSupportedVideoFile('clip.mp4'), isTrue);
        expect(StickerImageProcessor.isSupportedVideoFile('clip.WEBM'), isTrue);
        expect(StickerImageProcessor.isSupportedVideoFile('photo.jpg'), isFalse);

        // 1. Silent video rejected
        await expectLater(
          () => StickerImageProcessor.processVideoToStickerWithAudio(
            videoPath: '${tempDir.path}/silent_clip.mp4',
            tempOutputDirPath: tempDir.path,
          ),
          throwsA(isA<VideoNoAudioException>()),
        );

        // 2. > 10s video rejected
        await expectLater(
          () => StickerImageProcessor.processVideoToStickerWithAudio(
            videoPath: '${tempDir.path}/toolong_clip.mp4',
            tempOutputDirPath: tempDir.path,
          ),
          throwsA(isA<VideoDurationExceededException>()),
        );

        // 3. Valid <= 10s video with audio succeeds
        final processed =
            await StickerImageProcessor.processVideoToStickerWithAudio(
          videoPath: '${tempDir.path}/valid_funny.mp4',
          tempOutputDirPath: tempDir.path,
        );
        expect(processed.durationMs, lessThanOrEqualTo(10000));
        expect(File(processed.tempAudioFilePath).existsSync(), isTrue);
        expect(
          StickerImageProcessor.isAnimatedWebp(processed.webpBytes),
          isTrue,
        );
        expect(processed.webpBytes.lengthInBytes, lessThanOrEqualTo(500 * 1024));
      },
    );

    test(
      'StickerPackManager manages video+audio stickers, validates pack, preserves audio on edit, cleans up on delete, and backs up/restores audio',
      () async {
        final manager = StickerPackManager();
        final videoPack = await manager.createPack(
          name: 'Meme Suara',
          publisher: 'Kreator',
          videoAudioStickerPack: true,
        );

        final workDir = Directory('${tempDir.path}/work')..createSync();
        final processed =
            await StickerImageProcessor.processVideoToStickerWithAudio(
          videoPath: '${tempDir.path}/valid_clip.mp4',
          tempOutputDirPath: workDir.path,
        );

        // Rejects adding without audio into videoAudioStickerPack
        await expectLater(
          () => manager.addStickerToPack(
            packIdentifier: videoPack.identifier,
            imageBytes: processed.webpBytes,
          ),
          throwsA(isA<Exception>()),
        );

        // Add 3 video+audio stickers
        final s1 = await manager.addStickerToPack(
          packIdentifier: videoPack.identifier,
          imageBytes: processed.webpBytes,
          emojis: const ['🔊'],
          sourceAudioFilePath: processed.tempAudioFilePath,
          durationMs: processed.durationMs,
        );
        expect(s1.hasAudio, isTrue);

        final batchAdded = await manager.addMultipleStickersToPack(
          packIdentifier: videoPack.identifier,
          imagesBytesList: [processed.webpBytes, processed.webpBytes],
          defaultEmojis: const ['😂'],
          sourceAudioFilePaths: [
            processed.tempAudioFilePath,
            processed.tempAudioFilePath,
          ],
          durationsMs: [processed.durationMs, processed.durationMs],
        );
        expect(batchAdded.length, equals(2));

        // Pre-flight WhatsApp validation succeeds (3 stickers, 512x512 WebP <=500KB + audio files present)
        final currentPack = manager.getPack(videoPack.identifier)!;
        final validation = await WhatsAppStickerValidator.validatePack(
          currentPack,
          stickersDirectoryPath: tempDir.path,
        );
        expect(validation.isValid, isTrue, reason: validation.errorMessage);

        // Editing emojis via replaceStickerInPack preserves existing companion audio
        final edited = await manager.replaceStickerInPack(
          packIdentifier: videoPack.identifier,
          oldFileName: s1.imageFileName,
          newImageBytes: processed.webpBytes,
          newEmojis: const ['🔥'],
        );
        expect(edited.hasAudio, isTrue);
        expect(edited.audioFileName, equals(s1.audioFileName));
        expect(edited.emojis, equals(['🔥']));

        // Export ZIP backup and verify audio files are restored cleanly
        final backupService = BackupRestoreService();
        final backupMeta = await backupService.exportBackupZip(
          customBackupDir: backupDir.path,
          customStickersDir: tempDir.path,
        );
        expect(File(backupMeta.filePath).existsSync(), isTrue);

        // Remove 1 sticker and verify its companion audio file is deleted from disk
        final audioPathToDelete =
            manager.getAudioFilePath(videoPack.identifier, edited.audioFileName)!;
        expect(File(audioPathToDelete).existsSync(), isTrue);
        await manager.removeStickerFromPack(
          packIdentifier: videoPack.identifier,
          fileName: edited.imageFileName,
        );
        expect(File(audioPathToDelete).existsSync(), isFalse);

        // Restore from ZIP (overwrite) brings all 3 stickers + audio files back
        final restoreRes = await backupService.restoreFromZip(
          zipFilePath: backupMeta.filePath,
          overwriteConflicts: true,
          customStickersDir: tempDir.path,
        );
        expect(restoreRes.success, isTrue);
        final restoredPack = manager.getPack(videoPack.identifier)!;
        expect(restoredPack.videoAudioStickerPack, isTrue);
        expect(restoredPack.stickers.length, equals(3));
        for (final item in restoredPack.stickers) {
          expect(item.hasAudio, isTrue);
          final restoredAudio =
              manager.getAudioFilePath(restoredPack.identifier, item.audioFileName)!;
          expect(File(restoredAudio).existsSync(), isTrue);
        }
      },
    );

    testWidgets(
      'AddStickerSheet, HomeScreen, and PackDetailScreen render Video Audio UI and tap-to-play speaker controls',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(430, 932);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        final manager = StickerPackManager();
        late final String packId;
        late final StickerItem savedSticker;

        await tester.runAsync(() async {
          final pack = await manager.createPack(
            name: 'Koleksi Suara',
            publisher: 'pkri',
            videoAudioStickerPack: true,
          );
          packId = pack.identifier;
          final processed =
              await StickerImageProcessor.processVideoToStickerWithAudio(
            videoPath: '${tempDir.path}/sample.mp4',
            tempOutputDirPath: tempDir.path,
          );
          savedSticker = await manager.addStickerToPack(
            packIdentifier: packId,
            imageBytes: processed.webpBytes,
            emojis: const ['🔊'],
            sourceAudioFilePath: processed.tempAudioFilePath,
            durationMs: processed.durationMs,
          );
        });

        // 1. AddStickerSheet shows dedicated Video+Audio picker option
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AddStickerSheet(packIdentifier: packId)),
          ),
        );
        await tester.pump();

        expect(find.text('Tambah Stiker Video Audio (Maks 10s)'), findsOneWidget);
        expect(find.text('Galeri Video Bersuara (.mp4)'), findsOneWidget);
        expect(
          find.text('Video dengan audio suara (maks 10 detik)'),
          findsOneWidget,
        );

        // 2. HomeScreen shows Audio badge on Video Audio pack card
        await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
        await tester.pump();
        expect(find.text('Koleksi Suara'), findsOneWidget);
        expect(find.text('Audio'), findsOneWidget);

        // 3. PackDetailScreen shows Video Audio (≤10s) badge and tap-to-play speaker button on tile
        await tester.pumpWidget(
          MaterialApp(home: PackDetailScreen(packIdentifier: packId)),
        );
        await tester.pump();

        expect(find.text('Video Audio (≤10s)'), findsOneWidget);
        final speakerBtn = find.byKey(
          ValueKey('sticker_audio_btn_${savedSticker.imageFileName}'),
        );
        expect(speakerBtn, findsOneWidget);

        // Tap speaker button -> plays audio without opening Edit sheet
        await tester.tap(speakerBtn);
        await tester.pump();
        expect(playedAudioPaths.length, equals(1));
        expect(find.text('Edit Stiker Video Audio'), findsNothing);

        // Tap speaker button again -> stops audio
        await tester.tap(speakerBtn);
        await tester.pump();
        expect(stopAudioCallCount, greaterThanOrEqualTo(1));

        // Tap tile body -> opens Edit Stiker Video Audio with Putar Suara Stiker & Informasi
        await tester.tap(
          find.byKey(ValueKey('sticker_tile_tap_${savedSticker.imageFileName}')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Edit Stiker Video Audio'), findsOneWidget);
        expect(find.byKey(const Key('preview_audio_toggle_button')), findsOneWidget);
        expect(find.byKey(const Key('preview_send_via_bot_button')), findsOneWidget);
        expect(find.textContaining('Putar Suara Stiker'), findsOneWidget);
        // Verify Crop (Fit, Penuh, Bulat, Reset) & Zoom Slider appear on Audio Sticker editor
        expect(find.text('Fit'), findsOneWidget);
        expect(find.text('Penuh'), findsOneWidget);
        expect(find.text('Bulat'), findsOneWidget);
        expect(find.text('Reset'), findsOneWidget);
        expect(find.byKey(const Key('audio_sticker_zoom_slider')), findsOneWidget);
        expect(find.text('100%'), findsOneWidget);

        // Switch crop mode to Bulat and adjust Zoom Slider
        await tester.tap(find.text('Bulat'));
        await tester.pump();

        final slider = tester.widget<Slider>(
          find.byKey(const Key('audio_sticker_zoom_slider')),
        );
        slider.onChanged!(1.8);
        await tester.pump();
        expect(find.text('180%'), findsOneWidget);
      },
    );

    test(
      'transformAnimatedStickerWebp applies Crop (Penuh / Bulat) and Zoom across all animated frames while keeping 512x512 <= 500 KB',
      () async {
        // Build a 9:16 portrait 2-frame animated sticker (narrow vertical bar centered on 512x512)
        final portraitF1 = img.Image(width: 240, height: 480, numChannels: 4);
        img.fill(portraitF1, color: img.ColorRgba8(240, 80, 40, 255));
        final portraitF2 = img.Image(width: 240, height: 480, numChannels: 4);
        img.fill(portraitF2, color: img.ColorRgba8(40, 190, 120, 255));

        final baseAnim = await StickerImageProcessor.processAnimatedToStickerWebp(
          frames: [
            Uint8List.fromList(img.encodePng(portraitF1)),
            Uint8List.fromList(img.encodePng(portraitF2)),
          ],
          frameDurationMs: 120,
        );

        final fillScale =
            StickerImageProcessor.computeContentFillScale(baseAnim.webpBytes);
        expect(fillScale, greaterThan(1.8));

        // Apply Bulat (circular crop + auto-fill scale) + 1.5x center zoom
        const canvasSize = 240.0;
        const zoom = 1.5;
        const pan = (canvasSize * 0.5) * (1.0 - zoom); // center-anchored zoom
        final transformedBytes =
            await StickerImageProcessor.transformAnimatedStickerWebp(
          webpBytes: baseAnim.webpBytes,
          userScale: zoom,
          panX: pan,
          panY: pan,
          canvasSize: canvasSize,
          modeBaseScale: fillScale,
          circleMask: true,
        );

        expect(StickerImageProcessor.isAnimatedWebp(transformedBytes), isTrue);
        expect(transformedBytes.lengthInBytes, lessThanOrEqualTo(500 * 1024));

        final decoded = img.decodeWebP(transformedBytes);
        expect(decoded, isNotNull);
        expect(decoded!.width, equals(512));
        expect(decoded.height, equals(512));
        expect(decoded.numFrames, equals(2));
        // Corner (0, 0) must be transparent due to circular crop mask, while center (256, 256) is opaque
        expect(decoded.getPixel(0, 0).a, equals(0));
        expect(decoded.getPixel(256, 256).a, greaterThan(200));
      },
    );

    testWidgets(
      'AudioStickerBotService & PackDetailScreen send Video+Audio stickers to WhatsApp Chatbot Bridge and receive Sound Stickers',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(430, 932);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        // Verify phone & URL normalization
        expect(
          AudioStickerBotService.normalizePhoneNumber('0812-3456-7890'),
          equals('6281234567890'),
        );
        expect(
          AudioStickerBotService.normalizeBridgeBaseUrl('192.168.1.25:3100/'),
          equals('http://192.168.1.25:3100'),
        );

        final capturedRequests = <Map<String, dynamic>>[];
        AudioStickerBotService.mockHttpClientFactory = () => _FakeBotHttpClient(
              onRequest: (method, uri, body) {
                capturedRequests.add({
                  'method': method,
                  'path': uri.path,
                  'body': body.isNotEmpty ? jsonDecode(body) : null,
                });
                if (uri.path == '/api/status') {
                  return (
                    200,
                    jsonEncode({
                      'ok': true,
                      'connected': true,
                      'botNumber': '628999888777',
                    }),
                  );
                }
                return (
                  200,
                  jsonEncode({
                    'ok': true,
                    'sentCount': 1,
                    'message': '1 stiker audio berhasil dikirim ke WhatsApp Anda!',
                  }),
                );
              },
            );

        final manager = StickerPackManager();
        late final String packId;
        await tester.runAsync(() async {
          final pack = await manager.createPack(
            name: 'Paket Bot Audio',
            publisher: 'pkri',
            videoAudioStickerPack: true,
          );
          packId = pack.identifier;
          final processed =
              await StickerImageProcessor.processVideoToStickerWithAudio(
            videoPath: '${tempDir.path}/voice_meme.mp4',
            tempOutputDirPath: tempDir.path,
          );
          await manager.addStickerToPack(
            packIdentifier: packId,
            imageBytes: processed.webpBytes,
            emojis: const ['🔊'],
            sourceAudioFilePath: processed.tempAudioFilePath,
            durationMs: processed.durationMs,
          );
        });

        await tester.pumpWidget(
          MaterialApp(home: PackDetailScreen(packIdentifier: packId)),
        );
        await tester.pump();

        // Tap "Kirim Stiker Bersuara via Bot WA" -> opens AudioBotBridgeSheet since not configured yet
        final sendBotBtn = find.byKey(const Key('send_pack_via_audio_bot_button'));
        expect(sendBotBtn, findsOneWidget);
        await tester.tap(sendBotBtn);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('bot_bridge_url_field')), findsOneWidget);
        expect(find.byKey(const Key('bot_target_phone_field')), findsOneWidget);

        // Enter Bot Server URL & User WA phone, check status, then send
        await tester.enterText(
          find.byKey(const Key('bot_bridge_url_field')),
          '192.168.1.50:3100',
        );
        await tester.enterText(
          find.byKey(const Key('bot_target_phone_field')),
          '081298765432',
        );

        await tester.tap(find.byKey(const Key('bot_check_status_button')));
        await tester.pumpAndSettle();
        expect(find.textContaining('628999888777'), findsOneWidget);

        await tester.tap(find.byKey(const Key('bot_submit_send_button')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 5));

        expect(capturedRequests.length, equals(2));
        final postReq = capturedRequests.last;
        expect(postReq['method'], equals('POST'));
        expect(postReq['path'], equals('/api/send-audio-sticker'));
        final postBody = postReq['body'] as Map<String, dynamic>;
        expect(postBody['targetPhone'], equals('6281298765432'));
        final sentStickers = postBody['stickers'] as List<dynamic>;
        expect(sentStickers.length, equals(1));
        expect((sentStickers.first['webpBase64'] as String).isNotEmpty, isTrue);
        expect((sentStickers.first['audioBase64'] as String).isNotEmpty, isTrue);
      },
    );

    testWidgets(
      'Option 1 Centralized Mode: user only enters phone number and auto-connects via audio_bot_server.json',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(430, 932);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        expect(
          AudioStickerBotService.isWildcardBindHost('http://0.0.0.0:3100'),
          isTrue,
        );

        final capturedRequests = <Map<String, dynamic>>[];
        AudioStickerBotService.mockHttpClientFactory = () => _FakeBotHttpClient(
              onRequest: (method, uri, body) {
                capturedRequests.add({
                  'method': method,
                  'host': uri.host,
                  'path': uri.path,
                  'body': body.isNotEmpty ? jsonDecode(body) : null,
                });
                if (uri.host == 'raw.githubusercontent.com') {
                  return (
                    200,
                    jsonEncode({
                      'bridge_url': 'https://sticko-termux.trycloudflare.com',
                      'bot_whatsapp_number': '628999888777',
                    }),
                  );
                }
                if (uri.path == '/api/status') {
                  return (
                    200,
                    jsonEncode({
                      'ok': true,
                      'connected': true,
                      'botNumber': '628999888777',
                    }),
                  );
                }
                return (
                  200,
                  jsonEncode({
                    'ok': true,
                    'sentCount': 1,
                    'botNumber': '628999888777',
                    'message': '1 stiker audio berhasil dikirim via Server Terpusat!',
                  }),
                );
              },
            );

        final manager = StickerPackManager();
        late final String packId;
        await tester.runAsync(() async {
          final pack = await manager.createPack(
            name: 'Paket Opsi 1 Terpusat',
            publisher: 'pkri',
            videoAudioStickerPack: true,
          );
          packId = pack.identifier;
          final processed =
              await StickerImageProcessor.processVideoToStickerWithAudio(
            videoPath: '${tempDir.path}/central_meme.mp4',
            tempOutputDirPath: tempDir.path,
          );
          await manager.addStickerToPack(
            packIdentifier: packId,
            imageBytes: processed.webpBytes,
            emojis: const ['🔊'],
            sourceAudioFilePath: processed.tempAudioFilePath,
            durationMs: processed.durationMs,
          );
        });

        await tester.pumpWidget(
          MaterialApp(home: PackDetailScreen(packIdentifier: packId)),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('send_pack_via_audio_bot_button')));
        await tester.pumpAndSettle();

        // User ONLY enters their own WhatsApp phone number (leaves bot_bridge_url_field empty!)
        await tester.enterText(
          find.byKey(const Key('bot_target_phone_field')),
          '081298765432',
        );

        await tester.tap(find.byKey(const Key('bot_submit_send_button')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 5));

        expect(AudioStickerBotService().isConfigured, isTrue);
        expect(AudioStickerBotService().bridgeUrl, isEmpty);
        expect(
          AudioStickerBotService().remoteBridgeUrl,
          equals('https://sticko-termux.trycloudflare.com'),
        );

        final githubReq = capturedRequests.firstWhere(
          (r) => r['host'] == 'raw.githubusercontent.com',
        );
        expect(githubReq['method'], equals('GET'));

        final sendReq = capturedRequests.last;
        expect(sendReq['method'], equals('POST'));
        expect(sendReq['host'], equals('sticko-termux.trycloudflare.com'));
        expect(sendReq['path'], equals('/api/send-audio-sticker'));
        expect(
          (sendReq['body'] as Map<String, dynamic>)['targetPhone'],
          equals('6281298765432'),
        );
      },
    );
  });
}

class _FakeBotHttpClient implements HttpClient {
  final (int, String) Function(String method, Uri uri, String body) onRequest;
  _FakeBotHttpClient({required this.onRequest});

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeBotHttpRequest('GET', url, onRequest);

  @override
  Future<HttpClientRequest> postUrl(Uri url) async =>
      _FakeBotHttpRequest('POST', url, onRequest);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBotHttpRequest implements HttpClientRequest {
  final String methodName;
  final Uri url;
  final (int, String) Function(String method, Uri uri, String body) onRequest;
  final List<int> _buffer = [];

  _FakeBotHttpRequest(this.methodName, this.url, this.onRequest);

  @override
  final HttpHeaders headers = _FakeBotHttpHeaders();

  @override
  void add(List<int> data) => _buffer.addAll(data);

  @override
  Future<HttpClientResponse> close() async {
    final body = utf8.decode(_buffer);
    final (code, respBody) = onRequest(methodName, url, body);
    return _FakeBotHttpResponse(code, respBody);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBotHttpHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBotHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  final int statusCode;
  final String body;

  _FakeBotHttpResponse(this.statusCode, this.body);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([utf8.encode(body)]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
