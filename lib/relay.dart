import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'crypto_layers.dart';

/// Public store-and-forward relay used as a "mailbox" (no server of our own).
/// It only ever sees encrypted text under a random channel name. To self-host,
/// run ntfy yourself and change this URL.
const String kRelayUrl = 'https://ntfy.sh';

/// A message read back from the relay, with the relay's own timestamp.
class RelayMessage {
  final Map<String, dynamic> body;
  final int serverTime; // seconds since epoch, set by the relay (not the phone)
  RelayMessage(this.body, this.serverTime);
}

/// One encrypted channel on the relay (subscribe + publish).
class RelayChannel {
  final Uint8List secret;
  final void Function(Map<String, dynamic> message) onMessage;
  final String since;
  String _topic = '';
  bool _running = false;
  HttpClient? _client;
  final Set<String> _seen = <String>{};

  RelayChannel(this.secret, this.onMessage, {this.since = '10m'});

  /// Only computes the channel name (enough for publishing).
  Future<void> prepare() async {
    _topic = await AccountCrypto.topic(secret);
  }

  Future<void> start() async {
    _topic = await AccountCrypto.topic(secret);
    _running = true;
    _loop(); // runs in the background
  }

  void stop() {
    _running = false;
    _client?.close(force: true);
  }

  Future<void> _loop() async {
    while (_running) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      _client = client;
      try {
        // since=10m: also receive messages sent while this device was offline.
        final req = await client.getUrl(Uri.parse('$kRelayUrl/$_topic/json?since=$since'));
        req.headers.set('User-Agent', 'ImmoApp');
        final resp = await req.close();
        if (resp.statusCode == 200) {
          await for (final line in resp.transform(utf8.decoder).transform(const LineSplitter())) {
            if (!_running) break;
            await _handleLine(line);
          }
        }
      } catch (e) {
        if (_running) debugPrint('relay: $e');
      } finally {
        client.close(force: true);
      }
      if (_running) await Future.delayed(const Duration(seconds: 5));
    }
  }

  Future<void> _handleLine(String line) async {
    if (line.trim().isEmpty) return;
    try {
      final j = jsonDecode(line) as Map<String, dynamic>;
      if (j['event'] != 'message') return;
      final id = j['id']?.toString() ?? '';
      if (id.isNotEmpty) {
        if (_seen.contains(id)) return;
        _seen.add(id);
        if (_seen.length > 500) _seen.remove(_seen.first);
      }
      final m = await AccountCrypto.open(j['message']?.toString() ?? '', secret);
      if (m != null) onMessage(m);
    } catch (_) {}
  }

  Future<bool> publish(Map<String, dynamic> message) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final body = await AccountCrypto.seal(message, secret);
      final req = await client.postUrl(Uri.parse('$kRelayUrl/$_topic'));
      req.headers.set('User-Agent', 'ImmoApp');
      req.headers.set('Content-Type', 'text/plain');
      req.write(body);
      final resp = await req.close();
      await resp.drain();
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('relay publish: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Publishes and returns the relay's own clock (seconds), or null on failure.
  Future<int?> publishForTime(Map<String, dynamic> message) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      if (_topic.isEmpty) _topic = await AccountCrypto.topic(secret);
      final body = await AccountCrypto.seal(message, secret);
      final req = await client.postUrl(Uri.parse('$kRelayUrl/$_topic'));
      req.headers.set('User-Agent', 'ImmoApp');
      req.headers.set('Content-Type', 'text/plain');
      req.write(body);
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final t = (jsonDecode(text) as Map)['time'];
      return (t as num?)?.toInt();
    } catch (e) {
      debugPrint('relay publishForTime: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Reads every message the relay still holds for this channel (about 12 h).
  /// Throws when the relay cannot be reached, so callers can tell
  /// "nobody else claimed it" apart from "no internet".
  Future<List<RelayMessage>> pollAll() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      if (_topic.isEmpty) _topic = await AccountCrypto.topic(secret);
      final req = await client.getUrl(Uri.parse('$kRelayUrl/$_topic/json?poll=1&since=all'));
      req.headers.set('User-Agent', 'ImmoApp');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) throw HttpException('relay status ${resp.statusCode}');
      final text = await resp.transform(utf8.decoder).join();
      final out = <RelayMessage>[];
      for (final line in const LineSplitter().convert(text)) {
        if (line.trim().isEmpty) continue;
        try {
          final j = jsonDecode(line) as Map<String, dynamic>;
          if (j['event'] != 'message') continue;
          final m = await AccountCrypto.open(j['message']?.toString() ?? '', secret);
          if (m != null) out.add(RelayMessage(m, (j['time'] as num?)?.toInt() ?? 0));
        } catch (_) {}
      }
      return out;
    } finally {
      client.close(force: true);
    }
  }
}
