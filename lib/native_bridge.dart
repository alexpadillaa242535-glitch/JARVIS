import 'package:flutter/services.dart';

/// Puente con el código Kotlin (configuración, permisos, control del teléfono).
class Native {
  static const MethodChannel _ch = MethodChannel('jarvis/native');

  static Future<void> setConfig(String url, String token) async {
    await _ch.invokeMethod('setConfig', {'url': url, 'token': token});
  }

  static Future<Map<String, String>> getConfig() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('getConfig');
      return {
        'url': (m?['url'] ?? '').toString(),
        'token': (m?['token'] ?? '').toString(),
      };
    } catch (_) {
      return {'url': '', 'token': ''};
    }
  }

  static Future<Map<String, bool>> status() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('status');
      return {'notif': m?['notif'] == true, 'access': m?['access'] == true};
    } catch (_) {
      return {'notif': false, 'access': false};
    }
  }

  static Future<void> openNotifSettings() => _ch.invokeMethod('openNotifSettings');
  static Future<void> openAccessSettings() => _ch.invokeMethod('openAccessSettings');
  static Future<void> openAppDetails() => _ch.invokeMethod('openAppDetails');
  static Future<void> minimize() => _ch.invokeMethod('minimize');

  static Future<bool> globalAction(String name) async =>
      (await _ch.invokeMethod<bool>('globalAction', {'name': name})) ?? false;

  static Future<bool> openApp(String target) async =>
      (await _ch.invokeMethod<bool>('openApp', {'target': target})) ?? false;

  static Future<bool> clickText(String text) async =>
      (await _ch.invokeMethod<bool>('clickText', {'text': text})) ?? false;

  static Future<String> readScreen() async =>
      (await _ch.invokeMethod<String>('readScreen')) ?? '';
}
