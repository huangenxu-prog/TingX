import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:tingx/core/network/bili_client.dart';
import 'package:tingx/player/bili_stream_audio_source.dart';
import 'package:tingx/player/listening_session.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('compare Guichuideng chapter two audio tracks', (tester) async {
    await BiliClient.instance.initLocal();
    final lookup = Stopwatch()..start();
    final sources = await ListeningSession.onlineSources('BV1YZSGYxErb', 26540311847)
        .timeout(const Duration(seconds: 20));
    debugPrint('TingX live lookup: ${lookup.elapsedMilliseconds}ms');
    final tested = <int>{};
    var advanced = false;
    for (final source in sources.whereType<BiliStreamAudioSource>()) {
      if (!tested.add(source.trackId)) continue;
      final player = AudioPlayer();
      final clock = Stopwatch()..start();
      try {
        await player.setAudioSource(source).timeout(const Duration(seconds: 15));
        final opened = clock.elapsedMilliseconds;
        unawaited(player.play().catchError((Object _) {}));
        await player.positionStream.firstWhere((p) => p.inMilliseconds >= 300)
            .timeout(const Duration(seconds: 8));
        debugPrint('TingX live track=${source.trackId} bps=${source.bandwidth} '
            'open=${opened}ms progress=${clock.elapsedMilliseconds}ms');
        advanced = true;
      } catch (e) {
        debugPrint('TingX live track=${source.trackId} bps=${source.bandwidth} '
            'failed=${e.runtimeType} elapsed=${clock.elapsedMilliseconds}ms');
      } finally {
        await player.dispose();
      }
      if (tested.length >= 2) break;
    }
    expect(advanced, isTrue, reason: 'No tested track advanced');
  });
}
