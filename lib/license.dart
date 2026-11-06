import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'crypto_layers.dart';
import 'key_claims.dart';
import 'key_hashes.dart';

/// Version number of THIS build. Must match the N in the release file ImmoV<N>.apk.
/// Bump it (and pubspec's build number) for every release you publish.
const int kAppVersion = 1;

/// Bumped whenever the stored data changes outside a HomeScreen (after a
/// transfer or a received share), so every list reloads itself.
final ValueNotifier<int> dataRevision = ValueNotifier<int>(0);

/// Bumped whenever the license or account changes, so the gates rebuild.
final ValueNotifier<int> authRevision = ValueNotifier<int>(0);

const Duration kTrialDuration = Duration(hours: 24);

String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();

bool isKeyFormatValid(String k) => RegExp(r'^[A-Za-z0-9]{40}$').hasMatch(k);

/// revoked = the key is held by an older device; needsOnline = not verified online
/// for too long (never saved to disk, only returned by evaluate()).
enum LicenseType { none, trial, permanent, expired, revoked, needsOnline }

/// How long a key-activated license may run without an online check.
const Duration kVerifyGrace = Duration(days: 7);
/// How often an open app renews/verifies its key claim.
const Duration kVerifyEvery = Duration(minutes: 25);

class LicenseState {
  LicenseType type;
  int activatedAt; // ms since epoch (trial start)
  int lastSeen; // ms since epoch (clock-rollback detection)
  int ignoredVersion; // update popup already dismissed for this version
  Set<String> used; // hashes of consumed keys
  int seq; // bumped on each save; decides which copy is newer
  bool viaAccount; // license inherited from another device through the account
  String claimSecret; // hex of the key-derived relay secret (never the key itself)
  int claimTime; // relay clock (s) of this device's claim
  int lastVerified; // ms, last successful online check

  LicenseState({
    this.type = LicenseType.none,
    this.activatedAt = 0,
    this.lastSeen = 0,
    this.ignoredVersion = 0,
    Set<String>? used,
    this.seq = 0,
    this.viaAccount = false,
    this.claimSecret = '',
    this.claimTime = 0,
    this.lastVerified = 0,
  }) : used = used ?? <String>{};

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'activatedAt': activatedAt,
        'lastSeen': lastSeen,
        'ignoredVersion': ignoredVersion,
        'used': used.toList(),
        'seq': seq,
        'viaAccount': viaAccount,
        'claimSecret': claimSecret,
        'claimTime': claimTime,
        'lastVerified': lastVerified,
      };

  factory LicenseState.fromJson(Map<String, dynamic> j) => LicenseState(
        type: LicenseType.values.firstWhere((t) => t.name == j['type'], orElse: () => LicenseType.none),
        activatedAt: (j['activatedAt'] as num?)?.toInt() ?? 0,
        lastSeen: (j['lastSeen'] as num?)?.toInt() ?? 0,
        ignoredVersion: (j['ignoredVersion'] as num?)?.toInt() ?? 0,
        used: ((j['used'] as List?) ?? []).map((e) => e.toString()).toSet(),
        seq: (j['seq'] as num?)?.toInt() ?? 0,
        viaAccount: j['viaAccount'] == true,
        claimSecret: j['claimSecret']?.toString() ?? '',
        claimTime: (j['claimTime'] as num?)?.toInt() ?? 0,
        lastVerified: (j['lastVerified'] as num?)?.toInt() ?? 0,
      );

  Duration get trialRemaining {
    final end = DateTime.fromMillisecondsSinceEpoch(activatedAt).add(kTrialDuration);
    final left = end.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }
}

/// Keeps the license in two places (app storage + a hidden file in the phone
/// storage) so that clearing the app's data does not reset a trial or free a key.
class LicenseStore {
  LicenseStore._();
  static final LicenseStore instance = LicenseStore._();

  static const String _externalPath = '/storage/emulated/0/.immo_lic';

