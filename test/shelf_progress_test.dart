import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tingx/core/storage/shelf_store.dart';
import 'package:tingx/models/book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('completed chapter contributes full progress and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final shelf = ShelfStore.instance;
    await shelf.load();
    const bvid = 'BV1TingXTest';
    final book = Book(
      bvid: bvid,
      aid: 1,
      title: '测试听书',
      pic: '',
      pages: 1,
    );
    await shelf.add(book);
    await shelf.updateProgress(
      bvid,
      cid: 101,
      chapterIndex: 0,
      positionMs: 95000,
      chapterDurationMs: 100000,
      totalChapters: 2,
    );
    expect(shelf.byBvid(bvid)!.percent, closeTo(0.475, 0.0001));

    await shelf.markChapterDone(bvid, 101);
    await shelf.markChapterDone(bvid, 101);
    final entry = shelf.byBvid(bvid)!;
    expect(entry.doneCids, [101]);
    expect(entry.chapterProgress[101], 1.0);
    expect(entry.percent, 0.5);

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('abts_shelf')!;
    expect(saved, contains('"101":1.0'));

    await shelf.remove(bvid);
  });
}
