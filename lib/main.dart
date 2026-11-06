import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'property_model.dart';
import 'license.dart';
import 'device_lock.dart';
import 'stats.dart';
import 'account_screen.dart';
import 'auth_screens.dart';
import 'updater.dart';
import 'sync_service.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AyachImmoApp());
  // Never block (or crash) app start-up because of notifications.
  _initNotifications();
}

Future<void> _initNotifications() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    tz.initializeTimeZones();
    _setLocalTimeZone();

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    await flutterLocalNotificationsPlugin.initialize(initializationSettings);
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _scheduleDailyNotifications();
  } catch (e) {
    debugPrint('Notification init failed: $e');
  }
}

/// `tz.local` defaults to UTC; pick a zone matching the device's UTC offset so
/// "22:00" really is 22:00 local time.
void _setLocalTimeZone() {
  final offset = DateTime.now().timeZoneOffset;
  final nowUtc = DateTime.now().toUtc();
  for (final loc in tz.timeZoneDatabase.locations.values) {
    if (loc.name.contains('/') && !loc.name.startsWith('Etc/') &&
        Duration(milliseconds: loc.timeZone(nowUtc.millisecondsSinceEpoch).offset) == offset) {
      tz.setLocalLocation(loc);
      return;
    }
  }
}

/// Daily reminders every 2 hours from 08:00 to 22:00 (8, 10, ..., 22).
Future<void> _scheduleDailyNotifications() async {
  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'daily_sync_channel',
    'تحديث البيانات',
    channelDescription: 'تذكير بتحديث بيانات العقارات والطلبات',
    importance: Importance.max,
    priority: Priority.high,
  );

  final now = tz.TZDateTime.now(tz.local);
  int id = 0;
  for (int hour = 8; hour <= 22; hour += 2) {
    var scheduledDate = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, 0, 0);
    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }

    await flutterLocalNotificationsPlugin.zonedSchedule(
      id++, // same ids each launch => re-scheduling replaces, never duplicates
      'تحديث بيانات عقاراتي وطلباتي',
      'يرجى التأكد من تحديث ومزامنة عقاراتك وطلباتك لتفادي فقدان البيانات.',
      scheduledDate,
      const NotificationDetails(android: androidDetails),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }
}

class AyachImmoApp extends StatelessWidget {
  const AyachImmoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'Ayach Immo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B132B),
        primaryColor: const Color(0xFF8FEFEF),
        fontFamily: 'Amiri',
      ),
      locale: const Locale('ar', 'AR'),
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
      home: const StoragePermissionGate(
        child: LicenseGate(child: AuthGate(child: MainNavigationScreen())),
      ),
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Each time the app is opened: remove leftover update installers.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      cleanupUpdateApks();
      UpdateManager.instance.check(context);
      SyncService.instance.start();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      cleanupUpdateApks();
      UpdateManager.instance.check(context); // mandatory updates are re-checked on every return
      SyncService.instance.start().then((_) => SyncService.instance.hello());
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      SyncService.instance.goOffline(); // the app is closed -> shown as offline
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SyncService.instance.stop();
    super.dispose();
  }

  final List<Widget> _screens = const [
    HomeScreen(key: ValueKey('MyPropertiesPage'), isRequestsPage: false),
    HomeScreen(key: ValueKey('MyRequestsPage'), isRequestsPage: true),
    TransferScreen(key: ValueKey('TransferPage')),
    AccountScreen(key: ValueKey('AccountPage')),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const UpdateBar(),
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: _screens,
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _currentIndex,
        backgroundColor: const Color(0xFF121C3A),
        selectedItemColor: const Color(0xFF8FEFEF),
        unselectedItemColor: const Color(0xFF64748B),
        onTap: (index) {
          currentTab.value = index;
          setState(() => _currentIndex = index);
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded),
            label: 'عقاراتي',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.assignment_rounded),
            label: 'طلباتي',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.swap_horiz_rounded),
            label: 'النقل',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_rounded),
            label: 'حسابي',
          ),
        ],
      ),
    );
  }
}

enum TransferMode { send, receive }

