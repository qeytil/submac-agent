import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'system_bridge.dart';

/// Plan 2.1 "Push, not polling": FCM delivers results from the cloud, so the app does not need to be alive.
///
/// How a push reaches the user:
/// - The server sends data-only messages (title/body/bot_id/chat_id in `data`).
/// - Android hands every message to `PushReceiver.kt`, which shows it through `Notifier` (the same calm
///   notifications bots use today), in the foreground, in the background and when the app is closed.
///   No Dart background isolate is needed.
/// - A tap carries `conv/<chat_id>` or `botchat/<bot_id>` through the normal notification-tap route.
///
/// Firebase is optional: if it fails to start, everything else keeps working (just no push).
class Push {
  Push._();
  static final I = Push._();

  /// FIREBASE CLIENT CONFIG (the only place it lives). Public values for Firebase project telesia-agent,
  /// safe to ship like the Supabase anon key. appId belongs to the Android app registered for package
  /// com.telesia.app, the applicationId (since v1.13.13; kept by the owner 2026-10-18). Swap appId here if the app is re-registered.
  static const firebaseOptions = FirebaseOptions(
    apiKey: 'AIzaSyDLfjR2dE1b5S-qVQyByhxMNRTElM0wAYo',
    appId: '1:264730074210:android:0187bdcc38dbc6d5f5053b',
    messagingSenderId: '264730074210',
    projectId: 'telesia-agent',
    storageBucket: 'telesia-agent.firebasestorage.app',
  );

  static const _askedKey = 'push_permission_asked';

  bool _ok = false;
  bool get available => _ok;
  String? _token;
  String? _savedFor; // "<user>|<token>" last written to push_tokens
  StreamSubscription<String>? _refreshSub;
  StreamSubscription<AuthState>? _authSub;

  /// Call once from main() after Supabase.initialize. Never throws.
  Future<void> init() async {
    if (!Platform.isAndroid || _ok) return;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: firebaseOptions).timeout(const Duration(seconds: 8));
      }
      _ok = true;
    } catch (e) {
      debugPrint('Push: Firebase init failed, push is off: $e');
      return;
    }
    try {
      final fm = FirebaseMessaging.instance;
      // Foreground: PushReceiver already shows the notification natively; nothing to draw here.
      FirebaseMessaging.onMessage.listen((_) {}, onError: (_) {});
      // Messages that carried a `notification` block (e.g. a console test) are drawn by Firebase itself
      // when the app is in the background; route their taps like ours.
      FirebaseMessaging.onMessageOpenedApp.listen((m) => _openFrom(m.data), onError: (_) {});
      unawaited(fm.getInitialMessage().then((m) {
        if (m != null) _openFrom(m.data);
      }).catchError((_) {}));
      _refreshSub = fm.onTokenRefresh.listen((t) {
        _token = t;
        unawaited(_save());
      }, onError: (_) {});
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((s) {
        if (s.session != null &&
            (s.event == AuthChangeEvent.signedIn || s.event == AuthChangeEvent.initialSession || s.event == AuthChangeEvent.userUpdated)) {
          unawaited(_onSignedIn());
        }
      }, onError: (_) {});
      if (Supabase.instance.client.auth.currentSession != null) unawaited(_onSignedIn());
    } catch (e) {
      debugPrint('Push: setup failed: $e');
    }
  }

  /// Payload for a push's data: the chat first, else the bot. Mirrors PushReceiver.kt.
  static String? payloadFor(Map<String, dynamic> data) {
    // A message from the Telesia team (admin): opens "From Telesia".
    final inbox = '${data['inbox_id'] ?? ''}'.trim();
    if (inbox.isNotEmpty || data['open'] == 'inbox') return inbox.isEmpty ? 'inbox' : 'inbox/$inbox';
    final chat = '${data['chat_id'] ?? ''}'.trim();
    if (chat.isNotEmpty) return 'conv/$chat';
    final bot = '${data['bot_id'] ?? ''}'.trim();
    if (bot.isNotEmpty) return 'botchat/$bot';
    return null;
  }

  void _openFrom(Map<String, dynamic> data) {
    final p = payloadFor(data);
    if (p != null) SystemBridge.I.onNotificationTap?.call(p);
  }

  Future<void> _onSignedIn() async {
    // Ask for notifications politely: once ever, a few seconds after the app opens signed in, and only
    // when Android does not already allow them. The System permissions screen can still turn them on later.
    unawaited(Future.delayed(const Duration(seconds: 6), _askOnce));
    try {
      _token ??= await FirebaseMessaging.instance.getToken().timeout(const Duration(seconds: 20));
    } catch (e) {
      debugPrint('Push: no token yet: $e');
    }
    await _save();
  }

  Future<void> _askOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_askedKey) == true) return;
      final fm = FirebaseMessaging.instance;
      final now = await fm.getNotificationSettings();
      if (now.authorizationStatus == AuthorizationStatus.authorized) {
        await prefs.setBool(_askedKey, true);
        return;
      }
      if (Supabase.instance.client.auth.currentSession == null) return;
      await prefs.setBool(_askedKey, true);
      await fm.requestPermission(alert: true, badge: true, sound: true);
    } catch (_) {}
  }

  /// Upserts this phone's token for the signed-in user (RPC claims it if another account had it).
  Future<void> _save() async {
    final t = _token;
    final user = Supabase.instance.client.auth.currentUser;
    if (!_ok || t == null || t.isEmpty || user == null) return;
    final key = '${user.id}|$t';
    if (_savedFor == key) return;
    try {
      await Supabase.instance.client.rpc('register_push_token', params: {'p_token': t, 'p_platform': 'android'});
      _savedFor = key;
    } catch (e) {
      // Fallback for a database without the RPC: plain upsert under RLS.
      try {
        await Supabase.instance.client.from('push_tokens').upsert(
          {'user_id': user.id, 'token': t, 'platform': 'android', 'updated_at': DateTime.now().toUtc().toIso8601String()},
          onConflict: 'token',
        );
        _savedFor = key;
      } catch (e2) {
        debugPrint('Push: could not save token: $e2');
      }
    }
  }

  /// Before signing out: stop pushes for this account on this phone. Best effort, never throws.
  Future<void> forget() async {
    final t = _token;
    _savedFor = null;
    if (!_ok || t == null) return;
    try {
      await Supabase.instance.client.from('push_tokens').delete().eq('token', t).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  @visibleForTesting
  Future<void> dispose() async {
    await _refreshSub?.cancel();
    await _authSub?.cancel();
  }
}
