import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../core/network/api_config.dart';
import '../core/storage/shelf_store.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../services/bili_api.dart';
import 'bili_stream_audio_source.dart';

class ListeningSession extends BaseAudioHandler {
  // Opt-in only: flutter build ... --dart-define=TINGX_EXPERIMENTAL_STREAM=true
  // The production default remains the original URI playback path.
  static const experimentalStream =
      bool.fromEnvironment('TINGX_EXPERIMENTAL_STREAM');
  ListeningSession({this.chapterSources = onlineSources});
  final Future<List<AudioSource>> Function(String bvid, int cid) chapterSources;

  static Future<List<AudioSource>> onlineSources(String bvid, int cid) async {
    final result = await BiliApi.instance.playUrl(bvid, cid);

    // iOS AVPlayer supports AAC/MP4 most reliably. Try ordinary DASH
    // audio first; Dolby/FLAC are fallback only, not the default.
    final tracks = [...result.tracks]
      ..sort((a, b) {
        final aAac = a.codecs.toLowerCase().contains('mp4a') ? 1 : 0;
        final bAac = b.codecs.toLowerCase().contains('mp4a') ? 1 : 0;
        if (aAac != bAac) return bAac.compareTo(aAac);
        return b.bandwidth.compareTo(a.bandwidth);
      });

    final urls = <String, BiliStreamAudioSource>{};
    final ordered = [
      ...tracks,
      if (result.dolby != null) result.dolby!,
      if (result.flac != null) result.flac!,
    ];
    void add(String raw, int id, int bandwidth) {
      final uri = Uri.tryParse(raw);
      if (uri == null || uri.host.isEmpty ||
          (uri.scheme != 'http' && uri.scheme != 'https')) return;
      final https = uri.replace(scheme: 'https');
      urls.putIfAbsent(https.toString(), () => BiliStreamAudioSource(
        uri: https,
        referer: BiliEndpoints.home,
        userAgent: BiliEndpoints.userAgent,
        trackId: id,
        bandwidth: bandwidth,
      ));
    }

    // Give a different ordinary track a chance before mirrors of track one.
    for (final track in tracks) {
      add(track.baseUrl, track.id, track.bandwidth);
    }
    for (final track in ordered) {
      add(track.baseUrl, track.id, track.bandwidth);
      for (final backup in track.backupUrls) {
        add(backup, track.id, track.bandwidth);
      }
    }
    return [
      for (final source in urls.values)
        if (experimentalStream) source else AudioSource.uri(source.uri,
          headers: const {'Referer': BiliEndpoints.home,
                          'User-Agent': BiliEndpoints.userAgent}),
    ];
  }

  ({String bvid, int cid, DateTime at, Future<List<AudioSource>> sources})? _next;

  void _prefetchNext() {
    final next = chapters.elementAtOrNull(index + 1);
    final currentBook = book;
    if (next == null || currentBook == null) return;
    final pending = chapterSources(currentBook.bvid, next.cid)
        .timeout(const Duration(seconds: 12))
        .catchError((Object _) => <AudioSource>[]);
    _next = (bvid: currentBook.bvid, cid: next.cid,
             at: DateTime.now(), sources: pending);
  }

  Future<List<AudioSource>> _takeSources(String bvid, int cid) async {
    final cached = _next;
    _next = null;
    if (cached != null && cached.bvid == bvid && cached.cid == cid &&
        DateTime.now().difference(cached.at) < const Duration(hours: 2)) {
      final items = await cached.sources;
      final now = DateTime.now();
      final valid = items.where((s) {
        final uri = s is BiliStreamAudioSource ? s.uri : s is UriAudioSource ? s.uri : null;
        final expiry = int.tryParse(uri?.queryParameters['deadline'] ?? '');
        return expiry == null ? now.difference(cached.at) < const Duration(minutes: 10)
            : expiry > now.millisecondsSinceEpoch ~/ 1000 + 60;
      }).toList();
      if (valid.isNotEmpty) return valid;
    }
    return chapterSources(bvid, cid).timeout(const Duration(seconds: 12));
  }

  // just_audio sends custom Referer/User-Agent headers through its local
  // proxy on iOS. Disabling the proxy can cause CDN requests to omit them.
  final audio = AudioPlayer(useProxyForRequestHeaders: true);

