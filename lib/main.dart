import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;

import 'core/network/bili_client.dart';
import 'core/storage/shelf_store.dart';
import 'models/book.dart';
import 'pages/discover_home.dart';
import 'pages/settings.dart';
import 'pages/book_jacket.dart';
import 'package:flutter/services.dart';
import 'models/chapter.dart';
import 'player/listening_session.dart';
import 'services/bili_api.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
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
          seedColor: brown,
          surface: const Color(0xfffaf6ee),
        ),
        scaffoldBackgroundColor: ivory,
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
  late final Widget discoverPage = DiscoverHome(openBook: details, listen: resume);
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

  Future<void> resume(Book book) async {
    if(player.busy)return;
    try {
      final (b,parts)=await chaptersOf(book);
      if(!mounted || parts.isEmpty)return;
      final entry=shelf.byBvid(b.bvid);
      final at=parts.indexWhere((c)=>c.cid==entry?.lastCid);
      setState(()=>tab=0);
      await player.open(b,parts,at<0?0:at,offset:at<0?0:entry!.positionMs);
    } catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('打开章节失败：$e')));
    }
  }

  int filter = 0;
  Widget playback() {
    final recent = shelf.books.where((e)=>e.lastCid>0).firstOrNull;
    final b = player.book ?? recent?.book;
    if(b==null)return Center(child:TextButton(onPressed:()=>setState(()=>tab=1),child:const Text('去发现有声书')));
    final idle=player.book==null;
    return LayoutBuilder(builder:(context,size)=>Column(mainAxisAlignment:MainAxisAlignment.spaceEvenly,children:[
      Padding(padding:const EdgeInsets.fromLTRB(14,16,14,16),child:AspectRatio(aspectRatio:16/9,child:cover(b))),
      SizedBox(height:(size.maxHeight*.43).clamp(182.0,318.0),child:FittedBox(fit:BoxFit.scaleDown,child:SizedBox(width:size.maxWidth,child:Column(children:[
        const SizedBox(height:8),
        Text(shortTitle(b),maxLines:1,overflow:TextOverflow.ellipsis,style:display.copyWith(fontSize:22)),
        Text(b.author,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:brown)),
        Text(player.chapter?.part ?? '第 ${(recent?.lastChapterIndex ?? 0)+1} 章',maxLines:1,overflow:TextOverflow.ellipsis),
        if(player.busy)const LinearProgressIndicator(),
        if(player.error!=null)TextButton(onPressed:()=>details(b),child:const Text('本章播放失败 · 重新选择章节')),
        StreamBuilder<Duration>(
          stream: player.audio.stream.position,
          builder: (_, snapshot) {
            final duration = player.audio.state.duration.inSeconds;
            final total = idle ? (recent?.chapterDurationMs ?? 0) ~/ 1000 : duration > 0 ? duration : (player.chapter?.duration ?? 0);
            final pos = idle ? (recent?.positionMs ?? 0) ~/ 1000 : (snapshot.data ?? Duration.zero).inSeconds.clamp(
              0,
              total,
            );
            return Column(
              children: [
                Slider(
                  value: pos.clamp(0,total).toDouble(),
                  max: total > 0 ? total.toDouble() : 1,
                  onChanged: player.ready && duration > 0
                      ? (v) => player.seek(Duration(seconds: v.round()))
                      : null,
                ),
                Padding(padding:const EdgeInsets.symmetric(horizontal:22),child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text(clock(pos)),Text(clock(total))])),
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
            IconButton(tooltip:'后退15秒',onPressed: player.rewind,icon:const _SkipIcon(Icons.replay),),
            IconButton.filled(
              tooltip: player.audio.state.playing ? '暂停' : '播放',
              style:IconButton.styleFrom(backgroundColor:brown,fixedSize:const Size(64,64)),
              onPressed: idle ? ()=>resume(b) : player.ready
                  ? (player.audio.state.playing ? player.pause : player.play)
                  : null,
              icon: Icon(player.audio.state.playing ? Icons.pause : Icons.play_arrow),
            ),
            IconButton(tooltip:'前进15秒',
              onPressed: player.fastForward,
              icon: const _SkipIcon(Icons.refresh),
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
              child: const Column(children:[Icon(Icons.list_alt),Text('目录')]),
            ),
            PopupMenuButton<double>(
              onSelected: (v) async {
                await player.audio.setRate(v);
                player.publish();
              },
              itemBuilder: (_) => [
                for (final n in [0.75, 1.0, 1.25, 1.5, 2.0])
                  PopupMenuItem(value: n, child: Text('${n}×')),
              ],
              child: Column(children:[const Icon(Icons.speed),Text('${player.audio.state.rate}×')]),
            ),
            PopupMenuButton<int>(
              onSelected: player.setSleep,
              itemBuilder: (_) => [
                for (final m in [0, 15, 30, 60, 90, 120])
                  PopupMenuItem(
                    value: m,
                    child: Text(m == 0 ? '关闭定时' : '$m 分钟'),
                  ),
              ],
              child: Column(children: [
                const Icon(Icons.schedule),
                ValueListenableBuilder<DateTime?>(
                  valueListenable: player.sleepDeadline,
                  builder: (_, deadline, __) => deadline == null
                      ? const Text('睡眠定时')
                      : _SleepCountdown(deadline),
                ),
              ]),
            ),
          ],
        ),
      ]))))]));
  }

  Widget bookshelf() {
    final all=shelf.books;
    final entries=all.where((e)=>filter==0 || (filter==1 ? e.hasProgress && e.percent<1 : e.percent>=1)).toList();
    return ListView(padding:const EdgeInsets.fromLTRB(18,0,18,20),children:[
      Wrap(spacing:8,children:[for(int i=0;i<3;i++) ChoiceChip(shape:const StadiumBorder(),side:BorderSide.none,selectedColor:brown,backgroundColor:const Color(0xfff1e6d8),showCheckmark:false,label:Text(['全部','在听','已听完'][i],style:TextStyle(color:filter==i?Colors.white:brown)),selected:filter==i,onSelected:(_)=>setState(()=>filter=i))]),
      const SizedBox(height:16),Row(children:[Expanded(child:Text('我的书架',style:display.copyWith(fontSize:21))),Text('${entries.length} 本')]),const SizedBox(height:12),
      if (entries.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(vertical: 36),
          child: Center(child: Text(['书架还是空的','还没有正在听的书','还没有听完的书'][filter])))
      else GridView.builder(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),itemCount:entries.length,
       gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:2,childAspectRatio:1.28,crossAxisSpacing:12,mainAxisSpacing:14),
       itemBuilder:(_,i){
        final entry = entries[i];
        return InkWell(
          onTap: () => details(entry.book),
          onLongPress: () async {
            final remove = await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('移出书架'),
                content: Text('确定将《${entry.book.displayTitle}》移出书架吗？本地收听记录也会被删除。'),
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
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:SizedBox.expand(child:BookJacket(entry.book))),Text(shortTitle(entry.book),maxLines:1,overflow:TextOverflow.ellipsis,style:display),Text(entry.hasProgress?'第${entry.lastChapterIndex+1}章 · ${entry.positionText}':entry.book.author,maxLines:1,overflow:TextOverflow.ellipsis)]));
      })]);
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['播放器', '发现', '书架'];
    return Scaffold(
      extendBodyBehindAppBar:false,
      appBar: AppBar(backgroundColor:ivory,foregroundColor:const Color(0xff422c20),
        systemOverlayStyle:SystemUiOverlayStyle.dark,
        leading:tab==0?BackButton(onPressed:()=>setState(()=>tab=2)):null,
        centerTitle: false,
        title: tab==0?null:Text(titles[tab],style:display.copyWith(fontSize:29)),
        actions: [
          if (tab == 0)
            PopupMenuButton<String>(
              tooltip: '更多',
              icon: const Icon(Icons.more_horiz,color:Color(0xff422c20)),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'settings', child: Text('设置')),
              ],
              onSelected: (_) => Navigator.push<void>(context,
                MaterialPageRoute(builder: (_) => const TingXSettings())),
            ),
        ],
      ),
      body: SafeArea(top:true,
        child: ListenableBuilder(
          listenable: Listenable.merge([player.revision, shelf]),
          builder: (_, _) => IndexedStack(
            index: tab,
            children: [playback(), discoverPage, bookshelf()],
          ),
        ),
      ),
      bottomNavigationBar: TingXTabBar(index: tab, select: (v) => setState(() => tab = v)),
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
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => fallback,
    ),
  );
}

