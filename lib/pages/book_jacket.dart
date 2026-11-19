import 'package:flutter/material.dart';
import '../models/book.dart';

const brown = Color(0xff894d2d);
const ivory = Color(0xfffaf3e9);
const display = TextStyle(fontFamily: 'Songti SC', fontWeight: FontWeight.bold, color: Color(0xff402a1c));

String shortTitle(Book book) => book.displayTitle;

class BookJacket extends StatelessWidget {
  const BookJacket(this.book, {super.key});
  final Book book;
  @override
  Widget build(BuildContext context) {
    final url = Book.normalizePic(book.pic);
    const unavailable = ColoredBox(
      color: ivory,
      child: Center(child: Icon(Icons.image_not_supported_outlined, color: Colors.brown)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: ivory,
        child: SizedBox.expand(
        child: url.isEmpty
            ? unavailable
            : Image.network(
                url,
                fit: BoxFit.cover,
                semanticLabel: shortTitle(book),
                errorBuilder: (_, __, ___) => unavailable,
              ),
        ),
      ),
    );
  }
}
