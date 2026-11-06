import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'sync_service.dart';

String _fmt(int ms) {
  if (ms <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
}

/// Devices signed in to the same account.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Re-evaluate "online / offline" regularly.
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _openMap(double lat, double lon) async {
    await launchUrl(Uri.parse('https://www.google.com/maps?q=$lat,$lon'), mode: LaunchMode.externalApplication)
        .catchError((_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('الأجهزة المتصلة',
            style: TextStyle(color: Color(0xFF8FEFEF), fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF8FEFEF)),
            tooltip: 'تحديث',
            onPressed: () => SyncService.instance.hello(),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<DeviceRecord>>(
        valueListenable: SyncService.instance.devices,
        builder: (context, list, _) {
          if (list.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'لا توجد أجهزة بعد. افتح التطبيق على جهازك الآخر وسجّل الدخول بنفس الحساب.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFA0AEC0), fontSize: 16),
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final d = list[i];
              final online = d.online;
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF152238),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: online ? const Color(0xFF10B981) : const Color(0xFF4A5568)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.smartphone_rounded, color: online ? const Color(0xFF10B981) : const Color(0xFF64748B)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            d.isSelf ? '${d.name} (هذا الجهاز)' : d.name,
                            style: const TextStyle(color: Color(0xFF8FEFEF), fontSize: 17, fontWeight: FontWeight.bold),
                          ),
                        ),
                        Text(online ? 'متصل' : 'غير متصل',
                            style: TextStyle(color: online ? const Color(0xFF10B981) : const Color(0xFF64748B), fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('النوع: ${d.platform}', style: const TextStyle(color: Color(0xFFCBD5E1))),
                    const SizedBox(height: 4),
                    d.lat != null && d.lon != null
                        ? GestureDetector(
                            onTap: () => _openMap(d.lat!, d.lon!),
                            child: Text('الموقع: ${d.lat!.toStringAsFixed(4)}, ${d.lon!.toStringAsFixed(4)}  (فتح الخريطة)',
                                style: const TextStyle(color: Color(0xFF38BDF8))),
                          )
                        : const Text('الموقع: غير متاح', style: TextStyle(color: Color(0xFF64748B))),
                    const SizedBox(height: 4),
                    Text('آخر ظهور: ${d.isSelf ? 'الآن' : _fmt(d.lastSeen)}', style: const TextStyle(color: Color(0xFFCBD5E1))),
                    const SizedBox(height: 4),
                    Text('تسجيل الدخول: ${_fmt(d.loginAt)}', style: const TextStyle(color: Color(0xFFCBD5E1))),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
