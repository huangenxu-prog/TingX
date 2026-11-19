import 'chapter.dart';

/// 一本书（B 站视频），picture/bvid/作者/统计/多P章节
class Book {
  // Only expose literary genres and audio formats actually tagged by the source.
  static const _genreTags = {
    '广播剧','评书','相声','悬疑','推理','悬疑推理','灵异','恐怖','玄幻','仙侠',
    '玄幻仙侠','修仙','奇幻','武侠','历史','历史小说','架空历史','都市','科幻',
    '科幻小说','言情','古言','现言','古代言情','现代言情','穿越','重生','军事',
    '冒险','盗墓','刑侦','文学','名著','经典文学','儿童文学','童话','纪实',
    '传记','人物传记','轻小说','游戏','体育','末世','无限流','古风','年代文',
  };
  final List<String> genres;
  final String bvid;
  final int aid;
  final String title;
  final String pic;
  final int pages; // 分P数
  final int duration; // 总时长(秒)
  final String author;
  final int mid;
  final String authorFace;
  final String desc;
  final int play;
  final int like;
  final int coin;
  final int favorite;
  final int pubdate;
  final String upName;

  final List<Chapter>? chapters;

  Book({
    required this.bvid,
    this.genres = const [],
    required this.aid,
    required this.title,
    required this.pic,
    this.pages = 1,
    this.duration = 0,
    this.author = '',
    this.mid = 0,
    this.authorFace = '',
    this.desc = '',
    this.play = 0,
    this.like = 0,
    this.coin = 0,
    this.favorite = 0,
    this.pubdate = 0,
    this.upName = '',
    this.chapters,
  });

  String get cleanTitle => title
      .replaceAll('<em class="keyword">', '')
      .replaceAll('</em>', '');

  // Keep source metadata for episode counts, credits, search and persistence.
  static final _quoted = RegExp(r'《([^《》]+)》|<([^<>]+)>');
  static const _format = r'(?:多人有声剧|多人有声书|有声小说|有声书|超长爽文|有声剧|有声读物|有声小说全集|完整版|无删减(?:版)?|已完结|完结版|全集|全本)';
  static const _promo = r'(?:免费听书|免费畅听|一口气听完|一口气看完|超长合集|高清音质|高音质|精品有声书|\d+\s*(?:个)?小时(?:超长视频|超长合集)|有声书\s*[+＋]\s*字幕)';
  static final _label = RegExp(
    '^(?:[【（(\\[]\\s*(?:$_format|$_promo|完结)\\s*[】）)\\]]|(?:$_format|$_promo)(?=[\\s:：·｜|《<【（(\\-]))[\\s:：·｜|\\-]*',
  );
  static final _suffix = RegExp(
    '(?:[\\s｜|·\\-]+(?:by\\s+|演播[：:]|播讲[：:]).+|(?:[\\s｜|·\\-]+|[【（(\\[])(?:$_format|$_promo|完结|(?:全|共)\\s*\\d+\\s*集)[】）)\\]]?)\$',
    caseSensitive: false,
  );

  late final String displayTitle = _displayTitle(cleanTitle);

  static String _displayTitle(String source) {
    final decoded = source.replaceAll('&amp;', '&').replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>').replaceAll('&nbsp;', ' ').trim();
    final quoted = _quoted.firstMatch(decoded);
    if (quoted != null) {
      final name = (quoted[1] ?? quoted[2]!).trim();
      final volume = RegExp(r'^\s*(第[一二三四五六七八九十百\d]+[部卷季]|[上中下][部册卷])')
          .firstMatch(decoded.substring(quoted.end));
      if (name.isNotEmpty) return volume == null ? name : '$name ${volume[1]}';
    }
    var result = decoded;
    while (result.isNotEmpty) {
      final next = result.replaceFirst(_label, '').replaceFirst(_suffix, '').trim();
      if (next == result) break;
      result = next;
    }
    return result.isEmpty ? decoded : result;
  }

  /// 归一化封面地址：`//i0.hdslb.com/...` 与 http 源统一转 https
  static String normalizePic(String input) {
    final u = input.trim();
    if (u.isEmpty) return u;
    if (u.startsWith('//')) return 'https:$u';
    if (u.startsWith('http://')) return 'https://${u.substring(7)}';
    return u;
  }

