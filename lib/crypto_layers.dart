import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// End-to-end encryption between the devices of one account.
///
/// The shared secret never leaves the devices: it is derived from the username
/// and password (PBKDF2). Messages go through a public relay as opaque text and
/// are wrapped in THREE independent layers:
///   1) ChaCha20-Poly1305   2) AES-256-GCM   3) XChaCha20-Poly1305
/// each with its own key derived from the secret with HKDF.
class AccountCrypto {
  static final Pbkdf2 _pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 20000, bits: 256);
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final Cipher _l1 = Chacha20.poly1305Aead();
  static final Cipher _l2 = AesGcm.with256bits();
  static final Cipher _l3 = Xchacha20.poly1305Aead();

  static Future<Uint8List> deriveSecret(String username, String password) async {
    final key = await _pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: utf8.encode('immo-account:${username.trim().toLowerCase()}'),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// Inbox key for receiving shares from other users. It is derived from the
  /// username only (people must be able to write to it), so it hides content
  /// from outsiders who do not know the username, but is not private against
  /// someone who does.
  static Future<Uint8List> inboxSecret(String username) async {
    final h = await Sha256().hash(utf8.encode('immo-inbox-v1:${username.trim().toLowerCase()}'));
    return Uint8List.fromList(h.bytes);
  }

  static Future<SecretKey> _sub(Uint8List secret, String label) =>
      _hkdf.deriveKey(secretKey: SecretKey(secret), nonce: utf8.encode('immo-v1'), info: utf8.encode(label));

  /// Unguessable relay channel name derived from the secret.
  static Future<String> topic(Uint8List secret) async {
    final bytes = await (await _sub(secret, 'topic')).extractBytes();
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'immo-${hex.substring(0, 40)}';
  }

  static Future<Uint8List> _enc(Cipher c, SecretKey k, List<int> data) async {
    final box = await c.encrypt(data, secretKey: k);
    return Uint8List.fromList(box.concatenation());
  }

  static Future<List<int>> _dec(Cipher c, SecretKey k, List<int> data) {
    final box = SecretBox.fromConcatenation(data, nonceLength: c.nonceLength, macLength: c.macAlgorithm.macLength);
    return c.decrypt(box, secretKey: k);
  }

  static Future<String> seal(Map<String, dynamic> message, Uint8List secret) async {
    final k1 = await _sub(secret, 'layer1');
    final k2 = await _sub(secret, 'layer2');
    final k3 = await _sub(secret, 'layer3');
    var data = await _enc(_l1, k1, utf8.encode(jsonEncode(message)));
    data = await _enc(_l2, k2, data);
    data = await _enc(_l3, k3, data);
    return base64Url.encode(data);
  }

  /// null when the text is not a valid message for this secret.
  static Future<Map<String, dynamic>?> open(String text, Uint8List secret) async {
    try {
      final k1 = await _sub(secret, 'layer1');
      final k2 = await _sub(secret, 'layer2');
      final k3 = await _sub(secret, 'layer3');
      var data = base64Url.decode(text.trim());
      data = Uint8List.fromList(await _dec(_l3, k3, data));
      data = Uint8List.fromList(await _dec(_l2, k2, data));
      data = Uint8List.fromList(await _dec(_l1, k1, data));
      return jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
