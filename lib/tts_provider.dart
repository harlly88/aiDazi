import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'image_provider.dart';
import 'secure_key_store.dart';
import 'storage.dart';

/// 百炼 CosyVoice 系统预置音色（cosyvoice-v3-flash 可直接合成，无需注册声纹）
///
/// 角色编辑页音色选择器与模型配置页「兜底音色」共用此清单（agent.md 14.5 / 14.11）
class SystemVoice {
  final String id; // 百炼 voice 参数值
  final String label; // 中文展示名
  final String gender; // male / female

  const SystemVoice({required this.id, required this.label, required this.gender});
}

const List<SystemVoice> systemVoices = [
  SystemVoice(id: 'longanhuan_v3', label: '女声·温暖甜心（默认）', gender: 'female'),
  SystemVoice(id: 'longanyang', label: '男声·阳光青年', gender: 'male'),
];

/// 根据音色 id 查找系统音色，找不到返回 null
SystemVoice? findSystemVoice(String id) {
  for (final v in systemVoices) {
    if (v.id == id) return v;
  }
  return null;
}

/// 阿里云百炼 CosyVoice 客户端（语音合成）
///
/// - 语音合成：POST /api/v1/services/audio/tts/SpeechSynthesizer
///   非流式，返回 output.audio.url（24 小时有效）
/// - 鉴权：Bearer API Key（19.3 起读独立槽位 key_tts，与文字/图像/视频互不回落）
/// - 16.10/16.12：音色创建（voice-enrollment）统一走 customization 端点：
///   声音复刻（公网声音文件 URL）或 声音设计（voice_prompt 文字描述），返回 voice_id
/// - 15.16.1：合成模型名可传入（角色级 voice_model > 全局 tts_model > 默认值）
class BailianTtsClient {
  final String apiKey;
  final String baseUrl;
  final http.Client _httpClient;

  /// 默认合成模型（15.16.1：仅作缺省值，实际以角色级/全局配置优先）
  static const String defaultModel = 'cosyvoice-v3-flash';

