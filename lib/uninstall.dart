import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';

/// Asks Android to uninstall this app. Android never lets an app remove itself silently:
/// the system shows its own "Do you want to uninstall this app?" confirmation.
class SelfUninstall {
  static const String _package = 'com.example.ayach';

  static Future<void> request() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await const AndroidIntent(action: 'action_delete', data: 'package:$_package').launch();
    } catch (e) {
      debugPrint('uninstall: $e');
    }
  }
}
