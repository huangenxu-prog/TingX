import 'dart:io';

import 'package:just_audio/just_audio.dart';

/// Experimental byte-range transport. Not enabled in the production player.
///
/// A new HTTP request is created for each player range request. The caller
/// supplies the current signed URL, so expired URLs must be refreshed outside
/// this class.
class BiliStreamAudioSource extends StreamAudioSource {
  BiliStreamAudioSource({
    required this.uri,
    required this.referer,
    required this.userAgent,
  });

  final Uri uri;
  final String referer;
  final String userAgent;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final begin = start ?? 0;
    if (begin < 0 || (end != null && end <= begin)) {
      throw RangeError('Invalid audio byte range');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.refererHeader, referer);
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      if (start != null || end != null) {
        final last = end == null ? '' : '${end - 1}';
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$begin-$last');
      }
      final response = await req.close();
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw HttpException(
          'Audio server returned HTTP ${response.statusCode}',
          uri: Uri(scheme: uri.scheme, host: uri.host),
        );
      }
      if (begin > 0 && response.statusCode != HttpStatus.partialContent) {
        throw const FormatException('Server ignored nonzero audio Range');
      }
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      int? totalLength;
      int offset = 0;
      if (response.statusCode == HttpStatus.partialContent) {
        final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$')
            .firstMatch(range ?? '');
        if (match == null) {
          throw const FormatException('Invalid Content-Range');
        }
        offset = int.parse(match.group(1)!);
        if (offset != begin) {
          throw const FormatException('Unexpected Content-Range offset');
        }
        totalLength = int.tryParse(match.group(3)!);
      } else if (response.contentLength >= 0) {
        totalLength = response.contentLength;
      }
      final mime = response.headers.contentType?.mimeType;
      final contentType = mime == null ||
              mime == 'application/octet-stream' ||
              mime == 'binary/octet-stream'
          ? 'audio/mp4'
          : mime;
      final responseLength = response.contentLength;
      return StreamAudioResponse(
        sourceLength: totalLength,
        contentLength: responseLength < 0 ? null : responseLength,
        offset: offset,
        stream: response,
        contentType: contentType,
      );
    } finally {
      // StreamAudioResponse owns the response stream. Do not force-close the
      // client here: doing so would truncate playback after request() returns.
      client.close();
    }
  }
}