  BailianTtsClient({
    required this.apiKey,
    this.baseUrl = defaultTtsBaseUrl,
    http.Client? httpClient,
  })  : _httpClient = httpClient ?? http.Client(),
        assert(apiKey.isNotEmpty, 'API key cannot be empty');

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      };

  /// 查询 voice_id 注册状态：OK / RUNNING / FAILED（角色卡导入校验用，15.16.1）
  Future<String> queryVoice(String voiceId) async {
    final response = await _httpClient
        .post(
          Uri.parse('$baseUrl/api/v1/services/audio/tts/customization'),
          headers: _headers,
          body: json.encode({
            'model': 'voice-enrollment',
            'input': {
              'action': 'query_voice',
              'voice_id': voiceId,
            },
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw _apiError(response, '声音复刻查询失败');
    }

    final data = _decodeObject(response.body);
    final status = data['output']?['status']?.toString() ?? '';
    if (status.isEmpty) {
      throw Exception('百炼未返回注册状态: ${response.body}');
    }
    return status;
  }

  /// 创建音色（16.12：声音复刻 / 声音设计统一入口），返回 output.voice_id
  ///
  /// - [voiceUrl] 公网声音文件 URL → 声音复刻（Voice Cloning）：异步任务，
  ///   创建后轮询 [queryVoice] 直到 status==OK（间隔 3 秒，最长 2 分钟）
  /// - [voicePrompt] 声音自然语言描述（≤500 字符）→ 声音设计（Voice Design）：
  ///   通常同步返回 voice_id
  /// - [targetModel] 目标合成模型（创建与合成必须完全一致，如 cosyvoice-v3-flash）
  /// - [prefix] 音色名称前缀（一般传角色名）
  ///
  /// 二者都为空时抛 ArgumentError；错误按 _apiError 风格透传百炼 message。
  Future<String> createVoice({
    String? voiceUrl,
    String? voicePrompt,
    String? previewText,
    required String targetModel,
    required String prefix,
  }) async {
    if (voiceUrl == null && (voicePrompt == null || voicePrompt.isEmpty)) {
      throw ArgumentError('voiceUrl 与 voicePrompt 至少提供一个');
    }

    // 17.7 声音设计必须同时传 voice_prompt + preview_text（百炼文档明确要求，
    // 否则返回 InvalidParameter: provide url, or provide both voice_prompt and preview_text）
    final soundInput = voiceUrl != null
        ? {'url': voiceUrl}
        : {
            'voice_prompt': voicePrompt,
            'preview_text': previewText ?? '大家好，欢迎来到我们的直播间！',
          };

    // 17.13：百炼 prefix 只允许英文字母和数字，中文角色名需要 sanitize
    // 规则：保留字母数字 → 其他 → 下划线，去首尾下划线，限长 20
    var sanitizedPrefix = prefix
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '')
        .replaceAll(RegExp(r'_+'), '_');
    if (sanitizedPrefix.length > 20) {
      sanitizedPrefix = sanitizedPrefix.substring(0, 20);
    }
    final finalPrefix = sanitizedPrefix.isEmpty ? 'voice' : sanitizedPrefix;

    final response = await _httpClient
        .post(
          Uri.parse('$baseUrl/api/v1/services/audio/tts/customization'),
          headers: _headers,
          body: json.encode({
            'model': 'voice-enrollment',
            'input': {
              'action': 'create_voice',
              'target_model': targetModel,
              'prefix': finalPrefix,
              ...soundInput,
              'language_hints': ['zh'],
            },
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw _apiError(response, '创建音色失败');
    }

    final data = _decodeObject(response.body);
    final voiceId = data['output']?['voice_id']?.toString() ?? '';
    if (voiceId.isEmpty) {
      throw Exception('百炼未返回 voice_id: ${response.body}');
    }

    // 声音复刻为异步任务：轮询注册状态直到 OK（声音设计通常同步完成，直接返回）
    if (voiceUrl != null) {
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 3));
        final status = await queryVoice(voiceId);
        if (status == 'OK') return voiceId;
        if (status == 'FAILED') {
          throw Exception('声音复刻失败（voice_id=$voiceId）');
        }
      }
      throw Exception('声音复刻超时（2 分钟，voice_id=$voiceId）');
    }
    return voiceId;
  }

  /// 语音合成（非流式）：返回音频文件 URL（24 小时有效）
  ///
  /// [model] 合成模型名（15.16.1：复用外部 voice_id 时必须与注册时一致；
  /// 缺省读全局配置 getTtsModel()，无配置用默认值）
  Future<String> synthesize({
    required String voiceId,
    required String text,
    String? model,
    String format = 'mp3',
    double rate = 1.0,
    double pitch = 1.0,
    int volume = 50,
  }) async {
    if (text.trim().isEmpty) {
      throw ArgumentError('待合成文本不能为空');
    }
    if (voiceId.trim().isEmpty) {
      throw ArgumentError('voice_id 不能为空');
    }

    final response = await _httpClient
        .post(
          Uri.parse('$baseUrl/api/v1/services/audio/tts/SpeechSynthesizer'),
          headers: _headers,
          body: json.encode({
            'model': model ?? defaultModel,
            'input': {
              'text': text,
              'voice': voiceId.trim(),
              'format': format,
              'rate': rate,
              'pitch': pitch,
              'volume': volume,
            },
          }),
        )
        .timeout(const Duration(minutes: 2));

    if (response.statusCode != 200) {
      throw _apiError(response, '语音合成失败');
    }

    final data = _decodeObject(response.body);
    final audioUrl = data['output']?['audio']?['url']?.toString();
    if (audioUrl == null || audioUrl.isEmpty) {
      throw Exception('百炼未返回音频 URL: ${response.body}');
    }
    return audioUrl;
  }

  static Map<String, dynamic> _decodeObject(String body) {
    final decoded = json.decode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('百炼返回了无效的 JSON 结构');
    }
    return decoded;
  }

  Exception _apiError(http.Response response, String fallback) {
    try {
      final data = _decodeObject(response.body);
      final code = data['code']?.toString() ?? '';
      final message = data['message']?.toString() ?? '';
      if (message.isNotEmpty) {
        return Exception('$fallback [$code]: $message');
      }
    } catch (_) {
      // 非 JSON 错误体，直接用 fallback
    }
    return Exception('$fallback: HTTP ${response.statusCode}');
  }
}