class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key});

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  TransferMode _mode = TransferMode.send;
  bool _isProcessing = false;
  String _statusMessage = 'جاهز للبدء';
  final Strategy _strategy = Strategy.P2P_POINT_TO_POINT;
  static const String _serviceId = 'com.example.ayach.transfer';

  final Map<String, String> _discoveredDevices = {};
  String? _selectedEndpointId;

  // Receiver side: payload id -> content uri of the incoming file.
  final Map<int, String> _incomingFiles = {};
  // Sender side
  int? _outgoingPayloadId;
  File? _outgoingTempFile;

  void _setStatus(String msg, {bool? processing}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = msg;
      if (processing != null) _isProcessing = processing;
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _ensurePermissions() async {
    try {
      final statuses = await [
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.nearbyWifiDevices,
      ].request();
      // Permissions that don't exist on the running Android version come back
      // as granted/denied depending on the plugin; location is the one that
      // must be granted everywhere.
      final locationOk = statuses[Permission.location]?.isGranted ?? false;
      if (!locationOk) {
        _setStatus('يجب منح إذن الموقع والأجهزة القريبة لاستخدام النقل.');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('Permission error: $e');
      _setStatus('تعذر طلب الأذونات.');
      return false;
    }
  }

  Future<void> _handleStart() async {
    if (_isProcessing) return;
    if (!await _ensurePermissions()) return;
    if (_mode == TransferMode.send) {
      if (_selectedEndpointId == null) {
        await _startDiscovery();
      } else {
        _confirmAndStartSend();
      }
    } else {
      await _startAdvertising();
    }
  }

  Future<void> _startDiscovery() async {
    setState(() {
      _discoveredDevices.clear();
      _statusMessage = 'جاري البحث عن أجهزة قريبة...';
    });

    try {
      await Nearby().stopDiscovery();
      final myName = await DeviceIdentity.name();
      await Nearby().startDiscovery(
        myName,
        _strategy,
        serviceId: _serviceId,
        onEndpointFound: (endpointId, name, serviceId) {
          if (!mounted) return;
          setState(() {
            _discoveredDevices[endpointId] = name;
            _statusMessage = 'تم العثور على جهاز: $name';
          });
        },
        onEndpointLost: (endpointId) {
          if (!mounted) return;
          setState(() {
            _discoveredDevices.remove(endpointId);
            if (_selectedEndpointId == endpointId) _selectedEndpointId = null;
          });
        },
      );
    } catch (e) {
      debugPrint('خطأ في البحث: $e');
      _setStatus('تعذر البحث عن الأجهزة. تأكد من تفعيل البلوتوث والواي فاي والموقع.');
    }
  }

  Future<void> _startAdvertising() async {
    _setStatus('جهاز الاستقبال يعمل... في انتظار اتصال المرسل', processing: true);

    try {
      await Nearby().stopAdvertising();
      final myName = await DeviceIdentity.name();
      await Nearby().startAdvertising(
        myName,
        _strategy,
        serviceId: _serviceId,
        onConnectionInitiated: (endpointId, info) => _askToAcceptIncoming(endpointId, info),
        onConnectionResult: (endpointId, status) {
          if (status == Status.CONNECTED) {
            _setStatus('متصل بنجاح! يتم استقبال البيانات...');
          } else {
            _setStatus('تم رفض/فشل الاتصال.', processing: false);
          }
        },
        onDisconnected: (endpointId) {
          if (_isProcessing && _incomingFiles.isEmpty) {
            _setStatus('انقطع الاتصال.', processing: false);
          }
        },
      );
    } catch (e) {
      debugPrint('خطأ في الاستقبال: $e');
      _setStatus('تعذر بدء وضع الاستقبال.', processing: false);
    }
  }

  /// The receiver's data is replaced entirely, so never accept a connection
  /// without the user comparing the pairing code on both screens.
  void _askToAcceptIncoming(String endpointId, ConnectionInfo info) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121C3A),
        title: const Text('طلب اتصال'),
        content: Text(
          'الجهاز: ${info.endpointName}\nرمز التحقق: ${info.authenticationToken}\n\nتأكد أن الرمز نفسه يظهر على جهاز المرسل. سيتم استبدال كل بياناتك بالبيانات المستلمة.',
          style: const TextStyle(color: Color(0xFFCBD5E1)),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Nearby().rejectConnection(endpointId);
              _setStatus('تم رفض الاتصال.', processing: false);
            },
            child: const Text('رفض', style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Nearby().acceptConnection(
                endpointId,
                onPayLoadRecieved: _onPayloadReceived,
                onPayloadTransferUpdate: _onReceiverTransferUpdate,
              );
            },
            child: const Text('قبول'),
          ),
        ],
      ),
    );
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.FILE && payload.uri != null) {
      _incomingFiles[payload.id] = payload.uri!;
    }
  }

  Future<void> _onReceiverTransferUpdate(String endpointId, PayloadTransferUpdate update) async {
    if (!_incomingFiles.containsKey(update.id)) return;
    if (update.status == PayloadStatus.IN_PROGRESS) {
      if (update.totalBytes > 0) {
        final pct = (update.bytesTransferred * 100 ~/ update.totalBytes);
        _setStatus('جاري استقبال البيانات... $pct%');
      }
    } else if (update.status == PayloadStatus.SUCCESS) {
      final uri = _incomingFiles.remove(update.id)!;
      await _importReceivedFile(uri);
    } else if (update.status == PayloadStatus.FAILURE || update.status == PayloadStatus.CANCELED) {
      _incomingFiles.remove(update.id);
      _setStatus('فشل استقبال البيانات.', processing: false);
    }
  }

  void _confirmAndStartSend() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121C3A),
        title: const Text('تنبيه هام جداً', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
        content: const Text(
          'سيتم نسخ كل المعلومات (عقاراتي وطلباتي) إلى الجهاز المستلم حرفياً، وأي معلومات سابقة في جهاز المستلم سيتم حذفها واستبدالها بالكامل.\n\nهل تريد الاستمرار؟',
          style: TextStyle(color: Color(0xFFCBD5E1)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء', style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              if (!await _verifyOwner()) return;
              await _connectAndSend();
            },
            child: const Text('موافق واستمرار', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _safeStopNearby() async {
    try {
      await Nearby().stopDiscovery();
      await Nearby().stopAdvertising();
    } catch (_) {}
  }

  /// The owner must confirm the account password and the phone's lock code before data/account leave this device.
  Future<bool> _verifyOwner() async {
    if (!await AccountStore.instance.exists()) return true;
    if (!mounted) return false;
    final pass = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: const Color(0xFF121C3A),
          title: const Text('تأكيد الهوية'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: pass, obscureText: true, decoration: InputDecoration(labelText: 'كلمة المرور', errorText: error)),
              const SizedBox(height: 8),
              const Text('ثم سيُطلب منك رمز قفل هاتفك.', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () async {
                if (await AccountStore.instance.verifyPassword(pass.text) &&
                    await DeviceLock.confirm('أكّد برمز قفل هاتفك نقل بياناتك')) {
                  if (ctx.mounted) Navigator.pop(ctx, true);
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
    pass.dispose();
    return ok == true;
  }

  Future<void> _connectAndSend() async {
    final endpointId = _selectedEndpointId;
    if (endpointId == null) return;

    _setStatus('جاري الاتصال بالجهاز المستهدف...', processing: true);

    try {
      await Nearby().stopDiscovery();
      final myName = await DeviceIdentity.name();

      await Nearby().requestConnection(
        myName,
        endpointId,
        onConnectionInitiated: (id, info) {
          _setStatus('رمز التحقق: ${info.authenticationToken} (يجب أن يطابق رمز جهاز المستلم)');
          Nearby().acceptConnection(
            id,
            onPayLoadRecieved: (id, payload) {},
            onPayloadTransferUpdate: _onSenderTransferUpdate,
          );
        },
        onConnectionResult: (id, status) async {
          if (status == Status.CONNECTED) {
            await _sendAllData(id);
          } else {
            _setStatus('فشل الاتصال بالجهاز (ربما تم الرفض).', processing: false);
          }
        },
        onDisconnected: (id) {
          if (_outgoingPayloadId != null) {
            _outgoingPayloadId = null;
            _setStatus('انقطع الاتصال قبل اكتمال الإرسال.', processing: false);
          }
        },
      );
    } catch (e) {
      debugPrint('خطأ في الاتصال والإرسال: $e');
      _setStatus('تعذر الاتصال بالجهاز.', processing: false);
    }
  }

  Future<void> _sendAllData(String endpointId) async {
    try {
      _setStatus('جاري تجهيز البيانات...');
      final directory = await getApplicationDocumentsDirectory();
      final tmpDir = await getTemporaryDirectory();
      final file = File('${tmpDir.path}/ayach_transfer.json');
      await _writeExportFile(file, directory.path);
      _outgoingTempFile = file;

      _setStatus('جاري إرسال البيانات...');
      _outgoingPayloadId = await Nearby().sendFilePayload(endpointId, file.path);
    } catch (e) {
      debugPrint('خطأ في الإرسال: $e');
      _setStatus('فشل إرسال البيانات.', processing: false);
    }
  }

  Future<void> _onSenderTransferUpdate(String endpointId, PayloadTransferUpdate update) async {
    if (update.id != _outgoingPayloadId) return;
    if (update.status == PayloadStatus.IN_PROGRESS) {
      if (update.totalBytes > 0) {
        _setStatus('جاري الإرسال... ${update.bytesTransferred * 100 ~/ update.totalBytes}%');
      }
    } else if (update.status == PayloadStatus.SUCCESS) {
      _outgoingPayloadId = null;
      await _cleanupOutgoing();
      await Nearby().disconnectFromEndpoint(endpointId);
      _setStatus('تم نقل البيانات بنجاح!', processing: false);
      _snack('تم نقل البيانات بنجاح!');
      if (mounted) setState(() => _selectedEndpointId = null);
    } else if (update.status == PayloadStatus.FAILURE || update.status == PayloadStatus.CANCELED) {
      _outgoingPayloadId = null;
      await _cleanupOutgoing();
      _setStatus('فشل إرسال البيانات.', processing: false);
    }
  }

  Future<void> _cleanupOutgoing() async {
    try {
      if (await _outgoingTempFile?.exists() ?? false) await _outgoingTempFile!.delete();
    } catch (_) {}
    _outgoingTempFile = null;
  }

  /// Streams `{"uploads": {relPath: base64}, "requests": {...}}` to [out]
  /// without holding everything in memory twice.
  Future<void> _writeExportFile(File out, String docsPath) async {
    final sink = out.openWrite();
    try {
      sink.write('{');
      var firstSection = true;
      for (final section in const ['uploads', 'requests']) {
        if (!firstSection) sink.write(',');
        firstSection = false;
        sink.write('${jsonEncode(section)}:{');
        var first = true;
        final dir = Directory('$docsPath/$section');
        if (await dir.exists()) {
          await for (final entity in dir.list(recursive: true, followLinks: false)) {
            if (entity is! File) continue;
            final rel = entity.path.substring(dir.path.length).replaceAll('\\', '/');
            if (!first) sink.write(',');
            first = false;
            sink.write('${jsonEncode(rel)}:${jsonEncode(base64Encode(await entity.readAsBytes()))}');
          }
        }
        sink.write('}');
      }
      final lic = await LicenseStore.instance.load();
      final account = await AccountStore.instance.exportForTransfer(lic);
      sink.write(',"account":${jsonEncode(account)}');
      sink.write('}');
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  Future<void> _importReceivedFile(String uri) async {
    _setStatus('جاري حفظ البيانات...');
    File? tmp;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final tmpDir = await getTemporaryDirectory();
      tmp = File('${tmpDir.path}/ayach_received.json');
      final ok = await Nearby().copyFileAndDeleteOriginal(uri, tmp.path);
      if (!ok) throw Exception('copy failed');

      final data = jsonDecode(await tmp.readAsString()) as Map<String, dynamic>;

      // 1) write everything into staging folders; 2) swap only if all succeeded.
      for (final section in const ['uploads', 'requests']) {
        final staging = Directory('${docs.path}/${section}_incoming');
        if (await staging.exists()) await staging.delete(recursive: true);
        await staging.create(recursive: true);
        final files = (data[section] as Map?) ?? {};
        for (final entry in files.entries) {
          final rel = entry.key.toString();
          final parts = rel.split('/').where((p) => p.isNotEmpty).toList();
          if (parts.isEmpty || parts.any((p) => p == '..' || p == '.')) continue; // path-traversal guard
          final target = File('${staging.path}/${parts.join('/')}');
          await target.parent.create(recursive: true);
          await target.writeAsBytes(base64Decode(entry.value.toString()));
        }
      }
      for (final section in const ['uploads', 'requests']) {
        final live = Directory('${docs.path}/$section');
        if (await live.exists()) await live.delete(recursive: true);
        await Directory('${docs.path}/${section}_incoming').rename(live.path);
      }

      final acc = data['account'];
      if (acc is Map<String, dynamic>) {
        await AccountStore.instance.importFromTransfer(acc);
      }

      dataRevision.value++;
      _setStatus('تم استلام وتحديث البيانات بنجاح!', processing: false);
      _snack('تم استقبال وتحديث البيانات بنجاح!');
    } catch (e) {
      debugPrint('خطأ في المعالجة: $e');
      _setStatus('فشل حفظ البيانات المستلمة.', processing: false);
    } finally {
      try {
        if (tmp != null && await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _safeStopNearby();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'نقل البيانات (Nearby Connections)',
          style: TextStyle(
            color: Color(0xFF8FEFEF),
            fontWeight: FontWeight.bold,
            shadows: [Shadow(color: Color(0xFF8FEFEF), blurRadius: 10)],
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Center(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF152238),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF4A5568)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () {
                        if (_isProcessing) return;
                        _safeStopNearby();
                        setState(() => _mode = TransferMode.send);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                        decoration: BoxDecoration(
                          color: _mode == TransferMode.send ? const Color(0xFF8FEFEF) : Colors.transparent,
                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(10)),
                        ),
                        child: Text(
                          'إرسال',
                          style: TextStyle(
                            color: _mode == TransferMode.send ? const Color(0xFF0B132B) : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        if (_isProcessing) return;
                        _safeStopNearby();
                        setState(() => _mode = TransferMode.receive);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                        decoration: BoxDecoration(
                          color: _mode == TransferMode.receive ? const Color(0xFF8FEFEF) : Colors.transparent,
                          borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)),
                        ),
                        child: Text(
                          'استلام',
                          style: TextStyle(
                            color: _mode == TransferMode.receive ? const Color(0xFF0B132B) : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(_statusMessage, style: const TextStyle(color: Color(0xFF8FEFEF), fontSize: 14)),
            const SizedBox(height: 20),

            Center(
              child: _isProcessing
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(color: Color(0xFF8FEFEF)),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () async {
                            try {
                              await Nearby().stopAllEndpoints();
                            } catch (_) {}
                            await _safeStopNearby();
                            await _cleanupOutgoing();
                            _outgoingPayloadId = null;
                            _incomingFiles.clear();
                            _setStatus('تم الإلغاء.', processing: false);
                          },
                          child: const Text('إلغاء', style: TextStyle(color: Colors.redAccent)),
                        ),
                      ],
                    )
                  : GestureDetector(
                      onTap: _handleStart,
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF8FEFEF),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF8FEFEF).withValues(alpha: 0.4),
                              blurRadius: 20,
                              spreadRadius: 5,
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            _mode == TransferMode.send && _selectedEndpointId == null ? 'بحث' : 'بدء',
                            style: const TextStyle(
                              color: Color(0xFF0B132B),
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 20),

            if (_mode == TransferMode.send) ...[
              const Text('الأجهزة المتاحة:', style: TextStyle(color: Color(0xFFCBD5E1), fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Expanded(
                child: _discoveredDevices.isEmpty
                    ? const Center(child: Text('اضغط على "بحث" للعثور على الجهاز المستقبل.', style: TextStyle(color: Color(0xFF64748B))))
                    : ListView.builder(
                        itemCount: _discoveredDevices.length,
                        itemBuilder: (context, index) {
                          String endpointId = _discoveredDevices.keys.elementAt(index);
                          String name = _discoveredDevices[endpointId]!;
                          bool isSelected = _selectedEndpointId == endpointId;

                          return Card(
                            color: isSelected ? const Color(0xFF1E3A8A) : const Color(0xFF152238),
                            child: ListTile(
                              title: Text(name, style: const TextStyle(color: Colors.white)),
                              subtitle: const Text('النوع: هاتف Android', style: TextStyle(color: Color(0xFF64748B))),
                              trailing: ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: isSelected ? Colors.green : const Color(0xFF38BDF8)),
                                onPressed: () {
                                  setState(() => _selectedEndpointId = endpointId);
                                },
                                child: Text(isSelected ? 'تم الاختيار' : 'اختيار', style: const TextStyle(color: Colors.black)),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ] else ...[
              const Expanded(
                child: Center(
                  child: Text(
                    'وضع الاستقبال مفعل تلقائياً عبر Nearby Connections.\nتأكد من بقاء الشاشة مضاءة بانتظار المرسل.',
                    style: TextStyle(color: Color(0xFF8FEFEF), fontSize: 15),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final bool isRequestsPage;
  const HomeScreen({super.key, required this.isRequestsPage});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Property> allProperties = [];
  List<Property> filteredProperties = [];
  bool isLoading = true;

  final TextEditingController searchController = TextEditingController();
  String? selectedCategory;
  String? selectedType;
  String? selectedCity;
  String? selectedQuartier;

  @override
  void initState() {
    super.initState();
    _loadProperties();
    searchController.addListener(_filterProperties);
    dataRevision.addListener(_loadProperties);
  }

  @override
  void dispose() {
    dataRevision.removeListener(_loadProperties);
    searchController.dispose();
    super.dispose();
  }

  Future<void> _loadProperties() async {
    if (!mounted) return;
    setState(() => isLoading = true);
    try {
      final directory = await getApplicationDocumentsDirectory();
      String folderName = widget.isRequestsPage ? 'requests' : 'uploads';
      final baseDir = Directory('${directory.path}/$folderName');
      
      List<Property> loadedProps = [];

      if (await baseDir.exists()) {
        final categories = baseDir.listSync();
        for (var catDir in categories) {
          if (catDir is Directory) {
            final cities = catDir.listSync();
            for (var cityDir in cities) {
              if (cityDir is Directory) {
                final quartiers = cityDir.listSync();
                for (var quartierDir in quartiers) {
                  if (quartierDir is Directory) {
                    final props = quartierDir.listSync();
                    for (var propDir in props) {
                      if (propDir is Directory) {
                        final jsonFile = File('${propDir.path}/data.json');
                        if (await jsonFile.exists()) {
                          try {
                            final jsonString = await jsonFile.readAsString();
                            final data = jsonDecode(jsonString) as Map<String, dynamic>;
                            loadedProps.add(Property.fromJson(data, propDir.path));
                          } catch (e) {
                            debugPrint('تعذر قراءة ${jsonFile.path}: $e');
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }

      if (mounted) {
        allProperties = loadedProps;
        _filterProperties(); // keeps active search/filters after a reload
        setState(() => isLoading = false);
      }
    } catch (e) {
      debugPrint('خطأ في التحميل: $e');
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _sortProperties(List<Property> list) {
    list.sort((a, b) {
      if (a.isFavorite && !b.isFavorite) return -1;
      if (!a.isFavorite && b.isFavorite) return 1;
      return b.createdAt.compareTo(a.createdAt); // newest first
    });
  }

  void _filterProperties() {
    String query = searchController.text.toLowerCase();

    final results = allProperties.where((property) {
      bool matchesSearch = query.isEmpty ||
          property.category.toLowerCase().contains(query) ||
          property.city.toLowerCase().contains(query) ||
          property.quartier.toLowerCase().contains(query) ||
          property.description.toLowerCase().contains(query) ||
          property.price.toLowerCase().contains(query) ||
          (property.ownerName ?? '').toLowerCase().contains(query) ||
          (property.clientName ?? '').toLowerCase().contains(query);

      bool matchesCategory = selectedCategory == null || property.category == selectedCategory;
      bool matchesType = selectedType == null || property.type == selectedType;
      bool matchesCity = selectedCity == null || property.city.toLowerCase().contains(selectedCity!.toLowerCase());
      bool matchesQuartier = selectedQuartier == null || property.quartier.toLowerCase().contains(selectedQuartier!.toLowerCase());

      return matchesSearch && matchesCategory && matchesType && matchesCity && matchesQuartier;
    }).toList();

    _sortProperties(results);

    if (!mounted) return;
    setState(() {
      filteredProperties = results;
    });
  }

  Future<void> _toggleFavorite(Property property) async {
    Property updatedProp = Property(
      id: property.id,
      category: property.category,
      type: property.type,
      city: property.city,
      quartier: property.quartier,
      area: property.area,
      description: property.description,
      price: property.price,
      createdAt: property.createdAt,
      images: property.images,
      path: property.path,
      ownerName: property.ownerName,
      ownerPhone: property.ownerPhone,
      clientName: property.clientName,
      clientPhone: property.clientPhone,
      isFavorite: !property.isFavorite,
      audioPath: property.audioPath,
      videos: property.videos,
      sharedBy: property.sharedBy,
      isDone: property.isDone,
    );

    final jsonFile = File('${property.path}/data.json');
    await jsonFile.writeAsString(jsonEncode(updatedProp.toJson()));

    await _loadProperties();
  }

  /// Marks a property/request as sold, rented or found (and back).
  Future<void> _toggleDone(Property property) async {
    final updated = Property(
      id: property.id,
      category: property.category,
      type: property.type,
      city: property.city,
      quartier: property.quartier,
      area: property.area,
      description: property.description,
      price: property.price,
      createdAt: property.createdAt,
      images: property.images,
      path: property.path,
      ownerName: property.ownerName,
      ownerPhone: property.ownerPhone,
      clientName: property.clientName,
      clientPhone: property.clientPhone,
      isFavorite: property.isFavorite,
      audioPath: property.audioPath,
      videos: property.videos,
      sharedBy: property.sharedBy,
      isDone: !property.isDone,
    );
    await File('${property.path}/data.json').writeAsString(jsonEncode(updated.toJson()));
    await StatsStore.instance.bump(widget.isRequestsPage ? 'done_requests' : 'done_properties', updated.isDone ? 1 : -1);
    await _loadProperties();
  }

  /// Shares the property details (never the owner's name/phone) plus photos.
  void _chooseShare(Property p) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121C3A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('مشاركة العقار', style: TextStyle(color: Color(0xFF8FEFEF), fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_rounded, color: Color(0xFF38BDF8)),
              title: const Text('مشاركة خارج التطبيق'),
              subtitle: const Text('واتساب، انستغرام وغيرها'),
              onTap: () {
                Navigator.pop(ctx);
                _shareProperty(p);
              },
            ),
            ListTile(
              leading: const Icon(Icons.people_alt_rounded, color: Color(0xFF8FEFEF)),
              title: const Text('مشاركة مع التطبيق'),
              subtitle: const Text('إلى مستخدم آخر باسم المستخدم الخاص به'),
              onTap: () {
                Navigator.pop(ctx);
                _shareInApp(p);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Sends only this property's details (no owner name/phone, no media) to another user.
  Future<void> _shareInApp(Property p) async {
    final controller = TextEditingController();
    String? error;
    final messenger = ScaffoldMessenger.of(context);
    final sent = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: const Color(0xFF121C3A),
          title: const Text('اسم مستخدم المستلم'),
          content: TextField(
            controller: controller,
            autocorrect: false,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(labelText: 'مثال: ahmed#a7k2', errorText: error),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () async {
                final err = await SyncService.sendShare(controller.text, {
                  'category': p.category,
                  'type': p.type,
                  'city': p.city,
                  'quartier': p.quartier,
                  'area': p.area,
                  'description': p.description,
                  'price': p.price,
                });
                if (err != null) {
                  setS(() => error = err);
                } else if (ctx.mounted) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('إرسال'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (sent == true) messenger.showSnackBar(const SnackBar(content: Text('تم إرسال العقار.')));
  }

  Future<void> _shareProperty(Property p) async {
    final typeText = p.type == 'sell' ? 'بيع' : (p.type == 'local' ? 'كراء' : 'شراء');
    final lines = <String>[];
    void add(String label, String value, [String suffix = '']) {
      if (value.trim().isNotEmpty) lines.add('$label: ${value.trim()}$suffix.');
    }

    add('نوع العقار', p.category);
    add('المعاملة', typeText);
    add('المدينة', p.city);
    add('الحي', p.quartier);
    add('المساحة', p.area, ' م²');
    add('الوصف', p.description);
    add('الثمن', formatPrice(p.price), ' درهم');

    try {
      final tmp = await getTemporaryDirectory();
      final files = <XFile>[];
      for (var i = 0; i < p.images.length; i++) {
        final src = File(p.images[i]);
        if (await src.exists()) {
          final name = p.images[i].split('/').last;
          final dst = await src.copy('${tmp.path}/share_${i}_$name');
          files.add(XFile(dst.path));
        }
      }
      await SharePlus.instance.share(
        ShareParams(text: lines.join('\n'), files: files.isEmpty ? null : files),
      );
    } catch (e) {
      debugPrint('خطأ في المشاركة: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذرت المشاركة.')));
      }
    }
  }

  void _resetFilters() {
    setState(() {
      searchController.clear();
      selectedCategory = null;
      selectedType = null;
      selectedCity = null;
      selectedQuartier = null;
      filteredProperties = List.from(allProperties);
    });
  }

  Future<void> _deleteProperty(Property property) async {
    try {
      final propDir = Directory(property.path);
      if (await propDir.exists()) {
        await propDir.delete(recursive: true);
        await StatsStore.instance.bump(widget.isRequestsPage ? 'deleted_requests' : 'deleted_properties', 1);

        String rootFolder = widget.isRequestsPage ? 'requests' : 'uploads';
        Directory currentDir = propDir.parent;
        while (currentDir.path.contains('/$rootFolder') && currentDir.path.split('/').last != rootFolder) {
          final contents = currentDir.listSync();
          if (contents.isEmpty) {
            Directory parentDir = currentDir.parent;
            await currentDir.delete();
            currentDir = parentDir;
          } else {
            break;
          }
        }
      }
      await _loadProperties();
    } catch (e) {
      debugPrint("خطأ أثناء الحذف: $e");
    }
  }

  void _openAddModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AddPropertyModal(
        isRequestsPage: widget.isRequestsPage,
        onPropertyAdded: _loadProperties,
      ),
    );
  }

  void _openEditModal(Property property) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => EditPropertyModal(
        property: property,
        isRequestsPage: widget.isRequestsPage,
        onPropertyUpdated: _loadProperties,
      ),
    );
  }

  void _openFilterDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121C3A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 20, right: 20, top: 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('التصفية المتقدمة', style: TextStyle(fontSize: 20, color: Color(0xFF8FEFEF), fontWeight: FontWeight.bold)),
                        TextButton(
                          onPressed: () {
                            _resetFilters();
                            Navigator.pop(context);
                          },
                          child: const Text('إعادة تعيين', style: TextStyle(color: Colors.redAccent)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 15),
                    DropdownButtonFormField<String>(
                      initialValue: selectedCategory,
                      dropdownColor: const Color(0xFF152238),
                      decoration: _inputDecoration('نوع العقار'),
                      items: ['شقة', 'فيلات', 'أراضي فلاحية', 'أراضي سكنية', 'منازل', 'محلات تجارية', 'مباني صناعية']
                          .map((val) => DropdownMenuItem(value: val, child: Text(val))).toList(),
                      onChanged: (val) => setModalState(() => selectedCategory = val),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: selectedType,
                      dropdownColor: const Color(0xFF152238),
                      decoration: _inputDecoration('طريقة التجارة'),
                      items: const [
                        DropdownMenuItem(value: 'sell', child: Text('بيع')),
                        DropdownMenuItem(value: 'local', child: Text('كراء')),
                        DropdownMenuItem(value: 'buy', child: Text('شراء')),
                      ],
                      onChanged: (val) => setModalState(() => selectedType = val),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: TextEditingController(text: selectedCity),
                      decoration: _inputDecoration('المدينة'),
                      onChanged: (val) => selectedCity = val.isEmpty ? null : val,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: TextEditingController(text: selectedQuartier),
                      decoration: _inputDecoration('الحي'),
                      onChanged: (val) => selectedQuartier = val.isEmpty ? null : val,
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8FEFEF), padding: const EdgeInsets.all(12)),
                        onPressed: () {
                          _filterProperties();
                          Navigator.pop(context);
                        },
                        child: const Text('تطبيق', style: TextStyle(color: Color(0xFF0B132B), fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              widget.isRequestsPage ? 'طلباتي' : 'عقاراتي',
              style: const TextStyle(
                color: Color(0xFF8FEFEF),
                fontWeight: FontWeight.bold,
                shadows: [Shadow(color: Color(0xFF8FEFEF), blurRadius: 10)],
              ),
            ),
            OutlinedButton(
              onPressed: _openAddModal,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF8FEFEF)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('إضافة +', style: TextStyle(color: Color(0xFF8FEFEF), fontSize: 16)),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: searchController,
                    decoration: InputDecoration(
                      hintText: widget.isRequestsPage ? 'ابحث في الطلبات...' : 'ابحث في العقارات...',
                      hintStyle: const TextStyle(color: Color(0xFF64748B)),
                      prefixIcon: const Icon(Icons.search, color: Color(0xFF8FEFEF)),
                      filled: true,
                      fillColor: const Color(0xFF152238),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _openFilterDialog,
                  icon: const Icon(Icons.filter_list_rounded, color: Color(0xFF8FEFEF), size: 28),
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF152238),
                    padding: const EdgeInsets.all(12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                widget.isRequestsPage
                    ? 'العدد الإجمالي للطلبات: ${allProperties.length}'
                    : 'العدد الإجمالي للعقارات: ${allProperties.length}',
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
              ),
            ),
          ),
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF8FEFEF)))
                : filteredProperties.isEmpty
                    ? Center(
                        child: Text(
                          widget.isRequestsPage ? 'لا توجد طلبات مسجلة حالياً.' : 'لا توجد عقارات مسجلة حالياً.',
                          style: const TextStyle(fontSize: 18, color: Color(0xFFA0AEC0)),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: filteredProperties.length,
                        itemBuilder: (context, index) {
                          Property item = filteredProperties[index];
                          return PropertyCard(
                            property: item,
                            index: index,
                            isRequestsPage: widget.isRequestsPage,
                            onEdit: () => _openEditModal(item),
                            onDelete: () => _deleteProperty(item),
                            onToggleFavorite: () => _toggleFavorite(item),
                            onToggleDone: () => _toggleDone(item),
                            onShare: widget.isRequestsPage ? null : () => _chooseShare(item),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Color(0xFFCBD5E1)),
      filled: true,
      fillColor: const Color(0xFF152238),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF4A5568))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF8FEFEF))),
    );
  }
}

class PropertyCard extends StatelessWidget {
  final Property property;
  final int index;
  final bool isRequestsPage;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onToggleFavorite;
  final VoidCallback onToggleDone;
  final VoidCallback? onShare;

  const PropertyCard({
    super.key,
    required this.property,
    required this.index,
    required this.isRequestsPage,
    required this.onEdit,
    required this.onDelete,
    required this.onToggleFavorite,
    required this.onToggleDone,
    this.onShare,
  });

  /// Tap on the name or the phone: choose WhatsApp chat or a normal phone call.
  void _showContactActions(BuildContext context, String name, String phone) {
    final messenger = ScaffoldMessenger.of(context);
    if (phone.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('لا يوجد رقم هاتف.')));
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121C3A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                name.isEmpty ? phone : '$name  ($phone)',
                style: const TextStyle(color: Color(0xFF8FEFEF), fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.chat_rounded, color: Color(0xFF25D366)),
              title: const Text('محادثة على واتساب'),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await launchUrl(
                  Uri.parse('https://wa.me/${_whatsAppNumber(phone)}'),
                  mode: LaunchMode.externalApplication,
                ).catchError((_) => false);
                if (!ok) messenger.showSnackBar(const SnackBar(content: Text('تعذر فتح واتساب.')));
              },
            ),
            ListTile(
              leading: const Icon(Icons.call_rounded, color: Color(0xFF38BDF8)),
              title: const Text('اتصال عادي'),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await launchUrl(Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^0-9+]'), '')))
                    .catchError((_) => false);
                if (!ok) messenger.showSnackBar(const SnackBar(content: Text('تعذر فتح تطبيق الاتصال.')));
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// wa.me needs the international format without + or leading zeros.
  /// Local Moroccan numbers (06.../07.../05...) get the 212 prefix.
  String _whatsAppNumber(String phone) {
    var d = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (d.startsWith('+')) return d.substring(1);
    if (d.startsWith('00')) return d.substring(2);
    if (d.startsWith('0')) return '212${d.substring(1)}';
    return d;
  }

  /// Long-press on the name or the phone copies the phone number.
  Widget _contactLine(BuildContext context, String label, String? name, String? phone, Color color) {
    final n = (name ?? '').trim();
    final ph = (phone ?? '').trim();
    if (n.isEmpty && ph.isEmpty) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showContactActions(context, n, ph),
      onLongPress: () async {
        final messenger = ScaffoldMessenger.of(context);
        if (ph.isEmpty) {
          messenger.showSnackBar(const SnackBar(content: Text('لا يوجد رقم هاتف للنسخ.')));
          return;
        }
        await Clipboard.setData(ClipboardData(text: ph));
        messenger.showSnackBar(SnackBar(content: Text('تم نسخ الرقم: $ph')));
      },
      child: Text(
        '$label: $n ($ph)',
        style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.bold),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String typeText = property.type == 'sell' ? 'بيع' : (property.type == 'local' ? 'كراء' : 'شراء');

    return Stack(
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF152238),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: property.isDone ? const Color(0xFF22C55E) : (property.isFavorite ? Colors.amber : const Color(0xFF4A5568)),
              width: (property.isFavorite || property.isDone) ? 1.5 : 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: property.isFavorite ? Colors.amber.withValues(alpha: 0.15) : Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              )
            ],
          ),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${property.category} (${property.city} - ${property.quartier})',
                            style: const TextStyle(fontSize: 18, color: Color(0xFF8FEFEF), fontWeight: FontWeight.bold)),
                        if (property.sharedBy != null) ...[
                          Text('مشارك من: ${property.sharedBy}', style: const TextStyle(color: Color(0xFFF59E0B), fontSize: 13, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                        ],
                        const SizedBox(height: 6),
                        Text('المعاملة: $typeText | المساحة: ${property.area} م²', style: const TextStyle(color: Color(0xFFCBD5E1))),
                        const SizedBox(height: 4),
                        Text('الوصف: ${property.description}', style: const TextStyle(color: Color(0xFFCBD5E1))),
                        if (property.audioPath != null) ...[
                          const SizedBox(height: 6),
                          AudioPlayButton(path: property.audioPath!),
                        ],
                        if (property.videos.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => VideoViewerScreen(videos: property.videos)),
                                ),
                                icon: const Icon(Icons.videocam_rounded, color: Color(0xFF8FEFEF)),
                                label: Text('الفيديوهات (${property.videos.length})', style: const TextStyle(color: Color(0xFF8FEFEF))),
                                style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF8FEFEF))),
                              ),
                              IconButton(
                                icon: const Icon(Icons.share_rounded, color: Color(0xFF38BDF8)),
                                tooltip: 'مشاركة الفيديوهات',
                                onPressed: () => shareFilesOnly(context, property.videos),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 6),
                        
                        if (!isRequestsPage)
                          _contactLine(context, 'المالك', property.ownerName, property.ownerPhone, const Color(0xFF38BDF8)),
                        if (isRequestsPage)
                          _contactLine(context, 'الزبون', property.clientName, property.clientPhone, const Color(0xFF10B981)),

                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF8FEFEF),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('الثمن: ${formatPrice(property.price)} درهم',
                              style: const TextStyle(color: Color(0xFF0B132B), fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  GestureDetector(
                    onTap: () {
                      if (property.images.isNotEmpty) {
                        Navigator.push(context, MaterialPageRoute(builder: (_) => ImageViewerScreen(images: property.images)));
                      }
                    },
                    child: SizedBox(
                      width: 100,
                      height: 80,
                      child: property.images.isNotEmpty
                          ? Stack(
                              children: property.images.take(3).toList().asMap().entries.map((entry) {
                                int imgIndex = entry.key;
                                String imgPath = entry.value;
                                return Positioned(
                                  top: imgIndex * 4.0,
                                  right: imgIndex * 4.0,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(
                                      File(imgPath),
                                      width: 80,
                                      height: 70,
                                      fit: BoxFit.cover,
                                      cacheWidth: 200,
                                      errorBuilder: (_, __, ___) => const SizedBox(
                                        width: 80,
                                        height: 70,
                                        child: Icon(Icons.broken_image, color: Color(0xFF64748B)),
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            )
                          : Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Center(
                                child: Text('بدون صور', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
              const Divider(color: Color(0xFF4A5568), height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onShare != null)
                    IconButton(
                      icon: const Icon(Icons.share_rounded, color: Color(0xFF38BDF8)),
                      onPressed: onShare,
                      tooltip: 'مشاركة',
                    ),
                  IconButton(
                    icon: Icon(
                      property.isDone ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded,
                      color: property.isDone ? const Color(0xFF22C55E) : const Color(0xFF64748B),
                      size: 26,
                    ),
                    onPressed: onToggleDone,
                    tooltip: property.isDone
                        ? 'إلغاء التأكيد'
                        : (isRequestsPage ? 'تم إيجاد العقار للزبون' : (property.type == 'local' ? 'تم الكراء' : 'تم البيع')),
                  ),
                  IconButton(
                    icon: Icon(
                      property.isFavorite ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: property.isFavorite ? Colors.amber : const Color(0xFF64748B),
                      size: 26,
                    ),
                    onPressed: onToggleFavorite,
                    tooltip: property.isFavorite ? 'إزالة من المفضلة' : 'إضافة للمفضلة',
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_rounded, color: Color(0xFF8FEFEF)),
                    onPressed: onEdit,
                    tooltip: 'تعديل',
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_rounded, color: Colors.redAccent),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: const Color(0xFF121C3A),
                          title: const Text('تأكيد الحذف'),
                          content: const Text('هل أنت متأكد من رغبتك في الحذف؟'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('إلغاء', style: TextStyle(color: Colors.white)),
                            ),
                            TextButton(
                              onPressed: () {
                                Navigator.pop(ctx);
                                onDelete();
                              },
                              child: const Text('حذف', style: TextStyle(color: Colors.redAccent)),
                            ),
                          ],
                        ),
                      );
                    },
                    tooltip: 'حذف',
                  ),
                ],
              ),
            ],
          ),
        ),

        if (property.isDone)
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFF22C55E), borderRadius: BorderRadius.circular(10)),
              child: Text(isRequestsPage ? 'تم الإيجاد' : (property.type == 'local' ? 'تم الكراء' : 'تم البيع'),
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
        if (property.isFavorite)
          const Positioned(
            top: 10,
            left: 10,
            child: Icon(
              Icons.star_rounded,
              color: Colors.amber,
              size: 28,
            ),
          ),
      ],
    );
  }
}

class AddPropertyModal extends StatefulWidget {
  final bool isRequestsPage;
  final VoidCallback onPropertyAdded;
  const AddPropertyModal({super.key, required this.isRequestsPage, required this.onPropertyAdded});

  @override
  State<AddPropertyModal> createState() => _AddPropertyModalState();
}

class _AddPropertyModalState extends State<AddPropertyModal> {
  final _formKey = GlobalKey<FormState>();
  String? category, type;
  final TextEditingController cityController = TextEditingController();
  final TextEditingController quartierController = TextEditingController();
  final TextEditingController areaController = TextEditingController();
  final TextEditingController descController = TextEditingController();
  final TextEditingController priceController = TextEditingController();
  final TextEditingController nameController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  List<XFile> selectedImages = [];
  List<XFile> selectedVideos = [];
  final GlobalKey<AudioRecorderFieldState> _audioKey = GlobalKey<AudioRecorderFieldState>();
  String? audioTempPath;

  Future<void> _pickImages() async {
    try {
      final List<XFile> images = await ImagePicker().pickMultiImage();
      if (images.isNotEmpty && mounted) {
        setState(() => selectedImages = images);
      }
    } catch (e) {
      debugPrint('خطأ في اختيار الصور: $e');
    }
  }

  Future<void> _pickVideos() async {
    try {
      final List<XFile> videos = await ImagePicker().pickMultiVideo();
      if (videos.isNotEmpty && mounted) {
        setState(() => selectedVideos = videos);
      }
    } catch (e) {
      debugPrint('خطأ في اختيار الفيديوهات: $e');
    }
  }

  @override
  void dispose() {
    for (final c in [cityController, quartierController, areaController, descController, priceController, nameController, phoneController]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submitForm() async {
    if (_formKey.currentState!.validate() && category != null && type != null) {
      await _audioKey.currentState?.stopIfRecording();
      final directory = await getApplicationDocumentsDirectory();
      
      String folderName = widget.isRequestsPage ? 'requests' : 'uploads';
      String safe(String v) => v.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
      final baseDir = Directory('${directory.path}/$folderName/$category/${safe(cityController.text)}/${safe(quartierController.text)}');
      
      if (!await baseDir.exists()) {
        await baseDir.create(recursive: true);
      }

      // First unused number (a count would collide after a deletion).
      int nextNumber = 1;
      while (await Directory('${baseDir.path}/$category $nextNumber').exists()) {
        nextNumber++;
      }
      
      final propertyDir = Directory('${baseDir.path}/$category $nextNumber');
      final imagesDir = Directory('${propertyDir.path}/images');
      await imagesDir.create(recursive: true);

      List<String> savedImagePaths = [];
      for (var image in selectedImages) {
        final fileName = '${DateTime.now().millisecondsSinceEpoch}_${image.name}';
        final savedPath = '${imagesDir.path}/$fileName';
        await File(image.path).copy(savedPath);
        savedImagePaths.add(savedPath);
      }

      final List<String> savedVideoPaths = [];
      if (selectedVideos.isNotEmpty) {
        final videosDir = Directory('${propertyDir.path}/videos');
        await videosDir.create(recursive: true);
        for (var i = 0; i < selectedVideos.length; i++) {
          final v = selectedVideos[i];
          final savedPath = '${videosDir.path}/${DateTime.now().millisecondsSinceEpoch}_${i}_${v.name}';
          await File(v.path).copy(savedPath);
          savedVideoPaths.add(savedPath);
        }
      }

      String? savedAudioPath;
      if (audioTempPath != null && await File(audioTempPath!).exists()) {
        final audioDir = Directory('${propertyDir.path}/audio');
        await audioDir.create(recursive: true);
        savedAudioPath = '${audioDir.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';
        await File(audioTempPath!).copy(savedAudioPath);
      }

      Property newProp = Property(
        id: nextNumber,
        category: category!,
        type: type!,
        city: cityController.text.trim(),
        quartier: quartierController.text.trim(),
        area: areaController.text.trim(),
        description: descController.text.trim(),
        price: priceController.text.trim(),
        createdAt: DateTime.now().toString(),
        images: savedImagePaths,
        path: propertyDir.path,
        ownerName: !widget.isRequestsPage ? nameController.text.trim() : null,
        ownerPhone: !widget.isRequestsPage ? phoneController.text.trim() : null,
        clientName: widget.isRequestsPage ? nameController.text.trim() : null,
        clientPhone: widget.isRequestsPage ? phoneController.text.trim() : null,
        audioPath: savedAudioPath,
        videos: savedVideoPaths,
      );

      final jsonFile = File('${propertyDir.path}/data.json');
      await jsonFile.writeAsString(jsonEncode(newProp.toJson()));

      if (!mounted) return;
      widget.onPropertyAdded();
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 20, right: 20, top: 20,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF121C3A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.isRequestsPage ? 'إضافة طلب جديد' : 'إضافة عقار جديد',
                style: const TextStyle(fontSize: 22, color: Color(0xFF8FEFEF), fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickImages,
                      icon: const Icon(Icons.add_a_photo, color: Color(0xFF8FEFEF)),
                      label: Text('الصور (${selectedImages.length})', style: const TextStyle(color: Color(0xFF8FEFEF))),
                      style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF8FEFEF))),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickVideos,
                      icon: const Icon(Icons.video_library_rounded, color: Color(0xFF8FEFEF)),
                      label: Text('الفيديوهات (${selectedVideos.length})', style: const TextStyle(color: Color(0xFF8FEFEF))),
                      style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF8FEFEF))),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                dropdownColor: const Color(0xFF152238),
                validator: (v) => v == null ? 'مطلوب' : null,
                decoration: _inputDecoration('اختر نوع العقار'),
                items: ['شقة', 'فيلات', 'أراضي فلاحية', 'أراضي سكنية', 'منازل', 'محلات تجارية', 'مباني صناعية']
                    .map((val) => DropdownMenuItem(value: val, child: Text(val))).toList(),
                onChanged: (val) => setState(() => category = val),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                dropdownColor: const Color(0xFF152238),
                validator: (v) => v == null ? 'مطلوب' : null,
                decoration: _inputDecoration('اختر المعاملة'),
                items: const [
                  DropdownMenuItem(value: 'sell', child: Text('بيع')),
                  DropdownMenuItem(value: 'local', child: Text('كراء')),
                  DropdownMenuItem(value: 'buy', child: Text('شراء')),
                ],
                onChanged: (val) => setState(() => type = val),
              ),
              const SizedBox(height: 12),
              TextFormField(controller: cityController, decoration: _inputDecoration('المدينة'), validator: (v) => (v ?? '').trim().isEmpty ? 'مطلوب' : null),
              const SizedBox(height: 12),
              TextFormField(controller: quartierController, decoration: _inputDecoration('الحي'), validator: (v) => (v ?? '').trim().isEmpty ? 'مطلوب' : null),
              const SizedBox(height: 12),
              
              TextFormField(
                controller: nameController,
                decoration: _inputDecoration(widget.isRequestsPage ? 'اسم الزبون' : 'اسم المالك (صاحب العقار)'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: phoneController,
                decoration: _inputDecoration(widget.isRequestsPage ? 'رقم هاتف الزبون' : 'رقم هاتف المالك'),
                keyboardType: TextInputType.phone,
              ),

              const SizedBox(height: 12),
              TextFormField(controller: areaController, decoration: _inputDecoration('المساحة (م²)')),
              const SizedBox(height: 12),
              TextFormField(controller: descController, maxLines: 3, decoration: _inputDecoration('الوصف...')),
              const SizedBox(height: 8),
              AudioRecorderField(key: _audioKey, onChanged: (p) => audioTempPath = p),
              const SizedBox(height: 12),
              TextFormField(controller: priceController, decoration: _inputDecoration('الثمن'), validator: (v) => (v ?? '').trim().isEmpty ? 'مطلوب' : null),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('إلغاء', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                      onPressed: _submitForm,
                      child: const Text('إنهاء', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Color(0xFFCBD5E1)),
      filled: true,
      fillColor: const Color(0xFF152238),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF4A5568))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF8FEFEF))),
    );
  }
}

class EditPropertyModal extends StatefulWidget {
  final Property property;
  final bool isRequestsPage;
  final VoidCallback onPropertyUpdated;

  const EditPropertyModal({
    super.key,
    required this.property,
    required this.isRequestsPage,
    required this.onPropertyUpdated,
  });

  @override
  State<EditPropertyModal> createState() => _EditPropertyModalState();
}

class _EditPropertyModalState extends State<EditPropertyModal> {
  final _formKey = GlobalKey<FormState>();
  late String type;
  late TextEditingController areaController;
  late TextEditingController descController;
  late TextEditingController priceController;
  late TextEditingController nameController;
  late TextEditingController phoneController;

  // Media being edited. Existing items are paths; new ones come from the pickers.
  late List<String> _images;
  late List<String> _videos;
  String? _audio;
  final List<XFile> _newImages = [];
  final List<XFile> _newVideos = [];
  String? _newAudioTemp;
  final GlobalKey<AudioRecorderFieldState> _audioKey = GlobalKey<AudioRecorderFieldState>();
  List<String> _finalImages = [];
  List<String> _finalVideos = [];
  String? _finalAudio;

  @override
  void dispose() {
    areaController.dispose();
    descController.dispose();
    priceController.dispose();
    nameController.dispose();
    phoneController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    type = widget.property.type;
    _images = List.of(widget.property.images);
    _videos = List.of(widget.property.videos);
    _audio = widget.property.audioPath;
    areaController = TextEditingController(text: widget.property.area);
    descController = TextEditingController(text: widget.property.description);
    priceController = TextEditingController(text: widget.property.price);
    
    nameController = TextEditingController(
      text: widget.isRequestsPage ? (widget.property.clientName ?? '') : (widget.property.ownerName ?? ''),
    );
    phoneController = TextEditingController(
      text: widget.isRequestsPage ? (widget.property.clientPhone ?? '') : (widget.property.ownerPhone ?? ''),
    );
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Applies the media changes on disk and fills _final* lists.
  Future<void> _applyMedia() async {
    final dir = widget.property.path;
    await _audioKey.currentState?.stopIfRecording();

    // removed items
    for (final p in widget.property.images) {
      if (!_images.contains(p)) await _deleteQuietly(p);
    }
    for (final p in widget.property.videos) {
      if (!_videos.contains(p)) await _deleteQuietly(p);
    }
    if (widget.property.audioPath != null && _audio != widget.property.audioPath) {
      await _deleteQuietly(widget.property.audioPath!);
    }

    // new items
    final images = List<String>.of(_images);
    if (_newImages.isNotEmpty) {
      final d = Directory('$dir/images');
      await d.create(recursive: true);
      for (var i = 0; i < _newImages.length; i++) {
        final path = '${d.path}/${DateTime.now().millisecondsSinceEpoch}_${i}_${_newImages[i].name}';
        await File(_newImages[i].path).copy(path);
        images.add(path);
      }
    }
    final videos = List<String>.of(_videos);
    if (_newVideos.isNotEmpty) {
      final d = Directory('$dir/videos');
      await d.create(recursive: true);
      for (var i = 0; i < _newVideos.length; i++) {
        final path = '${d.path}/${DateTime.now().millisecondsSinceEpoch}_${i}_${_newVideos[i].name}';
        await File(_newVideos[i].path).copy(path);
        videos.add(path);
      }
    }
    String? audio = _audio;
    if (_newAudioTemp != null && await File(_newAudioTemp!).exists()) {
      final d = Directory('$dir/audio');
      await d.create(recursive: true);
      audio = '${d.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';
      await File(_newAudioTemp!).copy(audio);
    }
    _finalImages = images;
    _finalVideos = videos;
    _finalAudio = audio;
  }

  Future<void> _addImages() async {
    try {
      final picked = await ImagePicker().pickMultiImage();
      if (picked.isNotEmpty && mounted) setState(() => _newImages.addAll(picked));
    } catch (e) {
      debugPrint('pick images: $e');
    }
  }

  Future<void> _addVideos() async {
    try {
      final picked = await ImagePicker().pickMultiVideo();
      if (picked.isNotEmpty && mounted) setState(() => _newVideos.addAll(picked));
    } catch (e) {
      debugPrint('pick videos: $e');
    }
  }

  Widget _thumb(String path, VoidCallback onRemove) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(path),
            width: 70,
            height: 70,
            fit: BoxFit.cover,
            cacheWidth: 200,
            errorBuilder: (_, __, ___) => const SizedBox(width: 70, height: 70, child: Icon(Icons.broken_image, color: Color(0xFF64748B))),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 18, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _videoChip(String name, VoidCallback onRemove) {
    return Chip(
      backgroundColor: const Color(0xFF152238),
      avatar: const Icon(Icons.videocam_rounded, color: Color(0xFF8FEFEF), size: 18),
      label: SizedBox(width: 110, child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
      deleteIcon: const Icon(Icons.close, size: 18, color: Colors.redAccent),
      onDeleted: onRemove,
    );
  }

  Widget _mediaEditor() {
    String fileName(String p) => p.split('/').last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('الصور', style: TextStyle(color: Color(0xFFCBD5E1), fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in _images) _thumb(p, () => setState(() => _images.remove(p))),
            for (final x in _newImages) _thumb(x.path, () => setState(() => _newImages.remove(x))),
            OutlinedButton.icon(
              onPressed: _addImages,
              icon: const Icon(Icons.add_a_photo, color: Color(0xFF8FEFEF)),
              label: const Text('إضافة', style: TextStyle(color: Color(0xFF8FEFEF))),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF8FEFEF))),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const Text('الفيديوهات', style: TextStyle(color: Color(0xFFCBD5E1), fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in _videos) _videoChip(fileName(p), () => setState(() => _videos.remove(p))),
            for (final x in _newVideos) _videoChip(x.name, () => setState(() => _newVideos.remove(x))),
            OutlinedButton.icon(
              onPressed: _addVideos,
              icon: const Icon(Icons.video_library_rounded, color: Color(0xFF8FEFEF)),
              label: const Text('إضافة', style: TextStyle(color: Color(0xFF8FEFEF))),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF8FEFEF))),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const Text('الصوتية', style: TextStyle(color: Color(0xFFCBD5E1), fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        if (_audio != null)
          Row(
            children: [
              Expanded(child: AudioPlayButton(path: _audio!)),
              IconButton(
                onPressed: () => setState(() => _audio = null),
                icon: const Icon(Icons.delete_rounded, color: Colors.redAccent),
                tooltip: 'حذف التسجيل',
              ),
            ],
          )
        else
          AudioRecorderField(key: _audioKey, onChanged: (p) => _newAudioTemp = p),
      ],
    );
  }

  Future<void> _updateProperty() async {
    if (_formKey.currentState!.validate()) {
      await _applyMedia();
      Property updatedProp = Property(
        id: widget.property.id,
        category: widget.property.category,
        type: type,
        city: widget.property.city,
        quartier: widget.property.quartier,
        area: areaController.text.trim(),
        description: descController.text.trim(),
        price: priceController.text.trim(),
        createdAt: widget.property.createdAt,
        images: _finalImages,
        path: widget.property.path,
        ownerName: !widget.isRequestsPage ? nameController.text.trim() : widget.property.ownerName,
        ownerPhone: !widget.isRequestsPage ? phoneController.text.trim() : widget.property.ownerPhone,
        clientName: widget.isRequestsPage ? nameController.text.trim() : widget.property.clientName,
        clientPhone: widget.isRequestsPage ? phoneController.text.trim() : widget.property.clientPhone,
        isFavorite: widget.property.isFavorite,
        audioPath: _finalAudio,
        videos: _finalVideos,
        sharedBy: widget.property.sharedBy,
        isDone: widget.property.isDone,
      );

      final jsonFile = File('${widget.property.path}/data.json');
      await jsonFile.writeAsString(jsonEncode(updatedProp.toJson()));

      if (!mounted) return;
      widget.onPropertyUpdated();
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 20, right: 20, top: 20,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF121C3A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('تعديل البيانات', style: TextStyle(fontSize: 22, color: Color(0xFF8FEFEF), fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              _mediaEditor(),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: type,
                dropdownColor: const Color(0xFF152238),
                decoration: _inputDecoration('اختر المعاملة'),
                items: const [
                  DropdownMenuItem(value: 'sell', child: Text('بيع')),
                  DropdownMenuItem(value: 'local', child: Text('كراء')),
                  DropdownMenuItem(value: 'buy', child: Text('شراء')),
                ],
                onChanged: (val) => setState(() => type = val!),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: nameController,
                decoration: _inputDecoration(widget.isRequestsPage ? 'اسم الزبون' : 'اسم المالك (صاحب العقار)'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: phoneController,
                decoration: _inputDecoration(widget.isRequestsPage ? 'رقم هاتف الزبون' : 'رقم هاتف المالك'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              TextFormField(controller: areaController, decoration: _inputDecoration('المساحة')),
              const SizedBox(height: 12),
              TextFormField(controller: descController, maxLines: 3, decoration: _inputDecoration('الوصف...')),
              const SizedBox(height: 12),
              TextFormField(controller: priceController, decoration: _inputDecoration('الثمن'), validator: (v) => (v ?? '').trim().isEmpty ? 'مطلوب' : null),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('إلغاء', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                      onPressed: _updateProperty,
                      child: const Text('حفظ', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Color(0xFFCBD5E1)),
      filled: true,
      fillColor: const Color(0xFF152238),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF4A5568))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF8FEFEF))),
    );
  }
}

class ImageViewerScreen extends StatelessWidget {
  final List<String> images;

  const ImageViewerScreen({super.key, required this.images});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: const [OrientationToggleButton()],
      ),
      body: ImageViewerBody(images: images),
    );
  }
}