  Future<File> _docsFile() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/license.json');
  }

  Future<LicenseState?> _read(File f) async {
    try {
      if (await f.exists()) {
        return LicenseState.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      }
    } catch (_) {}
    return null;
  }

  Future<LicenseState> load() async {
    final docs = await _read(await _docsFile());
    final ext = (!kIsWeb && Platform.isAndroid) ? await _read(File(_externalPath)) : null;
    if (docs == null && ext == null) return LicenseState();
    if (docs == null) return ext!;
    if (ext == null) return docs;
    final base = ext.seq > docs.seq ? ext : docs;
    base.used = {...docs.used, ...ext.used};
    base.lastSeen = max(docs.lastSeen, ext.lastSeen);
    base.ignoredVersion = max(docs.ignoredVersion, ext.ignoredVersion);
    return base;
  }

  Future<void> save(LicenseState s) async {
    s.seq++;
    final text = jsonEncode(s.toJson());
    try {
      await (await _docsFile()).writeAsString(text);
    } catch (e) {
      debugPrint('license save (docs): $e');
    }
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await File(_externalPath).writeAsString(text);
      } catch (e) {
        debugPrint('license save (external): $e');
      }
    }
  }

  /// Loads the license and applies trial expiry. Expiry wipes all app data.
  Future<LicenseState> evaluate() async {
    final s = await load();
    final now = DateTime.now().millisecondsSinceEpoch;
    // A license that only came from another device through the account is
    // worthless without that account: after "clear storage" the key stage returns.
    if (s.viaAccount && (s.type == LicenseType.trial || s.type == LicenseType.permanent) && !await AccountStore.instance.exists()) {
      s.type = LicenseType.none;
      s.viaAccount = false;
      s.activatedAt = 0;
      await save(s);
      authRevision.value++;
      return s;
    }
    if (s.type == LicenseType.trial) {
      final clockRolledBack = now < s.lastSeen - const Duration(minutes: 2).inMilliseconds;
      final expired = now >= s.activatedAt + kTrialDuration.inMilliseconds;
      if (clockRolledBack || expired) {
        await wipeAllData();
        s.type = LicenseType.expired;
        await save(s);
        authRevision.value++;
        return s;
      }
    }
    if (now > s.lastSeen) {
      s.lastSeen = now;
      await save(s);
    }
    // Key-activated licenses must be re-verified online at least every 7 days.
    if (s.claimSecret.isNotEmpty && (s.type == LicenseType.trial || s.type == LicenseType.permanent)) {
      final effNow = max(now, s.lastSeen);
      if (effNow - s.lastVerified > kVerifyGrace.inMilliseconds) {
        return LicenseState.fromJson({...s.toJson(), 'type': LicenseType.needsOnline.name});
      }
    }
    return s;
  }

  /// Renews this device's claim on its key and detects a rival that is older.
  /// Returns true when the license is still valid (or could not be checked).
  Future<bool> verifyClaim() async {
    final s = await load();
    if (s.claimSecret.isEmpty || (s.type != LicenseType.trial && s.type != LicenseType.permanent)) return true;
    final r = await KeyClaims.verify(KeyClaims.fromHex(s.claimSecret), s.claimTime);
    if (r == ClaimStatus.conflict) {
      s.type = LicenseType.revoked;
      await save(s);
      authRevision.value++;
      return false;
    }
    if (r == ClaimStatus.ok) {
      s.lastVerified = DateTime.now().millisecondsSinceEpoch;
      await save(s);
      authRevision.value++;
    }
    return true;
  }

  /// null = key is usable. Otherwise an Arabic error message.
  Future<String?> checkKey(String raw, {required bool permanentOnly}) async {
    final key = raw.trim();
    if (!isKeyFormatValid(key)) return 'المفتاح يجب أن يتكون من 40 حرفا ورقما.';
    final h = sha256Hex(key);
    final s = await load();
    if (s.used.contains(h)) return 'هذا المفتاح مستعمل من قبل ولم يعد صالحا.';
    final isTrial = trialKeyHashes.contains(h);
    final isPerm = permanentKeyHashes.contains(h);
    if (!isTrial && !isPerm) return 'المفتاح غير صحيح.';
    if (permanentOnly && !isPerm) return 'يلزم مفتاح دائم لهذه العملية.';
    if (isTrial && s.type != LicenseType.none) return 'لا يمكن استعمال مفتاح تجريبي الآن.';
    return null;
  }

  /// Activates the app with a trial or permanent key. null = success.
  Future<String?> activate(String raw) async {
    final err = await checkKey(raw, permanentOnly: false);
    if (err != null) return err;
    final key = raw.trim();
    final h = sha256Hex(key);
    // Single use across devices: claim the key on the relay first.
    final secret = KeyClaims.secretFor(key);
    final claim = await KeyClaims.claim(secret);
    if (claim.status == ClaimStatus.conflict) return 'هذا المفتاح مستعمل على جهاز آخر ولم يعد صالحا.';
    if (claim.status == ClaimStatus.offline) return 'يلزم اتصال بالإنترنت للتحقق من المفتاح. حاول مرة أخرى.';
    final s = await load();
    final now = DateTime.now().millisecondsSinceEpoch;
    s.claimSecret = KeyClaims.toHex(secret);
    s.claimTime = claim.claimTime;
    s.lastVerified = now;
    s.viaAccount = false;
    s.used.add(h);
    s.lastSeen = max(s.lastSeen, now);
    if (permanentKeyHashes.contains(h)) {
      s.type = LicenseType.permanent;
    } else {
      s.type = LicenseType.trial;
      s.activatedAt = now;
    }
    await save(s);
    authRevision.value++;
    return null;
  }

  /// Update keys: claims the key on the relay before anything is downloaded.
  /// null = this device now holds the key.
  Future<String?> claimOnly(String raw) async {
    final claim = await KeyClaims.claim(KeyClaims.secretFor(raw.trim()));
    if (claim.status == ClaimStatus.conflict) return 'هذا المفتاح مستعمل على جهاز آخر ولم يعد صالحا.';
    if (claim.status == ClaimStatus.offline) return 'يلزم اتصال بالإنترنت للتحقق من المفتاح.';
    return null;
  }

  /// Marks a permanent key as consumed (used for paid updates).
  Future<void> consumeKey(String raw) async {
    final s = await load();
    s.used.add(sha256Hex(raw.trim()));
    await save(s);
  }

  /// A permanent account imported from another device carries the license with it.
  Future<void> activatePermanentViaAccount() async {
    final s = await load();
    if (s.type == LicenseType.revoked) return; // a revoked key is not restored through an account
    if (s.type == LicenseType.permanent && s.claimSecret.isNotEmpty) return; // already holds its own key
    s.type = LicenseType.permanent;
    s.viaAccount = true;
    await save(s);
    authRevision.value++;
  }

  Future<void> activateTrialViaAccount(int activatedAt) async {
    final s = await load();
    if (s.type != LicenseType.none || activatedAt <= 0) return;
    s.type = LicenseType.trial;
    s.viaAccount = true;
    s.activatedAt = activatedAt;
    s.lastSeen = max(s.lastSeen, DateTime.now().millisecondsSinceEpoch);
    await save(s);
    authRevision.value++;
  }

  Future<int> getIgnoredVersion() async => (await load()).ignoredVersion;

  Future<void> setIgnoredVersion(int v) async {
    final s = await load();
    if (v > s.ignoredVersion) {
      s.ignoredVersion = v;
      await save(s);
    }
  }

  /// Deletes every property/request, the voice/video files and the account.
  Future<void> wipeAllData() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      for (final name in ['uploads', 'requests', 'uploads_incoming', 'requests_incoming']) {
        final d = Directory('${docs.path}/$name');
        if (await d.exists()) await d.delete(recursive: true);
      }
      await AccountStore.instance.delete();
    } catch (e) {
      debugPrint('wipeAllData: $e');
    }
  }
}

