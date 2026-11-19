import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../models/book.dart';
import 'book_jacket.dart';
import '../services/bili_api.dart';

const _ink = Color(0xff483427);
const _accent = Color(0xff965b35);
const _categories = <({String label, List<String> keywords})>[
  (label: '热门推荐', keywords: ['有声小说']),
  (label: '广播剧', keywords: ['广播剧 全集']),
  (label: '评书相声', keywords: ['评书', '相声']),
  (label: '历史', keywords: ['历史 有声小说']),
  (label: '都市', keywords: ['都市 有声小说']),
  (label: '悬疑灵异', keywords: ['悬疑 有声小说', '灵异 有声小说']),
  (label: '玄幻', keywords: ['玄幻 有声小说']),
  (label: '仙侠武侠', keywords: ['仙侠 有声小说', '武侠 有声小说']),
  (label: '科幻', keywords: ['科幻 有声小说']),
  (label: '言情', keywords: ['言情 有声小说']),
  (label: '穿越重生', keywords: ['穿越 有声小说', '重生 有声小说']),
  (label: '军事', keywords: ['军事 有声小说']),
  (label: '儿童', keywords: ['儿童 有声书']),
  (label: '名著', keywords: ['世界名著 朗读']),
];

class DiscoverHome extends StatefulWidget {
  const DiscoverHome({super.key, required this.openBook, required this.listen});
  final ValueChanged<Book> openBook;
  final ValueChanged<Book> listen;

  @override
  State<DiscoverHome> createState() => _DiscoverHomeState();
}

