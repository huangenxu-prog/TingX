import 'package:flutter/material.dart';
import '../models/book.dart';

const brown = Color(0xff894d2d);
const ivory = Color(0xfffaf3e9);
const display = TextStyle(fontFamily: 'Songti SC', fontWeight: FontWeight.bold, color: Color(0xff402a1c));

String shortTitle(Book book) => RegExp('《([^》]+)》').firstMatch(book.cleanTitle)?.group(1) ?? book.cleanTitle;

class BookJacket extends StatelessWidget {
  const BookJacket(this.book, {super.key});
  final Book book;
  @override
  Widget build(BuildContext context) {
    const colors = [
      [Color(0xff443765), Color(0xffc38a70)], [Color(0xff102e30), Color(0xff3a5647)],
      [Color(0xff46150f), Color(0xff9a4f29)], [Color(0xff201c19), Color(0xff593a13)],
      [Color(0xff457c8b), Color(0xffc3d9d5)], [Color(0xffb64721), Color(0xffefa34c)]
    ];
    final tone = colors[book.bvid.codeUnits.fold<int>(0,(a,b)=>a+b) % colors.length];
    return DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
      gradient: LinearGradient(begin: Alignment.topLeft,end:Alignment.bottomRight,colors:tone)),
      child: Center(child: Padding(padding:const EdgeInsets.all(8),child:FittedBox(fit:BoxFit.scaleDown,
        child:Text(shortTitle(book).characters.take(13).join('\n'),textAlign:TextAlign.center,
          style:display.copyWith(color:Colors.white,fontSize:22,height:1.05))))));
  }
}
