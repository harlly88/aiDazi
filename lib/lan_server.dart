import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lan_config_html.dart';
import 'secure_key_store.dart';
import 'storage.dart';
import 'tts_provider.dart' show enrollImportedCharacter;
import 'utils.dart' show Config, jsonToMsg;

/// 19.5：局域网配置事件
sealed class LanEvent {}

/// 密钥已保存并落盘（slots 如 ['llm:qwen', 'tts']）——服务随后自动关闭（四步流程第 4 步）
class LanKeysSaved extends LanEvent {
  final List<String> slots;
  LanKeysSaved(this.slots);
}

/// 角色卡已导入入池（服务保持开启，可连续导入；warnings 含音色注册等非致命提示）
class LanCharacterImported extends LanEvent {
  final String? studentKey;
  final String name;
  final List<String> warnings;
  LanCharacterImported(this.studentKey, this.name, this.warnings);
}

/// 空转 10 分钟超时（服务已自动关闭）
class LanIdleTimeout extends LanEvent {}

/// 19.5：局域网配置服务（io 实现，dart:io HttpServer，零新增依赖）
///
/// - 只 bind 局域网具体 IP（192.168.\* / 10.\* / 172.16-31.\*），**绝不 0.0.0.0**（19.9）
/// - 端口默认 8888，占用顺延 8889 / 8890，全部失败抛异常
/// - 路由：GET / 内嵌配置页；GET /api/status 只读状态（掩码）；POST /api/keys 保存密钥
///   后自动关闭；POST /api/character?filename= 原始字节直传角色卡（上限 50MB，不关服务）
/// - 空转 10 分钟自动关闭；请求处理全部 try/catch，不让服务 isolate 崩溃
class LanConfigServer {
  HttpServer? _server;
  Timer? _idleTimer;
  void Function(LanEvent event)? _onEvent;
  bool _closing = false;

  /// 启动成功返回实际地址 "192.168.x.x:8888"；失败抛异常（无局域网 IP / 端口全占用）
  Future<String> start({void Function(LanEvent event)? onEvent}) async {
    if (_server != null) {
      throw Exception('配置服务已在运行');
    }
    _onEvent = onEvent;
    _closing = false;

    final ip = await _findLanIp();
    if (ip == null) {
      throw Exception('未检测到局域网 IP，请连接 WiFi 后重试');
    }

    const ports = [8888, 8889, 8890];
    Object? lastError;
    for (final port in ports) {
      try {
        // 19.9：只 bind 局域网具体 IP，绝不用 InternetAddress.anyIPv4 / 0.0.0.0
        final server = await HttpServer.bind(InternetAddress(ip), port);
        _server = server;
        _resetIdleTimer();
        server.listen(_handleRequest,
            onError: (Object error) => debugPrint('lan server error: $error'),
            onDone: () {
          _server = null;
        });
        return '$ip:$port';
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('端口 8888/8889/8890 均被占用：$lastError');
  }

  /// 关闭服务（幂等，可重复调用）
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  // ===== 局域网 IP 探测 =====

  /// 取局域网 IPv4：优先 192.168.\*，其次 10.\*，再次 172.16-31.\*；无结果返回 null
  Future<String?> _findLanIp() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final all = <String>[];
    for (final ni in interfaces) {
      for (final addr in ni.addresses) {
        all.add(addr.address);
      }
    }
    for (final ip in all) {
      if (ip.startsWith('192.168.')) return ip;
    }
    for (final ip in all) {
      if (ip.startsWith('10.')) return ip;
    }
    for (final ip in all) {
      if (ip.startsWith('172.')) {
        final second = int.tryParse(ip.split('.').length > 1 ? ip.split('.')[1] : '');
        if (second != null && second >= 16 && second <= 31) return ip;
      }
    }
    return null;
  }

  // ===== 生命周期 =====

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    if (_closing) return;
    _idleTimer = Timer(const Duration(minutes: 10), () {
      debugPrint('lan server idle timeout, closing');
      _onEvent?.call(LanIdleTimeout());
      unawaited(close());
    });
  }

