import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import 'license.dart';

const String kUpdateRepoOwner = 'RushBas01';
const String kUpdateRepoName = 'IMMo';
const String kUpdatePrice = '3\$';

class UpdateInfo {
  final int version;
  final String name;
  final String url;
  UpdateInfo(this.version, this.name, this.url);
}

/// Looks for files named ImmoV<N>.apk in the GitHub repo (root folder or the
/// latest release) and drives the "pay + permanent key + download" flow.
class UpdateManager {
  UpdateManager._();
  static final UpdateManager instance = UpdateManager._();

  /// A newer version exists (shown as a top bar once the popup was dismissed).
  final ValueNotifier<UpdateInfo?> pending = ValueNotifier<UpdateInfo?>(null);
  final ValueNotifier<bool> showBar = ValueNotifier<bool>(false);
  bool _checking = false;
  bool _dialogOpen = false;

  static final RegExp _namePattern = RegExp(r'^ImmoV(\d+)\.apk$', caseSensitive: false);

  Future<dynamic> _getJson(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'ImmoApp');
      req.headers.set('Accept', 'application/vnd.github+json');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) throw HttpException('HTTP ${resp.statusCode}');
      return jsonDecode(await resp.transform(utf8.decoder).join());
    } finally {
      client.close(force: true);
    }
  }

  UpdateInfo? _best(Iterable<MapEntry<String, String>> nameToUrl) {
    UpdateInfo? best;
    for (final e in nameToUrl) {
      final m = _namePattern.firstMatch(e.key);
      if (m == null) continue;
      final v = int.parse(m.group(1)!);
      if (best == null || v > best.version) best = UpdateInfo(v, e.key, e.value);
    }
    return best;
  }

  Future<UpdateInfo?> fetchLatest() async {
    final base = 'https://api.github.com/repos/$kUpdateRepoOwner/$kUpdateRepoName';
    UpdateInfo? best;
    try {
      final files = await _getJson('$base/contents/') as List;
      best = _best(files
          .where((f) => f['type'] == 'file' && f['download_url'] != null)
          .map((f) => MapEntry(f['name'].toString(), f['download_url'].toString())));
    } catch (e) {
      debugPrint('update check (contents): $e');
    }
    try {
      final rel = await _getJson('$base/releases/latest') as Map<String, dynamic>;
      final fromRelease = _best(((rel['assets'] as List?) ?? [])
          .map((a) => MapEntry(a['name'].toString(), a['browser_download_url'].toString())));
      if (fromRelease != null && (best == null || fromRelease.version > best.version)) best = fromRelease;
    } catch (e) {
      debugPrint('update check (release): $e');
    }
    return best;
  }

  /// Call after the user is logged in. Shows the popup once per version.
  Future<void> check(BuildContext context) async {
    if (_checking || kIsWeb || !Platform.isAndroid) return;
    _checking = true;
    try {
      final latest = await fetchLatest();
      if (latest == null || latest.version <= kAppVersion) {
        pending.value = null;
        showBar.value = false;
        return;
      }
      pending.value = latest;
      final ignored = await LicenseStore.instance.getIgnoredVersion();
      if (ignored >= latest.version) {
        showBar.value = true;
      } else if (context.mounted) {
        await showUpdatePopup(context, latest);
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> showUpdatePopup(BuildContext context, UpdateInfo info) async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    final agree = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121C3A),
        title: const Text('تحديث جديد متوفر', style: TextStyle(color: Color(0xFF8FEFEF))),
        content: Text(
          'تم إصدار تحديث جديد (الإصدار ${info.version}).\n\nرسوم التحديث: $kUpdatePrice\n\nهل توافق على التحديث؟ سيُطلب منك إدخال مفتاح دائم جديد.',
          style: const TextStyle(color: Color(0xFFCBD5E1)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('تجاهل', style: TextStyle(color: Colors.white70))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('موافق')),
        ],
      ),
    );
    _dialogOpen = false;
    if (agree == true && context.mounted) {
      await promptKeyAndUpdate(context, info);
    } else {
      await LicenseStore.instance.setIgnoredVersion(info.version);
      showBar.value = true;
    }
  }

  /// Asks for a new permanent key; downloads only if the key is valid.
  Future<void> promptKeyAndUpdate(BuildContext context, UpdateInfo info) async {
    final controller = TextEditingController();
    String? error;
    final key = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: const Color(0xFF121C3A),
          title: const Text('أدخل المفتاح الدائم الجديد', style: TextStyle(color: Color(0xFF8FEFEF))),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                maxLength: 40,
                decoration: InputDecoration(labelText: 'المفتاح (40 حرفا ورقما)', errorText: error),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء', style: TextStyle(color: Colors.white70))),
            ElevatedButton(
              onPressed: () async {
                setS(() => error = 'جاري التحقق من المفتاح...');
                var err = await LicenseStore.instance.checkKey(controller.text, permanentOnly: true);
                // Single use across devices: claim the key before downloading.
                err ??= await LicenseStore.instance.claimOnly(controller.text);
                if (err != null) {
                  setS(() => error = err);
                } else if (ctx.mounted) {
                  Navigator.pop(ctx, controller.text.trim());
                }
              },
              child: const Text('تحديث'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();

    if (key == null) {
      // No key -> nothing is downloaded. The top bar stays so the user can retry.
      await LicenseStore.instance.setIgnoredVersion(info.version);
      showBar.value = true;
      return;
    }
    if (!context.mounted) return;
    await _downloadAndInstall(context, info, key);
  }

  Future<void> _downloadAndInstall(BuildContext context, UpdateInfo info, String key) async {
    final progress = ValueNotifier<double?>(0);
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: const Color(0xFF121C3A),
          title: const Text('جاري تحميل التحديث...', style: TextStyle(color: Color(0xFF8FEFEF))),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, v, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: v, color: const Color(0xFF8FEFEF)),
                const SizedBox(height: 12),
                Text(v == null ? '' : '${(v * 100).toStringAsFixed(0)}%'),
              ],
            ),
          ),
        ),
      ),
    );

    File? file;
    String? failure;
    try {
      final dir = Directory('/storage/emulated/0/Download');
      if (!await dir.exists()) await dir.create(recursive: true);
      file = File('${dir.path}/${info.name}');
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
      try {
        final req = await client.getUrl(Uri.parse(info.url));
        req.headers.set('User-Agent', 'ImmoApp');
        final resp = await req.close();
        if (resp.statusCode != 200) throw HttpException('HTTP ${resp.statusCode}');
        final total = resp.contentLength;
        final sink = file.openWrite();
        var received = 0;
        try {
          await for (final chunk in resp) {
            sink.add(chunk);
            received += chunk.length;
            progress.value = total > 0 ? received / total : null;
          }
        } finally {
          await sink.flush();
          await sink.close();
        }
        if (total > 0 && received != total) throw const HttpException('incomplete download');
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      debugPrint('update download: $e');
      failure = 'فشل تحميل التحديث. تحقق من الاتصال بالإنترنت وحاول مرة أخرى.';
      try {
        if (file != null && await file.exists()) await file.delete();
      } catch (_) {}
    }

    navigator.pop(); // close progress dialog
    progress.dispose();

    if (failure != null || file == null) {
      messenger.showSnackBar(SnackBar(content: Text(failure ?? 'فشل التحديث.')));
      return; // key NOT consumed
    }
    await LicenseStore.instance.consumeKey(key); // consumed only after a successful download
    pending.value = null;
    showBar.value = false;
    final result = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
    if (result.type != ResultType.done) {
      messenger.showSnackBar(SnackBar(content: Text('تم تحميل التحديث في مجلد Download باسم ${info.name}. افتحه لتثبيته.')));
    }
  }
}

/// Top bar: "an update is waiting" + update button.
class UpdateBar extends StatelessWidget {
  const UpdateBar({super.key});

  @override
  Widget build(BuildContext context) {
    final m = UpdateManager.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: m.showBar,
      builder: (context, visible, _) {
        final info = m.pending.value;
        if (!visible || info == null) return const SizedBox.shrink();
        return Material(
          color: const Color(0xFF1E3A8A),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.system_update, color: Color(0xFF8FEFEF)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('يوجد تحديث بالانتظار (الإصدار ${info.version})', style: const TextStyle(color: Colors.white))),
                  TextButton(
                    onPressed: () => m.promptKeyAndUpdate(context, info),
                    child: const Text('تحديث', style: TextStyle(color: Color(0xFF8FEFEF), fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
