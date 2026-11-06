import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'device_lock.dart';
import 'devices_screen.dart';
import 'license.dart';
import 'stats.dart';
import 'sync_service.dart';

const Color _accent = Color(0xFF8FEFEF);
const Color _card = Color(0xFF152238);
const Color _green = Color(0xFF22C55E);
const Color _amber = Color(0xFFF59E0B);
const Color _red = Color(0xFFEF4444);
const Color _blue = Color(0xFF38BDF8);

/// Index of the visible bottom tab; the account page refreshes its numbers when it is opened.
final ValueNotifier<int> currentTab = ValueNotifier<int>(0);
const int kAccountTab = 3;

/// "حسابي": account details, statistics with charts, connected devices, logout and delete.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  AccountStats? _stats;
  String _name = '', _code = '', _phone = '';
  int _since = 0;
  LicenseState? _lic;

  @override
  void initState() {
    super.initState();
    _load();
    dataRevision.addListener(_load);
    authRevision.addListener(_load);
    currentTab.addListener(_onTab);
  }

  @override
  void dispose() {
    dataRevision.removeListener(_load);
    authRevision.removeListener(_load);
    currentTab.removeListener(_onTab);
    super.dispose();
  }

  void _onTab() {
    if (currentTab.value == kAccountTab) _load();
  }

  Future<void> _load() async {
    final acc = AccountStore.instance;
    final stats = await AccountStats.load();
    final name = await acc.displayName();
    final code = await acc.userCode();
    final phone = await acc.phone();
    final since = await acc.createdAt();
    final lic = await LicenseStore.instance.load();
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _name = name;
      _code = code;
      _phone = phone;
      _since = since;
      _lic = lic;
    });
  }

  String _licenseText() {
    final l = _lic;
    if (l == null) return '';
    if (l.type == LicenseType.permanent) return 'الترخيص: دائم (إلى الأبد)';
    if (l.type == LicenseType.trial) {
      final left = l.trialRemaining;
      return 'الترخيص: مؤقت — المتبقي ${left.inDays} يوم ${left.inHours % 24} س ${left.inMinutes % 60} د';
    }
    return '';
  }

  String _date(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _showAbout() async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121C3A),
        title: const Text('حول التطبيق', style: TextStyle(color: _accent)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('جميع حقوق الطباعة والنشر محفوظة © SmileyRush', style: TextStyle(color: Color(0xFFCBD5E1))),
            const SizedBox(height: 12),
            const Text('تيليجرام: @SmileyRush', style: TextStyle(color: _blue)),
            const SizedBox(height: 12),
            if (_licenseText().isNotEmpty) Text(_licenseText(), style: const TextStyle(color: Color(0xFFCBD5E1))),
            Text('الإصدار: $kAppVersion', style: const TextStyle(color: Color(0xFF64748B))),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final ok = await launchUrl(Uri.parse('https://t.me/SmileyRush'), mode: LaunchMode.externalApplication).catchError((_) => false);
              if (!ok) {
                await Clipboard.setData(const ClipboardData(text: 'https://t.me/SmileyRush'));
                messenger.showSnackBar(const SnackBar(content: Text('تم نسخ رابط التلجرام.')));
              }
            },
            child: const Text('فتح التلجرام'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    await SyncService.instance.announceLogout();
    await AccountStore.instance.logout();
  }

  Future<void> _confirmDeleteAccount() async {
    final pass = TextEditingController();
    bool everywhere = false;
    String? error;
    bool busy = false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: const Color(0xFF121C3A),
          title: const Text('حذف الحساب', style: TextStyle(color: Colors.redAccent)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'سيتم حذف الحساب وجميع العقارات والطلبات والصور والفيديوهات والتسجيلات من هذا الجهاز نهائيا ولا يمكن التراجع.',
                  style: TextStyle(color: Color(0xFFCBD5E1)),
                ),
                const SizedBox(height: 12),
                TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور')),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: everywhere,
                  onChanged: (v) => setS(() => everywhere = v),
                  title: const Text('احذفه أيضا من جميع أجهزتي', style: TextStyle(fontSize: 14)),
                ),
                const Text('سيُطلب منك رمز قفل هاتفك للتأكيد.', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
                if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      setS(() => busy = true);
                      final good = await AccountStore.instance.verifyPassword(pass.text) &&
                          await DeviceLock.confirm('أكّد برمز قفل هاتفك حذف الحساب نهائيا');
                      if (!good) {
                        setS(() {
                          busy = false;
                          error = 'كلمة المرور أو رمز القفل غير صحيح.';
                        });
                        return;
                      }
                      await SyncService.instance.deleteAccount(everywhere: everywhere);
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    },
              child: const Text('حذف نهائي', style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
      ),
    );
    pass.dispose();
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حذف الحساب وجميع البيانات.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = _stats;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('حسابي', style: TextStyle(color: _accent, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh, color: _accent), tooltip: 'تحديث الأرقام', onPressed: _load),
          IconButton(icon: const Icon(Icons.more_vert, color: _accent), tooltip: 'حول', onPressed: _showAbout),
        ],
      ),
      body: st == null
          ? const Center(child: CircularProgressIndicator(color: _accent))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _profileCard(),
                  const SizedBox(height: 12),
                  _tile(
                    icon: Icons.devices_rounded,
                    title: 'الأجهزة المتصلة',
                    subtitle: 'الأجهزة المسجلة بهذا الحساب',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DevicesScreen())),
                  ),
                  const SizedBox(height: 16),
                  _sectionTitle('الإحصائيات'),
                  _summaryCards(st),
                  const SizedBox(height: 12),
                  _chartCard('الإضافات خلال آخر 6 أشهر', _MonthlyChart(properties: st.properties.addedPerMonth, requests: st.requests.addedPerMonth)),
                  const SizedBox(height: 12),
                  _chartCard('حالة العقارات', _StatusBar(section: st.properties, doneLabel: 'مباعة/مكراة')),
                  const SizedBox(height: 12),
                  _chartCard('حالة الطلبات', _StatusBar(section: st.requests, doneLabel: 'تم إيجادها')),
                  const SizedBox(height: 12),
                  _chartCard('العقارات حسب النوع', _TypeBars(section: st.properties, requests: false)),
                  const SizedBox(height: 12),
                  _chartCard('الطلبات حسب النوع', _TypeBars(section: st.requests, requests: true)),
                  if (st.properties.byCity.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _chartCard('أكثر المدن في عقاراتك', _TopBars(data: st.properties.byCity)),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _logout,
                      icon: const Icon(Icons.logout_rounded, color: Colors.redAccent),
                      label: const Text('تسجيل الخروج', style: TextStyle(color: Colors.redAccent)),
                      style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.redAccent), padding: const EdgeInsets.all(14)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _confirmDeleteAccount,
                      icon: const Icon(Icons.delete_forever_rounded, color: Colors.white),
                      label: const Text('حذف الحساب', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, padding: const EdgeInsets.all(14)),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }

  Widget _profileCard() {
    Widget row(String label, String value, {bool copy = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Text('$label: ', style: const TextStyle(color: Color(0xFF94A3B8))),
              Expanded(child: SelectableText(value.isEmpty ? '—' : value, textDirection: TextDirection.ltr, textAlign: TextAlign.start)),
              if (copy && value.isNotEmpty)
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: value));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم النسخ.')));
                  },
                  child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.copy_rounded, size: 18, color: _accent)),
                ),
            ],
          ),
        );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF4A5568))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const CircleAvatar(radius: 26, backgroundColor: Color(0xFF1E3A5F), child: Icon(Icons.person_rounded, color: _accent, size: 30)),
              const SizedBox(width: 12),
              Expanded(child: Text(_name.isEmpty ? '—' : _name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
            ],
          ),
          const Divider(color: Color(0xFF4A5568), height: 24),
          row('رمز المستخدم', _code, copy: true),
          row('رقم الهاتف', _phone),
          row('تاريخ إنشاء الحساب', _date(_since)),
          if (_licenseText().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_licenseText(), style: const TextStyle(color: Color(0xFFCBD5E1)))),
        ],
      ),
    );
  }

  Widget _tile({required IconData icon, required String title, String? subtitle, required VoidCallback onTap}) {
    return Material(
      color: _card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon, color: _accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    if (subtitle != null) Text(subtitle, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFF64748B)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _accent)),
      );

  Widget _chartCard(String title, Widget child) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF4A5568))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      );

  Widget _summaryCards(AccountStats st) {
    Widget box(String label, String value, Color c) => Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.withValues(alpha: 0.6))),
            child: Column(
              children: [
                Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: c)),
                const SizedBox(height: 2),
                Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFFCBD5E1)), textAlign: TextAlign.center),
              ],
            ),
          ),
        );
    String pct(SectionStats s) => '${(s.successRate * 100).round()}%';
    return Column(
      children: [
        Row(children: [
          box('عقارات مخزنة', '${st.properties.total}', _accent),
          box('ناجحة', '${st.properties.done}', _green),
          box('محذوفة', '${st.properties.deleted}', _red),
          box('نسبة النجاح', pct(st.properties), _amber),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          box('طلبات مخزنة', '${st.requests.total}', _accent),
          box('ناجحة', '${st.requests.done}', _green),
          box('محذوفة', '${st.requests.deleted}', _red),
          box('نسبة النجاح', pct(st.requests), _amber),
        ]),
      ],
    );
  }
}

