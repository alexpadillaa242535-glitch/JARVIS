import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

class Reply {
  final String heard;
  final String text;
  final List<String> actions;
  final Uint8List? audio;
  final String provider;

  Reply({
    this.heard = '',
    required this.text,
    this.actions = const [],
    this.audio,
    this.provider = '',
  });

  factory Reply.fromJson(Map<String, dynamic> j) {
    final b64 = j['audio_b64'] as String?;
    return Reply(
      heard: (j['heard'] ?? '').toString(),
      text: (j['text'] ?? '').toString(),
      actions: ((j['actions'] ?? []) as List).map((e) => e.toString()).toList(),
      audio: (b64 != null && b64.isNotEmpty) ? base64Decode(b64) : null,
      provider: (j['provider'] ?? '').toString(),
    );
  }
}

class JarvisApi {
  String baseUrl;
  String token;
  JarvisApi(this.baseUrl, this.token);

  int _gen = 0;
  WebSocketChannel? _channel;

  static String normalize(String u) {
    var s = u.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Map<String, String> get _headers => {
        'X-Jarvis-Token': token,
        'Content-Type': 'application/json; charset=utf-8',
      };

  Map<String, dynamic> _decode(http.Response r) {
    final body = utf8.decode(r.bodyBytes);
    if (r.statusCode != 200) {
      String detail = body;
      try {
        detail = (jsonDecode(body)['detail'] ?? body).toString();
      } catch (_) {}
      throw Exception('HTTP ${r.statusCode}: $detail');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<bool> health() async {
    try {
      final r = await http.get(Uri.parse('$baseUrl/health')).timeout(const Duration(seconds: 6));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Reply> chat(String text, {String? screen}) async {
    final r = await http
        .post(
          Uri.parse('$baseUrl/chat'),
          headers: _headers,
          body: jsonEncode({'text': text, 'screen': screen, 'speak': true}),
        )
        .timeout(const Duration(seconds: 60));
    return Reply.fromJson(_decode(r));
  }

  Future<Reply> voice(String path) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/voice'))
      ..headers['X-Jarvis-Token'] = token
      ..files.add(await http.MultipartFile.fromPath('file', path));
    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final res = await http.Response.fromStream(streamed);
    return Reply.fromJson(_decode(res));
  }

  /// WebSocket persistente con reconexión automática: el backend te "empuja" avisos.
  Future<void> startWs(
    void Function(Map<String, dynamic>) onMsg,
    void Function(bool) onState,
  ) async {
    final gen = ++_gen;
    var delay = 2;
    while (gen == _gen) {
      Timer? ping;
      try {
        final uri = Uri.parse(
            '${baseUrl.replaceFirst('http', 'ws')}/ws?token=${Uri.encodeQueryComponent(token)}');
        final ch = WebSocketChannel.connect(uri);
        _channel = ch;
        await ch.ready;
        onState(true);
        delay = 2;
        ping = Timer.periodic(const Duration(seconds: 25), (_) {
          try {
            ch.sink.add('ping');
          } catch (_) {}
        });
        await for (final m in ch.stream) {
          if (m == 'pong') continue;
          try {
            onMsg(jsonDecode(m as String) as Map<String, dynamic>);
          } catch (_) {}
        }
      } catch (_) {
        // se reintenta abajo
      } finally {
        ping?.cancel();
      }
      if (gen != _gen) break;
      onState(false);
      await Future.delayed(Duration(seconds: delay));
      delay = math.min(delay * 2, 30);
    }
  }

  void stopWs() {
    _gen++;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }
}
