import 'package:flutter/material.dart';
import '../models/book.dart';

const brown = Color(0xff894d2d);
const ivory = Color(0xfffaf3e9);
const display = TextStyle(fontFamily: 'Songti SC', fontWeight: FontWeight.bold, color: Color(0xff402a1c));

String shortTitle(Book book) => book.displayTitle;

/// Local cover study: deterministic artwork, no network or generation wait.
/// Landscape for shelves; portrait for the full-screen player.
class BookJacket extends StatelessWidget {
  const BookJacket(this.book, {super.key, this.portrait = false});
  final Book book;
  final bool portrait;

  @override
  Widget build(BuildContext context) {
    final title = shortTitle(book);
    final source = '${book.cleanTitle} ${book.desc}'.toLowerCase();
    final palettes = <List<Color>>[
      [const Color(0xff8e391e), const Color(0xffd28b46), const Color(0xff39271f)],
      [const Color(0xff173e53), const Color(0xff4c8090), const Color(0xff132333)],
      [const Color(0xff26263d), const Color(0xff675374), const Color(0xff191a2d)],
      [const Color(0xff354e3c), const Color(0xff91a27c), const Color(0xff263328)],
      [const Color(0xff69464a), const Color(0xffc48b88), const Color(0xff352a3d)],
      [const Color(0xff384c65), const Color(0xff8193a8), const Color(0xff202d43)],
    ];
    final theme = RegExp(r'历史|明朝|三国|大秦|大唐|大宋|清朝|帝王|权谋').hasMatch(source) ? 0
      : RegExp(r'悬疑|灵异|恐怖|诡|鬼|神秘|惊悚').hasMatch(source) ? 2
      : RegExp(r'修仙|仙侠|玄幻|武侠|凡人|剑|龙族').hasMatch(source) ? 1
      : RegExp(r'都市|人生|职场|商业|重生').hasMatch(source) ? 3
      : RegExp(r'言情|爱情|情感|婚姻').hasMatch(source) ? 4
      : 5;
    final palette = palettes[theme];
    final seed = book.bvid.codeUnits.fold<int>(0, (n, c) => (n * 31 + c) & 0x7fffffff);
    final alignment = Alignment(((seed % 5) - 2) / 2, -0.8);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: palette)),
        child: LayoutBuilder(builder: (context, bounds) {
          final compact = bounds.maxHeight < 115;
          return Stack(fit: StackFit.expand, children: [
            Positioned(
              right: -bounds.maxWidth * .13,
              top: -bounds.maxHeight * .28,
              child: Container(width: bounds.maxWidth * .85,
                height: bounds.maxWidth * .85,
                decoration: BoxDecoration(shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: .09),
                  border: Border.all(color: Colors.white.withValues(alpha: .17), width: 2))),
            ),
            Align(alignment: alignment, child: Icon(
              [Icons.account_balance_outlined, Icons.landscape_outlined,
               Icons.nights_stay_outlined, Icons.park_outlined,
               Icons.local_florist_outlined, Icons.auto_stories_outlined][theme],
              size: bounds.maxWidth * (portrait ? .66 : .45),
              color: Colors.white.withValues(alpha: .13))),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 9 : 20, vertical: compact ? 6 : 18),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(width: 28, height: 2, color: const Color(0xffe9c08b)),
                SizedBox(height: compact ? 5 : 16),
                Text(title, maxLines: portrait ? 3 : 2,
                  overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Songti SC', fontWeight: FontWeight.bold,
                    color: const Color(0xfffff4df),
                    shadows: const [Shadow(color: Colors.black38, blurRadius: 7)],
                    fontSize: compact ? 15 : portrait ? 34 : 23)),
                SizedBox(height: compact ? 4 : 12),
                if (!compact) Text('TINGX · 有声书', style: TextStyle(
                  fontSize: portrait ? 12 : 10, letterSpacing: 2,
                  color: Colors.white.withValues(alpha: .75))),
              ]),
            ),
          ]);
        }),
      ),
    );
  }
}