/// Local account. Only salted PBKDF2 hashes are stored, never the passwords.
class AccountStore {
  AccountStore._();
  static final AccountStore instance = AccountStore._();

  Future<File> _file() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/account.json');
  }

  Future<Map<String, dynamic>?> _read() async {
    try {
      final f = await _file();
      if (await f.exists()) return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
    return null;
  }

  Future<void> _write(Map<String, dynamic> m) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(m));
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  static Uint8List _pbkdf2(String password, List<int> salt, {int iterations = 10000}) {
    final hmac = Hmac(sha256, utf8.encode(password));
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final t = List<int>.from(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    return Uint8List.fromList(t);
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static bool _check(String password, String saltB64, String hashB64) =>
      _same(_pbkdf2(password, base64Decode(saltB64)), base64Decode(hashB64));

  Future<bool> exists() async => (await _read()) != null;
  Future<String?> username() async => (await _read())?['username']?.toString();
  Future<Uint8List?> secretBytes() async {
    final s = (await _read())?['secret']?.toString();
    return s == null ? null : base64Decode(s);
  }

  Future<int> loginAt() async => ((await _read())?['loginAt'] as num?)?.toInt() ?? 0;

  Future<bool> isLoggedIn() async => (await _read())?['loggedIn'] == true;

  Future<void> create(String username, String password, String devicePassword) async {
    final salt = _randomBytes(16), dsalt = _randomBytes(16);
    final secret = await AccountCrypto.deriveSecret(username, password);
    await _write({
      'secret': base64Encode(secret),
      'loginAt': DateTime.now().millisecondsSinceEpoch,
      'username': username.trim(),
      'salt': base64Encode(salt),
      'hash': base64Encode(_pbkdf2(password, salt)),
      'dsalt': base64Encode(dsalt),
      'dhash': base64Encode(_pbkdf2(devicePassword, dsalt)),
      'loggedIn': true,
    });
    authRevision.value++;
  }

  Future<bool> verifyPasswords(String password, String devicePassword) async {
    final a = await _read();
    if (a == null) return false;
    return _check(password, a['salt'], a['hash']) && _check(devicePassword, a['dsalt'], a['dhash']);
  }

  Future<bool> login(String username, String password, String devicePassword) async {
    final a = await _read();
    if (a == null) return false;
    if (a['username'].toString().toLowerCase() != username.trim().toLowerCase()) return false;
    if (!await verifyPasswords(password, devicePassword)) return false;
    a['loggedIn'] = true;
    a['loginAt'] = DateTime.now().millisecondsSinceEpoch;
    a['secret'] ??= base64Encode(await AccountCrypto.deriveSecret(username, password));
    await _write(a);
    authRevision.value++;
    return true;
  }

  Future<void> logout() async {
    final a = await _read();
    if (a == null) return;
    a['loggedIn'] = false;
    await _write(a);
    authRevision.value++;
  }

  Future<void> delete() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Account data sent to another of the owner's devices (hashes only).
  Future<Map<String, dynamic>?> exportForTransfer(LicenseState lic) async {
    final a = await _read();
    if (a == null) return null;
    return {
      'username': a['username'],
      'salt': a['salt'],
      'hash': a['hash'],
      'dsalt': a['dsalt'],
      'dhash': a['dhash'],
      'permanent': lic.type == LicenseType.permanent,
      'trial': lic.type == LicenseType.trial,
      'activatedAt': lic.activatedAt,
    };
  }

  Future<void> importFromTransfer(Map<String, dynamic> m) async {
    if (m['username'] == null || m['salt'] == null || m['hash'] == null || m['dsalt'] == null || m['dhash'] == null) return;
    await _write({
      'username': m['username'],
      'salt': m['salt'],
      'hash': m['hash'],
      'dsalt': m['dsalt'],
      'dhash': m['dhash'],
      'loggedIn': false, // the owner must log in on this device
    });
    if (m['permanent'] == true) {
      await LicenseStore.instance.activatePermanentViaAccount();
    } else if (m['trial'] == true) {
      // Same trial, same end time: a second device cannot extend it.
      await LicenseStore.instance.activateTrialViaAccount((m['activatedAt'] as num?)?.toInt() ?? 0);
    }
    authRevision.value++;
  }
}
