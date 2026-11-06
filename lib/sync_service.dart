import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'crypto_layers.dart';
import 'license.dart';
import 'key_claims.dart';
import 'property_model.dart';
import 'relay.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

String _randomHex(int bytes) {
  final r = Random.secure();
  return List<int>.generate(bytes, (_) => r.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class DeviceIdentity {
  static String? _name;

  static Future<String> id() => DeviceId.get();

  static Future<String> name() async {
    if (_name != null) return _name!;
    try {
      final i = await DeviceInfoPlugin().androidInfo;
      _name = '${i.manufacturer} ${i.model}';
    } catch (_) {
      _name = 'Android';
    }
    return _name!;
  }
}

class DeviceRecord {
  final String id;
  String name;
  String platform;
  double? lat;
  double? lon;
  int loginAt;
  int lastSeen;
  bool isSelf;
  bool offline;

  DeviceRecord({
    required this.id,
    required this.name,
    this.platform = 'Android',
    this.lat,
    this.lon,
    this.loginAt = 0,
    this.lastSeen = 0,
    this.isSelf = false,
    this.offline = false,
  });

  bool get online => isSelf || !offline && DateTime.now().millisecondsSinceEpoch - lastSeen < const Duration(minutes: 3).inMilliseconds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        'lat': lat,
        'lon': lon,
        'loginAt': loginAt,
        'lastSeen': lastSeen,
        'offline': offline,
      };

  factory DeviceRecord.fromJson(Map<String, dynamic> j) => DeviceRecord(
        id: j['id'].toString(),
        name: j['name']?.toString() ?? '?',
        platform: j['platform']?.toString() ?? 'Android',
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        loginAt: (j['loginAt'] as num?)?.toInt() ?? 0,
        lastSeen: (j['lastSeen'] as num?)?.toInt() ?? 0,
        offline: j['offline'] == true,
      );
}

/// Keeps this device in sync with the owner's other devices: heartbeats for the
/// "connected devices" page and the "is this you?" login approval.
class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  final ValueNotifier<List<DeviceRecord>> devices = ValueNotifier<List<DeviceRecord>>([]);
  final Map<String, DeviceRecord> _registry = {};
  final Set<String> _handledRequests = {};
  RelayChannel? _channel;
  RelayChannel? _inbox;
  final Set<String> _seenShares = {};
  bool _shareDialogOpen = false;
  Timer? _beatTimer;
  bool _started = false;
  bool _approvalOpen = false;
  String _selfId = '';
  String _selfName = '';
  int _loginAt = 0;
  double? _lat;
  double? _lon;

  int get _now => DateTime.now().millisecondsSinceEpoch;

  Future<void> start() async {
    if (_started || kIsWeb || !Platform.isAndroid) return;
    final secret = await AccountStore.instance.secretBytes();
    if (secret == null) return; // account from an older build: log in again once
    _started = true;
    _selfId = await DeviceIdentity.id();
    _selfName = await DeviceIdentity.name();
    _loginAt = await AccountStore.instance.loginAt();
    await _loadRegistry();
    _channel = RelayChannel(secret, _onMessage);
    await _channel!.start();
    await _startInbox();
    _updateLocation();
    await hello();
    _beatTimer = Timer.periodic(const Duration(seconds: 60), (_) => sendBeat());
  }

  Future<void> stop() async {
    _started = false;
    _beatTimer?.cancel();
    _channel?.stop();
    _channel = null;
    _inbox?.stop();
    _inbox = null;
  }

  /// App went to the background: tell the other devices this one is offline.
  Future<void> goOffline() async {
    if (!_started) return;
    await _channel?.publish({'t': 'bye', 'dev': _selfId, 'ts': _now});
    await stop();
  }

  /// Logout: other devices remove this device from their list until it logs in again.
  Future<void> announceLogout() async {
    if (_started) {
      await _channel?.publish({'t': 'logout', 'dev': _selfId, 'ts': _now});
      await stop();
    }
    _registry.clear();
    devices.value = [];
    await _saveRegistry();
  }

  /// Deletes the account and every property/request on this device. With
  /// [everywhere] the owner's other devices are told to wipe themselves too.
  Future<void> deleteAccount({required bool everywhere}) async {
    final secret = await AccountStore.instance.secretBytes();
    final selfId = await DeviceIdentity.id();
    if (everywhere && secret != null) {
      final ch = _channel ?? RelayChannel(secret, (_) {});
      await ch.prepare();
      await ch.publish({'t': 'wipeAccount', 'dev': selfId, 'ts': _now});
    } else {
      await announceLogout();
    }
    await stop();
    await LicenseStore.instance.wipeAllData(); // data + account file
    _registry.clear();
    devices.value = [];
    await _saveRegistry();
    dataRevision.value++;
    authRevision.value++;
  }

  Future<void> _wipedRemotely() async {
    await stop();
    await LicenseStore.instance.wipeAllData();
    _registry.clear();
    devices.value = [];
    await _saveRegistry();
    dataRevision.value++;
    authRevision.value++;
  }

  Future<void> _updateLocation() async {
    try {
      final status = await Permission.location.request();
      if (!status.isGranted || !await Geolocator.isLocationServiceEnabled()) return;
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.low, timeLimit: Duration(seconds: 15)),
      );
      _lat = pos.latitude;
      _lon = pos.longitude;
    } catch (e) {
      debugPrint('location: $e');
    }
  }

  /// "Who is online?" - every device answers with a heartbeat.
  Future<void> hello() async {
    await _channel?.publish({'t': 'hello', 'dev': _selfId, 'ts': _now});
    await sendBeat();
  }

  Future<void> sendBeat() async {
    if (!_started) return;
    _record(DeviceRecord(
      id: _selfId,
      name: _selfName,
      lat: _lat,
      lon: _lon,
      loginAt: _loginAt,
      lastSeen: _now,
      isSelf: true,
    ));
    await _channel?.publish({
      't': 'beat',
      'dev': _selfId,
      'name': _selfName,
      'platform': 'Android',
      'lat': _lat,
      'lon': _lon,
      'loginAt': _loginAt,
      'ts': _now,
    });
  }

  void _onMessage(Map<String, dynamic> m) {
    final dev = m['dev']?.toString() ?? '';
    if (dev == _selfId) return;
    switch (m['t']) {
      case 'hello':
        Future.delayed(Duration(milliseconds: 300 + Random().nextInt(2500)), sendBeat);
        break;
      case 'beat':
        _record(DeviceRecord(
          id: dev,
          name: m['name']?.toString() ?? '?',
          platform: m['platform']?.toString() ?? 'Android',
          lat: (m['lat'] as num?)?.toDouble(),
          lon: (m['lon'] as num?)?.toDouble(),
          loginAt: (m['loginAt'] as num?)?.toInt() ?? 0,
          lastSeen: (m['ts'] as num?)?.toInt() ?? _now,
        ));
        break;
      case 'bye':
        final r = _registry[dev];
        if (r != null) {
          r.offline = true;
          r.lastSeen = (m['ts'] as num?)?.toInt() ?? _now;
          _record(r);
        }
        break;
      case 'logout':
        if (_registry.remove(dev) != null) {
          devices.value = _sorted();
          _saveRegistry();
        }
        break;
      case 'loginReq':
        _askApproval(m);
        break;
      case 'wipeAccount':
        // Ignore stale copies from the relay cache that predate this login.
        if (((m['ts'] as num?)?.toInt() ?? 0) > _loginAt) _wipedRemotely();
        break;
    }
  }

  List<DeviceRecord> _sorted() => _registry.values.toList()
    ..sort((a, b) {
      if (a.isSelf != b.isSelf) return a.isSelf ? -1 : 1;
      return b.lastSeen.compareTo(a.lastSeen);
    });

  // ---------------- sharing a property with another user ----------------

  Future<File> _seenFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/inbox_seen.json');
  }

  Future<void> _startInbox() async {
    final user = await AccountStore.instance.username();
    if (user == null) return;
    try {
      final f = await _seenFile();
      if (await f.exists()) _seenShares.addAll((jsonDecode(await f.readAsString()) as List).map((e) => e.toString()));
    } catch (_) {}
    final secret = await AccountCrypto.inboxSecret(user);
    _inbox = RelayChannel(secret, (m) {
      if (m['t'] == 'share') _handleShare(m);
    }, since: '12h');
    await _inbox!.start();
  }

  /// Sends the property details (no owner contact, no media) to another user.
  static Future<String?> sendShare(String toUsername, Map<String, dynamic> property) async {
    final me = await AccountStore.instance.username();
    if (me == null) return 'سجّل الدخول أولا.';
    final to = toUsername.trim();
    if (to.length < 5 || !to.contains('#')) return 'اكتب اسم المستخدم كاملا مع الرمز (مثال: ahmed#a7k2).';
    if (to.toLowerCase() == me.toLowerCase()) return 'لا يمكنك المشاركة مع نفسك.';
    final channel = RelayChannel(await AccountCrypto.inboxSecret(to), (_) {});
    await channel.prepare();
    final ok = await channel.publish({
      't': 'share',
      'rid': _randomHex(8),
      'from': me,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'property': property,
    });
    return ok ? null : 'تعذر الإرسال. تحقق من الاتصال بالإنترنت.';
  }

  Future<void> _handleShare(Map<String, dynamic> m) async {
    final rid = m['rid']?.toString() ?? '';
    final ts = (m['ts'] as num?)?.toInt() ?? 0;
    final from = m['from']?.toString() ?? '';
    final prop = m['property'];
    if (rid.isEmpty || from.isEmpty || prop is! Map<String, dynamic> || _seenShares.contains(rid)) return;
    if ((_now - ts).abs() > const Duration(hours: 12).inMilliseconds) return;
    if (_shareDialogOpen) return; // the next one is shown when the inbox replays
    _shareDialogOpen = true;
    try {
      final ctx = appNavigatorKey.currentState?.overlay?.context;
      if (ctx == null || !ctx.mounted) return;
      _seenShares.add(rid);
      try {
        await (await _seenFile()).writeAsString(jsonEncode(_seenShares.toList()));
      } catch (_) {}

      final accept = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          backgroundColor: const Color(0xFF121C3A),
          title: const Text('عقار مشارَك معك', style: TextStyle(color: Color(0xFF8FEFEF))),
          content: Text(
            'المستخدم $from شاركك عقارا:\n\n${prop['category'] ?? ''} (${prop['city'] ?? ''} - ${prop['quartier'] ?? ''})\nالثمن: ${prop['price'] ?? ''} درهم\n\nهل تريد إضافته إلى عقاراتك؟',
            style: const TextStyle(color: Color(0xFFCBD5E1)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('رفض', style: TextStyle(color: Colors.redAccent))),
            ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('إضافة')),
          ],
        ),
      );
      if (accept == true) await _saveSharedProperty(from, prop);
    } finally {
      _shareDialogOpen = false;
    }
  }

  Future<void> _saveSharedProperty(String from, Map<String, dynamic> p) async {
    try {
      String safe(String v) => v.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
      final docs = await getApplicationDocumentsDirectory();
      final category = safe(p['category']?.toString() ?? 'عقار');
      final base = Directory('${docs.path}/uploads/$category/${safe(p['city']?.toString() ?? '')}/${safe(p['quartier']?.toString() ?? '')}');
      await base.create(recursive: true);
      var n = 1;
      while (await Directory('${base.path}/$category $n').exists()) {
        n++;
      }
      final dir = Directory('${base.path}/$category $n');
      await dir.create(recursive: true);
      final prop = Property(
        id: n,
        category: p['category']?.toString() ?? '',
        type: p['type']?.toString() ?? 'sell',
        city: p['city']?.toString() ?? '',
        quartier: p['quartier']?.toString() ?? '',
        area: p['area']?.toString() ?? '',
        description: p['description']?.toString() ?? '',
        price: p['price']?.toString() ?? '',
        createdAt: DateTime.now().toString(),
        images: const [],
        path: dir.path,
        sharedBy: from,
      );
      await File('${dir.path}/data.json').writeAsString(jsonEncode(prop.toJson()));
      dataRevision.value++;
    } catch (e) {
      debugPrint('save shared property: $e');
    }
  }

  void _record(DeviceRecord r) {
    _registry[r.id] = r;
    final list = _registry.values.toList()
      ..sort((a, b) {
        if (a.isSelf != b.isSelf) return a.isSelf ? -1 : 1;
        return b.lastSeen.compareTo(a.lastSeen);
      });
    devices.value = list;
    _saveRegistry();
  }

  Future<File> _registryFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/devices.json');
  }

  Future<void> _loadRegistry() async {
    try {
      final f = await _registryFile();
      if (await f.exists()) {
        for (final e in (jsonDecode(await f.readAsString()) as List)) {
          final r = DeviceRecord.fromJson(e as Map<String, dynamic>);
          if (r.id != _selfId) _registry[r.id] = r;
        }
        devices.value = _registry.values.toList();
      }
    } catch (_) {}
  }

  Future<void> _saveRegistry() async {
    try {
      await (await _registryFile()).writeAsString(jsonEncode(_registry.values.map((r) => r.toJson()).toList()));
    } catch (_) {}
  }

  /// Another device logged in with this account's username + password:
  /// ask the owner "is this you?" and require all credentials before approving.
  Future<void> _askApproval(Map<String, dynamic> m) async {
    final rid = m['rid']?.toString() ?? '';
    final ts = (m['ts'] as num?)?.toInt() ?? 0;
    if (rid.isEmpty || _handledRequests.contains(rid)) return;
    if ((_now - ts).abs() > const Duration(minutes: 10).inMilliseconds) return;
    if (_approvalOpen) return;
    _handledRequests.add(rid);
    _approvalOpen = true;
    try {
      final ctx = appNavigatorKey.currentState?.overlay?.context;
      if (ctx == null || !ctx.mounted) return;

      final isMe = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          backgroundColor: const Color(0xFF121C3A),
          title: const Text('محاولة تسجيل دخول', style: TextStyle(color: Colors.redAccent)),
          content: Text(
            'هناك محاولة تسجيل دخول إلى حسابك من الجهاز: ${m['name'] ?? '?'}.\n\nهل هذا أنت؟',
            style: const TextStyle(color: Color(0xFFCBD5E1)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('لا، ارفض', style: TextStyle(color: Colors.redAccent))),
            ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('نعم، هذا أنا')),
          ],
        ),
      );
      if (isMe != true) {
        await _channel?.publish({'t': 'loginDeny', 'rid': rid, 'dev': _selfId, 'ts': _now});
        return;
      }
      if (!ctx.mounted) return;

      final user = TextEditingController();
      final pass = TextEditingController();
      final dev = TextEditingController();
      String? error;
      final verified = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (c) => StatefulBuilder(
          builder: (c, setS) => AlertDialog(
            backgroundColor: const Color(0xFF121C3A),
            title: const Text('تأكيد الهوية'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: user, decoration: const InputDecoration(labelText: 'اسم المستخدم')),
                  const SizedBox(height: 8),
                  TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور')),
                  const SizedBox(height: 8),
                  TextField(controller: dev, obscureText: true, decoration: InputDecoration(labelText: 'كلمة مرور الهاتف', errorText: error)),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('رفض')),
              ElevatedButton(
                onPressed: () async {
                  final stored = await AccountStore.instance.username();
                  final ok = stored != null &&
                      stored.toLowerCase() == user.text.trim().toLowerCase() &&
                      await AccountStore.instance.verifyPasswords(pass.text, dev.text);
                  if (ok) {
                    if (c.mounted) Navigator.pop(c, true);
                  } else {
                    setS(() => error = 'بيانات غير صحيحة');
                  }
                },
                child: const Text('تأكيد'),
              ),
            ],
          ),
        ),
      );
      user.dispose();
      pass.dispose();
      dev.dispose();

      if (verified != true) {
        await _channel?.publish({'t': 'loginDeny', 'rid': rid, 'dev': _selfId, 'ts': _now});
        return;
      }
      final lic = await LicenseStore.instance.load();
      final account = await AccountStore.instance.exportForTransfer(lic);
      await _channel?.publish({'t': 'loginApprove', 'rid': rid, 'dev': _selfId, 'account': account, 'ts': _now});
    } finally {
      _approvalOpen = false;
    }
  }
}