class ImageViewerBody extends StatefulWidget {
  final List<String> images;
  const ImageViewerBody({super.key, required this.images});

  @override
  State<ImageViewerBody> createState() => _ImageViewerBodyState();
}

class _ImageViewerBodyState extends State<ImageViewerBody> {
  int currentIndex = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (var imgPath in widget.images) {
      precacheImage(FileImage(File(imgPath)), context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: PageView.builder(
              itemCount: widget.images.length,
              onPageChanged: (idx) => setState(() => currentIndex = idx),
              itemBuilder: (context, index) {
                return ZoomBox(
                  child: Image.file(
                    File(widget.images[index]),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image, color: Color(0xFF64748B), size: 64),
                    ),
                    frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                      if (wasSynchronouslyLoaded || frame != null) {
                        return child;
                      }
                      return const Center(
                        child: CircularProgressIndicator(color: Color(0xFF8FEFEF)),
                      );
                    },
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF121C3A),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF4A5568)),
            ),
            child: Text(
              'صورة ${currentIndex + 1} من ${widget.images.length}',
              style: const TextStyle(color: Color(0xFF8FEFEF), fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}


/// Play / stop button for a saved voice note.
class AudioPlayButton extends StatefulWidget {
  final String path;
  const AudioPlayButton({super.key, required this.path});

  @override
  State<AudioPlayButton> createState() => _AudioPlayButtonState();
}

class _AudioPlayButtonState extends State<AudioPlayButton> {
  AudioPlayer? _player;
  StreamSubscription<void>? _sub;
  bool _playing = false;

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await _player?.stop();
        if (mounted) setState(() => _playing = false);
        return;
      }
      if (!await File(widget.path).exists()) return;
      _player ??= AudioPlayer();
      _sub ??= _player!.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _playing = false);
      });
      await _player!.play(DeviceFileSource(widget.path));
      if (mounted) setState(() => _playing = true);
    } catch (e) {
      debugPrint('خطأ في تشغيل الصوت: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: _toggle,
          icon: Icon(_playing ? Icons.stop_circle_outlined : Icons.play_circle_outline, color: const Color(0xFF8FEFEF)),
          label: Text(_playing ? 'إيقاف' : 'تشغيل الصوتية', style: const TextStyle(color: Color(0xFF8FEFEF))),
          style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF8FEFEF))),
        ),
        IconButton(
          icon: const Icon(Icons.share_rounded, color: Color(0xFF38BDF8)),
          tooltip: 'مشاركة التسجيل الصوتي',
          onPressed: () => shareFilesOnly(context, [widget.path]),
        ),
      ],
    );
  }
}

