import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'core/network/bili_client.dart';
import 'core/storage/shelf_store.dart';
import 'models/book.dart';
import 'pages/discover_home.dart';
import 'pages/settings.dart';
import 'models/chapter.dart';
import 'player/listening_session.dart';
import 'services/bili_api.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([
    BiliClient.instance.initLocal(),
    ShelfStore.instance.load(),
  ]);
  final player = await AudioService.init(
    builder: ListeningSession.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'tingx.playback',
      androidNotificationChannelName: 'TingX',
    ),
  );
  await player.initialize();
  runApp(
    MaterialApp(
      title: 'TingX',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff84664e),
          surface: const Color(0xfffaf6ee),
        ),
        scaffoldBackgroundColor: const Color(0xfffaf6ee),
      ),
      home: Home(player),
    ),
  );
}

class Home extends StatefulWidget {
  const Home(this.player, {super.key});
  final ListeningSession player;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  int tab = 0;
  final shelf = ShelfStore.instance;
  late final Widget discoverPage = DiscoverHome(openBook: details);
  final search = TextEditingController();
  List<Book> results = [];
  String? message;
  bool searching = false;
  int request = 0;
  ListeningSession get player => widget.player;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(player.save());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    search.dispose();
    super.dispose();
  }

  Future<void> find(String input) async {
    final id = ++request;
    final query = input.trim();
    setState(() {
      searching = query.isNotEmpty;
      results = [];
      message = null;
    });
    if (query.isEmpty) return;
    try {
      final books = await BiliApi.instance.search(query);
      if (mounted && id == request)
        setState(() {
          results = books;
          message = books.isEmpty ? '没有找到相关有声书' : null;
        });
    } catch (e) {
      if (mounted && id == request) setState(() => message = '搜索失败：$e');
    } finally {
      if (mounted && id == request) setState(() => searching = false);
    }
  }

  Future<void> details(Book b) async {
    final selected = await Navigator.push<(Book, List<Chapter>, int, int)>(
      context,
      MaterialPageRoute(builder: (_) => Detail(b)),
    );
    if (selected == null || !mounted) return;
    setState(() => tab = 0);
    await player.open(
      selected.$1,
      selected.$2,
      selected.$3,
      offset: selected.$4,
    );
  }

  Widget playback() {
    final b = player.book;
    if (b == null && !player.busy) {
      final recent = shelf.books.firstOrNull;
      return Center(
        child: FilledButton.tonalIcon(
          icon: const Icon(Icons.headphones),
          onPressed: () =>
              recent == null ? setState(() => tab = 1) : details(recent.book),
          label: Text(
            recent == null ? '去发现有声书' : '继续收听 · ${recent.book.cleanTitle}',
            maxLines: 2,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(child: SizedBox(width: 220, height: 230, child: cover(b))),
        const SizedBox(height: 24),
        Text(
          b?.cleanTitle ?? '',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Text(player.chapter?.part ?? '', textAlign: TextAlign.center),
        if (player.busy) const LinearProgressIndicator(),
        if (player.error != null) Text(player.error!),
        if (player.error != null && b != null)
          TextButton(onPressed: () => details(b), child: const Text('重新选择章节')),
        StreamBuilder<Duration>(
          stream: player.audio.positionStream,
          builder: (_, snapshot) {
            final duration = player.audio.duration?.inSeconds ?? 0;
            final total = duration > 0 ? duration : (player.chapter?.duration ?? 0);
            final pos = (snapshot.data ?? Duration.zero).inSeconds.clamp(
              0,
              total,
            );
            return Column(
              children: [
                Slider(
                  value: pos.toDouble(),
                  max: total > 0 ? total.toDouble() : 1,
                  onChanged: player.ready && duration > 0
                      ? (v) => player.seek(Duration(seconds: v.round()))
                      : null,
                ),
                Text('${clock(pos)}  /  ${clock(total)}'),
              ],
            );
          },
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              tooltip: '上一章',
              onPressed: player.index > 0 ? player.skipToPrevious : null,
              icon: const Icon(Icons.skip_previous),
            ),
            TextButton(onPressed: player.rewind, child: const Text('−15s')),
            IconButton.filled(
              tooltip: player.audio.playing ? '暂停' : '播放',
              onPressed: player.ready
                  ? (player.audio.playing ? player.pause : player.play)
                  : null,
              icon: Icon(player.audio.playing ? Icons.pause : Icons.play_arrow),
            ),
            TextButton(
              onPressed: player.fastForward,
              child: const Text('+15s'),
            ),
            IconButton(
              tooltip: '下一章',
              onPressed: player.index + 1 < player.chapters.length
                  ? player.skipToNext
                  : null,
              icon: const Icon(Icons.skip_next),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton(
              onPressed: b == null ? null : () => details(b),
              child: const Text('章节'),
            ),
            PopupMenuButton<double>(
              onSelected: (v) async {
                await player.audio.setSpeed(v);
                player.publish();
              },
              itemBuilder: (_) => [
                for (final n in [0.75, 1.0, 1.25, 1.5, 2.0])
                  PopupMenuItem(value: n, child: Text('${n}×')),
              ],
              child: Text('${player.audio.speed}×'),
            ),
            PopupMenuButton<int>(
              onSelected: player.setSleep,
              itemBuilder: (_) => [
                for (final m in [0, 15, 30, 60])
                  PopupMenuItem(
                    value: m,
                    child: Text(m == 0 ? '关闭定时' : '$m 分钟'),
                  ),
              ],
              child: const Text('睡眠定时'),
            ),
          ],
        ),
      ],
    );
  }



  Widget bookshelf() {
    final entries = shelf.books;
    if (entries.isEmpty) return const Center(child: Text('书架还是空的'));
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: entries.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.62,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemBuilder: (_, i) {
        final entry = entries[i];
        return InkWell(
          onTap: () => details(entry.book),
          onLongPress: () async {
            final remove = await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('移出书架'),
                content: Text('确定将《${entry.book.cleanTitle}》移出书架吗？本地收听记录也会被删除。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('移出'),
                  ),
                ],
              ),
            );
            if (remove == true) {
              await shelf.remove(entry.book.bvid);
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: SizedBox.expand(child: cover(entry.book))),
              Text(
                entry.book.cleanTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Text('已听 ${(entry.percent * 100).round()}%'),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['播放器', '发现', '书架'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[tab]),
        actions: [
          if (tab == 0)
            PopupMenuButton<String>(
              tooltip: '更多',
              icon: const Icon(Icons.more_horiz),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'settings', child: Text('设置')),
                PopupMenuItem(value: 'timing', child: Text('起播耗时')),
              ],
              onSelected: (value) {
                if (value == 'settings') {
                  Navigator.push<void>(context, MaterialPageRoute(builder: (_) => const TingXSettings()));
                  return;
                }
                showDialog<void>(context: context, builder: (_) => AlertDialog(
                  title: const Text('本次起播耗时'),
                  content: SelectableText(player.startupDetails.isEmpty ? '暂无记录' : player.startupDetails.join('\n')),
                ));
              },
            ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([player.revision, shelf]),
          builder: (_, _) => IndexedStack(
            index: tab,
            children: [playback(), discoverPage, bookshelf()],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.headphones), label: '播放器'),
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            label: '发现',
          ),
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            label: '书架',
          ),
        ],
      ),
    );
  }
}

