import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'hud_painters.dart';
import 'jarvis_api.dart';
import 'native_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const JarvisApp());
}

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JARVIS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(scaffoldBackgroundColor: Colors.black),
      home: const JarvisHome(),
    );
  }
}

enum JState { idle, listening, thinking, speaking }

class JarvisHome extends StatefulWidget {
  const JarvisHome({super.key});

  @override
  State<JarvisHome> createState() => _JarvisHomeState();
}

class _JarvisHomeState extends State<JarvisHome> with SingleTickerProviderStateMixin {
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();
  final AudioRecorder _rec = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _tts = FlutterTts();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<String> _lines = [];

  JarvisApi _api = JarvisApi('', '');
  JState _state = JState.idle;
  bool _backendOk = false, _wsOk = false, _notifOn = false, _accessOn = false;
  String? _recPath;
  Timer? _poller;

  Color get _color {
    switch (_state) {
      case JState.idle:
        return const Color(0xFF00B7FF); // azul
      case JState.listening:
        return const Color(0xFFFF9800); // naranja
      case JState.thinking:
        return const Color(0xFF00E5FF); // cian
      case JState.speaking:
        return const Color(0xFF39FF88); // verde
    }
  }

  String get _stateLabel {
    switch (_state) {
      case JState.idle:
        return 'TOCA PARA HABLAR';
      case JState.listening:
        return 'ESCUCHANDO... (toca para enviar)';
      case JState.thinking:
        return 'PENSANDO...';
      case JState.speaking:
        return 'HABLANDO (toca para callar)';
    }
  }

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _poller?.cancel();
    _api.stopWs();
    _anim.dispose();
    _rec.dispose();
    _player.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      await _tts.setLanguage('es-ES');
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}
    final cfg = await Native.getConfig();
    _applyConfig(cfg['url'] ?? '', cfg['token'] ?? '');
    _poller = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
    _poll();
    if (_api.baseUrl.isEmpty || _api.token.isEmpty) {
      _log('Configura la URL del backend y el token (engranaje de arriba).');
      WidgetsBinding.instance.addPostFrameCallback((_) => _openSettings());
    } else {
      _log('Sistema en línea. Toca el reactor para hablarme.');
    }
  }

  void _applyConfig(String url, String token) {
    _api.stopWs();
    _api = JarvisApi(JarvisApi.normalize(url), token.trim());
    if (_api.baseUrl.isNotEmpty && _api.token.isNotEmpty) {
      _api.startWs(_onWs, (ok) {
        if (mounted) setState(() => _wsOk = ok);
      });
    }
  }

  Future<void> _poll() async {
    final s = await Native.status();
    final ok = await _api.health();
    if (!mounted) return;
    setState(() {
      _notifOn = s['notif'] ?? false;
      _accessOn = s['access'] ?? false;
      _backendOk = ok;
    });
  }

  void _log(String s) {
    if (!mounted) return;
    setState(() {
      _lines.add(s);
      if (_lines.length > 80) _lines.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  // ---------- Mensajes empujados por el backend (WebSocket) ----------
  void _onWs(Map<String, dynamic> m) {
    final text = (m['text'] ?? '').toString();
    if (text.isEmpty) return;
    if (m['type'] == 'speak') {
      _log('JARVIS (aviso): $text');
      final b64 = m['audio_b64'] as String?;
      Uint8List? audio;
      if (b64 != null && b64.isNotEmpty) {
        try {
          audio = Reply.fromJson({'text': text, 'audio_b64': b64}).audio;
        } catch (_) {}
      }
      if (_state == JState.idle) {
        setState(() => _state = JState.speaking);
        _speak(text, audio).whenComplete(() {
          if (mounted && _state == JState.speaking) setState(() => _state = JState.idle);
        });
      }
    } else {
      _log('Aviso: $text');
    }
  }

  // ---------- Voz ----------
  Future<void> _speak(String text, Uint8List? audio) async {
    if (text.trim().isEmpty) return;
    if (audio != null && audio.isNotEmpty) {
      try {
        await _player.stop();
        final done = _player.onPlayerComplete.first;
        await _player.play(BytesSource(audio));
        await done.timeout(const Duration(seconds: 120), onTimeout: () {});
        return;
      } catch (_) {
        // si falla Fish Audio / reproducción, cae al TTS de Android
      }
    }
    try {
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> _stopSpeaking() async {
    try {
      await _player.stop();
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> _onReactorTap() async {
    switch (_state) {
      case JState.idle:
        await _startRec();
        break;
      case JState.listening:
        await _stopRecAndSend();
        break;
      case JState.speaking:
        await _stopSpeaking();
        if (mounted) setState(() => _state = JState.idle);
        break;
      case JState.thinking:
        break;
    }
  }

  Future<void> _startRec() async {
    if (_api.baseUrl.isEmpty) {
      _openSettings();
      return;
    }
    try {
      if (!await _rec.hasPermission()) {
        _log('Necesito permiso de micrófono (Ajustes > Apps > JARVIS > Permisos).');
        return;
      }
      final dir = await getTemporaryDirectory();
      _recPath = '${dir.path}/jarvis_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000, numChannels: 1),
        path: _recPath!,
      );
      setState(() => _state = JState.listening);
    } catch (e) {
      _log('No pude grabar: $e');
    }
  }

  Future<void> _stopRecAndSend() async {
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {}
    path ??= _recPath;
    if (path == null) {
      setState(() => _state = JState.idle);
      return;
    }
    final p = path;
    await _ask(() => _api.voice(p));
  }

  Future<void> _sendText() async {
    final t = _input.text.trim();
    if (t.isEmpty || _state == JState.thinking) return;
    _input.clear();
    FocusScope.of(context).unfocus();
    _log('Yo: $t');
    await _ask(() => _api.chat(t));
  }

  Future<void> _ask(Future<Reply> Function() call) async {
    setState(() => _state = JState.thinking);
    try {
      final r = await call();
      if (r.heard.isNotEmpty) _log('Yo: ${r.heard}');
      await _handleReply(r);
    } catch (e) {
      _log('Error: $e');
      if (mounted) setState(() => _state = JState.idle);
    }
  }

  Future<void> _handleReply(Reply r) async {
    _log('JARVIS: ${r.text}');
    if (mounted) setState(() => _state = JState.speaking);
    final speaking = _speak(r.text, r.audio);
    String? screen;
    if (r.actions.isNotEmpty) screen = await _runActions(r.actions);
    await speaking;
    if (screen != null && screen.trim().isNotEmpty) {
      if (mounted) setState(() => _state = JState.thinking);
      try {
        final r2 = await _api.chat('Responde según lo que hay en mi pantalla y lo que te pedí antes.', screen: screen);
        _log('JARVIS: ${r2.text}');
        if (mounted) setState(() => _state = JState.speaking);
        await _speak(r2.text, r2.audio);
      } catch (e) {
        _log('Error: $e');
      }
    }
    if (mounted) setState(() => _state = JState.idle);
  }

  /// Ejecuta las acciones que pidió el backend. Devuelve el texto de pantalla si hubo read_screen.
  Future<String?> _runActions(List<String> actions) async {
    String? screen;
    for (final a in actions) {
      final cmd = a.split(':').first.trim();
      final arg = a.length > cmd.length + 1 ? a.substring(cmd.length + 1).trim() : '';
      try {
        switch (cmd) {
          case 'home':
          case 'back':
          case 'recents':
          case 'notifications':
          case 'screenshot':
            if (!_accessOn) {
              _log('Activa el servicio de accesibilidad de JARVIS para controlar el teléfono.');
            } else {
              await Native.globalAction(cmd);
            }
            break;
          case 'open':
            final okOpen = await Native.openApp(arg);
            if (!okOpen) _log('No encontré la app "$arg".');
            break;
          case 'click':
            final okClick = await Native.clickText(arg);
            if (!okClick) _log('No encontré un botón con el texto "$arg".');
            break;
          case 'read_screen':
            await Native.minimize();
            await Future.delayed(const Duration(milliseconds: 1500));
            screen = await Native.readScreen();
            break;
        }
      } catch (e) {
        _log('Acción $cmd falló: $e');
      }
      await Future.delayed(const Duration(milliseconds: 700));
    }
    return screen;
  }

  // ---------- Configuración ----------
  Future<void> _openSettings() async {
    if (!mounted) return;
    final urlC = TextEditingController(text: _api.baseUrl);
    final tokC = TextEditingController(text: _api.token);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF07141C),
        title: const Text('Configuración'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlC,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                    labelText: 'URL del backend', hintText: 'https://xxxx.up.railway.app o http://192.168.1.X:8000'),
              ),
              TextField(
                controller: tokC,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Token (JARVIS_TOKEN)'),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(onPressed: Native.openNotifSettings, child: const Text('Acceso a notificaciones')),
                  OutlinedButton(onPressed: Native.openAccessSettings, child: const Text('Accesibilidad')),
                  OutlinedButton(onPressed: Native.openAppDetails, child: const Text('Ajustes restringidos')),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
          FilledButton(
            onPressed: () async {
              final url = JarvisApi.normalize(urlC.text);
              final tok = tokC.text.trim();
              await Native.setConfig(url, tok);
              _applyConfig(url, tok);
              if (ctx.mounted) Navigator.pop(ctx);
              _poll();
              _log('Configuración guardada.');
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    urlC.dispose();
    tokC.dispose();
  }

  // ---------- UI ----------
  Widget _led(String label, bool on) {
    final c = on ? const Color(0xFF39FF88) : const Color(0xFFFF4D4D);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c,
          boxShadow: [BoxShadow(color: c.withOpacity(0.8), blurRadius: 6)],
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70, letterSpacing: 1)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _anim,
              builder: (_, __) => CustomPaint(painter: HudPainter(_anim.value, _color)),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
                  child: Row(
                    children: [
                      Text('J.A.R.V.I.S.',
                          style: TextStyle(fontSize: 20, letterSpacing: 6, color: _color, fontWeight: FontWeight.w300)),
                      const Spacer(),
                      IconButton(onPressed: _openSettings, icon: const Icon(Icons.settings, color: Colors.white54)),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Wrap(spacing: 16, runSpacing: 6, children: [
                    _led('BACKEND', _backendOk),
                    _led('ENLACE', _wsOk),
                    _led('NOTIFICACIONES', _notifOn),
                    _led('ACCESIBILIDAD', _accessOn),
                  ]),
                ),
                Expanded(
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: _onReactorTap,
                            child: SizedBox(
                              width: 250,
                              height: 250,
                              child: AnimatedBuilder(
                                animation: _anim,
                                builder: (_, __) => CustomPaint(
                                  painter: ReactorPainter(_anim.value, _color, _state != JState.idle),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(_stateLabel, style: TextStyle(color: _color, letterSpacing: 3, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
                Container(
                  height: 130,
                  margin: const EdgeInsets.symmetric(horizontal: 14),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    border: Border.all(color: _color.withOpacity(0.35)),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: ListView.builder(
                    controller: _scroll,
                    itemCount: _lines.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(_lines[i], style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        onSubmitted: (_) => _sendText(),
                        textInputAction: TextInputAction.send,
                        decoration: InputDecoration(
                          hintText: 'Escríbeme algo...',
                          isDense: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(onPressed: _sendText, icon: const Icon(Icons.send)),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