/// Record / preview / delete a voice note while adding a property or request.
class AudioRecorderField extends StatefulWidget {
  final ValueChanged<String?> onChanged;
  const AudioRecorderField({super.key, required this.onChanged});

  @override
  State<AudioRecorderField> createState() => AudioRecorderFieldState();
}

class AudioRecorderFieldState extends State<AudioRecorderField> {
  final AudioRecorder _recorder = AudioRecorder();
  AudioPlayer? _player;
  StreamSubscription<void>? _sub;
  bool _recording = false;
  bool _playing = false;
  String? _path;

  void _msg(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _start() async {
    try {
      if (!await _recorder.hasPermission()) {
        _msg('يجب السماح باستخدام الميكروفون.');
        return;
      }
      await _stopPlayback();
      final dir = await getTemporaryDirectory();
      final p = '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: p);
      if (mounted) setState(() => _recording = true);
    } catch (e) {
      debugPrint('خطأ في التسجيل: $e');
      _msg('تعذر بدء التسجيل.');
    }
  }

  Future<void> stopIfRecording() async {
    if (!_recording) return;
    try {
      final p = await _recorder.stop();
      if (mounted) setState(() => _recording = false);
      if (p != null) {
        // A new recording replaces an older one.
        if (_path != null && _path != p) {
          try { await File(_path!).delete(); } catch (_) {}
        }
        _path = p;
        widget.onChanged(p);
        if (mounted) setState(() {});
      }
    } catch (e) {
      debugPrint('خطأ في إيقاف التسجيل: $e');
      if (mounted) setState(() => _recording = false);
    }
  }

  Future<void> _stopPlayback() async {
    try { await _player?.stop(); } catch (_) {}
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _togglePlay() async {
    if (_path == null) return;
    try {
      if (_playing) {
        await _stopPlayback();
        return;
      }
      _player ??= AudioPlayer();
      _sub ??= _player!.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _playing = false);
      });
      await _player!.play(DeviceFileSource(_path!));
      if (mounted) setState(() => _playing = true);
    } catch (e) {
      debugPrint('خطأ في التشغيل: $e');
    }
  }

  Future<void> _delete() async {
    await _stopPlayback();
    final p = _path;
    setState(() => _path = null);
    widget.onChanged(null);
    try {
      if (p != null) await File(p).delete();
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    _player?.dispose();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_recording) {
      return Row(
        children: [
          const Icon(Icons.fiber_manual_record, color: Colors.redAccent),
          const SizedBox(width: 8),
          const Expanded(child: Text('جاري التسجيل...', style: TextStyle(color: Colors.redAccent))),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: stopIfRecording,
            icon: const Icon(Icons.stop, color: Colors.white),
            label: const Text('إيقاف', style: TextStyle(color: Colors.white)),
          ),
        ],
      );
    }
    if (_path != null) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _togglePlay,
              icon: Icon(_playing ? Icons.stop_circle_outlined : Icons.play_circle_outline, color: const Color(0xFF8FEFEF)),
              label: Text(_playing ? 'إيقاف' : 'تشغيل التسجيل', style: const TextStyle(color: Color(0xFF8FEFEF))),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF8FEFEF))),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _delete,
            icon: const Icon(Icons.delete_rounded, color: Colors.redAccent),
            tooltip: 'حذف التسجيل',
          ),
        ],
      );
    }
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _start,
        icon: const Icon(Icons.mic, color: Color(0xFF8FEFEF)),
        label: const Text('تسجيل مقطع صوتي', style: TextStyle(color: Color(0xFF8FEFEF))),
        style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF8FEFEF))),
      ),
    );
  }
}


