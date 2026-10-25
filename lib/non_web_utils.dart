import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'utils.dart';

Future<void> requestNotificationPermission() async {
  var permission = await Permission.notification.status;
  if (!permission.isGranted) {
    await Permission.notification.request();
  }
}

Future<bool> writeFile(String data) async {
  if (Platform.isAndroid) {
    return await writeFileAndroid(data);
  } else if (Platform.isWindows) {
    return await writeFileWindows(data);
  } else {
    debugPrint('Unsupported platform');
    return false;
  }
}

Future<bool> _saveBytes(
  Uint8List bytes, {
  required String dialogTitle,
  required String fileName,
  required String allowedExtension,
}) async {
  try {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: [allowedExtension],
      bytes: Platform.isAndroid || Platform.isIOS ? bytes : null,
    );

    if (outputFile == null) {
      return false;
    }

    final ext = '.$allowedExtension';
    final hasExt = outputFile.toLowerCase().endsWith(ext);

    // 桌面端：file_picker 只返回路径，由我们写文件。
    // 若用户在保存对话框里去掉了扩展名，写上时补上。
    if (!Platform.isAndroid && !Platform.isIOS) {
      final path = hasExt ? outputFile : '$outputFile$ext';
      await File(path).writeAsBytes(bytes);
      return true;
    }

    // 移动端：file_picker 已通过 bytes 写入系统文档。
    // 若返回的是文件路径且缺扩展名，重命名补上（content:// URI 无法改名则跳过）。
    if (!hasExt && outputFile.startsWith('/')) {
      try {
        final oldFile = File(outputFile);
        if (await oldFile.exists()) {
          await oldFile.rename('$outputFile$ext');
        }
      } catch (e) {
        debugPrint('rename to add extension failed: $e');
      }
    }
    return true;
  } catch (e) {
    debugPrint('Error saving file: $e');
    return false;
  }
}

Future<bool> writeFileAndroid(String data) async {
  final timeStamp = getTimeStr(DateTime.now().millisecondsSinceEpoch);
  return _saveBytes(
    Uint8List.fromList(utf8.encode(data)),
    dialogTitle: '请保存备份文件',
    fileName: 'aiDaziBackup_$timeStamp.json',
    allowedExtension: 'json',
  );
}

Future<bool> writeFileWindows(String data) async {
  try {
    Directory? directory = await getDownloadsDirectory();
    String path = directory?.path ?? '';
    String timeStamp = getTimeStr(DateTime.now().millisecondsSinceEpoch);
    File file = File('$path/aiDaziBackup_$timeStamp.json');
    await file.writeAsString(data);
    debugPrint('write file: ${file.path}');
    return true;
  } catch (e) {
    debugPrint('Error writing file: $e');
    return false;
  }
}
