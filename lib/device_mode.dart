import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 14.x 隐藏的「设备模式」开关（开机自启 + 看门狗保活，L1 级）。
/// 持久化由 Android 组件启用状态承担（PackageManager.setComponentEnabledSetting），
/// 无 prefs、无额外存储；非 Android 平台恒为关、设置无效。
class DeviceMode {
  static const MethodChannel _channel = MethodChannel('aidazi/device_mode');

  /// 仅 Android（真机/模拟器）支持；Web/Windows 恒 false
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// 当前是否开启（查询失败按关处理）
  static Future<bool> isEnabled() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 设置开关；返回是否成功。首次开启由调用方展示一次性须知。
  static Future<bool> setEnabled(bool enabled) async {
    if (!isSupported) return false;
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': enabled});
      return true;
    } catch (_) {
      return false;
    }
  }
}
