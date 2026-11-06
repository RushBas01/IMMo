import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'relay.dart';

/// Stable device id, stored in the app folder AND in a hidden file on the phone
/// storage so that "clear storage" does not make the device look like a new one.
class DeviceId {
  static String? _id;
  static const String _externalPath = '/storage/emulated/0/.immo_dev';

  static String _hex(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<String?> _readExt() async {
    try {
      final f = File(_externalPath);
      if (await f.exists()) {
        final t = (await f.readAsString()).trim();
        if (RegExp(r'^[0-9a-f]{24}$').hasMatch(t)) return t;
      }
    } catch (_) {}
    return null;
  }

  static Future<String> get() async {
    if (_id != null) return _id!;
    final docs = await getApplicationDocumentsDirectory();
    final f = File('${docs.path}/device.json');
    String? id;
    try {
      if (await f.exists()) id = (jsonDecode(await f.readAsString()) as Map)['id']?.toString();
    } catch (_) {}
    // The hidden copy wins: it survives "clear storage".
    final ext = (!kIsWeb && Platform.isAndroid) ? await _readExt() : null;
    id = ext ?? id ?? _hex(12);
    try {
      await f.writeAsString(jsonEncode({'id': id}));
    } catch (_) {}
    if (!kIsWeb && Platform.isAndroid && ext == null) {
      try {
        await File(_externalPath).writeAsString(id);
      } catch (_) {}
    }
    _id = id;
    return id;
  }
}

enum ClaimStatus { ok, conflict, offline }

class ClaimResult {
  final ClaimStatus status;
  final int claimTime; // relay clock (seconds) of the winning claim of this device
  const ClaimResult(this.status, [this.claimTime = 0]);
}

/// "One key, one device" without our own server.
///
/// Every key owns a private relay channel whose name and encryption key are
/// derived from the key itself, so only someone holding the key can read or
/// write it. The first device to activate publishes a claim there; every later
/// device first reads the channel and refuses if another device holds a claim.
/// The relay's own clock (not the phone's) orders competing claims, and the
/// earliest wins. The holder re-publishes its claim while the app is open, so
/// the claim stays alive on the relay (it keeps messages for about 12 hours).
class KeyClaims {
  static Uint8List secretFor(String key) {
    final h = sha256.convert(utf8.encode('immo-key-v1:${key.trim()}'));
    return Uint8List.fromList(h.bytes);
  }

  static String toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static Uint8List fromHex(String s) {
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// Earliest (claimTime, device) among all claims, or null if none.
  static MapEntry<String, int>? _winner(List<RelayMessage> msgs) {
    final best = <String, int>{};
    for (final m in msgs) {
      if (m.body['t'] != 'claim') continue;
      final dev = m.body['dev']?.toString() ?? '';
      var ct = (m.body['ct'] as num?)?.toInt() ?? 0;
      if (ct <= 0) ct = m.serverTime; // first claim: the relay's stamp is the claim time
      if (dev.isEmpty || ct <= 0) continue;
      if (!best.containsKey(dev) || ct < best[dev]!) best[dev] = ct;
    }
    MapEntry<String, int>? w;
    for (final e in best.entries) {
      if (w == null || e.value < w.value || (e.value == w.value && e.key.compareTo(w.key) < 0)) w = e;
    }
    return w;
  }

  /// First activation: refuses when another device already holds the key.
  static Future<ClaimResult> claim(Uint8List secret) async {
    final me = await DeviceId.get();
    final ch = RelayChannel(secret, (_) {});
    try {
      final before = _winner(await ch.pollAll());
      if (before != null && before.key != me) return const ClaimResult(ClaimStatus.conflict);
      var t = before?.value ?? 0;
      if (before == null) {
        final pub = await ch.publishForTime({'t': 'claim', 'dev': me, 'ct': 0});
        if (pub == null || pub <= 0) return const ClaimResult(ClaimStatus.offline);
        t = pub;
      }
      // Two devices racing for the same key: re-read and let the earliest win.
      await Future.delayed(const Duration(seconds: 2));
      final after = _winner(await ch.pollAll());
      if (after != null && after.key != me) return const ClaimResult(ClaimStatus.conflict);
      return ClaimResult(ClaimStatus.ok, t);
    } catch (e) {
      debugPrint('claim: $e');
      return const ClaimResult(ClaimStatus.offline);
    }
  }

  /// Periodic check by the holder: renews the claim and detects a rival
  /// that is older than this one (then this device loses the key).
  static Future<ClaimStatus> verify(Uint8List secret, int myClaimTime) async {
    final me = await DeviceId.get();
    final ch = RelayChannel(secret, (_) {});
    try {
      final published = await ch.publishForTime({'t': 'claim', 'dev': me, 'ct': myClaimTime});
      if (published == null) return ClaimStatus.offline;
      final w = _winner(await ch.pollAll());
      if (w != null && w.key != me) return ClaimStatus.conflict;
      return ClaimStatus.ok;
    } catch (e) {
      debugPrint('verify: $e');
      return ClaimStatus.offline;
    }
  }
}
