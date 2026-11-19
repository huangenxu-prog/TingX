import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:tingx/player/bili_stream_audio_source.dart';
import 'package:tingx/core/storage/shelf_store.dart';
import 'package:tingx/models/book.dart';
import 'package:tingx/player/listening_session.dart';

// Generate a short PCM tone on-device. Only the stream locator is replaced.
Future<File> tone(Directory dir, int seconds) async {
  const rate = 8000;
  final size = rate * seconds * 2;
  final b = ByteData(44 + size);
  final bytes = b.buffer.asUint8List();
  void tag(int at, String text) => bytes.setAll(at, text.codeUnits);
  void word(int at, int value) => b.setUint32(at, value, Endian.little);
  void half(int at, int value) => b.setUint16(at, value, Endian.little);
  tag(0, 'RIFF');
  word(4, 36 + size);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  word(16, 16);
  half(20, 1);
  half(22, 1);
  word(24, rate);
  word(28, rate * 2);
  half(32, 2);
  half(34, 16);
  tag(36, 'data');
  word(40, size);
  for (int i = 0; i < rate * seconds; i++) {
    b.setInt16(
      44 + i * 2,
      (sin(i * 2 * pi * 440 / rate) * 4000).round(),
      Endian.little,
    );
  }
  return File('${dir.path}/tone-$seconds.wav').writeAsBytes(bytes);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets('iOS plays, advances chapters and resumes the saved offset', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final dir = await Directory.systemTemp.createTemp('tingx-test');
    final first = await tone(dir, 2);
    final second = await tone(dir, 24);
    final session = await AudioService.init(
      builder: () => ListeningSession(
        chapterSources: (_, cid) async => [
          BiliStreamAudioSource(uri: cid == 1 ? first.uri : second.uri, referer: "", userAgent: "TingX"),
        ],
      ),
    );
    await session.initialize();
    final book = Book.fromView({
      'bvid': 'fixture',
      'title': '测试',
      'pages': [
        {'cid': 1, 'part': '一', 'duration': 2},
        {'cid': 2, 'part': '二', 'duration': 24},
      ],
    });
    await session.open(book, book.chapters!, 0);
    expect(session.error, isNull);
    final until = DateTime.now().add(const Duration(seconds: 20));
    while ((session.chapter?.cid != 2 ||
            !session.audio.state.playing ||
            !session.ready) &&
        DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(session.chapter?.cid, 2);
    expect(session.audio.state.playing, isTrue);
    await session.seek(const Duration(seconds: 8));
    await session.pause();
    await ShelfStore.instance.load();
    final saved = ShelfStore.instance.byBvid(book.bvid)!;
    expect(saved.lastCid, 2);
    expect(saved.positionMs, closeTo(8000, 1500));
    await session.open(
      book,
      book.chapters!,
      saved.lastChapterIndex,
      offset: saved.positionMs,
    );
    expect(session.error, isNull);
    expect(session.audio.state.position.inMilliseconds, closeTo(8000, 1500));
    await session.pause();
    await session.audio.dispose();
    await dir.delete(recursive: true);
  });
}
