import 'package:flutter_test/flutter_test.dart';
import 'package:tingx/core/storage/shelf_store.dart';
import 'package:tingx/models/audio_stream.dart';
import 'package:tingx/models/book.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('AAC survives null FLAC metadata and both CDN field spellings', () {
    final audio = BookAudio.fromMap({
      'dash': {
        'flac': {'audio': null},
        'audio': [
          {
            'base_url': 'https://example.com/a',
            'backupUrl': ['https://example.com/b'],
          },
        ],
      },
    });
    expect(audio.tracks.single.baseUrl, 'https://example.com/a');
    expect(audio.tracks.single.backupUrls, ['https://example.com/b']);
  });

  test('shelf restores the exact chapter and offset', () async {
    SharedPreferences.setMockInitialValues({});
    final shelf = ShelfStore.instance;
    final book = Book.fromView({
      'bvid': 'fixture',
      'pages': [
        {'cid': 100, 'part': '序'},
        {'cid': 200, 'part': '正文'},
      ],
    });
    await shelf.add(book);
    await shelf.updateProgress(
      book.bvid,
      cid: 200,
      chapterIndex: 1,
      positionMs: 37123,
      chapterDurationMs: 90000,
      totalChapters: 2,
    );
    await shelf.load();
    final record = shelf.byBvid(book.bvid)!;
    expect(record.lastCid, 200);
    expect(record.positionMs, 37123);
    expect(record.totalChapters, 2);
  });
}
