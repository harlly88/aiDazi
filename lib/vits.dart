import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'secure_key_store.dart';
import 'storage.dart';
import 'tts_provider.dart';
import 'utils.dart';

AudioPlayer? _activePlayer;
int _playbackOperation = 0;

Future<void> stopAudio() async {
  _playbackOperation++;
  final player = _activePlayer;
  _activePlayer = null;
  if (player != null) {
    await player.stop();
    await player.dispose();
  }
}

/// 下载百炼音频直链到本地临时文件（15.7：规避远程直链在 just_audio 上的
/// 「播放错误(0) source error」——HTTP/302 重定向/防盗链问题彻底规避）
///
/// [key] 缓存文件名标识（通常用待合成文本 hash），同 key 24h 内重复播放不重新下载
Future<String> downloadTtsAudio(String url, {String? key}) async {
  final dir = await getTemporaryDirectory();
  final name = key ?? url.hashCode.toRadixString(16);
  final file = File('${dir.path}/tts_$name.mp3');
  if (await file.exists() && await file.length() > 0) {
    return file.path;
  }
  final http.Response response;
  try {
    response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 60));
  } catch (e) {
    throw Exception('语音下载失败（${Uri.parse(url).host}）: $e');
  }
  if (response.statusCode != 200) {
    throw Exception(
        '语音下载失败: HTTP ${response.statusCode}（${Uri.parse(url).host}）');
  }
  await file.writeAsBytes(response.bodyBytes);
  return file.path;
}

Future<void> playAudio(BuildContext context, String audioSource) async {
  final operation = ++_playbackOperation;
  final previousPlayer = _activePlayer;
  _activePlayer = null;
  if (previousPlayer != null) {
    await previousPlayer.stop();
    await previousPlayer.dispose();
  }
  if (operation != _playbackOperation) return;

  final player = AudioPlayer();
  _activePlayer = player;
  try {
    // 15.7：远程 URL 先下载到本地临时文件再播放；本地路径直接播放
    String path = audioSource;
    if (!File(path).existsSync()) {
      path = await downloadTtsAudio(audioSource);
    }
    if (operation != _playbackOperation) return;
    await player.setAudioSource(AudioSource.file(path));
    if (operation != _playbackOperation) return;
    await player.play();
  } catch (e) {
    if (operation == _playbackOperation && context.mounted) {
      snackBarAlert(context, "播放错误: $e");
    }
  } finally {
    if (identical(_activePlayer, player)) {
      _activePlayer = null;
      await player.dispose();
    }
  }
}

/// 合成语音：角色 voice_id/系统音色（索引 6）优先，空或失效时回落全局兜底音色（14.5）
///
/// 兜底规则：
/// - 角色未设置音色（索引 6 为空）→ 直接用兜底音色
/// - 角色 voice_id 合成失败（如他人账号注册的 voice_id 失效）→ 自动回落兜底音色重试
/// - TTS 永远可用，不因无声纹而静音报错
///
/// 15.16.1 模型优先级：角色 voice_id 有效时用角色级 voice_model（无则全局 tts_model）；
/// 兜底男女声（系统音色）恒用全局 tts_model
///
/// 15.7：返回值为本地临时文件路径（非远程 URL），缓存与播放均走本地文件
Future<String?> getAudio(BuildContext context, String query) async {
  // 19.3：语音能力改读独立槽位 key_tts（互不回落）
  final apiKey = await getTtsApiKey();
  if (apiKey == null || apiKey.isEmpty) {
    throw Exception(keyNotSetError('语音'));
  }

  final fallbackVoice = await getTtsFallbackVoice();
  final roleVoiceId = await getVoiceId();
  final roleVoiceModel = await getVoiceModel();
  final globalTtsModel = await getTtsModel();
  // 第二十章：接口地址可独立配置（空 = 官方默认）
  final client =
      BailianTtsClient(apiKey: apiKey, baseUrl: await getTtsBaseUrl());

  if (roleVoiceId.isEmpty) {
    // 角色未设置音色：直接用兜底音色（系统音色恒用全局模型）
    final cacheKey =
        '${query.hashCode.toRadixString(16)}_${fallbackVoice.hashCode.toRadixString(16)}';
    final url = await client.synthesize(
        voiceId: fallbackVoice, text: query, model: globalTtsModel);
    return await downloadTtsAudio(url, key: cacheKey);
  }

  // 角色 voice_id：模型优先级 角色级 voice_model > 全局 tts_model
  final roleModel = roleVoiceModel.isNotEmpty ? roleVoiceModel : globalTtsModel;
  final cacheKey =
      '${query.hashCode.toRadixString(16)}_${roleVoiceId.hashCode.toRadixString(16)}';
  try {
    final url =
        await client.synthesize(voiceId: roleVoiceId, text: query, model: roleModel);
    return await downloadTtsAudio(url, key: cacheKey);
  } catch (e) {
    // voice_id 失效（他人账号注册等）：回落兜底音色重试，保证语音永远可用
    // 18.3：不再纯静默，提示用户角色音色失效已用兜底音色
    debugPrint('role voice synthesis failed, fallback to $fallbackVoice: $e');
    if (context.mounted) {
      snackBarAlert(context, '角色音色合成失败，已改用系统音色');
    }
    final url = await client.synthesize(
        voiceId: fallbackVoice, text: query, model: globalTtsModel);
    return await downloadTtsAudio(url, key: cacheKey);
  }
}
