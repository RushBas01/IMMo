import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'device_lock.dart';
import 'license.dart';
import 'license_key.dart';
import 'sync_service.dart';
import 'uninstall.dart';

const Color _accent = Color(0xFF8FEFEF);
const Color _fieldFill = Color(0xFF152238);

InputDecoration _dec(String label, {String? error}) => InputDecoration(
      labelText: label,
      errorText: error,
      labelStyle: const TextStyle(color: Color(0xFFCBD5E1)),
      filled: true,
      fillColor: _fieldFill,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF4A5568))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _accent)),
    );

/// Shows the activation screen until a valid key was used.
/// A trial that ran out of time wipes the app data and asks for a permanent key.
class LicenseGate extends StatefulWidget {
  final Widget child;
  const LicenseGate({super.key, required this.child});

  @override
  State<LicenseGate> createState() => _LicenseGateState();
}

class _LicenseGateState extends State<LicenseGate> with WidgetsBindingObserver {
  LicenseState? _state;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    authRevision.addListener(_reload);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    _timer?.cancel();
    authRevision.removeListener(_reload);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  DateTime _lastVerify = DateTime.fromMillisecondsSinceEpoch(0);
  bool _uninstallAsked = false;

  Future<void> _reload() async {
    final s = await LicenseStore.instance.evaluate();
    if (mounted) setState(() => _state = s);
    // Renew/verify the key claim in the background (never blocks the UI).
    if (s.claimSecret.isNotEmpty &&
        s.type != LicenseType.revoked &&
        DateTime.now().difference(_lastVerify) >= kVerifyEvery) {
      _lastVerify = DateTime.now();
      LicenseStore.instance.verifyClaim();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    if (s == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: _accent)));
    }
    switch (s.type) {
      case LicenseType.trial:
      case LicenseType.permanent:
        return widget.child;
      case LicenseType.grace:
        return ActivationScreen(mode: ActivationMode.grace, graceEnd: s.graceEndsAt);
      case LicenseType.expired:
        if (!_uninstallAsked) {
          _uninstallAsked = true;
          // The 3 days passed without payment: data is already wiped, now remove the app.
          WidgetsBinding.instance.addPostFrameCallback((_) => SelfUninstall.request());
        }
        return const ActivationScreen(mode: ActivationMode.expired);
      case LicenseType.revoked:
        return const ActivationScreen(mode: ActivationMode.revoked);
      case LicenseType.needsOnline:
        return const NeedsOnlineScreen();
      case LicenseType.none:
        return const ActivationScreen(mode: ActivationMode.fresh);
    }
  }
}

enum ActivationMode { fresh, expired, revoked, grace }

