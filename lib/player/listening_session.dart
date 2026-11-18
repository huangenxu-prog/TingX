import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as mk;

import '../core/network/api_config.dart';
import '../core/storage/shelf_store.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../services/bili_api.dart';
import 'bili_stream_audio_source.dart';

class ListeningSession extends BaseAudioHandler {
  // Experimental builds retain the same-source engine comparison.
  static const experimentalStream =
      bool.fromEnvironment('TINGX_EXPERIMENTAL_STREAM');
  ListeningSession({this.chapterSources = onlineSources});
  final Future<List<BiliStreamAudioSource>> Function(String bvid, int cid) chapterSources;

  static Future<List<BiliStreamAudioSource>> onlineSources(String bvid, int cid) async {
    final result = await BiliApi.instance.playUrl(bvid, cid);

    // Preserve the existing source preference. Try ordinary DASH
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
    return urls.values.toList();
  }

  ({String bvid, int cid, DateTime at, Future<List<BiliStreamAudioSource>> sources})? _next;

  void _prefetchNext() {
    final next = chapters.elementAtOrNull(index + 1);
    final currentBook = book;
    if (next == null || currentBook == null) return;
    final pending = chapterSources(currentBook.bvid, next.cid)
        .timeout(const Duration(seconds: 12))
        .catchError((Object _) => <BiliStreamAudioSource>[]);
    _next = (bvid: currentBook.bvid, cid: next.cid,
             at: DateTime.now(), sources: pending);
  }

  Future<List<BiliStreamAudioSource>> _takeSources(String bvid, int cid) async {
    final cached = _next;
    _next = null;
    if (cached != null && cached.bvid == bvid && cached.cid == cid &&
        DateTime.now().difference(cached.at) < const Duration(hours: 2)) {
      final items = await cached.sources;
      final now = DateTime.now();
      final valid = items.where((s) {
        final uri = s.uri;
        final expiry = int.tryParse(uri.queryParameters['deadline'] ?? '');
        return expiry == null ? now.difference(cached.at) < const Duration(minutes: 10)
            : expiry > now.millisecondsSinceEpoch ~/ 1000 + 60;
      }).toList();
      if (valid.isNotEmpty) return valid;
    }
    return chapterSources(bvid, cid).timeout(const Duration(seconds: 12));
  }

  final audio = mk.Player();

  Future<void> _load(BiliStreamAudioSource source, int offset, Duration timeout) async {
    final loaded = Completer<void>();
    final duration = audio.stream.duration.listen((value) {
      if (value > Duration.zero && !loaded.isCompleted) loaded.complete();
    });
    final errors = audio.stream.error.listen((message) {
      if (!loaded.isCompleted) loaded.completeError(StateError(message));
    });
    try {
      await Future.wait<void>([
        loaded.future,
        audio.open(mk.Media(source.uri.toString(),
          httpHeaders: {'Referer': source.referer, 'User-Agent': source.userAgent},
          start: Duration(milliseconds: offset)), play: false),
      ], eagerError: true).timeout(timeout);
    } finally {
      await duration.cancel();
      await errors.cancel();
    }
  }

  Future<String> _diagnoseSource(BiliStreamAudioSource source) async {
    final uri = source.uri;
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
  BiliStreamAudioSource? _activeStream;
  String? error;
  final startupDetails = <String>[];
  Timer? sleep;
  Chapter? get chapter => chapters.elementAtOrNull(index);

  Future<void> initialize() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    _audioSession = session;
    audio.stream.playing.listen((_) => publish());
    audio.stream.buffering.listen((_) => publish());
    audio.stream.rate.listen((_) => publish());
    audio.stream.error.listen((message) {
      if (ready && !busy) {
        error = '播放中断：$message';
        publish();
      }
    });
    audio.stream.completed.listen((completed) {
      if (completed && ready && !busy) unawaited(finishChapter());
    });
    session.becomingNoisyEventStream.listen((_) {
      if (audio.state.playing) unawaited(pause());
    });
    session.interruptionEventStream.listen((event) {
      if (event.begin && audio.state.playing) unawaited(pause());
    });
    Timer.periodic(const Duration(seconds: 4), (_) {
      if (audio.state.playing) unawaited(save());
    });
  }

  void publish() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          audio.state.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.fastForward,
          MediaAction.rewind,
        },
        playing: audio.state.playing,
        processingState:
            busy ? AudioProcessingState.loading : !ready ? AudioProcessingState.idle : audio.state.completed ? AudioProcessingState.completed : audio.state.buffering ? AudioProcessingState.buffering : AudioProcessingState.ready,
        updatePosition: audio.state.position,
        bufferedPosition: audio.state.buffer,
        speed: audio.state.rate,
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
      positionMs: audio.state.position.inMilliseconds,
      chapterDurationMs:
          audio.state.duration.inMilliseconds,
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
    startupDetails.clear();
    busy = true;
    error = null;
    revision.value++;
    try {
      await save();
      ready = false;
      await audio.stop();
      _activeStream?.close();
      _activeStream = null;
      book = selected;
      chapters = parts;
      index = at;
      final current = parts[at];
      startupDetails.add('${current.part}\n保存进度和停止上一章 ${startupClock.elapsedMilliseconds} ms');
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
        startupDetails.add('取播放地址 ${sourceClock.elapsedMilliseconds} ms');
        final sources = [
          ...fetched.where((s) => !attempted.contains(s.uri)),
          ...fetched.where((s) => attempted.contains(s.uri)),
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
          attempted.add(source.uri);
          final loadClock = Stopwatch()..start();
          try {
            final timeout = experimentalStream && candidate == 0 && refresh == 0
                ? const Duration(seconds: 15)
                : const Duration(seconds: 5);
            await _load(source, offset, timeout);
            debugPrint('[TingX] source opened: cid=${current.cid}, '
                'candidate=$candidate, elapsed=${loadClock.elapsedMilliseconds}ms');
            startupDetails.add('打开音轨 ${source.trackId} 成功 ${loadClock.elapsedMilliseconds} ms');
            _activeStream = source;
            opened = true;
            break;
          } catch (e) {
            startupDetails.add('打开音轨 ${source.trackId} 失败 ${loadClock.elapsedMilliseconds} ms');
            await audio.stop();
            source.close();
            lastError = e;
            attempts.add('${source.trackId}/${source.bandwidth ~/ 1000}k ${loadClock.elapsedMilliseconds}ms');
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
          duration: audio.state.duration,
          artUri: selected.pic.isEmpty ? null : Uri.tryParse(selected.pic),
        ),
      );
      await shelf.add(selected);
      await shelf.setTotalChapters(selected.bvid, parts.length);
      ready = true;
      await save();
      await _startPlayback();
      startupDetails.add('从打开章节到发起播放 ${startupClock.elapsedMilliseconds} ms');
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
    if (audio.state.completed) {
      await audio.seek(Duration.zero);
    }
    await audio.play();
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
      audio.state.duration.inMilliseconds,
    );
    await audio.seek(Duration(milliseconds: ms));
    await save();
  }

  @override
  Future<void> fastForward() =>
      seek(audio.state.position + const Duration(seconds: 15));
  @override
  Future<void> rewind() => seek(audio.state.position - const Duration(seconds: 15));
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
