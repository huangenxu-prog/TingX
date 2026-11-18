import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../core/network/api_config.dart';
import '../core/storage/shelf_store.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../services/bili_api.dart';

class ListeningSession extends BaseAudioHandler {
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

    final urls = <String>{};
    void addUrls(String primary, List<String> backups) {
      for (final raw in [primary, ...backups]) {
        if (raw.startsWith('https://')) {
          urls.add(raw);
        } else if (raw.startsWith('http://')) {
          urls.add(raw.replaceFirst('http://', 'https://'));
        }
      }
    }

    for (final track in tracks) {
      addUrls(track.baseUrl, track.backupUrls);
    }
    if (result.dolby != null) {
      addUrls(result.dolby!.baseUrl, result.dolby!.backupUrls);
    }
    if (result.flac != null) {
      addUrls(result.flac!.baseUrl, result.flac!.backupUrls);
    }

    return [
      for (final url in urls)
        AudioSource.uri(
          Uri.parse(url),
          headers: const {
            'Referer': BiliEndpoints.home,
            'User-Agent': BiliEndpoints.userAgent,
          },
        ),
    ];
  }

  // just_audio sends custom Referer/User-Agent headers through its local
  // proxy on iOS. Disabling the proxy can cause CDN requests to omit them.
  final audio = AudioPlayer(useProxyForRequestHeaders: true);
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
      Object? lastError;
      var opened = false;
      for (var refresh = 0; refresh < 2 && !opened; refresh++) {
        if (refresh > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        final sourceClock = Stopwatch()..start();
        final sources = await chapterSources(selected.bvid, current.cid);
        debugPrint('[TingX] source lookup: cid=${current.cid}, '
            'attempt=$refresh, elapsed=${sourceClock.elapsedMilliseconds}ms, '
            'candidates=${sources.length}');
        for (var candidate = 0; candidate < sources.length; candidate++) {
          final source = sources[candidate];
          final loadClock = Stopwatch()..start();
          try {
            await audio.setAudioSource(
              source,
              initialPosition: Duration(milliseconds: offset),
            ).timeout(const Duration(seconds: 8));
            debugPrint('[TingX] source opened: cid=${current.cid}, '
                'candidate=$candidate, elapsed=${loadClock.elapsedMilliseconds}ms');
            opened = true;
            break;
          } catch (e) {
            lastError = e;
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
        throw StateError('全部音轨与备用地址均无法打开：$lastError');
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