class ActivationScreen extends StatefulWidget {
  final ActivationMode mode;
  final int graceEnd; // ms, only for the grace mode
  const ActivationScreen({super.key, required this.mode, this.graceEnd = 0});

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final TextEditingController _key = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    activationNotice.removeListener(_notice);
    _key.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _notice();
    activationNotice.addListener(_notice);
  }

  void _notice() {
    final n = activationNotice.value;
    if (n != null && mounted) {
      setState(() => _error = n);
      activationNotice.value = null;
    }
  }

  String _graceLeft() {
    final left = DateTime.fromMillisecondsSinceEpoch(widget.graceEnd).difference(DateTime.now());
    if (left.isNegative) return 'أقل من دقيقة';
    return '${left.inDays} يوم ${left.inHours % 24} ساعة ${left.inMinutes % 60} دقيقة';
  }

  Future<void> _activate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await LicenseStore.instance.activate(_key.text);
    if (mounted) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.mode == ActivationMode.fresh ? Icons.vpn_key_rounded : (widget.mode == ActivationMode.revoked ? Icons.block : Icons.lock_clock), size: 72, color: widget.mode == ActivationMode.grace ? const Color(0xFFF59E0B) : _accent),
                const SizedBox(height: 16),
                Text(
                  widget.mode == ActivationMode.expired
                      ? 'انتهت المهلة وحُذف الحساب'
                      : widget.mode == ActivationMode.grace
                          ? 'انتهت مدة الترخيص'
                          : (widget.mode == ActivationMode.revoked ? 'المفتاح مستعمل على جهاز آخر' : 'تفعيل التطبيق'),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _accent),
                ),
                const SizedBox(height: 12),
                Text(
                  widget.mode == ActivationMode.expired
                      ? 'لم يُسدَّد المبلغ خلال 3 أيام فحُذف الحساب وبياناته. يمكنك شراء مفتاح جديد وإدخاله للبدء من جديد.'
                      : widget.mode == ActivationMode.grace
                          ? 'يلزم مفتاح التأبيد (إلى الأبد). بياناتك محفوظة ولم تُحذف: لديك مهلة ${_graceLeft()} لسداد المبلغ وإدخال المفتاح، وإلا سيُحذف الحساب وبياناته ويُلغى تثبيت التطبيق.'
                      : (widget.mode == ActivationMode.revoked
                          ? 'مفتاح هذا الجهاز فعّله جهاز آخر قبله، لذلك أُوقف هنا. لتتابع أدخل مفتاحا جديدا (بياناتك لم تُحذف).'
                          : 'الصق مفتاح التفعيل الذي أرسله لك المطور للمتابعة.'),
                  style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 15),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _key,
                  minLines: 2,
                  maxLines: 4,
                  autocorrect: false,
                  enableSuggestions: false,
                  textDirection: TextDirection.ltr,
                  decoration: _dec('مفتاح التفعيل', error: _error),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: _accent, padding: const EdgeInsets.all(14)),
                    onPressed: _busy ? null : _activate,
                    child: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('تفعيل', style: TextStyle(color: Color(0xFF0B132B), fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
                const SizedBox(height: 8),
                if (widget.mode == ActivationMode.fresh || widget.mode == ActivationMode.revoked)
                  TextButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RemoteLoginScreen())),
                    child: const Text('لدي حساب بالفعل (تسجيل الدخول بموافقة جهازي الآخر)', textAlign: TextAlign.center),
                  ),
                if (widget.mode == ActivationMode.expired)
                  TextButton(
                    onPressed: SelfUninstall.request,
                    child: const Text('إلغاء تثبيت التطبيق', style: TextStyle(color: Colors.redAccent)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when a key-activated license has not been verified online for over 7 days.
class NeedsOnlineScreen extends StatefulWidget {
  const NeedsOnlineScreen({super.key});

  @override
  State<NeedsOnlineScreen> createState() => _NeedsOnlineScreenState();
}

class _NeedsOnlineScreenState extends State<NeedsOnlineScreen> {
  bool _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    await LicenseStore.instance.verifyClaim();
    authRevision.value++;
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off_rounded, size: 72, color: _accent),
                const SizedBox(height: 16),
                const Text('يلزم الاتصال بالإنترنت', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _accent)),
                const SizedBox(height: 12),
                const Text(
                  'لم يتم التحقق من الترخيص منذ أكثر من 7 أيام. اتصل بالإنترنت ثم اضغط إعادة المحاولة. بياناتك محفوظة.',
                  style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 15),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: _accent, padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14)),
                  onPressed: _busy ? null : _retry,
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('إعادة المحاولة', style: TextStyle(color: Color(0xFF0B132B), fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// After activation: create an account, or log in to the existing one.
class AuthGate extends StatefulWidget {
  final Widget child;
  const AuthGate({super.key, required this.child});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool? _exists;
  bool _loggedIn = false;

  @override
  void initState() {
    super.initState();
    authRevision.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    authRevision.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final e = await AccountStore.instance.exists();
    final l = e && await AccountStore.instance.isLoggedIn();
    if (mounted) {
      setState(() {
        _exists = e;
        _loggedIn = l;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_exists == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: _accent)));
    }
    if (_exists == false) return const CreateAccountScreen();
    if (!_loggedIn) return const LoginScreen();
    return widget.child;
  }
}

class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key});

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final _form = GlobalKey<FormState>();
  final _user = TextEditingController();
  final _phone = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  bool _busy = false;
  String _keyNote = '';

  @override
  void initState() {
    super.initState();
    LicenseStore.instance.load().then((l) {
      if (!mounted) return;
      setState(() {
        _keyNote = l.type == LicenseType.permanent
            ? 'المفتاح صحيح ✓ (دائم). أدخل نفس الاسم ورقم الهاتف اللذين صدر لهما المفتاح.'
            : 'المفتاح صحيح ✓ (مؤقت). أدخل نفس الاسم ورقم الهاتف اللذين صدر لهما المفتاح.';
      });
    });
  }

  @override
  void dispose() {
    for (final c in [_user, _phone, _pass, _pass2]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Unique user code made by the app (the person cannot choose it).
  static String _makeCode() {
    const chars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return List.generate(6, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<void> _create() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final name = _user.text.trim();
    // The licence key was issued for one name + phone: check it now.
    final ok = await LicenseStore.instance.verifyBind(name, _phone.text);
    if (!ok) {
      // verifyBind already reset the key and returns to the activation screen.
      if (mounted) setState(() => _busy = false);
      return;
    }
    final handle = '$name#${_makeCode()}';
    final code = handle.split('#').last;
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121C3A),
        title: const Text('رمز المستخدم الخاص بك', style: TextStyle(color: _accent)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(code, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, letterSpacing: 3)),
            const SizedBox(height: 8),
            SelectableText('اسم الدخول الكامل: $handle', textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            const Text(
              'الرمز أنشأه التطبيق ولا يشاركه فيه أي حساب آخر. احفظ اسم الدخول الكامل: تحتاجه لتسجيل الدخول، ويستعمله الآخرون لمشاركة العقارات معك.',
              style: TextStyle(color: Color(0xFFCBD5E1)),
            ),
          ],
        ),
        actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('متابعة'))],
      ),
    );
    await AccountStore.instance.create(handle, _phone.text.trim(), _pass.text);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _form,
              child: Column(
                children: [
                  const Icon(Icons.person_add_alt_1_rounded, size: 64, color: _accent),
                  const SizedBox(height: 12),
                  const Text('إنشاء حساب جديد', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _accent)),
                  if (_keyNote.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_keyNote, style: const TextStyle(color: Color(0xFF86EFAC), fontSize: 14), textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _user,
                    decoration: _dec('اسم المستخدم (يمكن أن يتكرر بين الناس)'),
                    validator: (v) => RegExp(r'^[A-Za-z0-9_ \u0600-\u06FF]{2,30}$').hasMatch((v ?? '').trim())
                        ? null
                        : 'من 2 إلى 30 حرفا أو رقما (بدون #)',
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    textDirection: TextDirection.ltr,
                    decoration: _dec('رقم الهاتف (نفس الرقم الذي صدر له المفتاح)'),
                    validator: (v) => LicenseKeys.normPhone(v ?? '').length < 8 ? 'رقم هاتف غير صحيح' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pass,
                    obscureText: true,
                    decoration: _dec('كلمة المرور'),
                    validator: (v) => (v ?? '').length < 6 ? 'ست خانات على الأقل' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pass2,
                    obscureText: true,
                    decoration: _dec('تأكيد كلمة المرور'),
                    validator: (v) => v != _pass.text ? 'كلمتا المرور غير متطابقتين' : null,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'سيُطلب منك رمز قفل هاتفك (PIN أو النمط أو البصمة) عند العمليات الحساسة مثل تسجيل الدخول من جهاز آخر.',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: _accent, padding: const EdgeInsets.all(14)),
                      onPressed: _busy ? null : _create,
                      child: const Text('إنشاء الحساب', style: TextStyle(color: Color(0xFF0B132B), fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RemoteLoginScreen())),
                    child: const Text('لدي حساب بالفعل على جهاز آخر'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = (await DeviceLock.confirm('أكّد هويتك برمز قفل هاتفك')) && await AccountStore.instance.login(_user.text, _pass.text);
    if (mounted) {
      setState(() {
        _busy = false;
        if (!ok) _error = 'بيانات الدخول غير صحيحة.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.lock_rounded, size: 64, color: _accent),
                const SizedBox(height: 12),
                const Text('تسجيل الدخول', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _accent)),
                const SizedBox(height: 20),
                TextField(controller: _user, textDirection: TextDirection.ltr, decoration: _dec('اسم المستخدم كاملا (مثال: ahmed#a7k2)')),
                const SizedBox(height: 12),
                TextField(controller: _pass, obscureText: true, decoration: _dec('كلمة المرور', error: _error)),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: _accent, padding: const EdgeInsets.all(14)),
                    onPressed: _busy ? null : _login,
                    child: const Text('دخول', style: TextStyle(color: Color(0xFF0B132B), fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


/// Log in with an existing account on a new device. A device that is already
/// logged in must approve ("is this you?"); no central server is involved.
class RemoteLoginScreen extends StatefulWidget {
  const RemoteLoginScreen({super.key});

  @override
  State<RemoteLoginScreen> createState() => _RemoteLoginScreenState();
}

class _RemoteLoginScreenState extends State<RemoteLoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _go() async {
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'أدخل كل البيانات.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    if (!await DeviceLock.confirm('أكّد هويتك برمز قفل هاتفك لتسجيل الدخول')) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'لم يتم تأكيد رمز قفل الهاتف.';
        });
      }
      return;
    }
    final err = await RemoteLogin.attempt(_user.text, _pass.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    if (err == null) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.devices_rounded, size: 64, color: _accent),
                const SizedBox(height: 12),
                const Text('الدخول بحساب موجود', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _accent)),
                const SizedBox(height: 8),
                const Text(
                  'سيظهر على جهازك الآخر (المسجّل دخوله) سؤال "هل هذا أنت؟". افتح التطبيق عليه ووافق.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFCBD5E1)),
                ),
                const SizedBox(height: 20),
                TextField(controller: _user, enabled: !_busy, decoration: _dec('اسم المستخدم')),
                const SizedBox(height: 12),
                TextField(controller: _pass, enabled: !_busy, obscureText: true, decoration: _dec('كلمة المرور')),
                const SizedBox(height: 12),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: _accent, padding: const EdgeInsets.all(14)),
                    onPressed: _busy ? null : _go,
                    child: _busy
                        ? const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                              SizedBox(width: 10),
                              Text('بانتظار موافقة الجهاز الآخر...', style: TextStyle(color: Color(0xFF0B132B))),
                            ],
                          )
                        : const Text('إرسال طلب الدخول', style: TextStyle(color: Color(0xFF0B132B), fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
