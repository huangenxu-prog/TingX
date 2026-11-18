import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/bili_api.dart';

/// 发现首页：所有作品均来自真实搜索；统计字段必须来自视频详情。
class DiscoverHome extends StatefulWidget {
  const DiscoverHome({super.key, required this.openBook});
  final void Function(Book) openBook;

  @override
  State<DiscoverHome> createState() => _DiscoverHomeState();
}

class _DiscoverHomeState extends State<DiscoverHome> {
  final search = TextEditingController();
  final api = BiliApi.instance;
  final categories = const [
    '历史', '都市', '玄幻', '仙侠', '悬疑', '科幻', '武侠', '军事',
    '言情', '穿越', '灵异', '名著', '评书', '相声', '广播剧', '文学',
  ];
  List<Book> hot = [];
  List<Book> results = [];
  List<Book> enriched = [];
  bool loading = false;
  bool searching = false;
  String? error;
  String? keyword;
  final Map<String, int> sectionOffsets = {};
  int generation = 0;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    generation++;
    search.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    final id = ++generation;
    setState(() { loading = true; error = null; });
    try {
      final list = await api.rankHotNovel(limit: 30);
      if (!mounted || id != generation) return;
      setState(() { hot = list; loading = false; });
      // 搜索结果只包含播放量，点赞与收藏必须通过详情获取。
      // 限制为六条，避免一次发出大量请求触发 B 站风控。
      final details = <Book>[];
      for (final book in list.take(6)) {
        if (!mounted || id != generation) return;
        try {
          details.add(await api.detail(book.bvid));
        } catch (_) {
          // 不用缺失统计的搜索条目冒充点赞/收藏排名。
        }
      }
      if (mounted && id == generation) setState(() => enriched = details);
    } catch (e) {
      if (mounted && id == generation) setState(() { error = '推荐加载失败，请重试'; loading = false; });
    }
  }

  Future<void> find(String value) async {
    final q = value.trim();
    final id = ++generation;
    setState(() { keyword = q.isEmpty ? null : q; results = []; searching = q.isNotEmpty; error = null; });
    if (q.isEmpty) { refresh(); return; }
    try {
      final list = await api.search(q);
      if (mounted && id == generation) setState(() => results = list);
    } catch (_) {
      if (mounted && id == generation) setState(() => error = '搜索失败，请稍后重试');
    } finally {
      if (mounted && id == generation) setState(() => searching = false);
    }
  }

  List<Book> batch(String title, List<Book> source) {
    if (source.isEmpty) return [];
    final start = (sectionOffsets[title] ?? 0) % source.length;
    return List.generate(source.length < 6 ? source.length : 6,
        (i) => source[(start + i) % source.length]);
  }

  Widget bookTile(Book book) => InkWell(
    onTap: () => widget.openBook(book),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AspectRatio(
        aspectRatio: 3 / 4,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: book.pic.isEmpty
              ? const ColoredBox(color: Color(0xffe8dece), child: Icon(Icons.menu_book))
              : Image.network(book.pic, fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const ColoredBox(
                    color: Color(0xffe8dece), child: Icon(Icons.menu_book))),
        ),
      ),
      const SizedBox(height: 5),
      Text(book.cleanTitle, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12)),
    ]),
  );

  Widget section(String title, List<Book> source, {bool shuffle = true}) {
    final books = batch(title, source);
    return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        if (shuffle && source.length > 6)
          TextButton.icon(
            onPressed: () => setState(() => sectionOffsets[title] = (sectionOffsets[title] ?? 0) + 6),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('换一批'),
          ),
      ]),
      if (books.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('暂无可靠数据', style: TextStyle(color: Colors.grey)))
      else
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: books.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, childAspectRatio: .56,
            crossAxisSpacing: 12, mainAxisSpacing: 12),
          itemBuilder: (_, i) => bookTile(books[i]),
        ),
      const SizedBox(height: 14),
    ],
  );
  }

  Widget categoryStrip() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('分类', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      SizedBox(height: 112, child: PageView.builder(
        itemCount: (categories.length / 8).ceil(),
        itemBuilder: (_, page) => GridView.count(
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 4, childAspectRatio: 2.3,
          crossAxisSpacing: 8, mainAxisSpacing: 8,
          children: categories.skip(page * 8).take(8).map((name) =>
            OutlinedButton(
              onPressed: () { search.text = name; find('$name 有声小说'); },
              style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
              child: Text(name, style: const TextStyle(fontSize: 12)),
            )).toList(),
        ),
      )),
      const SizedBox(height: 18),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final ranked = [...enriched];
    final byFavorite = [...ranked]..sort((a, b) => b.favorite.compareTo(a.favorite));
    final byLike = [...ranked]..sort((a, b) => b.like.compareTo(a.like));
    return ListView(padding: const EdgeInsets.all(16), children: [
      TextField(
        controller: search,
        textInputAction: TextInputAction.search,
        onSubmitted: find,
        decoration: InputDecoration(
          hintText: '搜索有声小说、作者、演播者',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: IconButton(
            icon: Icon(keyword == null ? Icons.arrow_forward : Icons.close),
            onPressed: () {
              if (keyword != null) { search.clear(); find(''); }
              else { find(search.text); }
            },
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
        ),
      ),
      if (loading || searching) const LinearProgressIndicator(),
      if (error != null) Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
      const SizedBox(height: 20),
      if (keyword != null)
        section('搜索结果', results, shuffle: false)
      else ...[
        section('热门推荐', hot),
        categoryStrip(),
        section('收藏榜', byFavorite.where((b) => b.favorite > 0).toList()),
        section('热播榜', hot),
        section('高赞榜', byLike.where((b) => b.like > 0).toList()),
        TextButton(onPressed: refresh, child: const Text('刷新推荐')),
      ],
    ]);
  }
}