/// Logging in on a new device: needs the approval of a device that is already logged in.
class RemoteLogin {
  /// Returns null on success, otherwise an Arabic error message.
  static Future<String?> attempt(String username, String password, String devicePassword) async {
    final secret = await AccountCrypto.deriveSecret(username, password);
    final rid = _randomHex(8);
    final completer = Completer<Map<String, dynamic>?>();
    final channel = RelayChannel(secret, (m) {
      if (m['rid'] != rid || completer.isCompleted) return;
      if (m['t'] == 'loginApprove') completer.complete(m);
      if (m['t'] == 'loginDeny') completer.complete(null);
    });
    await channel.start();
    try {
      final sent = await channel.publish({
        't': 'loginReq',
        'rid': rid,
        'dev': await DeviceIdentity.id(),
        'name': await DeviceIdentity.name(),
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      if (!sent) return 'تعذر الاتصال بالإنترنت.';

      final Map<String, dynamic>? reply;
      try {
        reply = await completer.future.timeout(const Duration(minutes: 5));
      } on TimeoutException {
        return 'لم يستجب أي جهاز. تأكد من البيانات وافتح التطبيق على جهازك الآخر ثم أعد المحاولة.';
      }
      if (reply == null) return 'تم رفض محاولة الدخول من الجهاز الآخر.';

      final account = reply['account'];
      if (account is! Map<String, dynamic>) return 'ردّ غير صالح من الجهاز الآخر.';
      await AccountStore.instance.importFromTransfer(account);
      final ok = await AccountStore.instance.login(username, password, devicePassword);
      if (!ok) {
        await AccountStore.instance.delete();
        authRevision.value++;
        return 'كلمة مرور الهاتف غير صحيحة.';
      }
      return null;
    } finally {
      channel.stop();
    }
  }
}
