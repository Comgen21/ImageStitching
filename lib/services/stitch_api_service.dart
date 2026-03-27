import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// HTTP client for the Python FastAPI stitching backend.
///
/// ─── Quick setup ───────────────────────────────────────────────
///   1. Run the backend:
///        cd backend
///        pip install -r requirements.txt
///        uvicorn main:app --host 0.0.0.0 --port 8000
///   2. Find your PC's LAN IP (e.g., 192.168.1.42)
///   3. Set [baseUrl] below to http://<PC_LAN_IP>:8000
/// ───────────────────────────────────────────────────────────────
class StitchApiService {
  // ← Change to your PC's LAN IP when running locally
  static const String baseUrl = 'http://192.168.1.63:8000';

  static const Duration _uploadTimeout = Duration(seconds: 120);
  static const Duration _pollInterval = Duration(seconds: 2);
  static const int _maxPolls = 150; // 5 minutes max

  /// Uploads [imagePaths] to the backend and waits for the stitched result.
  ///
  /// Returns the URL of the stitched image on the server.
  /// Throws [StitchApiException] on any failure.
  static Future<StitchResult> stitch(List<String> imagePaths) async {
    final sessionId = await _upload(imagePaths);
    return _poll(sessionId);
  }

  /// Check server reachability. Returns true if the server responds.
  static Future<bool> isReachable() async {
    try {
      final r = await http
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Private ─────────────────────────────────────────────────────────────────

  static Future<String> _upload(List<String> imagePaths) async {
    final uri = Uri.parse('$baseUrl/stitch');
    final request = http.MultipartRequest('POST', uri);

    for (final path in imagePaths) {
      request.files.add(await http.MultipartFile.fromPath('files', path));
    }

    http.StreamedResponse streamed;
    try {
      streamed = await request.send().timeout(_uploadTimeout);
    } on SocketException catch (e) {
      throw StitchApiException(
        'Cannot reach stitching server at $baseUrl.\n'
        'Make sure the backend is running and the phone is on the same WiFi.\n'
        'Error: $e',
      );
    } on TimeoutException {
      throw StitchApiException('Upload timed out after ${_uploadTimeout.inSeconds}s.');
    }

    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw StitchApiException(
        'Upload failed (HTTP ${streamed.statusCode}): $body',
      );
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    return json['session_id'] as String;
  }

  static Future<StitchResult> _poll(String sessionId) async {
    final uri = Uri.parse('$baseUrl/result/$sessionId');
    for (int i = 0; i < _maxPolls; i++) {
      await Future.delayed(_pollInterval);
      final r = await http.get(uri).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) continue;

      final json = jsonDecode(r.body) as Map<String, dynamic>;
      final status = json['status'] as String;

      if (status == 'success') {
        return StitchResult(
          imageUrl: '$baseUrl${json['image_url']}',
          qualityScore: (json['quality_score'] as num).toDouble(),
          framesUsed: json['frames_used'] as int,
          width: json['width'] as int,
          height: json['height'] as int,
        );
      }

      if (status == 'error') {
        throw StitchApiException(json['error'] as String? ?? 'Unknown error');
      }
      // still 'processing' — keep polling
    }
    throw StitchApiException('Timed out waiting for stitching result.');
  }
}

// ── Result model ─────────────────────────────────────────────────────────────

class StitchResult {
  final String imageUrl;
  final double qualityScore;
  final int framesUsed;
  final int width;
  final int height;

  const StitchResult({
    required this.imageUrl,
    required this.qualityScore,
    required this.framesUsed,
    required this.width,
    required this.height,
  });
}

class StitchApiException implements Exception {
  final String message;
  const StitchApiException(this.message);
  @override
  String toString() => message;
}