/// Deletes `IMMO V<number>.apk` (also `ImmoV3.apk` and duplicates like `IMMO V3 (1).apk`)
/// anywhere in the phone's storage, including nested sub-folders. Runs only when the app is opened/resumed.
Future<void> cleanupUpdateApks() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    if (!await Permission.manageExternalStorage.isGranted) return;
    final root = Directory('/storage/emulated/0');
    if (!await root.exists()) return;
    // IMMO V3.apk, ImmoV3.apk, IMMO V3 (1).apk, IMMO V3(1).apk ...
    final pattern = RegExp(r'^IMMO\s*V\d+(\s*\(\d+\))?\.apk$', caseSensitive: false);

    // Manual walk: one unreadable folder must not stop the whole search.
    final stack = <MapEntry<Directory, int>>[MapEntry(root, 0)];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      final List<FileSystemEntity> children;
      try {
        children = await current.key.list(followLinks: false).toList();
      } catch (_) {
        continue;
      }
      for (final entity in children) {
        final name = entity.path.split('/').last;
        if (entity is File) {
          if (pattern.hasMatch(name)) {
            try {
              await entity.delete();
            } catch (e) {
              debugPrint('تعذر حذف ${entity.path}: $e');
            }
          }
        } else if (entity is Directory && current.value < 12) {
          // "Android" holds other apps' private data (unreadable); skip hidden folders.
          if (name.startsWith('.') || (current.value == 0 && name == 'Android')) continue;
          stack.add(MapEntry(entity, current.value + 1));
        }
      }
    }
  } catch (e) {
    debugPrint('cleanupUpdateApks: $e');
  }
}