  /// 解析搜索接口的时长：可能是秒数，也可能是 "5152:33"（分:秒）/"1:02:03" 字符串
  static int parseDurationSeconds(Object? v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    final s = '$v'.trim();
    if (s.isEmpty) return 0;
    final parts = s.split(':');
    if (parts.length >= 2) {
      var total = 0;
      for (final p in parts) {
        total = total * 60 + (int.tryParse(p.trim()) ?? 0);
      }
      return total;
    }
    return int.tryParse(s) ?? 0;
  }

  String get durationText {
    if (duration <= 0) return '';
    final h = duration ~/ 3600;
    final m = (duration % 3600) ~/ 60;
    final s = duration % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 从搜索结果构造
  factory Book.fromSearch(Map<String, dynamic> m) {
    return Book(
      genres: '${m['tag'] ?? ''}'.split(RegExp(r'[,，]')).map((s) => s.trim())
          .where(_genreTags.contains).toSet().toList(),
      bvid: m['bvid'] as String? ?? '',
      aid: int.tryParse('${m['aid'] ?? 0}') ?? 0,
      title: m['title'] as String? ?? '',
      pic: normalizePic(m['pic'] as String? ?? ''),
      pages: int.tryParse('${m['videos'] ?? 1}') ?? 1,
      duration: parseDurationSeconds(m['duration']),
      author: m['author'] as String? ?? '',
      mid: int.tryParse('${m['mid'] ?? 0}') ?? 0,
      play: int.tryParse('${m['play'] ?? 0}') ?? 0,
      pubdate: int.tryParse('${m['pubdate'] ?? 0}') ?? 0,
      desc: m['description'] as String? ?? '',
    );
  }

  /// 从详情（view）构造
  factory Book.fromView(Map<String, dynamic> m) {
    final owner = m['owner'] as Map? ?? {};
    final stat = m['stat'] as Map? ?? {};
    final pages = m['pages'] as List? ?? [];
    return Book(
      bvid: m['bvid'] as String? ?? '',
      aid: int.tryParse('${m['aid'] ?? 0}') ?? 0,
      title: m['title'] as String? ?? '',
      pic: normalizePic(m['pic'] as String? ?? ''),
      pages: pages.isEmpty ? 1 : pages.length,
      duration: int.tryParse('${m['duration'] ?? 0}') ?? 0,
      author: owner['name'] as String? ?? '',
      mid: int.tryParse('${owner['mid'] ?? 0}') ?? 0,
      authorFace: owner['face'] as String? ?? '',
      desc: m['desc'] as String? ?? '',
      play: int.tryParse('${stat['view'] ?? 0}') ?? 0,
      like: int.tryParse('${stat['like'] ?? 0}') ?? 0,
      coin: int.tryParse('${stat['coin'] ?? 0}') ?? 0,
      favorite: int.tryParse('${stat['favorite'] ?? 0}') ?? 0,
      pubdate: int.tryParse('${m['pubdate'] ?? 0}') ?? 0,
      upName: owner['name'] as String? ?? '',
      chapters: pages
          .map((e) => Chapter.fromMap((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'bvid': bvid,
        'aid': aid,
        'title': cleanTitle,
        'pic': pic,
        'pages': pages,
        'duration': duration,
        'author': author,
        'mid': mid,
        'authorFace': authorFace,
        'desc': desc,
        'play': play,
      };

  factory Book.fromJson(Map<String, dynamic> m) => Book(
        bvid: m['bvid'] as String? ?? '',
        aid: int.tryParse('${m['aid'] ?? 0}') ?? 0,
        title: m['title'] as String? ?? '',
        pic: normalizePic(m['pic'] as String? ?? ''),
        pages: int.tryParse('${m['pages'] ?? 1}') ?? 1,
        duration: int.tryParse('${m['duration'] ?? 0}') ?? 0,
        author: m['author'] as String? ?? '',
        mid: int.tryParse('${m['mid'] ?? 0}') ?? 0,
        authorFace: m['authorFace'] as String? ?? '',
        desc: m['desc'] as String? ?? '',
        play: int.tryParse('${m['play'] ?? 0}') ?? 0,
      );
}