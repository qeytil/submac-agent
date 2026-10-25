import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Android "All files access" (MANAGE_EXTERNAL_STORAGE) for the phone's shared storage.
class DeviceAccess {
  static const root = '/storage/emulated/0';

  static Future<bool> isGranted() async {
    if (!Platform.isAndroid) return false;
    try {
      if (await Permission.manageExternalStorage.isGranted) return true;
      return await Permission.storage.isGranted && await Directory('$root/Download').exists() &&
          _canList('$root/Download');
    } catch (_) {
      return false;
    }
  }

  static bool _canList(String path) {
    try {
      Directory(path).listSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> request() async {
    if (!Platform.isAndroid) return false;
    try {
      var s = await Permission.manageExternalStorage.request();
      if (s.isGranted) return true;
      // Android 10 and below fall back to the classic storage permission.
      s = await Permission.storage.request();
      return s.isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openSettings() => openAppSettings();
}