/// Blocks the whole app until "All files access" is granted.
class StoragePermissionGate extends StatefulWidget {
  final Widget child;
  const StoragePermissionGate({super.key, required this.child});

  @override
  State<StoragePermissionGate> createState() => _StoragePermissionGateState();
}

class _StoragePermissionGateState extends State<StoragePermissionGate> with WidgetsBindingObserver {
  bool? _granted;
  bool _requesting = false;

  bool get _needsGate => !kIsWeb && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the Settings screen.
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (!_needsGate) {
      if (mounted) setState(() => _granted = true);
      return;
    }
    bool ok = false;
    try {
      ok = await Permission.manageExternalStorage.isGranted;
    } catch (_) {}
    if (mounted) setState(() => _granted = ok);
  }

  Future<void> _request() async {
    if (_requesting) return;
    _requesting = true;
    try {
      final status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) {
        // The system page can't be shown again after repeated denial.
        if (status.isPermanentlyDenied) await openAppSettings();
      }
    } catch (e) {
      debugPrint('Permission error: $e');
      await openAppSettings();
    } finally {
      _requesting = false;
      await _check();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_granted == true) return widget.child;
    if (_granted == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: Color(0xFF8FEFEF))));
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.folder_open_rounded, size: 72, color: Color(0xFF8FEFEF)),
                const SizedBox(height: 16),
                const Text('إذن الوصول إلى التخزين مطلوب',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF8FEFEF))),
                const SizedBox(height: 12),
                const Text(
                  'لا يمكن استخدام التطبيق بدون منح إذن "الوصول إلى جميع الملفات". اضغط على الزر ثم فعّل الإذن للتطبيق وارجع إليه.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 15),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8FEFEF),
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                  ),
                  onPressed: _request,
                  child: const Text('منح الإذن',
                      style: TextStyle(color: Color(0xFF0B132B), fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shares only the given files (no text). Files are copied to the cache first.
Future<void> shareFilesOnly(BuildContext context, List<String> paths) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final tmp = await getTemporaryDirectory();
    final files = <XFile>[];
    for (var i = 0; i < paths.length; i++) {
      final src = File(paths[i]);
      if (!await src.exists()) continue;
      final dst = await src.copy('${tmp.path}/share_${DateTime.now().millisecondsSinceEpoch}_${i}_${paths[i].split('/').last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}');
      files.add(XFile(dst.path));
    }
    if (files.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('لا توجد ملفات للمشاركة.')));
      return;
    }
    await SharePlus.instance.share(ShareParams(files: files));
  } catch (e) {
    debugPrint('خطأ في المشاركة: $e');
    messenger.showSnackBar(const SnackBar(content: Text('تعذرت المشاركة.')));
  }
}