/// 下载图片 URL 到 {appDocs}/ref_images/ref_{timestamp}.png（16.10.2 导入流程用）
///
/// 百炼生成的图片 URL 24 小时过期，落地为本地文件后由 saveRefImage 持久化
Future<String> _downloadRefImage(String url) async {
  // 第十六章：OpenAI 协议 b64 兜底产物已是本地路径，直通不再发起 http
  if (!url.startsWith('http')) return url;
  final response = await http
      .get(Uri.parse(url))
      .timeout(const Duration(minutes: 5));
  if (response.statusCode != 200) {
    throw Exception('参考图下载失败: HTTP ${response.statusCode}');
  }
  final dir = await getApplicationDocumentsDirectory();
  final refDir = Directory('${dir.path}/ref_images');
  if (!await refDir.exists()) {
    await refDir.create(recursive: true);
  }
  final file = File(
      '${refDir.path}/ref_${DateTime.now().millisecondsSinceEpoch}.png');
  await file.writeAsBytes(response.bodyBytes);
  return file.path;
}

/// 角色导入后处理编排（16.10.2）：音色注册 + 参考图生成，供 main.dart 导入流程调用
///
/// - voice_url（公网声音文件 URL）→ 声音复刻注册；voice_prompt（声音描述）→ 声音设计注册；
///   二者取其一（voice_url 优先），成功后 voice_id 写工作态并持久化到 student 记录索引 6；
///   声音设计方式同时持久化 voice_prompt（索引 17）
/// - appearance_prompt（样貌描述）→ 万相文生图 → 下载到 {appDocs}/ref_images/
///   → saveRefImage 持久化参考图（student 记录索引 7）
/// - 任一步骤失败直接 throw，由调用方决定提示与后续处理
Future<({String? voiceId, String? refImagePath})> enrollImportedCharacter({
  String? studentKey,
  String? voiceUrl,
  String? voicePrompt,
  String? appearancePrompt,
  required String roleName,
}) async {
  // 19.3：语音能力改读独立槽位 key_tts（互不回落）
  final apiKey = await getTtsApiKey();
  if (apiKey == null || apiKey.isEmpty) {
    throw Exception(keyNotSetError('语音'));
  }
  final targetModel = await getTtsModel();

  String? voiceId;
  final hasUrl = voiceUrl != null && voiceUrl.isNotEmpty;
  final hasPrompt = voicePrompt != null && voicePrompt.isNotEmpty;
  if (hasUrl || hasPrompt) {
    // 第二十章：接口地址可独立配置（空 = 官方默认）
    final client =
        BailianTtsClient(apiKey: apiKey, baseUrl: await getTtsBaseUrl());
    voiceId = await client.createVoice(
      voiceUrl: hasUrl ? voiceUrl : null,
      voicePrompt: hasUrl ? null : voicePrompt,
      targetModel: targetModel,
      prefix: roleName,
    );
    // 18.2：有 studentKey 时直接写该池记录（导入场景，不覆写当前工作态）；
    // 否则走 saveVoiceId（写工作态+当前角色记录）
    if (studentKey != null && studentKey.isNotEmpty) {
      await updateStudentFieldByKey(studentKey, 6, voiceId);
      await updateStudentFieldByKey(studentKey, 15, targetModel);
    } else {
      await saveVoiceId(voiceId);
      await saveVoiceModel(targetModel);
    }
    if (!hasUrl) {
      // 声音设计方式：同时持久化描述（student 记录索引 17）
      if (studentKey != null && studentKey.isNotEmpty) {
        await updateStudentFieldByKey(studentKey, 17, voicePrompt!);
      } else {
        await saveVoicePrompt(voicePrompt!);
      }
    }
  }

  String? refImagePath;
  if (appearancePrompt != null && appearancePrompt.isNotEmpty) {
    final url = await generateWanxImage(
      prompt: appearancePrompt,
      refImageBytes: null,
    );
    refImagePath = await _downloadRefImage(url);
    // 18.2：直接写池记录索引 7（参考图），不覆写工作态
    if (studentKey != null && studentKey.isNotEmpty) {
      await updateStudentFieldByKey(studentKey, 7, refImagePath);
    } else {
      await saveRefImage(refImagePath);
    }
  }

  return (voiceId: voiceId, refImagePath: refImagePath);
}
