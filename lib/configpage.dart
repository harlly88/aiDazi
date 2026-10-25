// ignore_for_file: use_build_context_synchronously

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:shared_preferences/shared_preferences.dart';
import 'storage.dart';
import 'i18n.dart';
import 'app_theme.dart' show primaryBlue;
import 'secure_key_store.dart';
import 'lan_config_page.dart';
import 'tts_provider.dart' show systemVoices;

import 'utils.dart'
    show snackBarAlert, Config, DecimalTextInputFormatter;

/// 19.7：密钥配置卡片（置顶）——四行槽位掩码 + 「网页配置」入口
///
/// 四项能力密钥独立（文字 / 语音 / 图像 / 视频），App 内不再提供手动输入；
/// 掩码永不回显明文（19.9）。Web 构建隐藏本卡片，保留旧手动输入路径。
class _KeyStatusCard extends StatefulWidget {
  const _KeyStatusCard();

  @override
  State<_KeyStatusCard> createState() => _KeyStatusCardState();
}

class _KeyStatusCardState extends State<_KeyStatusCard> {
  String _llmMask = '';
  String _ttsMask = '';
  String _imageMask = '';
  String _videoMask = '';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final configs = await getApiConfigs();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('current_api') ?? '';
    final current = (raw.startsWith('api_') && raw.length > 4)
        ? raw.substring(4)
        : (configs.isNotEmpty ? configs.first.name : '');
    final llmMask = maskKey(await getLlmApiKeyByName(current));
    final ttsMask = maskKey(await getTtsApiKey());
    final imageMask = maskKey(await getImageApiKey());
    final videoMask = maskKey(await getVideoApiKey());
    if (!mounted) return;
    setState(() {
      _llmMask = llmMask;
      _ttsMask = ttsMask;
      _imageMask = imageMask;
      _videoMask = videoMask;
      _loaded = true;
    });
  }

  Widget _slotRow(String label, String mask, {String? leading}) => ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: leading != null
            ? Text(leading,
                style: const TextStyle(fontSize: 12, color: Colors.grey))
            : null,
        title: Text(label, style: const TextStyle(fontSize: 14)),
        trailing: Text(
          mask,
          style: TextStyle(
            fontSize: 13,
            color: mask == '未配置' ? Colors.redAccent : Colors.grey[700],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Card(
      color: primaryBlue.withValues(alpha: 0.06),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(I18n.t('key_config_title'),
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: primaryBlue)),
            ),
            Text(I18n.t('key_config_hint'),
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            // 26.1-1：文字行不再显示厂商后缀（provider 已退化为内部标签）
            _slotRow(I18n.t('key_slot_llm'), _loaded ? _llmMask : '…',
                leading: '①'),
            _slotRow(I18n.t('key_slot_tts'), _loaded ? _ttsMask : '…',
                leading: '②'),
            _slotRow(I18n.t('key_slot_image'), _loaded ? _imageMask : '…',
                leading: '③'),
            _slotRow(I18n.t('key_slot_video'), _loaded ? _videoMask : '…',
                leading: '④'),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryBlue,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.devices, size: 18),
                label: Text(I18n.t('lan_config_title')),
                onPressed: () async {
                  await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const LanConfigPage()));
                  // 返回后刷新掩码（网页端可能已保存/切换 provider）
                  await _load();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 17.15 的 API Key 申请链接映射已于第二十六章删除（密钥申请自行去官网）。

/// 预置 LLM 模板已移至 storage.dart 公开为 presetConfigs（第二十二章：设置页与
/// 局域网配置服务共用，网页保存回落预置创建，修复 LLM 地址/模型名不落盘问题）

bool _isPresetName(String name) =>
    presetConfigs.any((c) => c.name == name);

class ConfigPage extends StatefulWidget {
  final Function(Config) updateFunc;
  final Config currentConfig;
  const ConfigPage({super.key, required this.updateFunc, required this.currentConfig});

  @override
  ConfigPageState createState() => ConfigPageState();
}