  // ===== 请求分发 =====

  /// 15.4：角色辅助生成外链——文档目录 lan_config.json 的 character_gen_url，
  /// 文件不存在/字段缺失/解析异常一律回落内置默认值（改文件刷新网页即生效，无需重新打包）
  Future<String> _characterGenUrl() async {
    const fallback = 'https://dazi.ai126.cn';
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/lan_config.json');
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        if (data is Map<String, dynamic>) {
          final url = data['character_gen_url'];
          if (url is String && url.isNotEmpty) return url;
        }
      }
    } catch (e) {
      debugPrint('read lan_config.json error: $e');
    }
    return fallback;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _resetIdleTimer();
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && (path == '/' || path == '/index.html')) {
        request.response.headers
            .set('Content-Type', 'text/html; charset=utf-8');
        // 15.4：角色辅助生成外链占位符替换（URL 来自文档目录 lan_config.json，每次请求读取，改文件刷新即生效）
        final html = lanConfigHtml.replaceAll(
            '__CHARACTER_GEN_URL__', await _characterGenUrl());
        request.response.write(html);
        await request.response.close();
        return;
      }
      if (request.method == 'GET' && path == '/api/status') {
        await _handleStatus(request);
        return;
      }
      if (request.method == 'POST' && path == '/api/keys') {
        await _handleKeys(request);
        return;
      }
      // 第十六章：恢复千问默认设定（清全部密钥 + 三要素恢复默认，不关服务）
      if (request.method == 'POST' && path == '/api/reset') {
        await _handleReset(request);
        return;
      }
      if (request.method == 'POST' && path == '/api/character') {
        await _handleCharacter(request);
        return;
      }
      // 第二十五章：角色导出（纯读 GET，不关服务，可连续下载）
      if (request.method == 'GET' && path == '/api/characters') {
        await _handleCharacterList(request);
        return;
      }
      if (request.method == 'GET' && path == '/api/character/export') {
        await _handleCharacterExport(request);
        return;
      }
      // 第十五章：故事导入/导出（纯读 GET 不关服务；POST 导入不关可连续）
      if (request.method == 'GET' && path == '/api/stories') {
        await _handleStoryList(request);
        return;
      }
      if (request.method == 'GET' && path == '/api/story/export') {
        await _handleStoryExport(request);
        return;
      }
      if (request.method == 'POST' && path == '/api/story') {
        await _handleStoryImport(request);
        return;
      }
      await _json(request, 404, {'ok': false, 'error': 'not found'});
    } catch (e) {
      debugPrint('lan server handle error: $e');
      try {
        await _json(request, 400, {'ok': false, 'error': '$e'});
      } catch (_) {
        // 响应可能已关闭（如超限时已返回 413），忽略
      }
    }
  }

  Future<void> _json(HttpRequest request, int status, Map<String, dynamic> data) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(data));
    await request.response.close();
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    if (body.isEmpty) throw Exception('请求体为空');
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) throw Exception('请求体格式无效');
    return decoded;
  }

  Future<String?> _currentProvider() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('current_api') ?? '';
    if (raw.startsWith('api_') && raw.length > 4) return raw.substring(4);
    return null;
  }

  // ===== GET /api/status：provider 列表 + 当前选中 + 四槽密钥掩码 + 模型名（只读） =====

  Future<void> _handleStatus(HttpRequest request) async {
    final configs = await getApiConfigs();
    final current = (await _currentProvider()) ??
        (configs.isNotEmpty ? configs.first.name : 'qwen');
    // 22.2：掩码直接读槽位（不依赖 Config 列表是否已存在）
    final llmMask = maskKey(await getLlmApiKeyByName(current));
    String llmUrl = '';
    String llmModel = '';
    for (final c in configs) {
      if (c.name == current) {
        llmUrl = c.baseUrl;
        llmModel = c.model;
        break;
      }
    }
    // 22.2：prefs 尚无该 provider 的 Config（未进过设置页）→ 预填预置默认值
    if (llmUrl.isEmpty && llmModel.isEmpty) {
      final preset = findPresetConfig(current);
      if (preset != null) {
        llmUrl = preset.baseUrl;
        llmModel = preset.model;
      }
    }
    _json(request, 200, {
      'ok': true,
      'currentProvider': current,
      'llmKeyMask': llmMask,
      'ttsKeyMask': maskKey(await getTtsApiKey()),
      'imageKeyMask': maskKey(await getImageApiKey()),
      'videoKeyMask': maskKey(await getVideoApiKey()),
      // 第二十一章：三要素配套（密钥 + 接口地址 + 模型名称），地址/模型名明文预填
      'llmUrl': llmUrl,
      'llmModel': llmModel,
      'ttsUrl': await getTtsBaseUrl(),
      'imageUrl': await getImageBaseUrl(),
      'videoUrl': await getVideoBaseUrl(),
      'ttsModel': await getTtsModel(),
      'imageModel': (await getWanImageConfig()).$1,
      'videoModel': await getVideoModel(),
    });
  }

  // ===== POST /api/keys：四槽位独立保存（字段全可选，只更新提供的字段）→ 自动关闭 =====

  Future<void> _handleKeys(HttpRequest request) async {
    final data = await _readJsonBody(request);
    final saved = <String>[];

    final llmProvider = data['llmProvider']?.toString();
    final ttsKey = data['ttsKey']?.toString().trim();
    if (ttsKey != null && ttsKey.isNotEmpty) {
      await setTtsApiKey(ttsKey);
      saved.add('tts');
    }

    final imageKey = data['imageKey']?.toString().trim();
    if (imageKey != null && imageKey.isNotEmpty) {
      await setImageApiKey(imageKey);
      saved.add('image');
    }

    final videoKey = data['videoKey']?.toString().trim();
    if (videoKey != null && videoKey.isNotEmpty) {
      await setVideoApiKey(videoKey);
      saved.add('video');
    }

    // ===== 第二十二章：LLM 三要素（密钥/地址/模型名）合并原子保存 =====
    // 根因修复：此前 url/model 保存要求 prefs 已存在 api_{provider} 列表（预置 Config
    // 仅在设置页打开时补齐），新用户网页首次配置时该键缺失 → 静默丢弃，且
    // setCurrentApiConfig 写下的 current 会指向空列表被 getApiConfigs 误删。
    // 现在找不到已存 Config 时回落预置模板创建；先 setApiConfig 确保列表存在，
    // 再写密钥 / 切换 current（current 永不指向空列表）。

    // 目标 provider（网页未指定时用当前 provider）
    Future<String> targetProvider() async =>
        (llmProvider != null && llmProvider.isNotEmpty)
            ? llmProvider
            : (await _currentProvider()) ?? 'qwen';

    final llmKey = data['llmKey']?.toString().trim();
    final llmUrl = data['llmUrl']?.toString().trim();
    final llmModel = data['llmModel']?.toString().trim();
    final hasLlmKey = llmKey != null && llmKey.isNotEmpty;
    final hasLlmUrl = llmUrl != null && llmUrl.isNotEmpty;
    final hasLlmModel = llmModel != null && llmModel.isNotEmpty;
    if (hasLlmKey || hasLlmUrl || hasLlmModel) {
      final provider = await targetProvider();
      final configs = await getApiConfigs();
      Config target = findPresetConfig(provider) ??
          Config(
              name: provider,
              baseUrl: '',
              apiKey: '',
              model: '',
              temperature: '1',
              frequencyPenalty: '',
              presencePenalty: '',
              maxTokens: '8192');
      for (final c in configs) {
        if (c.name == provider) {
          target = c;
          break;
        }
      }
      // 1. 先存 Config（确保 api_{provider} 列表存在）
      await setApiConfig(Config(
        name: provider,
        baseUrl: hasLlmUrl ? llmUrl : target.baseUrl,
        apiKey: target.apiKey,
        model: hasLlmModel ? llmModel : target.model,
        temperature: target.temperature,
        frequencyPenalty: target.frequencyPenalty,
        presencePenalty: target.presencePenalty,
        maxTokens: target.maxTokens,
      ));
      // 2. 密钥 + 切换 current（列表已存在）
      if (hasLlmKey) {
        await setLlmApiKey(provider, llmKey);
        await setCurrentApiConfig(provider);
        saved.add('llm:$provider');
      }
      if (hasLlmUrl) saved.add('llmUrl:$provider');
      if (hasLlmModel) saved.add('llmModel:$provider');
    }

    // 三能力地址：字段存在即保存（含空串 = 恢复官方默认）
    if (data.containsKey('ttsUrl')) {
      await setTtsBaseUrl(data['ttsUrl']?.toString().trim() ?? '');
      saved.add('ttsUrl');
    }
    if (data.containsKey('imageUrl')) {
      await setImageBaseUrl(data['imageUrl']?.toString().trim() ?? '');
      saved.add('imageUrl');
    }
    if (data.containsKey('videoUrl')) {
      await setVideoBaseUrl(data['videoUrl']?.toString().trim() ?? '');
      saved.add('videoUrl');
    }

    // 第二十一章：模型名称独立保存（字段存在即保存，空串 = 恢复默认模型名）
    if (data.containsKey('ttsModel')) {
      final m = data['ttsModel']?.toString().trim() ?? '';
      await setTtsModel(m.isEmpty ? 'cosyvoice-v3-flash' : m);
      saved.add('ttsModel');
    }
    if (data.containsKey('imageModel')) {
      final m = data['imageModel']?.toString().trim() ?? '';
      final (_, size) = await getWanImageConfig();
      await setWanImageConfig(m.isEmpty ? 'wan2.7-image' : m, size);
      saved.add('imageModel');
    }
    if (data.containsKey('videoModel')) {
      final m = data['videoModel']?.toString().trim() ?? '';
      await setVideoModel(m.isEmpty ? 'wan3.0-video-prime' : m);
      saved.add('videoModel');
    }

    if (saved.isEmpty) {
      await _json(request, 400, {'ok': false, 'error': '未提供任何配置'});
      return;
    }

    await _json(request, 200, {'ok': true, 'saved': saved});
    debugPrint('lan server keys saved: $saved, closing');
    // 用户四步流程第 4 步：保存成功 → 自动关闭
    _onEvent?.call(LanKeysSaved(saved));
    await close();
  }

  // ===== POST /api/reset：恢复千问默认设定（第十六章，不关服务） =====

  /// 全量恢复出厂 API 配置态（用户自行改乱三要素后的回归出口）：
  /// 1. 清空四能力全部密钥槽位（key_llm_* + key_tts/key_image/key_video）
  /// 2. LLM 六家 provider Config 恢复预置模板，current → qwen
  /// 3. 三能力地址恢复默认（空串 = 官方 dashscope），模型名恢复默认；
  ///    图像 size 保留（属绘图参数非 API 设定）
  /// 成功后**不关服务**——网页刷新状态继续引导用户当场重填新 Key（保存时才关）
  Future<void> _handleReset(HttpRequest request) async {
    await clearAllApiKeys();
    for (final preset in presetConfigs) {
      await setApiConfig(preset);
    }
    await setCurrentApiConfig('qwen');
    await setTtsBaseUrl('');
    await setImageBaseUrl('');
    await setVideoBaseUrl('');
    await setTtsModel('cosyvoice-v3-flash');
    final (_, size) = await getWanImageConfig();
    await setWanImageConfig('wan2.7-image', size);
    await setVideoModel('wan3.0-video-prime');
    debugPrint('lan server reset to qwen defaults (service keeps running)');
    await _json(request, 200, {'ok': true});
    // 不关服务、不触发 LanKeysSaved（区别于保存流程）
  }

  // ===== POST /api/character?filename=xx.png：原始字节直传角色卡（上限 50MB）=====

  Future<void> _handleCharacter(HttpRequest request) async {
    final filename = request.uri.queryParameters['filename'] ?? 'card.png';
    const maxBytes = 50 * 1024 * 1024;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        await _json(request, 413, {'ok': false, 'error': '角色卡超过 50MB 上限'});
        return;
      }
    }
    final bytes = builder.takeBytes();

    final CharacterImportResult result;
    try {
      result = await importCharacterCardBytes(
          Uint8List.fromList(bytes), filename);
    } catch (e) {
      await _json(request, 400, {'ok': false, 'error': '$e'});
      return;
    }

    // 19.8：导入后处理链——voice_url / voice_prompt / appearance_prompt 自动
    // enrollment（写入池记录，不经过工作态）；TTS 密钥未配置时角色照常入池，
    // warnings 返回提示（不阻塞导入）
    final warnings = List<String>.from(result.warnings);
    final needsEnroll = result.voiceUrl.isNotEmpty ||
        result.voicePrompt.isNotEmpty ||
        result.appearancePrompt.isNotEmpty;
    if (needsEnroll) {
      final ttsKey = await getTtsApiKey();
      if (ttsKey == null) {
        warnings.add('音色注册已跳过：未配置语音密钥');
      } else {
        try {
          await enrollImportedCharacter(
            studentKey: result.studentKey,
            voiceUrl: result.voiceUrl.isNotEmpty ? result.voiceUrl : null,
            voicePrompt:
                result.voicePrompt.isNotEmpty ? result.voicePrompt : null,
            appearancePrompt:
                result.appearancePrompt.isNotEmpty ? result.appearancePrompt : null,
            roleName: result.name,
          );
        } catch (e) {
          warnings.add('音色/参考图注册失败：$e');
        }
      }
    }

    await _json(request, 200, {
      'ok': true,
      'studentKey': result.studentKey,
      'warnings': warnings,
    });
    // 不自动关闭（支持连续导入多张）
    _onEvent?.call(
        LanCharacterImported(result.studentKey, result.name, warnings));
  }

  // ===== GET /api/characters：角色池名称列表（25.5） =====
  Future<void> _handleCharacterList(HttpRequest request) async {
    final students = await getStudents();
    final names = students
        .where((s) => s.isNotEmpty && s[0].isNotEmpty)
        .map((s) => s[0])
        .toList()
      ..sort();
    _json(request, 200, {'ok': true, 'characters': names});
  }

  // ===== GET /api/character/export?name=：构造 ST V2 PNG 卡流式下载（25.5） =====
  Future<void> _handleCharacterExport(HttpRequest request) async {
    final name = request.uri.queryParameters['name'] ?? '';
    if (name.isEmpty) {
      await _json(request, 400, {'ok': false, 'error': '缺少 name 参数'});
      return;
    }
    final students = await getStudents();
    List<String>? record;
    for (final s in students) {
      if (s.isNotEmpty && s[0] == name) {
        record = s;
        break;
      }
    }
    if (record == null) {
      await _json(request, 404, {'ok': false, 'error': '未找到角色：$name'});
      return;
    }
    try {
      // 25.3：角色池记录槽位 → 共用卡构造（0 名/1 头像/2 开场白/3 人设/5 生图提示
      // /7 参考图/9 音色URL/10 背景图/14 性格/15-18 语音四要素）
      final bytes = await buildCharacterCardBytes(
        name: record[0],
        description: record[3],
        firstMes: record[2],
        drawCharPrompt: record[5],
        voiceRefUrl: record[9],
        refImage: record[7],
        bgImages: record[10].isEmpty ? const [] : record[10].split(','),
        personality: record[14],
        voiceModel: record[15],
        voiceUrl: record[16],
        voicePrompt: record[17],
        appearancePrompt: record[18],
        avatarUri: record[1],
      );
      final filename = 'aiDaziCard_$name.png';
      final response = request.response;
      response.statusCode = 200;
      response.headers.contentType = ContentType('image', 'png');
      // RFC 5987：中文文件名安全编码
      response.headers.set('Content-Disposition',
          "attachment; filename*=UTF-8''${Uri.encodeComponent(filename)}");
      response.contentLength = bytes.length;
      await response.addStream(Stream<Uint8List>.value(bytes));
      await response.close();
      // 纯读操作不关服务、不触发事件
    } catch (e) {
      debugPrint('lan export character error: $e');
      await _json(request, 500, {'ok': false, 'error': '导出失败：$e'});
    }
  }

  // ===== 第十五章：故事导入/导出 =====

  /// GET /api/stories：列出故事池（纯读不关服务）
  Future<void> _handleStoryList(HttpRequest request) async {
    final historys = await getHistorys();
    final stories = historys.map((h) {
      return {'name': h[0], 'timestamp': h[1]};
    }).toList();
    _json(request, 200, {'ok': true, 'stories': stories});
  }

  /// GET /api/story/export?timestamp=xxx：导出 characterBook JSON 下载（纯读不关服务）
  Future<void> _handleStoryExport(HttpRequest request) async {
    final timestamp = request.uri.queryParameters['timestamp'] ?? '';
    if (timestamp.isEmpty) {
      await _json(request, 400, {'ok': false, 'error': '缺少 timestamp 参数'});
      return;
    }
    final historys = await getHistorys();
    List<String>? record;
    for (final h in historys) {
      if (h[1] == timestamp) {
        record = h;
        break;
      }
    }
    if (record == null) {
      await _json(request, 404, {'ok': false, 'error': '未找到故事：$timestamp'});
      return;
    }
    try {
      // record = [name, timestamp, msgJson]；msgJson → List<Message> → 提取文本
      final name = record[0];
      final msgJson = record[2];
      final messages = jsonToMsg(msgJson);
      final msgContents = messages.map((m) => m.message).toList();

      // 构造 characterBook JSON（与 downloadHistorytoJson 格式一致）
      final entries = <Map<String, dynamic>>[];
      for (var i = 0; i < msgContents.length; i++) {
        entries.add({
          'keys': <String>[],
          'content': msgContents[i],
          'extensions': <String, dynamic>{},
          'enabled': true,
          'insertion_order': i,
          'constant': true,
        });
      }
      final characterBook = {
        'name': name,
        'description': '',
        'extensions': <String, dynamic>{},
        'entries': entries,
      };
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(characterBook)));
      final filename = 'aiDaziStory_$name.json';
      final response = request.response;
      response.statusCode = 200;
      response.headers.contentType = ContentType('application', 'json');
      // RFC 5987：中文文件名安全编码
      response.headers.set('Content-Disposition',
          "attachment; filename*=UTF-8''${Uri.encodeComponent(filename)}");
      response.contentLength = bytes.length;
      await response.addStream(Stream<Uint8List>.value(bytes));
      await response.close();
      // 纯读操作不关服务、不触发事件
    } catch (e) {
      debugPrint('lan export story error: $e');
      await _json(request, 500, {'ok': false, 'error': '导出失败：$e'});
    }
  }

  /// POST /api/story：导入故事（原始 JSON 字节，非 multipart，上限 50MB；不关可连续）
  Future<void> _handleStoryImport(HttpRequest request) async {
    const maxBytes = 50 * 1024 * 1024;
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in request) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          await _json(request, 413, {'ok': false, 'error': '故事文件超过 50MB 上限'});
          return;
        }
      }
      final bytes = builder.takeBytes();
      final jsonString = utf8.decode(bytes);
      if (jsonString.isEmpty) {
        await _json(request, 400, {'ok': false, 'error': '请求体为空'});
        return;
      }
      await restoreHistoryFromJson(jsonString);
      debugPrint('lan story imported successfully');
      await _json(request, 200, {'ok': true});
      // 导入后不关服务，可连续导入
    } catch (e) {
      debugPrint('lan import story error: $e');
      await _json(request, 400, {'ok': false, 'error': '$e'});
    }
  }
}
