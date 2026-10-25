import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'image_provider.dart'
    show encodeRefImageDataUri, isOfficialDashScopeHost;
import 'secure_key_store.dart';
import 'storage.dart';

/// 万相视频生成客户端（异步：创建任务 → 轮询获取，双协议兼容，第十七章）
///
/// - 百炼协议（官方/默认地址，现状不动）：
///   - 创建任务：POST /api/v1/services/aigc/video-generation/video-synthesis
///     请求头必须带 X-DashScope-Async: enable
///   - 轮询任务：GET /api/v1/tasks/{task_id}
///     task_status: PENDING / RUNNING / SUCCEEDED / FAILED
/// - MiniMax 官方协议（第三方兼容，第十七章）：自定义地址百炼路径 404 时自动回落
///   - 创建任务：POST {base}/v2/video_generation（content: text + 参考图 image_url
///     role=reference_image，data URI 内联，App 参考图=主角形象参考非首帧）
///   - 轮询任务：GET {base}/v2/query/video_generation/{task_id}
///     task.status: queued / running / succeeded / failed / cancelled
/// - 鉴权：Bearer API Key（19.3 起读独立槽位 key_video，与其他能力互不回落）
/// - 轮询策略：初始 2s（MiniMax 5s），指数退避至 30s 封顶，默认单任务最长 1000 秒（带取消）
/// - 模型名从模型配置读取（15.16，默认 wan3.0-video-prime；第三方如 minimax-h3）
/// - 参考图/首帧图 Base64 直传（15.12 移除 OSS）：传入 [refImage] 时走图生视频
class WanxVideoClient {
  final String apiKey;
  final String baseUrl;
  final http.Client _httpClient;