class ConfigPageState extends State<ConfigPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  String? selectedConfig;
  List<Config> apiConfigs = [];
  TextEditingController nameController = TextEditingController();
  TextEditingController urlController = TextEditingController();
  TextEditingController keyController = TextEditingController();
  TextEditingController modelController = TextEditingController();
  TextEditingController temperatureController = TextEditingController();
  TextEditingController frequencyPenaltyController = TextEditingController();
  TextEditingController presencePenaltyController = TextEditingController();
  TextEditingController maxTokensController = TextEditingController();

  // TTS 兜底音色
  String _fallbackVoice = 'longanhuan_v3';

  // 15.16：TTS / 生图 / 生视频模型名全部可编辑（官方可能下线/升级模型）
  // （19.2：ASR 已整体移除，语音输入回归系统输入法）
  final _ttsModelController = TextEditingController();
  final _wanImageModelController = TextEditingController();
  final _wanVideoModelController = TextEditingController();

  // 第二十章：TTS / 生图 / 生视频接口地址独立可编辑（空 = 官方默认）
  final _ttsUrlController = TextEditingController();
  final _imageUrlController = TextEditingController();
  final _videoUrlController = TextEditingController();

  // 万相文生图
  String _wanImageSize = '1080*1920';

  // 万相文生视频
  String _wanVideoResolution = '720P';
  String _wanVideoRatio = '9:16';
  int _wanVideoDuration = 5;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    getApiConfigs().then((List<Config> value) async {
      debugPrint("Loaded API configs: $value");
      // 14.4 预设自动补齐：无论列表是否为空，按 name 判重补齐缺失的预置项
      final existingNames = value.map((c) => c.name).toSet();
      for (final preset in presetConfigs) {
        if (!existingNames.contains(preset.name)) {
          value.add(preset);
        }
      }
      // 预置项排前，自定义项按字母序
      value.sort((a, b) {
        final ap = _isPresetName(a.name) ? 0 : 1;
        final bp = _isPresetName(b.name) ? 0 : 1;
        return ap != bp ? ap - bp : a.name.compareTo(b.name);
      });

      setState(() {
        apiConfigs = value;
        for (Config c in apiConfigs) {
          if (c.name == widget.currentConfig.name) {
            selectedConfig = c.name;
            break;
          }
        }
        nameController.text = widget.currentConfig.name;
        urlController.text = widget.currentConfig.baseUrl;
        keyController.text = widget.currentConfig.apiKey;
        modelController.text = widget.currentConfig.model;
        temperatureController.text = widget.currentConfig.temperature ?? "";
        frequencyPenaltyController.text = widget.currentConfig.frequencyPenalty ?? "";
        presencePenaltyController.text = widget.currentConfig.presencePenalty ?? "";
        maxTokensController.text = widget.currentConfig.maxTokens ?? "";
      });
    });
    // 语音 / 生图 / 生视频配置载入（15.16：模型名可编辑）
    getTtsFallbackVoice().then((v) {
      if (mounted) setState(() => _fallbackVoice = v);
    });
    getTtsModel().then((v) {
      if (mounted) _ttsModelController.text = v;
    });
    getWanImageConfig().then((config) {
      if (mounted) {
        setState(() {
          _wanImageModelController.text = config.$1;
          _wanImageSize = config.$2;
        });
      }
    });
    getVideoModel().then((v) {
      if (mounted) _wanVideoModelController.text = v;
    });
    getWanVideoConfig().then((config) {
      if (mounted) {
        setState(() {
          _wanVideoResolution = config.$1;
          _wanVideoRatio = config.$2;
          _wanVideoDuration = config.$3;
        });
      }
    });
    // 第二十章：接口地址独立配置（getter 已回落默认，输入框显示生效值）
    getTtsBaseUrl().then((v) {
      if (mounted) _ttsUrlController.text = v;
    });
    getImageBaseUrl().then((v) {
      if (mounted) _imageUrlController.text = v;
    });
    getVideoBaseUrl().then((v) {
      if (mounted) _videoUrlController.text = v;
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    nameController.dispose();
    urlController.dispose();
    keyController.dispose();
    modelController.dispose();
    temperatureController.dispose();
    frequencyPenaltyController.dispose();
    presencePenaltyController.dispose();
    maxTokensController.dispose();
    _ttsModelController.dispose();
    _wanImageModelController.dispose();
    _wanVideoModelController.dispose();
    _ttsUrlController.dispose();
    _imageUrlController.dispose();
    _videoUrlController.dispose();
    super.dispose();
  }

  Future<void> deleteConfirm(BuildContext context, String config) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false, // user must tap button!
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(I18n.t('confirm_delete')),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(I18n.t('delete_confirm_msg').replaceFirst('?', config)),
                Text(I18n.t('cannot_undo')),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: Text(I18n.t('cancel')),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: Text(I18n.t('delete')),
              onPressed: () {
                setState(() {
                  for (Config c in apiConfigs) {
                    if (c.name == config) {
                      deleteApiConfig(config);
                      apiConfigs.remove(c);
                      if (selectedConfig == config) {
                        if (apiConfigs.isNotEmpty) {
                          selectedConfig = apiConfigs[0].name;
                        }
                      }
                      break;
                    }
                  }
                });
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void saveConfig() {
    if (apiConfigs.isNotEmpty) {
      for (Config c in apiConfigs) {
        if (c.name == nameController.text) {
          // 删除旧配置
          deleteApiConfig(nameController.text);
          apiConfigs.remove(c);
        }
      }
    }
    Config newConfig = Config(
      name: nameController.text,
      baseUrl: urlController.text,
      apiKey: keyController.text,
      model: modelController.text,
      temperature: temperatureController.text.isEmpty
          ? null
          : temperatureController.text,
      frequencyPenalty: frequencyPenaltyController.text.isEmpty
          ? null
          : frequencyPenaltyController.text,
      presencePenalty: presencePenaltyController.text.isEmpty
          ? null
          : presencePenaltyController.text,
      maxTokens: maxTokensController.text.isEmpty
          ? null
          : maxTokensController.text,
    );
    setApiConfig(newConfig);
    setCurrentApiConfig(nameController.text);
    setState(() {
      apiConfigs.add(newConfig);
      selectedConfig = nameController.text;
    });
  }

  /// 15.16：保存模型名（空值回落默认）
  Future<void> _saveModelName(
      Future<void> Function(String) setter, String value) async {
    await setter(value.trim());
    snackBarAlert(context, I18n.t('save_success'));
  }

  // 26.1-6：环境信息预览按钮与 _showEnvPreview 已删除（位置/天气功能同轮下线）

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(I18n.t('model_config')),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: I18n.t('llm_chat_model')),
            Tab(text: I18n.t('voice_config')),
            Tab(text: I18n.t('image_model')),
            Tab(text: I18n.t('video_model')),
          ],
        ),
        // 第二十三章：io 平台三要素统一走网页配置，无字段可保存，AppBar 按钮
        // 仅 Web 保留（旧手动路径）；下拉切换厂商已即时生效（updateFunc + setCurrentApiConfig）
        actions: [
          if (kIsWeb) ...[
            // 初始化
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                setState(() {
                  nameController.clear();
                  urlController.clear();
                  keyController.clear();
                  modelController.clear();
                  temperatureController.clear();
                  frequencyPenaltyController.clear();
                  presencePenaltyController.clear();
                  maxTokensController.clear();
                });
              },
            ),
            // 保存（当前 LLM 配置，Web 旧路径）
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: () async {
                saveConfig();
                // 18.1：保存按钮同步持久化模型名（输入框仅 onSubmitted 保存，
                // 移动端直接点保存会丢失；空值回落各自默认值；19.2 ASR 已移除）
                final tts = _ttsModelController.text.trim();
                final wanImage = _wanImageModelController.text.trim();
                final wanVideo = _wanVideoModelController.text.trim();
                await setTtsModel(tts.isEmpty ? 'cosyvoice-v3-flash' : tts);
                await setWanImageConfig(
                    wanImage.isEmpty ? 'wan2.7-image' : wanImage, _wanImageSize);
                await setVideoModel(
                    wanVideo.isEmpty ? 'wan3.0-video-prime' : wanVideo);
                // 第二十章：接口地址同步持久化（空 = 恢复官方默认）
                await setTtsBaseUrl(_ttsUrlController.text.trim());
                await setImageBaseUrl(_imageUrlController.text.trim());
                await setVideoBaseUrl(_videoUrlController.text.trim());
                widget.updateFunc(Config(
                  name: nameController.text,
                  baseUrl: urlController.text,
                  apiKey: keyController.text,
                  model: modelController.text,
                  temperature: temperatureController.text.isEmpty
                      ? null
                      : temperatureController.text,
                  frequencyPenalty: frequencyPenaltyController.text.isEmpty
                      ? null
                      : frequencyPenaltyController.text,
                  presencePenalty: presencePenaltyController.text.isEmpty
                      ? null
                      : presencePenaltyController.text,
                  maxTokens: maxTokensController.text.isEmpty
                      ? null
                      : maxTokensController.text,
                ));
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildLlmTab(),
          _buildVoiceTab(),
          _buildImageTab(),
          _buildVideoTab(),
        ],
      ),
    );
  }

  // ==================== LLM 对话模型 ====================
  Widget _buildLlmTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SingleChildScrollView(
        child: Column(
          children: [
            // 19.7：密钥配置卡片置顶（Web 隐藏，保留旧手动输入路径）
            if (!kIsWeb) const _KeyStatusCard(),
            // 第二十四章：预设管理（厂商下拉切换）仅 Web 保留——io 三要素统一网页
            // 配置，直接改地址/密钥/模型名即可指向任意服务，厂商切换无必要
            if (kIsWeb) ...[
            ListTile(
              title: Text(I18n.t('preset_manage'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                children: [
                  DropdownButton<String>(
                    value: selectedConfig,
                    hint: Text(I18n.t('select_preset')),
                    isExpanded: true,
                    items: apiConfigs.map((Config config) {
                      final isQwen = config.name == 'qwen';
                      return DropdownMenuItem<String>(
                        value: config.name,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Text(config.name),
                                  if (isQwen) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: primaryBlue
                                            .withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text(
                                        '推荐',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: primaryBlue,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            // 预置项不可删除（14.4），仅自定义项显示删除按钮
                            if (!_isPresetName(config.name))
                              IconButton(
                                icon: const Icon(Icons.delete),
                                onPressed: () {
                                  deleteConfirm(context, config.name);
                                },
                              ),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (String? newValue) {
                      setState(() {
                        selectedConfig = newValue;
                        for (Config c in apiConfigs) {
                          if (c.name == newValue) {
                            nameController.text = c.name;
                            urlController.text = c.baseUrl;
                            keyController.text = c.apiKey;
                            modelController.text = c.model;
                            temperatureController.text = c.temperature ?? "";
                            frequencyPenaltyController.text = c.frequencyPenalty ?? "";
                            presencePenaltyController.text = c.presencePenalty ?? "";
                            maxTokensController.text = c.maxTokens ?? "";
                            widget.updateFunc(c);
                            break;
                          }
                        }
                      });
                      setCurrentApiConfig(selectedConfig!);
                    },
                  ),
                ],
              ),
            ),
            ],
            const SizedBox(height: 20),
            // 第二十三章：配置参数块仅 Web 保留（io 三要素统一走网页配置，清除重复输入）
            if (kIsWeb) ...[
            ListTile(
              title: Text(I18n.t('config_params'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                children: [
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(labelText: I18n.t('name')),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: urlController,
                    decoration: InputDecoration(labelText: I18n.t('api_url')),
                  ),
                  const SizedBox(height: 10),
                  // 19.7：io 平台已移除手动 Key 输入（统一走网页配置）；
                  // Web 构建保留旧输入路径（仅保证可编译可运行）
                  if (kIsWeb) ...[
                    TextField(
                      controller: keyController,
                      decoration:
                          InputDecoration(labelText: I18n.t('api_key')),
                    ),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: keyController,
                      builder: (context, value, _) {
                        final isAliyun = urlController.text
                            .contains('dashscope.aliyuncs.com');
                        if (!isAliyun) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '提示：此为阿里云百炼 API Key',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[600]),
                          ),
                        );
                      },
                    ),
                  ],
                  const SizedBox(height: 6),
                  const SizedBox(height: 10),
                  TextField(
                    controller: modelController,
                    decoration: InputDecoration(labelText: I18n.t('model')),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: temperatureController,
                          decoration: InputDecoration(labelText: I18n.t('temperature')),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [DecimalTextInputFormatter()],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: frequencyPenaltyController,
                          decoration: InputDecoration(labelText: I18n.t('frequency_penalty')),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [DecimalTextInputFormatter()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: presencePenaltyController,
                          decoration: InputDecoration(labelText: I18n.t('presence_penalty')),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [DecimalTextInputFormatter()],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: maxTokensController,
                          decoration: InputDecoration(labelText: I18n.t('max_output_length')),
                          keyboardType: const TextInputType.numberWithOptions(),
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    child: Text(I18n.t('save_preset')),
                    onPressed: () {
                      if (nameController.text.isEmpty ||
                          urlController.text.isEmpty ||
                          keyController.text.isEmpty ||
                          modelController.text.isEmpty) {
                        snackBarAlert(context, I18n.t('please_fill_all'));
                      } else {
                        saveConfig();
                        snackBarAlert(context, I18n.t('save_success'));
                      }
                    },
                  ),
                ],
              ),
            ),
            ],
          ],
        ),
      ),
    );
  }

  // ==================== 语音（TTS） ====================
  Widget _buildVoiceTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(I18n.t('voice_config_hint')),
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          title: Text(I18n.t('tts_config'),
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 第二十三章：TTS 模型名 / 接口地址仅 Web 保留（io 统一走网页配置）
              if (kIsWeb) ...[
                // 15.16：TTS 模型名可编辑（默认 cosyvoice-v3-flash）
                TextField(
                  controller: _ttsModelController,
                  decoration: InputDecoration(
                    labelText: I18n.t('tts_model_name'),
                    hintText: 'cosyvoice-v3-flash',
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (v) =>
                      _saveModelName(setTtsModel, v.isEmpty ? 'cosyvoice-v3-flash' : v),
                ),
                const SizedBox(height: 8),
                // 第二十章：TTS 接口地址独立可编辑（空 = 官方默认）
                TextField(
                  controller: _ttsUrlController,
                  decoration: InputDecoration(
                    labelText: I18n.t('base_url_label'),
                    hintText: defaultTtsBaseUrl,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (v) =>
                      _saveModelName(setTtsBaseUrl, v.trim()),
                ),
                const SizedBox(height: 4),
                Text(I18n.t('base_url_hint'),
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 12),
              ],
              Text(I18n.t('tts_fallback_voice'),
                  style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 4),
              DropdownButton<String>(
                value: _fallbackVoice,
                isExpanded: true,
                items: systemVoices
                    .map((v) => DropdownMenuItem<String>(
                          value: v.id,
                          child: Text(v.label),
                        ))
                    .toList(),
                onChanged: (String? newValue) async {
                  if (newValue == null) return;
                  await setTtsFallbackVoice(newValue);
                  setState(() => _fallbackVoice = newValue);
                  snackBarAlert(context, I18n.t('save_success'));
                },
              ),
              const SizedBox(height: 4),
              Text(
                I18n.t('tts_fallback_voice_hint'),
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ==================== 生图模型（万相） ====================
  Widget _buildImageTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(I18n.t('wan_image_hint')),
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          title: Text(I18n.t('image_model'),
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              // 第二十三章：生图模型名 / 接口地址仅 Web 保留（io 统一走网页配置）
              if (kIsWeb) ...[
                // 15.16：生图模型名可编辑（默认 wan2.7-image；官方下线/升级可自行更换）
                TextField(
                  controller: _wanImageModelController,
                  decoration: InputDecoration(
                    labelText: I18n.t('model'),
                    hintText: 'wan2.7-image',
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (v) => _saveModelName(
                      (m) => setWanImageConfig(m, _wanImageSize),
                      v.isEmpty ? 'wan2.7-image' : v),
                ),
                const SizedBox(height: 8),
                // 第二十章：图像接口地址独立可编辑（空 = 官方默认）
                TextField(
                  controller: _imageUrlController,
                  decoration: InputDecoration(
                    labelText: I18n.t('base_url_label'),
                    hintText: defaultImageBaseUrl,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (v) => _saveModelName(setImageBaseUrl, v.trim()),
                ),
                const SizedBox(height: 4),
                Text(
                  I18n.t('model_editable_hint'),
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(height: 12),
              ],
              Text(I18n.t('image_resolution'), style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 4),
              // 15.6：统一 9:16 竖版档位（适配手机竖屏）
              DropdownButton<String>(
                value: _wanImageSize,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: '720*1280', child: Text('720×1280（9:16）')),
                  DropdownMenuItem(value: '1080*1920', child: Text('1080×1920（9:16）')),
                ],
                onChanged: (String? newValue) async {
                  if (newValue == null) return;
                  await setWanImageConfig(
                      _wanImageModelController.text, newValue);
                  setState(() => _wanImageSize = newValue);
                  snackBarAlert(context, I18n.t('save_success'));
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ==================== 生视频模型（万相） ====================
  Widget _buildVideoTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(I18n.t('wan_video_hint')),
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          title: Text(I18n.t('video_model'),
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 第二十三章：生视频模型名 / 接口地址仅 Web 保留（io 统一走网页配置）
              if (kIsWeb) ...[
                // 15.16：生视频模型名可编辑（默认 wan3.0-video-prime；旧 -t2v 命名图生自动切 i2v）
                TextField(
                  controller: _wanVideoModelController,
                  decoration: InputDecoration(
                    labelText: I18n.t('model'),
                    hintText: 'wan3.0-video-prime',
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (v) => _saveModelName(
                      setVideoModel, v.isEmpty ? 'wan3.0-video-prime' : v),
                ),
                const SizedBox(height: 8),
                // 第二十章：视频接口地址独立可编辑（空 = 官方默认）
                TextField(
                  controller: _videoUrlController,
                  decoration: InputDecoration(
                    labelText: I18n.t('base_url_label'),
                    hintText: defaultVideoBaseUrl,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (v) => _saveModelName(setVideoBaseUrl, v.trim()),
                ),
                const SizedBox(height: 4),
                Text(
                  I18n.t('model_editable_hint'),
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(height: 12),
              ],
              Text(I18n.t('video_resolution'), style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 4),
              DropdownButton<String>(
                value: _wanVideoResolution,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: '720P', child: Text('720P')),
                  DropdownMenuItem(value: '1080P', child: Text('1080P')),
                ],
                onChanged: (String? newValue) async {
                  if (newValue == null) return;
                  await setWanVideoConfig(newValue, _wanVideoRatio, _wanVideoDuration);
                  setState(() => _wanVideoResolution = newValue);
                  snackBarAlert(context, I18n.t('save_success'));
                },
              ),
              const SizedBox(height: 12),
              Text(I18n.t('video_ratio'), style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 4),
              DropdownButton<String>(
                value: _wanVideoRatio,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: '9:16', child: Text('9:16（竖屏）')),
                  DropdownMenuItem(value: '16:9', child: Text('16:9（横屏）')),
                  DropdownMenuItem(value: '1:1', child: Text('1:1（正方形）')),
                  DropdownMenuItem(value: '4:3', child: Text('4:3')),
                  DropdownMenuItem(value: '3:4', child: Text('3:4')),
                ],
                onChanged: (String? newValue) async {
                  if (newValue == null) return;
                  await setWanVideoConfig(_wanVideoResolution, newValue, _wanVideoDuration);
                  setState(() => _wanVideoRatio = newValue);
                  snackBarAlert(context, I18n.t('save_success'));
                },
              ),
              const SizedBox(height: 12),
              Text('${I18n.t('video_duration')}：$_wanVideoDuration ${I18n.t('video_duration_seconds')}',
                  style: const TextStyle(fontSize: 14)),
              Slider(
                value: _wanVideoDuration.toDouble(),
                min: 2,
                max: 15,
                divisions: 13,
                label: '$_wanVideoDuration',
                onChanged: (value) => setState(() => _wanVideoDuration = value.round()),
                onChangeEnd: (value) async {
                  await setWanVideoConfig(_wanVideoResolution, _wanVideoRatio, value.round());
                  snackBarAlert(context, I18n.t('save_success'));
                },
              ),
              Text(
                I18n.t('video_cost_hint'),
                style: TextStyle(fontSize: 12, color: Colors.orange[700]),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
