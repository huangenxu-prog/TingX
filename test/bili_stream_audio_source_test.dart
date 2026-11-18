import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingx/player/bili_stream_audio_source.dart';

void main() {
  test('returns correct byte range and total length', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=2-5');
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes 2-5/10',
      );
      request.response.headers.contentType = ContentType('audio', 'mp4');
      request.response.add([2, 3, 4, 5]);
      await request.response.close();
    });
    try {
      final source = BiliStreamAudioSource(
        uri: Uri.parse('http://127.0.0.1:${server.port}/audio'),
        referer: 'https://www.bilibili.com/',
        userAgent: 'TingX-test',
      );
      final result = await source.request(2, 6);
      expect(result.offset, 2);
      expect(result.sourceLength, 10);
      expect(result.contentLength, 4);
      expect(result.contentType, 'audio/mp4');
      expect(await result.stream.expand((bytes) => bytes).toList(), [2, 3, 4, 5]);
    } finally {
      await server.close(force: true);
    }
  });

  test('rejects server ignoring nonzero range', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.add([0, 1, 2, 3]);
      await request.response.close();
    });
    try {
      final source = BiliStreamAudioSource(
        uri: Uri.parse('http://127.0.0.1:${server.port}/audio'),
        referer: 'https://www.bilibili.com/',
        userAgent: 'TingX-test',
      );
      await expectLater(source.request(2, 4), throwsFormatException);
    } finally {
      await server.close(force: true);
    }
  });
}
