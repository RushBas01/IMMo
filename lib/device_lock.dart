import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Asks the phone itself for its screen-lock secret (PIN / pattern / password / fingerprint).
/// The app never sees or stores that secret: Android only answers yes or no, which proves the
/// person holding the phone really knows its lock code.
class DeviceLock {
  static final LocalAuthentication _auth = LocalAuthentication();

  /// true = confirmed. If the phone has no screen lock at all there is nothing to ask, so it passes.
  static Future<bool> confirm(String reason) async {
    try {
      if (!await _auth.isDeviceSupported()) return true;
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
    } catch (e) {
      debugPrint('DeviceLock: $e');
      return false;
    }
  }
}
