import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'license.dart';

const String kUpdateRepoOwner = 'RushBas01';
const String kUpdateRepoName = 'IMMo';
const String kUpdatePrice = '3\$';

class UpdateInfo {
  final int version;
  final String name;
  final String url;
  /// importance.txt says "higher": installed without asking and without a new key.
  final bool important;
  UpdateInfo(this.version, this.name, this.url, {this.important = false});
  UpdateInfo withImportance(bool v) => UpdateInfo(version, name, url, important: v);
}

/// Looks for the file of THIS platform in the GitHub repo (root folder or the latest
/// release) and drives the update flow. One repo serves every platform:
///   Android ImmoV<N>.apk | Windows ImmoV<N>.exe / .msi | Linux ImmoV<N>.AppImage / .deb
///   macOS ImmoV<N>.dmg   | iOS ImmoV<N>.ipa
/// importance.txt (same place) holds "higher" or "lower":
///   lower  -> popup, 3$ and a new permanent key (normal update)
///   higher -> installed immediately, no popup, no key (security fixes etc.)
class UpdateManager {
  UpdateManager._();
  static final UpdateManager instance = UpdateManager._();

  /// A newer version exists (shown as a top bar once the popup was dismissed).
  final ValueNotifier<UpdateInfo?> pending = ValueNotifier<UpdateInfo?>(null);
  final ValueNotifier<bool> showBar = ValueNotifier<bool>(false);
  bool _checking = false;
  bool _dialogOpen = false;

  static const String kImportanceFile = 'importance.txt';

  static String get _ext {
    if (Platform.isAndroid) return r'apk';
    if (Platform.isWindows) return r'(?:exe|msi)';
    if (Platform.isLinux) return r'(?:AppImage|deb)';
    if (Platform.isMacOS) return r'dmg';
    if (Platform.isIOS) return r'ipa';
    return r'apk';
  }

  static RegExp get _namePattern => RegExp('^ImmoV(\\d+)\\.$_ext\$', caseSensitive: false);

  Future<String> _getText(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'ImmoApp');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) throw HttpException('HTTP ${resp.statusCode}');
      return await resp.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

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
    String? importanceUrl;
    try {
      final files = await _getJson('$base/contents/') as List;
      best = _best(files
          .where((f) => f['type'] == 'file' && f['download_url'] != null)
          .map((f) => MapEntry(f['name'].toString(), f['download_url'].toString())));
      for (final f in files) {
        if (f['type'] == 'file' && f['name'].toString().toLowerCase() == kImportanceFile && f['download_url'] != null) {
          importanceUrl = f['download_url'].toString();
        }
      }
    } catch (e) {
      debugPrint('update check (contents): $e');
    }
    try {
      final rel = await _getJson('$base/releases/latest') as Map<String, dynamic>;
      final assets = (rel['assets'] as List?) ?? [];
      final fromRelease = _best(assets.map((a) => MapEntry(a['name'].toString(), a['browser_download_url'].toString())));
      if (fromRelease != null && (best == null || fromRelease.version > best.version)) best = fromRelease;
      for (final a in assets) {
        if (a['name'].toString().toLowerCase() == kImportanceFile && importanceUrl == null) {
          importanceUrl = a['browser_download_url'].toString();
        }
      }
    } catch (e) {
      debugPrint('update check (release): $e');
    }
    if (best != null && importanceUrl != null) {
      try {
        final t = (await _getText(importanceUrl)).trim().toLowerCase();
        best = best.withImportance(t.startsWith('high'));
      } catch (e) {
        debugPrint('update check (importance): $e');
      }
    }
    return best;
  }

  /// Call after the user is logged in. Shows the popup once per version.
  Future<void> check(BuildContext context) async {
    if (_checking || kIsWeb) return;
    _checking = true;
    try {
      final latest = await fetchLatest();
      if (latest == null || latest.version <= kAppVersion) {
        pending.value = null;
        showBar.value = false;
        return;
      }
      pending.value = latest;
      if (latest.important) {
        // Critical update: no question, no payment, no new key.
        if (context.mounted) await _forceUpdate(context, latest);
        return;
      }
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

  /// Mandatory update: downloads and installs without asking; retries until it works.
  Future<void> _forceUpdate(BuildContext context, UpdateInfo info) async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    try {
      while (context.mounted) {
        final ok = await _downloadAndInstall(context, info, null, forced: true);
        if (ok) break;
        if (!context.mounted) break;
        final retry = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF121C3A),
            title: const Text('تحديث أمني ضروري', style: TextStyle(color: Color(0xFFF59E0B))),
            content: const Text('تعذر تحميل التحديث الضروري. تحقق من الإنترنت وأعد المحاولة. التحديث مجاني.',
                style: TextStyle(color: Color(0xFFCBD5E1))),
            actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إعادة المحاولة'))],
          ),
        );
        if (retry != true) break;
      }
    } finally {
      _dialogOpen = false;
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
                minLines: 2,
                maxLines: 4,
                autocorrect: false,
                enableSuggestions: false,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(labelText: 'المفتاح الدائم (إلى الأبد)', errorText: error),
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

  /// Returns true when the installer was started (or the file saved). [key] is null for forced updates.
  Future<bool> _downloadAndInstall(BuildContext context, UpdateInfo info, String? key, {bool forced = false}) async {
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
          title: Text(forced ? 'جاري تثبيت تحديث أمني ضروري...' : 'جاري تحميل التحديث...', style: const TextStyle(color: Color(0xFF8FEFEF))),
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
      final dir = await _downloadDir();
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
      if (!forced) messenger.showSnackBar(SnackBar(content: Text(failure ?? 'فشل التحديث.')));
      return false; // key NOT consumed
    }
    if (key != null) await LicenseStore.instance.consumeKey(key); // consumed only after a successful download
    if (!forced) {
      // If the installer is cancelled the update stays available in the top bar.
      await LicenseStore.instance.setIgnoredVersion(info.version);
      showBar.value = true;
    }
    if (Platform.isIOS) {
      await launchUrl(Uri.parse(info.url), mode: LaunchMode.externalApplication).catchError((_) => false);
      return true;
    }
    final result = await OpenFilex.open(
      file.path,
      type: Platform.isAndroid ? 'application/vnd.android.package-archive' : null,
    );
    if (result.type != ResultType.done) {
      messenger.showSnackBar(SnackBar(content: Text('تم تحميل التحديث باسم ${info.name} في مجلد التنزيلات. افتحه لتثبيته.')));
    }
    return true;
  }

  Future<Directory> _downloadDir() async {
    if (Platform.isAndroid) return Directory('/storage/emulated/0/Download');
    return (await getDownloadsDirectory()) ?? await getTemporaryDirectory();
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