/// 1200000 -> 1,200,000 (only plain digit strings are reformatted).
String formatPrice(String raw) {
  final t = raw.trim();
  final digits = t.replaceAll(RegExp(r'[,\s]'), '');
  if (!RegExp(r'^\d+$').hasMatch(digits)) return t;
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return buf.toString();
}

/// Toggles between landscape and portrait; restores auto-rotation on close.
class OrientationToggleButton extends StatefulWidget {
  const OrientationToggleButton({super.key});

  @override
  State<OrientationToggleButton> createState() => _OrientationToggleButtonState();
}

class _OrientationToggleButtonState extends State<OrientationToggleButton> {
  bool _landscape = false;

  void _toggle() {
    setState(() => _landscape = !_landscape);
    SystemChrome.setPreferredOrientations(
      _landscape
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp],
    );
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(_landscape ? Icons.stay_current_portrait : Icons.stay_current_landscape, color: Colors.white),
      tooltip: _landscape ? 'عمودي' : 'أفقي',
      onPressed: _toggle,
    );
  }
}

/// Pinch-to-zoom plus +/- buttons around any child (image or video).
class ZoomBox extends StatefulWidget {
  final Widget child;
  const ZoomBox({super.key, required this.child});

  @override
  State<ZoomBox> createState() => _ZoomBoxState();
}