String _typeName(String t, bool requests) {
  switch (t) {
    case 'sell':
      return 'بيع';
    case 'local':
      return 'كراء';
    case 'buy':
      return 'شراء';
  }
  return t;
}

class _Legend extends StatelessWidget {
  final List<(String, Color)> items;
  const _Legend(this.items);

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          for (final (label, color) in items)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFFCBD5E1))),
            ]),
        ],
      );
}

/// Grouped bars: additions per month (properties vs requests), last 6 months.
class _MonthlyChart extends StatelessWidget {
  final Map<String, int> properties;
  final Map<String, int> requests;
  const _MonthlyChart({required this.properties, required this.requests});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final months = <String>[];
    for (var i = 5; i >= 0; i--) {
      final d = DateTime(now.year, now.month - i, 1);
      months.add('${d.year}-${d.month.toString().padLeft(2, '0')}');
    }
    final p = [for (final m in months) properties[m] ?? 0];
    final r = [for (final m in months) requests[m] ?? 0];
    return Column(
      children: [
        SizedBox(
          height: 150,
          width: double.infinity,
          child: CustomPaint(painter: _BarsPainter(labels: [for (final m in months) m.substring(5)], a: p, b: r)),
        ),
        const SizedBox(height: 8),
        const _Legend([('عقارات', _accent), ('طلبات', _amber)]),
      ],
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<String> labels;
  final List<int> a, b;
  _BarsPainter({required this.labels, required this.a, required this.b});

  @override
  void paint(Canvas canvas, Size size) {
    const bottom = 18.0, top = 14.0;
    final maxV = math.max(1, [...a, ...b].reduce(math.max));
    final h = size.height - bottom - top;
    final slot = size.width / labels.length;
    final bw = math.min(slot / 3, 22.0);
    final grid = Paint()..color = const Color(0xFF2D3748)..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = top + h - h * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    void bar(double x, int v, Color c) {
      final bh = h * v / maxV;
      final rect = RRect.fromRectAndRadius(Rect.fromLTWH(x, top + h - bh, bw, bh), const Radius.circular(3));
      canvas.drawRRect(rect, Paint()..color = c);
      if (v > 0) _text(canvas, '$v', Offset(x + bw / 2, top + h - bh - 12), 10, const Color(0xFFE2E8F0));
    }
    for (var i = 0; i < labels.length; i++) {
      final cx = slot * i + slot / 2;
      bar(cx - bw - 1, a[i], _accent);
      bar(cx + 1, b[i], _amber);
      _text(canvas, labels[i], Offset(cx, size.height - 10), 11, const Color(0xFF94A3B8));
    }
  }

  void _text(Canvas canvas, String t, Offset center, double size, Color color) {
    final tp = TextPainter(text: TextSpan(text: t, style: TextStyle(fontSize: size, color: color)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) => true;
}

/// Stacked bar: active / done / deleted.
class _StatusBar extends StatelessWidget {
  final SectionStats section;
  final String doneLabel;
  const _StatusBar({required this.section, required this.doneLabel});

  @override
  Widget build(BuildContext context) {
    final active = section.active, done = section.done, deleted = section.deleted;
    final sum = active + done + deleted;
    if (sum == 0) return const Text('لا توجد بيانات بعد.', style: TextStyle(color: Color(0xFF94A3B8)));
    Widget seg(int v, Color c) => v == 0 ? const SizedBox.shrink() : Expanded(flex: v, child: Container(height: 22, color: c, alignment: Alignment.center, child: Text('$v', style: const TextStyle(fontSize: 12, color: Colors.black87, fontWeight: FontWeight.bold))));
    return Column(
      children: [
        ClipRRect(borderRadius: BorderRadius.circular(8), child: Row(children: [seg(done, _green), seg(active, _accent), seg(deleted, _red)])),
        const SizedBox(height: 8),
        Align(alignment: AlignmentDirectional.centerStart, child: _Legend([(doneLabel, _green), ('قائمة', _accent), ('محذوفة', _red)])),
        const SizedBox(height: 6),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text('نسبة النجاح: ${(section.successRate * 100).round()}% من ${section.everAdded} أُضيفت', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
        ),
      ],
    );
  }
}

class _TypeBars extends StatelessWidget {
  final SectionStats section;
  final bool requests;
  const _TypeBars({required this.section, required this.requests});

  @override
  Widget build(BuildContext context) {
    if (section.byType.isEmpty) return const Text('لا توجد بيانات بعد.', style: TextStyle(color: Color(0xFF94A3B8)));
    return _TopBars(data: {for (final e in section.byType.entries) _typeName(e.key, requests): e.value});
  }
}

/// Horizontal bars for a name -> count map (top 6).
class _TopBars extends StatelessWidget {
  final Map<String, int> data;
  const _TopBars({required this.data});

  @override
  Widget build(BuildContext context) {
    final entries = data.entries.toList()..sort((x, y) => y.value.compareTo(x.value));
    final top = entries.take(6).toList();
    final maxV = top.isEmpty ? 1 : top.first.value;
    return Column(
      children: [
        for (final e in top)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(width: 84, child: Text(e.key, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                Expanded(
                  child: LayoutBuilder(
                    builder: (_, c) => Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Container(
                        width: math.max(6.0, c.maxWidth * e.value / maxV),
                        height: 16,
                        decoration: BoxDecoration(color: _blue, borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${e.value}', style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
      ],
    );
  }
}
