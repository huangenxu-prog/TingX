import 'dart:async';

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
import 'player/playback_comparison.dart';
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
    return LayoutBuilder(builder:(context,size)=>Column(children:[
      Expanded(child:SizedBox.expand(child:cover(b))),
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
                for (final m in [0, 15, 30, 60])
                  PopupMenuItem(
                    value: m,
                    child: Text(m == 0 ? '关闭定时' : '$m 分钟'),
                  ),
              ],
              child: const Column(children:[Icon(Icons.schedule),Text('睡眠定时')]),
            ),
          ],
        ),
      ]))))]));
  }

  Widget bookshelf() {
    final all=shelf.books;
    final entries=all.where((e)=>filter==0 || (filter==1 ? e.hasProgress && e.percent<1 : e.percent>=1)).toList();
    final recent=entries.where((e)=>e.lastCid>0).firstOrNull;
    return ListView(padding:const EdgeInsets.fromLTRB(18,0,18,20),children:[
      Wrap(spacing:8,children:[for(int i=0;i<3;i++) ChoiceChip(shape:const StadiumBorder(),side:BorderSide.none,selectedColor:brown,backgroundColor:const Color(0xfff1e6d8),showCheckmark:false,label:Text(['全部','在听','已听完'][i],style:TextStyle(color:filter==i?Colors.white:brown)),selected:filter==i,onSelected:(_)=>setState(()=>filter=i))]),
      if(recent!=null)...[
        const SizedBox(height:16),Text('继续收听',style:display.copyWith(fontSize:21)),
        Card(color:const Color(0xfffff9f2),child:Padding(padding:const EdgeInsets.all(10),child:Row(children:[
          SizedBox(width:78,height:108,child:BookJacket(recent.book)),const SizedBox(width:14),
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(shortTitle(recent.book),maxLines:1,overflow:TextOverflow.ellipsis,style:display.copyWith(fontSize:18)),
            Text('${recent.book.author} · 第${recent.lastChapterIndex+1}章',maxLines:1,overflow:TextOverflow.ellipsis),
            const SizedBox(height:8),LinearProgressIndicator(value:recent.chapterDurationMs>0?(recent.positionMs/recent.chapterDurationMs).clamp(0.0,1.0):0),
            Row(children:[Expanded(child:Text('${recent.positionText} / ${clock(recent.chapterDurationMs~/1000)}')),IconButton.filled(onPressed:()=>resume(recent.book),icon:const Icon(Icons.play_arrow))])]))])))],
      const SizedBox(height:16),Row(children:[Expanded(child:Text('我的书架',style:display.copyWith(fontSize:21))),Text('${entries.length} 本')]),const SizedBox(height:12),
      GridView.builder(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),itemCount:entries.length+1,
       gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:3,childAspectRatio:.54,crossAxisSpacing:12,mainAxisSpacing:14),
       itemBuilder:(_,i){
        if(i==entries.length)return InkWell(onTap:()=>setState(()=>tab=1),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:Container(alignment:Alignment.center,decoration:BoxDecoration(border:Border.all(color:Colors.brown.shade200),borderRadius:BorderRadius.circular(12)),child:const Icon(Icons.add))),const Text('去发现')]));
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
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:SizedBox.expand(child:BookJacket(entry.book))),Text(shortTitle(entry.book),maxLines:1,overflow:TextOverflow.ellipsis,style:display),Text(entry.hasProgress?'第${entry.lastChapterIndex+1}章 · ${entry.positionText}':entry.book.author,maxLines:1,overflow:TextOverflow.ellipsis)]));
      })]);
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['播放器', '发现', '书架'];
    return Scaffold(
      extendBodyBehindAppBar:tab==0,
      appBar: AppBar(backgroundColor:tab==0?Colors.transparent:ivory,foregroundColor:tab==0?Colors.white:null,
        systemOverlayStyle:tab==0?SystemUiOverlayStyle.light:SystemUiOverlayStyle.dark,
        leading:tab==0?BackButton(onPressed:()=>setState(()=>tab=2)):null,
        centerTitle: false,
        title: tab==0?null:Text(titles[tab],style:display.copyWith(fontSize:29)),
        actions: [
          if (tab == 0)
            PopupMenuButton<String>(
              tooltip: '更多',
              icon: const Icon(Icons.more_horiz,color:Colors.white),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'settings', child: Text('设置')),
                if (ListeningSession.experimentalStream)
                  PopupMenuItem(value: 'compare', child: Text('同源播放对照')),
                PopupMenuItem(value: 'timing', child: Text('起播耗时')),
              ],
              onSelected: (value) async {
                if (value == 'compare') {
                  await comparePlayback(context, player);
                  return;
                }
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
      body: SafeArea(top:tab!=0,
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
      fit: BoxFit.cover,
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
    appBar: AppBar(actions:[ListenableBuilder(listenable:ShelfStore.instance,builder:(_,__){
      final b=widget.book;
      final on=ShelfStore.instance.isOnShelf(b.bvid);
      return IconButton(tooltip:on?'移出书架':'加入书架',icon:Icon(on?Icons.bookmark:Icons.bookmark_border,color:brown),onPressed:() async {
        if(on){await confirmRemoval(context,b);}else{await ShelfStore.instance.add(b);final data=await info;await ShelfStore.instance.setTotalChapters(b.bvid,data.$2.length);}
      });
    })]),
    body: FutureBuilder(
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
        return ListView.builder(padding:const EdgeInsets.fromLTRB(18,6,18,30),itemCount:parts.length+1,itemBuilder:(_,row){
          if(row==0)return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Row(children:[SizedBox(width:112,height:155,child:cover(b)),const SizedBox(width:16),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text(shortTitle(b),maxLines:3,overflow:TextOverflow.ellipsis,style:const TextStyle(fontFamily:'Songti SC',fontSize:26,color:Color(0xff402a1c),fontWeight:FontWeight.bold)),
              if(b.cleanTitle.contains('完结') && !b.cleanTitle.contains('未完结'))const Text(' 完结 ',style:TextStyle(color:Colors.white,backgroundColor:Color(0xff9d4739),fontSize:12)),
              const SizedBox(height:8),if(b.author.isNotEmpty)Text('上传者：${b.author}',style:const TextStyle(color:brown)),if(RegExp(r'\d+集').hasMatch(b.cleanTitle))Text(RegExp(r'\d+集').firstMatch(b.cleanTitle)![0]!)
            ]))]),
            if(b.desc.isNotEmpty || synopsis.isNotEmpty) Padding(padding:const EdgeInsets.symmetric(vertical:12),child:InkWell(onTap:()=>setState(()=>expanded=!expanded),child:Column(crossAxisAlignment:CrossAxisAlignment.end,children:[Text(b.desc.isEmpty?synopsis:b.desc,maxLines:expanded?null:2,overflow:expanded?null:TextOverflow.ellipsis),Text(expanded?'收起':'展开',style:const TextStyle(color:brown))]))),
            const SizedBox(height:12),Center(child:Wrap(spacing:12,crossAxisAlignment:WrapCrossAlignment.center,children:[FilledButton.icon(style:FilledButton.styleFrom(backgroundColor:brown),onPressed:()=>choose(last<0?0:last),icon:const Icon(Icons.play_arrow),label:Text(last<0?'开始收听':'继续收听')),
            if(last>=0)Text('${partLabel(parts[last].part)} · 已听 ${saved!.positionText}',style:const TextStyle(fontSize:12))])),
            const Divider(height:30),Text('收听目录   ·   ${parts.length} 个分段',style:const TextStyle(fontFamily:'Songti SC',fontSize:19,color:Color(0xff402a1c))),const SizedBox(height:8)
          ]);
          final i=row-1;
          return Container(decoration:const BoxDecoration(border:Border(bottom:BorderSide(color:Color(0xffe7ded1),width:.5))),child:ListTile(dense:true,contentPadding:const EdgeInsets.symmetric(horizontal:5),selected:i==last,selectedColor:brown,
            leading:i==last?Container(width:3,height:18,color:brown):null,title:Text(partLabel(parts[i].part)),trailing:Text('${done.contains(parts[i].cid)?"✓  ":""}${parts[i].durationText}'),onTap:()=>choose(i)));
        });
      },
    ),
  );
}
