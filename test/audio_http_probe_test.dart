import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingx/player/audio_http_probe.dart';

void main() {
  test('probe verifies byte-range response and MP4 signature', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String?>[];
    server.listen((request) async {
      requests.add(request.headers.value(HttpHeaders.rangeHeader));
      expect(request.headers.value(HttpHeaders.refererHeader),
          'https://www.bilibili.com/');
      expect(request.headers.value(HttpHeaders.userAgentHeader), 'TingX-test');
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.contentType = ContentType('audio', 'mp4');
      request.response.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes 0-11/12');
      request.response.add([
        0, 0, 0, 12, 0x66, 0x74, 0x79, 0x70, 0x4d, 0x34, 0x41, 0x20,
      ]);
      await request.response.close();
    });
    try {
      final result = await AudioHttpProbe.inspect(
        Uri.parse('http://127.0.0.1:${server.port}/audio'),
        referer: 'https://www.bilibili.com/',
        userAgent: 'TingX-test',
      );
      expect(result.statusCode, 206);
      expect(result.isHttpSuccess, isTrue);
      expect(result.looksLikeMp4, isTrue);
      expect(result.contentType, 'audio/mp4');
      expect(requests, ['bytes=0-1023']);
    } finally {
      await server.close(force: true);
    }
  });
}