class _SkipIcon extends StatelessWidget {
  const _SkipIcon(this.icon);
  final IconData icon;
  @override
  Widget build(BuildContext context) => Stack(alignment:Alignment.center,children:[
    Icon(icon,size:30),const Padding(padding:EdgeInsets.only(top:4),child:Text('15',style:TextStyle(fontSize:8,fontWeight:FontWeight.bold)))]);
}

Future<(Book, List<Chapter>)> chaptersOf(Book selected) async {

    // The lightweight page list also works for titles without full view metadata.
    final parts = await BiliApi.instance.pageList(selected.bvid);
    if (parts.isNotEmpty) return (selected, parts);
    final b = await BiliApi.instance.detail(selected.bvid);
    return (b, b.chapters ?? <Chapter>[]);
  }

Future<void> confirmRemoval(BuildContext context,Book b) async {
  final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:const Text('移出书架'),content:Text('移出《${shortTitle(b)}》也会删除本地收听记录。'),actions:[
    TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('取消')),TextButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('移出'))]));
  if(ok==true)await ShelfStore.instance.remove(b.bvid);
}

String partLabel(String value){
  final match=RegExp(r'^第\s*\d+\s*章\s+(\d+)\s*[-–－]\s*(\d+)$').firstMatch(value.trim());
  return match==null?value:'第${int.parse(match[1]!)}–${int.parse(match[2]!)}集';
}

