import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils.dart' show Config;
import 'storage.dart' show getApiConfigs, setApiConfig;

/// 19.3 / 19.4：四槽位密钥统一入口（第七轮整改 P12）
///
/// 槽位模型（互不共用、互不回落）：
/// - `key_llm_{name}` 文字（LLM 对话，按 provider 分槽：qwen/deepseek/doubao/glm/kimi/custom）
/// - `key_tts`     语音（CosyVoice 合成 + 音色注册 enrollment）
/// - `key_image`   图像（万相文生图）
/// - `key_video`   视频（万相文生视频）
///
/// io 平台走 flutter_secure_storage（Android Keystore / Windows DPAPI 加密落盘）；
/// Web 平台（kIsWeb）LLM 回落 SharedPreferences 的 Config.apiKey（Web 保留旧手动入口，
/// 仅保证可编译可运行，见 agent.md 19.4 / 19.7）。
const _migrationFlag = 'key_migrated_v1';

const FlutterSecureStorage _secure = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

/// 统一「未配置密钥」错误文案（19.3：任一槽位为空直接报错，不回落）
String keyNotSetError(String capability) =>
    '$capability密钥未配置，请到 设置 → 模型配置 → 网页配置 填写';

// ===== 文字（LLM）=====

/// 取当前 provider 的 LLM 密钥；io 平台读 secure storage，
/// Web 平台回落 Config.apiKey（旧手动入口，仅保证可用）
Future<String?> getLlmApiKey(Config config) async {
  if (kIsWeb) {
    return config.apiKey.isNotEmpty ? config.apiKey : null;
  }
  final key = await _secure.read(key: 'key_llm_${config.name}');
  return (key != null && key.isNotEmpty) ? key : null;
}

/// 保存指定 provider 的 LLM 密钥（网页配置 / 迁移用）
Future<void> setLlmApiKey(String provider, String key) async {
  if (kIsWeb) return;
  await _secure.write(key: 'key_llm_$provider', value: key);
}

/// 读取指定 provider 槽位（配置页掩码展示用，不区分当前选中）
Future<String?> getLlmApiKeyByName(String provider) async {
  if (kIsWeb) return null;
  final key = await _secure.read(key: 'key_llm_$provider');
  return (key != null && key.isNotEmpty) ? key : null;
}

// ===== 语音（TTS）=====

Future<String?> getTtsApiKey() async {
  if (kIsWeb) return null;
  final key = await _secure.read(key: 'key_tts');
  return (key != null && key.isNotEmpty) ? key : null;
}

Future<void> setTtsApiKey(String key) async {
  if (kIsWeb) return;
  await _secure.write(key: 'key_tts', value: key);
}

// ===== 图像 =====

Future<String?> getImageApiKey() async {
  if (kIsWeb) return null;
  final key = await _secure.read(key: 'key_image');
  return (key != null && key.isNotEmpty) ? key : null;
}

Future<void> setImageApiKey(String key) async {
  if (kIsWeb) return;
  await _secure.write(key: 'key_image', value: key);
}

// ===== 视频 =====

Future<String?> getVideoApiKey() async {
  if (kIsWeb) return null;
  final key = await _secure.read(key: 'key_video');
  return (key != null && key.isNotEmpty) ? key : null;
}

Future<void> setVideoApiKey(String key) async {
  if (kIsWeb) return;
  await _secure.write(key: 'key_video', value: key);
}

/// 第十六章：清空四能力全部密钥槽位（网页「恢复千问默认设定」POST /api/reset 用）
///
/// - LLM：六家预置 provider + Config 列表出现过的其他 provider 名（防历史遗留漏删）
/// - TTS / 图像 / 视频：key_tts / key_image / key_video
/// - Web 平台 no-op（密钥走 Config.apiKey 旧路径，重置由 Config 恢复预置覆盖）
Future<void> clearAllApiKeys() async {
  if (kIsWeb) return;
  final providers = <String>{
    'qwen',
    'deepseek',
    'doubao',
    'glm',
    'kimi',
    'custom',
    for (final c in await getApiConfigs()) c.name,
  };
  for (final name in providers) {
    await _secure.delete(key: 'key_llm_$name');
  }
  await _secure.delete(key: 'key_tts');
  await _secure.delete(key: 'key_image');
  await _secure.delete(key: 'key_video');
}

/// 密钥掩码：`sk-****abcd`；null / 空 → 「未配置」。永不回显明文（19.9）
String maskKey(String? key) {
  if (key == null || key.isEmpty) return '未配置';
  if (key.length <= 8) return '****';
  return '${key.substring(0, 3)}****${key.substring(key.length - 4)}';
}

/// 旧明文密钥一次性迁移（19.4，仅 io 平台，首次启动执行）
///
/// 1. 旧 `aliyun_api_key` 非空 → 写 key_tts / key_image / key_video 三槽
///    （旧版本三能力共用该 Key，迁移即等效）
/// 2. 遍历旧 Config 列表，各 provider 非空 apiKey → 写 key_llm_{name}
/// 3. 迁移完成 → 删除 aliyun_api_key、各 Config.apiKey 置空、写迁移标记
/// 4. 静默执行，失败不阻塞启动（下次启动重试，不写标记）
Future<void> migratePlainKeysOnce() async {
  if (kIsWeb) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migrationFlag) ?? false) return;

    // 1. 旧百炼共用 Key → 三槽位
    final oldKey = prefs.getString('aliyun_api_key');
    if (oldKey != null && oldKey.isNotEmpty) {
      await _secure.write(key: 'key_tts', value: oldKey);
      await _secure.write(key: 'key_image', value: oldKey);
      await _secure.write(key: 'key_video', value: oldKey);
    }

    // 2. 各 provider 明文 apiKey → key_llm_{name}，并置空重存
    final configs = await getApiConfigs();
    for (final c in configs) {
      if (c.apiKey.isNotEmpty) {
        await _secure.write(key: 'key_llm_${c.name}', value: c.apiKey);
        await setApiConfig(Config(
          name: c.name,
          baseUrl: c.baseUrl,
          apiKey: '',
          model: c.model,
          temperature: c.temperature,
          frequencyPenalty: c.frequencyPenalty,
          presencePenalty: c.presencePenalty,
          maxTokens: c.maxTokens,
        ));
      }
    }

    // 3. 清旧键 + 写迁移标记
    await prefs.remove('aliyun_api_key');
    await prefs.setBool(_migrationFlag, true);
  } catch (_) {
    // 静默失败：下次启动重试
  }
}
