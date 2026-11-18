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
    final urls = <String>{
      for (final t in [...result.tracks, ?result.dolby, ?result.flac])
        for (final u in [t.baseUrl, ...t.backupUrls])
          if (u.startsWith('https://') || u.startsWith('http://'))
            u.replaceFirst('http://', 'https://'),
    };
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

  final audio = AudioPlayer(useProxyForRequestHeaders: false);
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
      final sources = await chapterSources(selected.bvid, current.cid);
      Object? lastError;
      for (final source in sources) {
        try {
          await audio.setAudioSource(
            source,
            initialPosition: Duration(milliseconds: offset),
          );
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
        }
      }
      if (sources.isEmpty || lastError != null)
        throw StateError('音轨无法打开：${lastError ?? "没有播放地址"}');
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
      unawaited(play());
    } catch (e) {
      error = '本章播放失败：$e';
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

  @override
  Future<void> play() async {
    if (!ready) return;
    try {
      if (audio.processingState == ProcessingState.completed)
        await audio.seek(Duration.zero);
      await audio.play();
    } catch (e) {
      error = '无法播放：$e';
      revision.value++;
    }
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
