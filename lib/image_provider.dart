import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'secure_key_store.dart';
import 'storage.dart';

/// 第十七章：百炼系域名判定（dashscope.aliyuncs.com / maas.qianwenaiapi.com 等），
/// 图像 / 视频双协议共用——官方域名走百炼协议 404 视为真实报错（如 ModelNotExist），
/// 不做第三方协议回落
bool isOfficialDashScopeHost(String baseUrl) {
  final host = Uri.tryParse(baseUrl)?.host.toLowerCase() ?? '';
  return host.contains('aliyuncs') || host.contains('qianwenaiapi');
}

/// 万相文生图客户端（同步调用，双协议兼容，第十六章）
///
/// - 百炼协议（官方/默认地址）：POST /api/v1/services/aigc/multimodal-generation/generation
///   文生图 content 仅含 text；图生图（参考图）content 附带 image（Base64 data URI 直传，无需 OSS）
/// - OpenAI Images 协议（第三方兼容，如智核 TT Image 2.5）：自定义地址百炼路径 404 时自动回落
///   文生图 POST {base}/v1/images/generations、图生图 POST {base}/v1/images/edits（参考图 data URI
///   内联于 images[]）；官方百炼域名 404 不回落（保留 ModelNotExist 等真实报错）
/// - 鉴权：Bearer API Key（19.3 起读独立槽位 key_image，与其他能力互不回落）
/// - 模型：wan2.7-image / wan2.7-image-pro（百炼）/ tt-image-2.5 等（第三方），模型名可在模型配置页修改
class WanxImageClient {
  final String apiKey;
  final String baseUrl;
  final http.Client _httpClient;

