import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'license_pubkey.dart';

enum KeyPlatform { any, android, ios, windows, macos, linux }

class KeyInfo {
  final KeyPlatform platform;
  final int days; // 0 = forever
  final String nonceHex;
  final String bindHex; // fingerprint of (user name + phone) the key was issued for
  final String canonical; // normalized key text (used for hashing / relay channel)
  KeyInfo(this.platform, this.days, this.nonceHex, this.bindHex, this.canonical);

  bool get forever => days == 0;
  Duration get duration => Duration(days: days);
}

/// Keys are Ed25519-signed tokens made by tools/immo_keygen.py. The app only holds the
/// public key, so keys cannot be forged by reading the app.
class LicenseKeys {
  static const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  static final List<int> _magic = utf8.encode('IMMO1');

  static String canonicalize(String raw) => raw.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');

  static Uint8List? _b32decode(String s) {
    final out = <int>[];
    var buffer = 0, bits = 0;
    for (final ch in s.split('')) {
      final v = _alphabet.indexOf(ch);
      if (v < 0) return null;
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xFF);
        buffer &= (1 << bits) - 1;
      }
    }
    return Uint8List.fromList(out);
  }

  static KeyPlatform get currentPlatform {
    if (kIsWeb) return KeyPlatform.any;
    if (Platform.isAndroid) return KeyPlatform.android;
    if (Platform.isIOS) return KeyPlatform.ios;
    if (Platform.isWindows) return KeyPlatform.windows;
    if (Platform.isMacOS) return KeyPlatform.macos;
    if (Platform.isLinux) return KeyPlatform.linux;
    return KeyPlatform.any;
  }

  static String platformNameAr(KeyPlatform p) {
    switch (p) {
      case KeyPlatform.android:
        return 'أندرويد';
      case KeyPlatform.ios:
        return 'آيفون';
      case KeyPlatform.windows:
        return 'ويندوز';
      case KeyPlatform.macos:
        return 'ماك';
      case KeyPlatform.linux:
        return 'لينكس';
      case KeyPlatform.any:
        return 'كل المنصات';
    }
  }

  static String normName(String n) => n.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Last 9 digits, so "+212 6xx" and "06xx" are the same number.
  static String normPhone(String p) {
    final d = p.replaceAll(RegExp(r'\D'), '');
    return d.length > 9 ? d.substring(d.length - 9) : d;
  }

  static String bindFor(String name, String phone) {
    final h = sha256.convert(utf8.encode('immo-bind-v1|${normName(name)}|${normPhone(phone)}')).bytes;
    return h.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Returns null when the text is not a genuine key made with the developer's private key.
  static Future<KeyInfo?> parse(String raw) async {
    if (kLicensePublicKey.every((b) => b == 0)) return null; // placeholder key: reject all
    final canon = canonicalize(raw);
    final data = _b32decode(canon);
    if (data == null || data.length < 83) return null;
    final payload = data.sublist(0, 19);
    final sig = data.sublist(19, 83);
    if (payload[0] != 1) return null;
    try {
      final ok = await Ed25519().verify(
        [..._magic, ...payload],
        signature: Signature(sig, publicKey: SimplePublicKey(kLicensePublicKey, type: KeyPairType.ed25519)),
      );
      if (!ok) return null;
    } catch (_) {
      return null;
    }
    final pIdx = payload[1];
    if (pIdx >= KeyPlatform.values.length) return null;
    String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return KeyInfo(KeyPlatform.values[pIdx], payload[2], hex(payload.sublist(3, 11)), hex(payload.sublist(11, 19)), canon);
  }
}
