import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'property_model.dart';

/// Small counters that cannot be derived from the files on disk (what was deleted or
/// marked as done). Stored next to the data and wiped with it.
class StatsStore {
  StatsStore._();
  static final StatsStore instance = StatsStore._();

  Future<File> _file() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/stats.json');
  }

  Future<Map<String, int>> read() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return m.map((k, v) => MapEntry(k, (v as num).toInt()));
      }
    } catch (_) {}
    return {};
  }

  Future<void> bump(String key, int delta) async {
    try {
      final m = await read();
      m[key] = ((m[key] ?? 0) + delta).clamp(0, 1 << 30);
      await (await _file()).writeAsString(jsonEncode(m));
    } catch (e) {
      debugPrint('stats: $e');
    }
  }

  Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// Numbers for one section (properties or requests).
class SectionStats {
  int total = 0; // currently stored
  int done = 0; // sold / rented / found (including ones deleted later)
  int deleted = 0;
  int favorites = 0;
  final Map<String, int> byType = {}; // sell / local / buy
  final Map<String, int> byCategory = {};
  final Map<String, int> byCity = {};
  final Map<String, int> addedPerMonth = {}; // "2026-11" -> count

  int get everAdded => total + deleted;
  int get active => (total - currentDone).clamp(0, total);
  int currentDone = 0;
  double get successRate => everAdded == 0 ? 0 : (done / everAdded).clamp(0, 1).toDouble();
}

class AccountStats {
  final SectionStats properties;
  final SectionStats requests;
  AccountStats(this.properties, this.requests);

  static Future<SectionStats> _scan(String folder, int done, int deleted) async {
    final st = SectionStats()
      ..done = done
      ..deleted = deleted;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final root = Directory('${docs.path}/$folder');
      if (await root.exists()) {
        await for (final e in root.list(recursive: true, followLinks: false)) {
          if (e is! File || !e.path.endsWith('/data.json')) continue;
          try {
            final p = Property.fromJson(jsonDecode(await e.readAsString()) as Map<String, dynamic>, e.parent.path);
            st.total++;
            if (p.isDone) st.currentDone++;
            if (p.isFavorite) st.favorites++;
            st.byType[p.type] = (st.byType[p.type] ?? 0) + 1;
            st.byCategory[p.category] = (st.byCategory[p.category] ?? 0) + 1;
            if (p.city.isNotEmpty) st.byCity[p.city] = (st.byCity[p.city] ?? 0) + 1;
            final d = DateTime.tryParse(p.createdAt);
            if (d != null) {
              final k = '${d.year}-${d.month.toString().padLeft(2, '0')}';
              st.addedPerMonth[k] = (st.addedPerMonth[k] ?? 0) + 1;
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('stats scan: $e');
    }
    // A done item that is still stored must be counted at least once.
    if (st.done < st.currentDone) st.done = st.currentDone;
    return st;
  }

  static Future<AccountStats> load() async {
    final c = await StatsStore.instance.read();
    final p = await _scan('uploads', c['done_properties'] ?? 0, c['deleted_properties'] ?? 0);
    final r = await _scan('requests', c['done_requests'] ?? 0, c['deleted_requests'] ?? 0);
    return AccountStats(p, r);
  }
}