  WanxImageClient({
    required this.apiKey,
    this.baseUrl = defaultImageBaseUrl,
    http.Client? httpClient,
  })  : _httpClient = httpClient ?? http.Client(),
        assert(apiKey.isNotEmpty, 'API key cannot be empty');

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      };

  /// 百炼系域名：404 视为真实报错（如 ModelNotExist），不做 OpenAI 协议回落
  bool get _isOfficialHost => isOfficialDashScopeHost(baseUrl);

  /// 生成图片，返回图片 URL（百炼临时 URL 24h 有效 / 第三方成品直链，调用方需下载到本地）；
  /// 第三方仅回 base64 时解码落盘返回本地路径（第十六章）
  ///
  /// [prompt] 生图提示词（含角色外貌描述）
  /// [model] 模型名（从模型配置读取，默认 wan2.7-image）
  /// [size] 分辨率，如 1080*1920（9:16 竖版；OpenAI 协议自动转为 1080x1920）
  /// [refImage] 参考图 data URI（Base64 直传），为空则纯文生图
  Future<String> generateImage({
    required String prompt,
    String model = 'wan2.7-image',
    String size = '1080*1920',
    String? refImage,
  }) async {
    if (prompt.trim().isEmpty) {
      throw ArgumentError('生图提示词不能为空');
    }

    // ===== 百炼协议（现状路径，零改动） =====
    final content = <Map<String, String>>[
      {'text': prompt.trim()},
    ];
    if (refImage != null && refImage.trim().isNotEmpty) {
      content.add({'image': refImage.trim()});
    }

    final response = await _httpClient
        .post(
          Uri.parse('$baseUrl/api/v1/services/aigc/multimodal-generation/generation'),
          headers: _headers,
          body: json.encode({
            'model': model,
            'input': {
              'messages': [
                {
                  'role': 'user',
                  'content': content,
                }
              ],
            },
            'parameters': {
              'size': size,
              'n': 1,
              'watermark': false,
            },
          }),
        )
        .timeout(const Duration(minutes: 5));

    if (response.statusCode == 200) {
      final data = _decodeObject(response.body);
      final choices = data['output']?['choices'];
      if (choices is List && choices.isNotEmpty) {
        final contents = choices[0]['message']?['content'];
        if (contents is List) {
          for (final item in contents) {
            if (item is Map<String, dynamic> && item['image'] != null) {
              final url = item['image'].toString();
              if (url.isNotEmpty) return url;
            }
          }
        }
      }
      throw Exception('百炼未返回图片 URL: ${response.body}');
    }

    // 第十六章：第三方地址百炼路径不存在（404）→ 回落 OpenAI Images 协议重试
    if (response.statusCode == 404 && !_isOfficialHost) {
      return _generateOpenAi(
          prompt: prompt, model: model, size: size, refImage: refImage);
    }
    throw _apiError(response, '文生图失败');
  }

  /// 第十六章：OpenAI Images 协议生图（第三方兼容）
  ///
  /// - 文生图 POST {base}/v1/images/generations；图生图 POST {base}/v1/images/edits，
  ///   参考图 data URI 内联于 images[]（无 OSS、不用 multipart）
  /// - base 已带 /v1 时不重复拼接；size 星号写法转字母 x
  /// - response_format 请求 url 直链（下游下载逻辑零改动）；服务端仅回 b64_json 时落盘兜底
  Future<String> _generateOpenAi({
    required String prompt,
    required String model,
    required String size,
    String? refImage,
  }) async {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    // 16.4：用户按第三方文档把完整端点 URL 当接口地址填入时
    // （如 https://api.lk888.ai/v1/images/generations），剥掉误填的端点后缀
    // 得到根地址，避免拼出 /v1/images/generations/v1/images/edits 这类重复路径
    const pastedSuffixes = ['/images/generations', '/images/edits'];
    for (final suffix in pastedSuffixes) {
      if (base.toLowerCase().endsWith(suffix)) {
        base = base.substring(0, base.length - suffix.length);
        while (base.endsWith('/')) {
          base = base.substring(0, base.length - 1);
        }
        break;
      }
    }
    final hasV1 = base.toLowerCase().endsWith('/v1');
    final ref =
        (refImage != null && refImage.trim().isNotEmpty) ? refImage.trim() : null;
    final endpoint =
        '$base${hasV1 ? '' : '/v1'}${ref != null ? '/images/edits' : '/images/generations'}';

    // 第三方参考图解码后上限约 10MB（按 base64 段长度估算）
    if (ref != null) {
      final b64 = ref.contains(',') ? ref.substring(ref.indexOf(',') + 1) : ref;
      final decodedMB = b64.length * 3 / 4 / 1024 / 1024;
      if (decodedMB > 10) {
        throw Exception('参考图过大（约 ${decodedMB.toStringAsFixed(1)}MB），'
            '第三方 OpenAI 协议单张参考图上限约 10MB，请压缩后重试');
      }
    }

    final body = <String, dynamic>{
      'model': model,
      'prompt': prompt.trim(),
      'size': size.replaceAll('*', 'x'), // 百炼 1080*1920 → OpenAI 1080x1920
      'response_format': 'url',
    };
    if (ref != null) {
      body['images'] = [
        {'image_url': ref}
      ];
    }

    final response = await _httpClient
        .post(Uri.parse(endpoint), headers: _headers, body: json.encode(body))
        .timeout(const Duration(minutes: 6)); // 第三方要求客户端读超时 ≥300 秒

    if (response.statusCode != 200) {
      throw _openAiError(response);
    }
    final data = _decodeObject(response.body);
    final images = data['data'];
    if (images is List && images.isNotEmpty) {
      final first = images.first;
      if (first is Map<String, dynamic>) {
        final url = first['url']?.toString() ?? '';
        if (url.isNotEmpty) return url;
        final b64 = first['b64_json']?.toString() ?? '';
        if (b64.isNotEmpty) {
          return _saveBase64ToLocal(b64); // 服务端忽略 response_format 的兜底
        }
      }
    }
    throw Exception('第三方未返回图片数据: ${response.body}');
  }

  /// OpenAI 协议错误解析（保留服务端报错原文，如模型名不存在）
  Exception _openAiError(http.Response response) {
    try {
      final data = _decodeObject(response.body);
      final error = data['error'];
      if (error is Map<String, dynamic>) {
        final message = error['message']?.toString() ?? '';
        if (message.isNotEmpty) {
          return Exception(
              '生图失败 [${error['type'] ?? response.statusCode}]: $message');
        }
      }
      final message = data['message']?.toString() ?? '';
      if (message.isNotEmpty) return Exception('生图失败: $message');
    } catch (_) {
      // 非 JSON 错误体，走 HTTP 状态码
    }
    return Exception('生图失败（OpenAI 协议）: HTTP ${response.statusCode}');
  }

  /// b64_json 兜底落盘：解码写 {docs}/backgrounds/gen_<时间戳>.png，返回本地路径
  Future<String> _saveBase64ToLocal(String b64) async {
    final bytes = base64Decode(b64);
    final dir = await getApplicationDocumentsDirectory();
    final bgDir = Directory('${dir.path}/backgrounds');
    if (!await bgDir.exists()) {
      await bgDir.create(recursive: true);
    }
    final file =
        File('${bgDir.path}/gen_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes);
    return file.path;
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

/// 参考图本地字节 → data URI（15.12 Base64 直传，替代 OSS 签名 URL）
///
/// 万相 image 参数原生支持 data:image/{png|jpeg|webp};base64,... 输入。
/// Base64 后体积 +33%，请求体上限 20MB → 原始字节按 15MB 校验。
String? encodeRefImageDataUri(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return null;
  if (bytes.length > 15 * 1024 * 1024) {
    throw Exception(
        '参考图过大（${(bytes.length / 1024 / 1024).toStringAsFixed(1)}MB），'
        'Base64 直传上限约 15MB，请压缩后重试');
  }
  String mime = 'image/png';
  if (bytes.length >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    mime = 'image/png'; // PNG
  } else if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    mime = 'image/jpeg'; // JPEG
  } else if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    mime = 'image/webp'; // RIFF....WEBP
  }
  return 'data:$mime;base64,${base64Encode(bytes)}';
}

/// 便捷入口：读取配置并生成图片，返回图片 URL 或本地路径（第十六章 b64 兜底）
///
/// [refImageBytes] 本地参考图字节（Base64 直传，15.12 移除 OSS）；
/// 为空或读取失败时自动降级为纯文生图（prompt 中已含角色外貌描述）
Future<String> generateWanxImage({
  required String prompt,
  Uint8List? refImageBytes,
}) async {
  // 19.3：图像能力改读独立槽位 key_image（互不回落）
  final apiKey = await getImageApiKey();
  if (apiKey == null || apiKey.isEmpty) {
    throw Exception(keyNotSetError('图像'));
  }
  final (model, size) = await getWanImageConfig();

  // 第二十章：接口地址可独立配置（空 = 官方默认）
  final client =
      WanxImageClient(apiKey: apiKey, baseUrl: await getImageBaseUrl());
  return client.generateImage(
    prompt: prompt,
    model: model,
    size: size,
    refImage: encodeRefImageDataUri(refImageBytes),
  );
}