class _SleepCountdown extends StatefulWidget {
  const _SleepCountdown(this.deadline);
  final DateTime deadline;
  @override
  State<_SleepCountdown> createState() => _SleepCountdownState();
}

class _SleepCountdownState extends State<_SleepCountdown> {
  late final Timer ticker;
  @override
  void initState() {
    super.initState();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }
  @override
  void dispose() {
    ticker.cancel();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final ms = widget.deadline.difference(DateTime.now()).inMilliseconds;
    return Text(clock(ms > 0 ? (ms + 999) ~/ 1000 : 0));
  }
}

class _PaperGrain extends CustomPainter {
  const _PaperGrain();
  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(42);
    final grain = Paint()..color = const Color(0x10856946);
    for (var n = 0; n < size.width * size.height / 20; n++) {
      canvas.drawCircle(Offset(random.nextDouble() * size.width,
          random.nextDouble() * size.height), .45, grain);
    }
  }
  @override
  bool shouldRepaint(_PaperGrain oldDelegate) => false;
}

class Detail extends StatefulWidget {
  final Book book;
  const Detail(this.book, {super.key});
  @override
  State<Detail> createState() => _DetailState();
}

class _DetailState extends State<Detail> {
  late Future<(Book,List<Chapter>)> info=chaptersOf(widget.book);
  bool expanded=false;
  String synopsis='';
  @override
  void initState(){
    super.initState();
    if(widget.book.desc.trim().isEmpty) loadSynopsis();
  }
  Future<void> loadSynopsis() async {
    try {
      final detail=await BiliApi.instance.detail(widget.book.bvid);
      if(mounted)setState(()=>synopsis=detail.desc.trim());
    } catch (_) {}
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(backgroundColor: ivory, surfaceTintColor: Colors.transparent,
      flexibleSpace: const CustomPaint(painter: _PaperGrain()), actions:[ListenableBuilder(listenable:ShelfStore.instance,builder:(_,__){
      final b=widget.book;
      final on=ShelfStore.instance.isOnShelf(b.bvid);
      return IconButton(tooltip:on?'移出书架':'加入书架',icon:Icon(on?Icons.bookmark:Icons.bookmark_border,color:brown),onPressed:() async {
        if(on){await confirmRemoval(context,b);}else{await ShelfStore.instance.add(b);final data=await info;await ShelfStore.instance.setTotalChapters(b.bvid,data.$2.length);}
      });
    })]),
    body: Stack(children: [
      const Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _PaperGrain()))),
      Positioned.fill(child: FutureBuilder(
      future: info,
      builder: (_, snapshot) {
        if (snapshot.hasError)
          return Center(
            child: TextButton(
              onPressed: () => setState(() => info = chaptersOf(widget.book)),
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
        const ink = Color(0xff422c20);
        const rule = Color(0xffddcdbb);
        const type = TextStyle(fontFamily: 'Songti SC', color: ink);
        final total = RegExp(r'(?:全|共)?\s*(\d+)\s*集').firstMatch(b.cleanTitle);
        final complete = b.cleanTitle.contains('完结') && !b.cleanTitle.contains('未完结');
        final description = b.desc.trim().isEmpty ? synopsis : b.desc.trim();
        Widget marker() => Container(width: 3, height: 20,
          decoration: BoxDecoration(color: brown, borderRadius: BorderRadius.circular(2)));
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 32),
          itemCount: parts.length + 1,
          itemBuilder: (_, row) {
            if (row == 0) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 160, height: 90, margin: const EdgeInsets.only(left: 6),
                  decoration: const BoxDecoration(boxShadow: [
                    BoxShadow(color: Color(0x55442b18), blurRadius: 8, offset: Offset(-2,5))
                  ]),
                  child: Stack(fit: StackFit.expand, children: [
                    BookJacket(b),
                    Positioned(left: 4, top: 5, bottom: 5, child: Container(width: 5,
                      decoration: const BoxDecoration(gradient: LinearGradient(
                        colors: [Colors.black38, Colors.white24, Colors.transparent])))),
                  ])),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(shortTitle(b), style: type.copyWith(fontSize: 30,fontWeight: FontWeight.bold)),
                    if (complete) Container(padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
                      decoration: BoxDecoration(color: const Color(0xff9d382e), borderRadius: BorderRadius.circular(4)),
                      child: const Text('完\n结',style: TextStyle(color: Colors.white,fontSize: 11,height: 1))),
                  ]),
                  const SizedBox(height: 9),
                  if (b.author.isNotEmpty) Text('上传者：${b.author}',style: type),
                  if (total != null) Text('全 ${total[1]}集',style: type),
                ])),
              ]),
              if (description.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 15),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end,children: [
                  Expanded(child: Text(description,maxLines: expanded ? null : 2,
                    overflow: expanded ? null : TextOverflow.ellipsis,style: type.copyWith(height: 1.5))),
                  TextButton(onPressed: () => setState(() => expanded = !expanded),
                    child: Text(expanded ? '收起 ⌃' : '展开 ﹀',style: type.copyWith(color: brown))),
                ])),
              const SizedBox(height: 18),
              Row(children: [
                FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: brown,
                  minimumSize: const Size(158,42)),onPressed: () => choose(last < 0 ? 0 : last),
                  icon: const Icon(Icons.play_arrow),label: Text(last < 0 ? '开始收听' : '继续收听')),
                if (last >= 0) ...[
                  Container(width: 1,height: 18,margin: const EdgeInsets.symmetric(horizontal: 10),color: rule),
                  Expanded(child: Text('上次听到第${last+1}章 · ${saved!.positionText}',style: type.copyWith(fontSize: 13))),
                ],
              ]),
              const Divider(height: 40,color: rule,thickness: .6),
              Row(children: [marker(),const SizedBox(width: 12),
                Text('收听目录',style: type.copyWith(fontSize: 21,fontWeight: FontWeight.bold)),
                const SizedBox(width: 18),Text('${parts.length}个分段',style: type)]),
              const SizedBox(height: 12),
            ]);
            final i = row - 1;
            final selected = i == (last < 0 ? 0 : last);
            return InkWell(onTap: () => choose(i), child: SizedBox(
              height: 54,
              child: DecoratedBox(
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: rule,width: .5))),
                child: Row(children: [
                  SizedBox(width: 3,child: selected ? marker() : null),
                  const SizedBox(width: 13),
                  Expanded(child: Text(partLabel(parts[i].part),
                    maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                    style: type.copyWith(fontSize: 17,color: selected ? brown : ink))),
                  const SizedBox(width: 8),
                  Text('${done.contains(parts[i].cid) ? "✓  " : ""}${parts[i].durationText}',
                    maxLines: 1, softWrap: false, style: type),
                ]),
              ),
            ));
          },
        );
      },
    )),]),
  );
}