class _ZoomBoxState extends State<ZoomBox> {
  final TransformationController _tc = TransformationController();
  Size _size = Size.zero;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _zoom(double factor) {
    final s = (_tc.value.getMaxScaleOnAxis() * factor).clamp(1.0, 5.0);
    final cx = _size.width / 2, cy = _size.height / 2;
    _tc.value = Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(cx * (1 - s), cy * (1 - s), 0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _size = Size(constraints.maxWidth, constraints.maxHeight);
      return Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _tc,
              minScale: 1,
              maxScale: 5,
              child: Center(child: widget.child),
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: Column(
              children: [
                IconButton.filledTonal(onPressed: () => _zoom(1.5), icon: const Icon(Icons.zoom_in), tooltip: 'تكبير'),
                IconButton.filledTonal(onPressed: () => _zoom(1 / 1.5), icon: const Icon(Icons.zoom_out), tooltip: 'تصغير'),
              ],
            ),
          ),
        ],
      );
    });
  }
}

/// Full-screen video player for a property's videos.
class VideoViewerScreen extends StatelessWidget {
  final List<String> videos;
  const VideoViewerScreen({super.key, required this.videos});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text('الفيديوهات (${videos.length})', style: const TextStyle(color: Colors.white)),
        actions: const [OrientationToggleButton()],
      ),
      body: PageView.builder(
        itemCount: videos.length,
        itemBuilder: (context, i) => _VideoPage(path: videos[i]),
      ),
    );
  }
}

class _VideoPage extends StatefulWidget {
  final String path;
  const _VideoPage({required this.path});

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _controller;
  bool _failed = false;
  double _speed = 1.0;

  void _seekBy(int seconds) {
    final c = _controller!;
    var t = c.value.position + Duration(seconds: seconds);
    if (t < Duration.zero) t = Duration.zero;
    if (t > c.value.duration) t = c.value.duration;
    c.seekTo(t);
  }

  @override
  void initState() {
    super.initState();
    final c = VideoPlayerController.file(File(widget.path));
    _controller = c;
    c.initialize().then((_) {
      if (mounted) setState(() {});
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
    c.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller!;
    if (_failed) {
      return const Center(child: Icon(Icons.broken_image, color: Color(0xFF64748B), size: 64));
    }
    if (!c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF8FEFEF)));
    }
    return Column(
      children: [
        Expanded(
          child: Center(
            child: ZoomBox(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))),
          ),
        ),
        VideoProgressIndicator(c, allowScrubbing: true, colors: const VideoProgressColors(playedColor: Color(0xFF8FEFEF))),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              iconSize: 36,
              color: const Color(0xFF8FEFEF),
              icon: const Icon(Icons.replay_5),
              tooltip: 'رجوع 5 ثوان',
              onPressed: () => _seekBy(-5),
            ),
            IconButton(
              iconSize: 48,
              color: const Color(0xFF8FEFEF),
              icon: Icon(c.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
              onPressed: () => c.value.isPlaying ? c.pause() : c.play(),
            ),
            IconButton(
              iconSize: 36,
              color: const Color(0xFF8FEFEF),
              icon: const Icon(Icons.forward_5),
              tooltip: 'تقديم 5 ثوان',
              onPressed: () => _seekBy(5),
            ),
            PopupMenuButton<double>(
              tooltip: 'السرعة',
              initialValue: _speed,
              onSelected: (v) {
                setState(() => _speed = v);
                c.setPlaybackSpeed(v);
              },
              itemBuilder: (_) => const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                  .map((v) => PopupMenuItem(value: v, child: Text('${v}x')))
                  .toList(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('${_speed}x', style: const TextStyle(color: Color(0xFF8FEFEF), fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
