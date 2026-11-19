import 'dart:async';
import 'dart:io';

/// A read-only probe for the first bytes of a signed audio URL.
///
/// Never logs the signed URL or query parameters. This probe is not a
/// replacement for the audio player's transport.
class AudioHttpProbe {
  static Future<AudioHttpProbeResult> inspect(
    Uri uri, {
    required String referer,
    required String userAgent,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.refererHeader, referer);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final response = await request.close().timeout(timeout);
      final status = response.statusCode;
      final contentRange =
          response.headers.value(HttpHeaders.contentRangeHeader);
      final contentType = response.headers.contentType?.mimeType;
      final length = response.contentLength;
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        final remaining = 1024 - bytes.length;
        if (remaining <= 0) break;
        bytes.addAll(chunk.take(remaining));
        if (bytes.length >= 1024) break;
      }
      return AudioHttpProbeResult(
        statusCode: status,
        contentType: contentType,
        contentRange: contentRange,
        contentLength: length,
        firstBytes: bytes,
      );
    } finally {
      client.close(force: true);
    }
  }
}

class AudioHttpProbeResult {
  const AudioHttpProbeResult({
    required this.statusCode,
    required this.contentType,
    required this.contentRange,
    required this.contentLength,
    required this.firstBytes,
  });

  final int statusCode;
  final String? contentType;
  final String? contentRange;
  final int contentLength;
  final List<int> firstBytes;

  bool get isHttpSuccess => statusCode == 200 || statusCode == 206;

  /// MP4-family files commonly expose an ftyp box at offset 4.
  bool get looksLikeMp4 =>
      firstBytes.length >= 8 &&
      firstBytes[4] == 0x66 &&
      firstBytes[5] == 0x74 &&
      firstBytes[6] == 0x79 &&
      firstBytes[7] == 0x70;

  String get summary =>
      'status=$statusCode, mime=$contentType, '
      'range=$contentRange, length=$contentLength, '
      'bytes=${firstBytes.length}, mp4=$looksLikeMp4';
}