class _DiscoverHomeState extends State<DiscoverHome> {
  final search = TextEditingController();
  final scroll = ScrollController();
  final books = <Book>[];
  int category = 0;
  String query = '';
  int generation = 0;
  int page = 0;
  bool busy = false;
  bool more = true;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    load();
    scroll.addListener(onScroll);
  }

  void onScroll() {
    if (!failed && scroll.position.extentAfter < 220) load();
  }

  @override
  void dispose() {
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  void restart(int index, String text) {
    generation++;
    category = index;
    query = text.trim();
    page = 0;
    more = true;
    busy = false;
    books.clear();
    if (scroll.hasClients) scroll.jumpTo(0);
    load();
  }

  Future<void> load() async {
    if (busy || !more) return;
    final id = generation;
    final next = page + 1;
    setState(() { busy = true; failed = false; });
    try {
      final keywords = query.isNotEmpty
          ? [query]
          : _categories[category].keywords;
      final rawCounts = List<int>.filled(keywords.length, 0);
      final batches = await Future.wait([
        for (var i = 0; i < keywords.length; i++)
          BiliApi.instance.search(
            keywords[i],
            page: next,
            order: query.isEmpty && category == 0 ? 'click' : null,
            onRawCount: (n) => rawCounts[i] = n,
          ),
      ]);
      // Interleave independently searched categories rather than putting all
      // results from the first keyword ahead of the second.
      final list = <Book>[];
      final longest = batches.fold<int>(0, (n, batch) => batch.length > n ? batch.length : n);
      for (var offset = 0; offset < longest; offset++) {
        for (final batch in batches) {
          if (offset < batch.length) list.add(batch[offset]);
        }
      }
      if (!mounted || id != generation) return;
      final seen = books.map((book) => book.bvid).toSet();
      setState(() {
        books.addAll(list.where((book) => seen.add(book.bvid)));
        page = next;
        more = rawCounts.any((count) => count >= 20);
      });
    } catch (_) {
      if (mounted && id == generation) setState(() => failed = true);
    } finally {
      if (mounted && id == generation) setState(() => busy = false);
    }
  }

  Widget categories() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(children: List.generate(_categories.length, (i) {
      final title = _categories[i].label;
      final selected = query.isEmpty && category == i;
      final color = selected ? Colors.white : _ink;
      return Padding(padding: const EdgeInsets.only(right: 6), child: Semantics(
        button: true, selected: selected, child: GestureDetector(onTap: () {
          FocusScope.of(context).unfocus();
          search.clear();
          restart(i, '');
        }, child: _Glass(selected: selected, child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
          child: Row(children: [
            const SizedBox(width: 4), Text(title, style: TextStyle(fontSize: 12, color: color))]),
        )))));
    })),
  );

  Widget tile(Book b) {
    final title = b.cleanTitle;
    final match = RegExp(r'(?:演播|播讲|主播)[：:︰]\s*([^｜|【】《》，,。\s]+)').firstMatch('$title ${b.desc}');
    final credit = match?.group(1) ?? b.author;

    return InkWell(onTap: () => widget.openBook(b), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: BookJacket(b)),
        Padding(padding: const EdgeInsets.fromLTRB(3, 5, 3, 0), child: Text(b.displayTitle,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink))),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: Text(credit,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Color(0xff76665a)))),
      ]));
  }

  @override
  Widget build(BuildContext context) {
    final heading = query.isNotEmpty ? '搜索结果' : category == 0 ? '热门榜单' : _categories[category].label;
    final featured = category == 0 && query.isEmpty && books.isNotEmpty;
    return DecoratedBox(decoration: const BoxDecoration(gradient: LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [ivory, ivory, ivory],
      stops: [0, .23, 1])), child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(14, 4, 14, 4), child: TextField(
          controller: search, textInputAction: TextInputAction.search,
          onSubmitted: (v) => restart(category, v),
          decoration: InputDecoration(isDense: true, filled: true, fillColor: Colors.white38,
            hintText: '搜索书名 / 作者 / 主播', prefixIcon: const Icon(Icons.search, color: _ink),
            suffixIcon: query.isEmpty ? null : IconButton(icon: const Icon(Icons.close),
              onPressed: () { search.clear(); restart(category, ''); }),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(26),
              borderSide: const BorderSide(color: Color(0xffd7c2ae))),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(26))))),
        categories(),
        Padding(padding: const EdgeInsets.fromLTRB(14, 2, 4, 0), child: Row(children: [
          Icon(query.isEmpty ? (category == 0 ? Icons.local_fire_department_outlined : Icons.category_outlined) : Icons.search, size: 17, color: _accent),
          const SizedBox(width: 5),
          Expanded(child: Text(heading, style: const TextStyle(fontSize: 18, color: _ink, fontWeight: FontWeight.w600))),
          Text('${books.length} 个结果', style: const TextStyle(color: _ink, fontSize: 12)),
          IconButton(tooltip: '刷新', onPressed: () => restart(category, query),
            icon: const Icon(Icons.refresh, size: 19, color: _ink))])),
        Expanded(child: CustomScrollView(controller: scroll, slivers: [
          if(featured) SliverToBoxAdapter(child:Container(height:148,margin:const EdgeInsets.fromLTRB(18,0,18,16),padding:const EdgeInsets.all(10),
            decoration:BoxDecoration(color:const Color(0xfffff9f2),borderRadius:BorderRadius.circular(20),border:Border.all(color:const Color(0xffe8d8c5))),
            child:Row(children:[SizedBox(width:84,child:GestureDetector(onTap:()=>widget.openBook(books.first),child:BookJacket(books.first))),
              const SizedBox(width:14),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
                Text(books.first.cleanTitle.contains('多人')?'榜首 · 多人有声剧':'榜首',style:const TextStyle(color:brown,fontWeight:FontWeight.bold)),
                GestureDetector(onTap:()=>widget.openBook(books.first),child:Text(shortTitle(books.first),maxLines:1,overflow:TextOverflow.ellipsis,style:display.copyWith(fontSize:20))),
                Text(books.first.author,maxLines:1,overflow:TextOverflow.ellipsis),
                IconButton.filled(tooltip:'播放',onPressed:()=>widget.listen(books.first),icon:const Icon(Icons.play_arrow))]))]))),
          SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 18), sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3,
              crossAxisSpacing: 8, mainAxisSpacing: 15, childAspectRatio: .62),
            delegate: SliverChildBuilderDelegate((_, i) => tile(books[i+(featured?1:0)]), childCount: books.length-(featured?1:0)))),
          SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(10), child: Center(child:
            busy ? const CircularProgressIndicator(strokeWidth: 2) :
            failed || more ? TextButton(onPressed: load, child: Text(failed ? '加载失败，点此重试' : '加载更多')) :
            books.isEmpty ? const Text('暂无相关有声书') : const SizedBox.shrink()))),
        ]))
      ]));
  }
}

class _Glass extends StatelessWidget {
  const _Glass({required this.child, this.selected = false});
  final Widget child;
  final bool selected;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(32),
      boxShadow: const [BoxShadow(color: Color(0x19744c30), blurRadius: 6, offset: Offset(0, 2))]),
    child: ClipRRect(borderRadius: BorderRadius.circular(32), child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8), child: DecoratedBox(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(32),
          border: Border.all(color: Colors.white70),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: selected ? const [Color(0xffb97c50), _accent]
              : const [Color(0xe6fff9ef), Color(0xb9f2e7db)])), child: child))));
}

class TingXTabBar extends StatelessWidget {
  const TingXTabBar({super.key, required this.index, required this.select});
  final int index;
  final ValueChanged<int> select;

  @override
  Widget build(BuildContext context) => SafeArea(top: false, child: Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 5), child: _Glass(child: Padding(
      padding: const EdgeInsets.all(3), child: Row(children: List.generate(3, (i) {
        final selected = index == i;
        final label = const ['播放器', '发现', '书架'][i];
        return Expanded(child: Semantics(button: true, selected: selected,
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => select(i),
            child: AnimatedContainer(duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(vertical: 5),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(28),
                color: selected ? const Color(0xfff8d6b6) : Colors.transparent),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(const [Icons.headphones, Icons.explore_outlined, Icons.menu_book_outlined][i],
                  size: 21, color: _ink), Text(label, style: const TextStyle(color: _ink, fontSize: 12))
              ])))));
      }))))));
}