  // Diagnose the CDN response without logging expiring signed URLs.
  // Only runs after a playback failure, never on the successful fast path.
  Future<String> _diagnoseSource(AudioSource source) async {
    final uri = switch (source) {
      BiliStreamAudioSource s => s.uri,
      UriAudioSource s => s.uri,
      _ => null,
    };
    if (uri == null) return '';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.refererHeader, BiliEndpoints.home);
        request.headers.set(HttpHeaders.userAgentHeader, BiliEndpoints.userAgent);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
        final response = await request.close();
        final range = response.headers.value(HttpHeaders.contentRangeHeader);
        return '首选地址探测 ${uri.host} HTTP ${response.statusCode}，Range ${range ?? "无"}';
      })().timeout(const Duration(seconds: 4));
    } catch (e) {
      return '首选地址探测 ${uri.host}，${e.runtimeType}';
    } finally {
      client.close(force: true);
    }
  }
  AudioSession? _audioSession;
  final revision = ValueNotifier(0);
  final shelf = ShelfStore.instance;
  Book? book;
  List<Chapter> chapters = [];
  int index = 0;
  bool busy = false;
  bool ready = false;
  bool completingChapter = false;
  String? error;
  Timer? sleep;
  Chapter? get chapter => chapters.elementAtOrNull(index);

  Future<void> initialize() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    _audioSession = session;
    audio.playbackEventStream.listen(
      (_) {
        publish();
      },
      onError: (Object e) {
        error = '播放中断：$e';
        revision.value++;
      },
    );
    audio.playerStateStream.listen((state) {
      if (ready &&
          !busy &&
          state.playing &&
          state.processingState == ProcessingState.completed) {
        unawaited(finishChapter());
      }
    });
    Timer.periodic(const Duration(seconds: 4), (_) {
      if (audio.playing) unawaited(save());
    });
  }

  void publish() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          audio.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.fastForward,
          MediaAction.rewind,
        },
        playing: audio.playing,
        processingState:
            AudioProcessingState.values[audio.processingState.index],
        updatePosition: audio.position,
        bufferedPosition: audio.bufferedPosition,
        speed: audio.speed,
      ),
    );
    revision.value++;
  }

  Future<void> save() async {
    if (!ready || book == null || chapter == null) return;
    await shelf.updateProgress(
      book!.bvid,
      cid: chapter!.cid,
      chapterIndex: index,
      positionMs: audio.position.inMilliseconds,
      chapterDurationMs:
          audio.duration?.inMilliseconds ?? chapter!.duration * 1000,
      totalChapters: chapters.length,
    );
  }

  Future<void> open(
    Book selected,
    List<Chapter> parts,
    int at, {
    int offset = 0,
  }) async {
    if (busy || at < 0 || at >= parts.length) return;
    final startupClock = Stopwatch()..start();
    busy = true;
    error = null;
    revision.value++;
    try {
      await save();
      ready = false;
      await audio.stop();
      book = selected;
      chapters = parts;
      index = at;
      final current = parts[at];
      // Bilibili DASH URLs can be signed and short-lived. If every CDN
      // endpoint fails, request fresh addresses once before showing an error.
      // Never retry indefinitely or skip the chapter silently.
      Future<String>? firstProbe;
      Object? lastError;
      final attempted = <Uri>{};
      final attempts = <String>[];
      var opened = false;
      for (var refresh = 0; refresh < 2 && !opened; refresh++) {
        if (refresh > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        final sourceClock = Stopwatch()..start();
        final fetched = await _takeSources(selected.bvid, current.cid);
        final sources = [
          ...fetched.where((s) => s is! BiliStreamAudioSource || !attempted.contains(s.uri)),
          ...fetched.whereType<BiliStreamAudioSource>().where((s) => attempted.contains(s.uri)),
        ];
        debugPrint('[TingX] source lookup: cid=${current.cid}, '
            'attempt=$refresh, elapsed=${sourceClock.elapsedMilliseconds}ms, '
            'candidates=${sources.length}');
        // Avoid minutes of serial attempts across many CDN backups.
        // Try the top two candidates, then refresh signed URLs once.
        for (var candidate = 0;
            candidate < sources.length && candidate < 2;
            candidate++) {
          final source = sources[candidate];
          if (source is BiliStreamAudioSource) attempted.add(source.uri);
          final loadClock = Stopwatch()..start();
          try {
            final timeout = experimentalStream && candidate == 0 && refresh == 0
                ? const Duration(seconds: 15)
                : const Duration(seconds: 5);
            await audio.setAudioSource(
              source,
              initialPosition: Duration(milliseconds: offset),
            ).timeout(timeout);
            debugPrint('[TingX] source opened: cid=${current.cid}, '
                'candidate=$candidate, elapsed=${loadClock.elapsedMilliseconds}ms');
            opened = true;
            break;
          } catch (e) {
            lastError = e;
            if (source is BiliStreamAudioSource) {
              attempts.add('${source.trackId}/${source.bandwidth ~/ 1000}k ${loadClock.elapsedMilliseconds}ms');
            }
            if (candidate == 0 && refresh == 0) {
              firstProbe = _diagnoseSource(source);
            }
            debugPrint(
              '[TingX] audio open failed: chapter=${current.cid}, '
              'refresh=$refresh, candidate=$candidate, '
              'elapsed=${loadClock.elapsedMilliseconds}ms, error=$e',
            );
          }
        }
        if (sources.isEmpty) {
          lastError = StateError('没有可用的音频地址');
        }
      }
      if (!opened) {
        await audio.stop();
        final probe = await firstProbe ?? '';
        throw StateError('本章音源加载失败（${selected.bvid} / ${current.cid}）：'
            '$lastError\n${attempts.join(" → ")}\n$probe');
      }
      mediaItem.add(
        MediaItem(
          id: '${selected.bvid}/${current.cid}',
          title: current.part,
          album: selected.cleanTitle,
          artist: selected.author,
          duration: audio.duration,
          artUri: selected.pic.isEmpty ? null : Uri.tryParse(selected.pic),
        ),
      );
      await shelf.add(selected);
      await shelf.setTotalChapters(selected.bvid, parts.length);
      ready = true;
      await save();
      await _startPlayback();
      _prefetchNext();
      debugPrint('[TingX] startup ready: cid=${current.cid}, '
          'elapsed=${startupClock.elapsedMilliseconds}ms');
    } catch (e) {
      ready = false;
      error = '本章播放失败：$e';
      debugPrint('[TingX] startup failed: '
          'elapsed=${startupClock.elapsedMilliseconds}ms, error=$e');
    } finally {
      busy = false;
      publish();
    }
  }

  Future<void> finishChapter() async {
    if (busy || !ready || completingChapter || book == null || chapter == null) {
      return;
    }
    completingChapter = true;
    try {
      final finishedBook = book!;
      final finishedCid = chapter!.cid;
      await shelf.markChapterDone(finishedBook.bvid, finishedCid);
      if (book?.bvid != finishedBook.bvid || chapter?.cid != finishedCid) {
        return;
      }
      if (index + 1 < chapters.length) {
        await skipToNext();
      } else {
        await save();
        await pause();
      }
    } finally {
      completingChapter = false;
    }
  }

  Future<void> _startPlayback() async {
    if (!ready) return;
    // A failed AVAudioSession activation is not a bad Bilibili stream.
    // Retry the session separately rather than cycling through CDN URLs.
    final session = _audioSession ?? await AudioSession.instance;
    Object? activationError;
    var activated = false;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        activated = await session.setActive(true);
        if (activated) break;
        activationError = StateError('音频会话未能激活');
      } catch (e) {
        activationError = e;
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    if (!activated) {
      throw StateError('iOS 音频会话激活失败：$activationError');
    }
    if (audio.processingState == ProcessingState.completed) {
      await audio.seek(Duration.zero);
    }
    // just_audio's play() future completes when playback stops/pauses.
    // Do not await the full chapter while loading or switching chapters.
    unawaited(audio.play().catchError((Object e) {
      error = '播放中断：$e';
      revision.value++;
    }));
  }

  @override
  Future<void> play() async {
    if (!ready) return;
    try {
      await _startPlayback();
      error = null;
    } catch (e) {
      error = '无法播放：$e';
    }
    revision.value++;
  }

  @override
  Future<void> pause() async {
    await audio.pause();
    await save();
  }

  @override
  Future<void> seek(Duration position) async {
    if (!ready) return;
    final ms = position.inMilliseconds.clamp(
      0,
      audio.duration?.inMilliseconds ?? 0,
    );
    await audio.seek(Duration(milliseconds: ms));
    await save();
  }

  @override
  Future<void> fastForward() =>
      seek(audio.position + const Duration(seconds: 15));
  @override
  Future<void> rewind() => seek(audio.position - const Duration(seconds: 15));
  @override
  Future<void> skipToNext() async {
    if (book != null) await open(book!, chapters, index + 1);
  }

  @override
  Future<void> skipToPrevious() async {
    if (book != null) await open(book!, chapters, index - 1);
  }

  void setSleep(int minutes) {
    sleep?.cancel();
    if (minutes > 0) sleep = Timer(Duration(minutes: minutes), pause);
  }
}
