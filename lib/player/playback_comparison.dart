import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:media_kit/media_kit.dart' as mk;

import 'listening_session.dart';

bool _mediaKitFirst = false;

Future<void> comparePlayback(BuildContext context, ListeningSession session) async {
  final book = session.book;
  final chapter = session.chapter;
  if (book == null || chapter == null || session.busy) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先选择章节，等本次加载结束')));
    return;
  }
  session.busy = true;
  final report = ValueNotifier<String>(chapter.part);
  void line(String text) => report.value += '\n$text';
  final finished = ValueNotifier<bool>(false);
  Future<void> run() async {
    try {
      await session.pause();
      final sources = await ListeningSession.onlineSources(book.bvid, chapter.cid)
          .timeout(const Duration(seconds: 15));
      final source = sources.first;
      line('音轨 ${source.trackId} · ${source.uri.host}');
      final order = [_mediaKitFirst, !_mediaKitFirst];
      _mediaKitFirst = !_mediaKitFirst;
      for (final useKit in order) {
        final name = useKit ? 'media_kit' : 'just_audio';
        line('正在测试 $name…');
        mk.Player? kit;
        AudioPlayer? current;
        try {
          if (useKit) {
            mk.MediaKit.ensureInitialized();
            kit = mk.Player();
          } else {
            current = AudioPlayer();
          }
          final clock = Stopwatch()..start();
          final target = kit;
          if (target != null) {
            await target.open(mk.Media(source.uri.toString(), httpHeaders: {
              'Referer': source.referer, 'User-Agent': source.userAgent,
            })).timeout(const Duration(seconds: 20));
          } else {
            await current!.setAudioSource(source).timeout(const Duration(seconds: 20));
            unawaited(current.play().catchError((Object _) {}));
          }
          int? first;
          while (clock.elapsed < const Duration(seconds: 25)) {
            final pos = target?.state.position ?? current!.position;
            if (pos.inMilliseconds >= 250) first ??= clock.elapsedMilliseconds;
            if (pos.inSeconds >= 3) break;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          final pos = target?.state.position ?? current!.position;
          line('$name：${first == null ? "未观察到进度" : "首次进度 $first ms"}，播放进度 ${pos.inMilliseconds} ms');
        } catch (e) {
          line('$name：${e.runtimeType}');
        } finally {
          await kit?.dispose();
          await current?.dispose();
        }
      }
      source.close();
    } catch (e) {
      line('测试中断：${e.runtimeType}');
    } finally {
      session.busy = false;
      session.revision.value++;
      finished.value = true;
    }
  }

  final task = run();
  await showDialog<void>(context: context, barrierDismissible: false, builder: (ctx) =>
      ValueListenableBuilder<bool>(valueListenable: finished, builder: (_, done, child) =>
        PopScope(canPop: done, child: AlertDialog(
          title: const Text('同源播放对照'),
          content: ValueListenableBuilder<String>(valueListenable: report,
            builder: (_, value, child) => SelectableText(value)),
          actions: [TextButton(onPressed: done ? () => Navigator.pop(ctx) : null,
            child: const Text('完成'))],
        ))));
  await task;
  report.dispose();
  finished.dispose();
}