String clock(int seconds) =>
    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
Widget cover(Book? b) {
  const fallback = ColoredBox(
    color: Color(0xffe8dece),
    child: Center(child: Icon(Icons.menu_book)),
  );
  if (b == null || b.pic.isEmpty) return fallback;
  return ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: Image.network(
      b.pic,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback,
    ),
  );
}

class Detail extends StatefulWidget {
  final Book book;
  const Detail(this.book, {super.key});
  @override
  State<Detail> createState() => _DetailState();
}

class _DetailState extends State<Detail> {
  late Future<(Book, List<Chapter>)> info = load();
  Future<(Book, List<Chapter>)> load() async {
    final selected = widget.book;
    // The lightweight page list also works for titles without full view metadata.
    final parts = await BiliApi.instance.pageList(selected.bvid);
    if (parts.isNotEmpty) return (selected, parts);
    final b = await BiliApi.instance.detail(selected.bvid);
    return (b, b.chapters ?? <Chapter>[]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.book.cleanTitle)),
    body: FutureBuilder(
      future: info,
      builder: (_, snapshot) {
        if (snapshot.hasError)
          return Center(
            child: TextButton(
              onPressed: () => setState(() => info = load()),
              child: Text('目录加载失败，点击重试\n${snapshot.error}'),
            ),
          );
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final (b, parts) = snapshot.requireData;
        if (parts.isEmpty) return const Center(child: Text('暂无可播放章节'));
        final saved = ShelfStore.instance.byBvid(b.bvid);
        final last = parts.indexWhere((c) => c.cid == saved?.lastCid);
        final done = saved?.doneCids.toSet() ?? <int>{};
        void choose(int i) => Navigator.pop(context, (
          b,
          parts,
          i,
          i == last ? saved!.positionMs : 0,
        ));
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 84, height: 112, child: cover(b)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(b.cleanTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Text(b.author, maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 8),
                        Text('共 ${parts.length} 章',
                          style: Theme.of(context).textTheme.bodySmall),
                        TextButton.icon(
                          onPressed: () async {
                            if (ShelfStore.instance.isOnShelf(b.bvid)) {
                              await ShelfStore.instance.remove(b.bvid);
                            } else {
                              await ShelfStore.instance.add(b);
                              await ShelfStore.instance.setTotalChapters(
                                b.bvid, parts.length);
                            }
                            if (mounted) setState(() {});
                          },
                          icon: Icon(ShelfStore.instance.isOnShelf(b.bvid)
                            ? Icons.bookmark_remove_outlined
                            : Icons.bookmark_add_outlined),
                          label: Text(ShelfStore.instance.isOnShelf(b.bvid)
                            ? '移出书架' : '加入书架'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (b.desc.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(b.desc, maxLines: 3,
                  overflow: TextOverflow.ellipsis),
              ),
            FilledButton.tonal(
              onPressed: () => choose(last < 0 ? 0 : last),
              child: Text(
                last >= 0 ? '继续收听 · ${saved!.positionText}' : '从第一章播放',
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: parts.length,
                itemBuilder: (_, i) => ListTile(
                  title: Text(parts[i].part),
                  leading: Text('${i + 1}'),
                  trailing: done.contains(parts[i].cid)
                      ? const Icon(Icons.check_circle_outline, color: Color(0xff84664e))
                      : Text(parts[i].durationText),
                  onTap: () => choose(i),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