  WanxVideoClient({
    required this.apiKey,
    this.baseUrl = defaultVideoBaseUrl,
    http.Client? httpClient,
  })  : _httpClient = httpClient ?? http.Client(),
        assert(apiKey.isNotEmpty, 'API key cannot be empty');

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      };

  /// 生成视频，阻塞轮询直至完成，返回视频 URL（百炼临时 URL 24h 有效 / 第三方平台
  /// 永久直链，第十七章双协议；调用方统一下载到本地）
  ///
  /// [prompt] 视频提示词（中英文均可）
  /// [model] 模型名（从模型配置读取，默认 wan3.0-video-prime；第三方如 minimax-h3）
  /// [refImage] 参考图 data URI（Base64 直传，15.12）：非空时百炼自动切 i2v 模型
  /// [resolution] 720P / 1080P
  /// [ratio] 画面比例：16:9 / 9:16 / 1:1 / 4:3 / 3:4
  /// [duration] 时长（秒），2-15 的整数，按秒计费
  Future<String> generateVideo({
    required String prompt,
    String model = 'wan3.0-video-prime',
    String? refImage,
    String resolution = '720P',
    String ratio = '9:16',
    int duration = 5,
    Duration timeout = const Duration(seconds: 1000), // 26.1-3：至少 1000 秒
  }) async {
    if (prompt.trim().isEmpty) {
      throw ArgumentError('视频提示词不能为空');
    }
    // 图生视频：旧 2.7 系命名约定 -t2v → -i2v 才切换；
    // wan3.0 系（如 wan3.0-video-prime）文生/图生同模型，原样传名
    String actualModel = model;
    if (refImage != null && refImage.trim().isNotEmpty) {
      actualModel = model.endsWith('-t2v')
          ? '${model.substring(0, model.length - 4)}-i2v'
          : model;
    }
    // 第十七章：百炼协议优先——200 走原轮询；第三方地址 404 回落 MiniMax 官方协议
    final createResponse = await _postWanCreate(
      prompt: prompt,
      model: actualModel,
      refImage: refImage,
      resolution: resolution,
      ratio: ratio,
      duration: duration,
    );
    if (createResponse.statusCode == 200) {
      return _waitForWan(_parseWanTaskId(createResponse), timeout: timeout);
    }
    if (createResponse.statusCode == 404 && !isOfficialDashScopeHost(baseUrl)) {
      // 回落分支传用户原始模型名（-t2v→-i2v 切换仅百炼命名约定）
      return _generateVideoMiniMax(
        prompt: prompt,
        model: model,
        refImage: refImage,
        resolution: resolution,
        ratio: ratio,
        duration: duration,
        timeout: timeout,
      );
    }
    throw _apiError(createResponse, '视频任务创建失败');
  }

  /// 百炼创建任务：返回原始响应（分流判定在 generateVideo，200 的解析在 _parseWanTaskId）
  Future<http.Response> _postWanCreate({
    required String prompt,
    required String model,
    required String resolution,
    required String ratio,
    required int duration,
    String? refImage,
  }) async {
    final hasRefImage = refImage != null && refImage.trim().isNotEmpty;
    final input = <String, dynamic>{
      'prompt': prompt.trim(),
    };
    if (hasRefImage) {
      input['img_url'] = refImage.trim(); // data URI，万相自动识别
    }
    final parameters = <String, dynamic>{
      'resolution': resolution,
      'duration': duration,
      'prompt_extend': true,
    };
    if (!hasRefImage) {
      parameters['ratio'] = ratio; // i2v 画面比例跟随首帧图
    }
    return _httpClient
        .post(
          Uri.parse(
              '$baseUrl/api/v1/services/aigc/video-generation/video-synthesis'),
          headers: {..._headers, 'X-DashScope-Async': 'enable'},
          body: json.encode({
            'model': model,
            'input': input,
            'parameters': parameters,
          }),
        )
        .timeout(const Duration(seconds: 30));
  }

  /// 百炼创建响应解析：output.task_id（缺失视为协议异常）
  String _parseWanTaskId(http.Response response) {
    final data = _decodeObject(response.body);
    final taskId = data['output']?['task_id']?.toString();
    if (taskId == null || taskId.isEmpty) {
      throw Exception('百炼未返回 task_id: ${response.body}');
    }
    return taskId;
  }

  /// 查询单次任务状态，返回 (task_status, video_url)
  Future<(String, String?)> queryTask(String taskId) async {
    final response = await _httpClient
        .get(
          Uri.parse('$baseUrl/api/v1/tasks/$taskId'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw _apiError(response, '视频任务查询失败');
    }
    final data = _decodeObject(response.body);
    final status = data['output']?['task_status']?.toString() ?? '';
    final videoUrl = data['output']?['video_url']?.toString();
    return (status, videoUrl);
  }

  /// 百炼轮询：PENDING/RUNNING 继续，SUCCEEDED 返回 video_url，FAILED/CANCELED/UNKNOWN 抛错
  Future<String> _waitForWan(
    String taskId, {
    required Duration timeout,
  }) async {
    final startedAt = DateTime.now();
    var delay = const Duration(seconds: 2);
    while (DateTime.now().difference(startedAt) < timeout) {
      final (status, videoUrl) = await queryTask(taskId);
      if (status == 'SUCCEEDED') {
        if (videoUrl != null && videoUrl.isNotEmpty) return videoUrl;
        throw Exception('视频任务成功但未返回 URL（task_id: $taskId）');
      }
      if (status == 'FAILED' || status == 'CANCELED' || status == 'UNKNOWN') {
        throw Exception('视频生成失败（task_id: $taskId, status: $status）');
      }
      await Future.delayed(delay);
      // 指数退避，30s 封顶
      delay = delay * 2;
      if (delay > const Duration(seconds: 30)) {
        delay = const Duration(seconds: 30);
      }
    }
    throw TimeoutException('视频生成超时（task_id: $taskId）');
  }

  // ===== 第十七章：MiniMax 官方协议（第三方兼容） =====

  /// MiniMax 协议生视频：创建任务 + 阻塞轮询，返回平台永久直链 URL
  ///
  /// - 选型依据：参考图支持 data: 内联（App 无 OSS 必须 base64 直传），
  ///   role=reference_image 与 App「参考图 = 主角形象参考」语义一致（非首帧）
  /// - resolution / duration 为 MiniMax 必填项，App 设置自动映射
  Future<String> _generateVideoMiniMax({
    required String prompt,
    required String model,
    required String resolution,
    required String ratio,
    required int duration,
    required Duration timeout,
    String? refImage,
  }) async {
    // 地址规范化（同 16.4 思路）：剥尾斜杠 → 剥误填完整端点 → 剥 /v1 或 /api 尾缀
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    const pastedSuffixes = ['/v2/video_generation', '/v1/media/generate'];
    for (final suffix in pastedSuffixes) {
      if (base.toLowerCase().endsWith(suffix)) {
        base = base.substring(0, base.length - suffix.length);
        while (base.endsWith('/')) {
          base = base.substring(0, base.length - 1);
        }
        break;
      }
    }
    for (final suffix in ['/v1', '/api']) {
      if (base.toLowerCase().endsWith(suffix)) {
        base = base.substring(0, base.length - suffix.length);
        while (base.endsWith('/')) {
          base = base.substring(0, base.length - 1);
        }
        break;
      }
    }
    final pollBase = '$base/v2/query/video_generation';

    final content = <Map<String, dynamic>>[
      {'type': 'text', 'text': prompt.trim()},
    ];
    final hasRef = refImage != null && refImage.trim().isNotEmpty;
    if (hasRef) {
      content.add({
        'type': 'image_url',
        'image_url': {'url': refImage.trim()},
        'role': 'reference_image',
      });
    }

    final body = <String, dynamic>{
      'model': model, // 平台模型名大小写不敏感（minimax-h3 / MiniMax-H3 均可）
      'content': content,
      'resolution': _mapMiniMaxResolution(resolution),
      'duration': duration.clamp(4, 15), // MiniMax 必填 4~15 秒
      'ratio': ratio, // 文生必填；参考生可选，均传 App 设置值
    };

    final createResp = await _httpClient
        .post(Uri.parse('$base/v2/video_generation'),
            headers: _headers, body: json.encode(body))
        .timeout(const Duration(seconds: 30));
    if (createResp.statusCode != 200) {
      throw _miniMaxCreateError(createResp);
    }
    final createData = _decodeObject(createResp.body);
    final taskId = createData['task_id']?.toString() ?? '';
    if (taskId.isEmpty) {
      throw Exception('第三方未返回 task_id: ${createResp.body}');
    }
    return _waitForMiniMax(pollBase, taskId, timeout: timeout);
  }

  /// App 分辨率档位 → MiniMax 档位（768P/1080P/2K/4K）：
  /// 百炼 720P 就近映射 768P，未知值兜底 768P（性价比高出片快）
  static String _mapMiniMaxResolution(String resolution) {
    const supported = ['768P', '1080P', '2K', '4K'];
    final normalized = resolution.trim().toUpperCase();
    if (normalized == '720P') return '768P';
    return supported.contains(normalized) ? normalized : '768P';
  }

  /// MiniMax 轮询：queued/running 继续；succeeded 取 task.content.url（平台永久直链）；
  /// failed/cancelled 抛 task.error.message（平台已自动退款）
  Future<String> _waitForMiniMax(
    String pollBase,
    String taskId, {
    required Duration timeout,
  }) async {
    final startedAt = DateTime.now();
    var delay = const Duration(seconds: 5); // 手册建议 5~10 秒
    while (DateTime.now().difference(startedAt) < timeout) {
      final response = await _httpClient
          .get(Uri.parse('$pollBase/$taskId'), headers: _headers)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw _apiError(response, '视频任务查询失败');
      }
      final data = _decodeObject(response.body);
      final task = data['task'];
      if (task is Map<String, dynamic>) {
        final status = task['status']?.toString() ?? '';
        if (status == 'succeeded') {
          final url = task['content'] is Map<String, dynamic>
              ? task['content']['url']?.toString() ?? ''
              : '';
          if (url.isNotEmpty) return url;
          throw Exception('视频任务成功但未返回 URL（task_id: $taskId）');
        }
        if (status == 'failed' || status == 'cancelled') {
          final err = task['error'];
          final msg =
              err is Map<String, dynamic> ? err['message']?.toString() ?? '' : '';
          throw Exception('视频生成失败（task_id: $taskId）'
              '${msg.isEmpty ? '' : ': $msg'}');
        }
        // queued / running → 继续轮询；无 task 字段视为异常响应也继续，不崩溃
      }
      await Future.delayed(delay);
      delay = delay * 2;
      if (delay > const Duration(seconds: 30)) {
        delay = const Duration(seconds: 30);
      }
    }
    throw TimeoutException('视频生成超时（task_id: $taskId）');
  }

  /// MiniMax 创建任务错误解析（保留服务端报错原文，如缺少 resolution、模型不存在）
  Exception _miniMaxCreateError(http.Response response) {
    try {
      final data = _decodeObject(response.body);
      final error = data['error'];
      if (error is Map<String, dynamic>) {
        final message = error['message']?.toString() ?? '';
        if (message.isNotEmpty) {
          return Exception(
              '视频任务创建失败 [${error['type'] ?? response.statusCode}]: $message');
        }
      }
    } catch (_) {
      // 非 JSON 错误体，走 HTTP 状态码
    }
    return Exception('视频任务创建失败（第三方协议）: HTTP ${response.statusCode}');
  }

  static Map<String, dynamic> _decodeObject(String body) {
    final decoded = json.decode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('服务端返回了无效的 JSON 结构');
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

/// 便捷入口：读取配置并生成视频
///
/// [refImageBytes] 首帧图本地字节（15.12 Base64 直传，替代 OSS）：
/// 非空时走图生视频（i2v），为空则纯文生视频（t2v）
Future<String> generateWanxVideo({
  required String prompt,
  Uint8List? refImageBytes,
}) async {
  // 19.3：视频能力改读独立槽位 key_video（互不回落）
  final apiKey = await getVideoApiKey();
  if (apiKey == null || apiKey.isEmpty) {
    throw Exception(keyNotSetError('视频'));
  }
  final model = await getVideoModel(); // 15.16：模型名可编辑，默认 wan3.0-video-prime
  final (resolution, ratio, duration) = await getWanVideoConfig();
  // 第二十章：接口地址可独立配置（空 = 官方默认）
  final client =
      WanxVideoClient(apiKey: apiKey, baseUrl: await getVideoBaseUrl());
  return client.generateVideo(
    prompt: prompt,
    model: model,
    refImage: encodeRefImageDataUri(refImageBytes),
    resolution: resolution,
    ratio: ratio,
    duration: duration,
  );
}
