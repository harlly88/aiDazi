import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'secure_key_store.dart';
import 'storage.dart';
import 'i18n.dart';
import 'openai.dart';
import 'tts_provider.dart' show BailianTtsClient;
import 'vits.dart';
import 'image_provider.dart';
import 'utils.dart' show snackBarAlert;

/// 15.17：常用性格关键词快捷 chips（点击添加，也可自由输入）
const List<String> kPersonalityPresets = [
  '乐观', '悲观', '温柔', '强势', '妒忌', '撒娇', '傲娇', '活泼', '内向', '幽默',
];

class PromptEditor extends StatefulWidget {
  /// 16.11：true = 新增角色模式（四分区表单）；false = 编辑模式（原功能）
  const PromptEditor({super.key, this.isNewCharacter = false});

  final bool isNewCharacter;

  @override
  PromptEditorState createState() => PromptEditorState();
}

/// 15.17：性格条目行（条目 + 关键词输入控制器）
class _TraitEntry {
  final PersonalityTrait trait;
  final TextEditingController controller;

  _TraitEntry(this.trait) : controller = TextEditingController(text: trait.trait);
}

class PromptEditorState extends State<PromptEditor> {
  TextEditingController controller = TextEditingController();
  TextEditingController studentNameController = TextEditingController();
  TextEditingController originMsgController = TextEditingController();
  TextEditingController studentAvatarController = TextEditingController();
  TextEditingController drawCharPromptController = TextEditingController();
  TextEditingController voiceIdController = TextEditingController();
  bool _isGenerating = false;
  bool _uploadingRefImage = false;
  String _refImageKey = "";
  // 15.17：角色性格条目（关键词 + 0-10 程度）
  List<_TraitEntry> _traits = [];
  // 16.10.4/16.12.7：音色区状态（voice_id 类型标记 + 声音描述创建）
  String _voicePrompt = ""; // 声音设计描述（非空 = 当前音色来自声音设计）
  String _voiceUrl = ""; // 声音复刻来源 URL（非空 = 当前音色来自声音复刻）
  bool _voiceDesignExpanded = false; // 「输入声音描述创建音色」展开态
  final TextEditingController _voiceDesignController = TextEditingController();
  bool _creatingVoice = false; // 声音设计 enrollment 进行中
  bool _testingVoice = false; // 测试播放进行中
  // 16.11：新增角色表单控制器（空白表单，与编辑模式的当前角色数据隔离）
  final TextEditingController _ncNameController = TextEditingController();
  final TextEditingController _ncFirstMsgController = TextEditingController();
  final TextEditingController _ncDescController = TextEditingController();
  final TextEditingController _ncVoiceDescController = TextEditingController();
  final TextEditingController _ncAppearanceController = TextEditingController();
  // 16.11.3：新增角色保存进度（null = 空闲；'voice' = 创建音色；'image' = 生成参考图）
  String? _newCharSaving;

  @override
  void initState() {
    super.initState();
    if (widget.isNewCharacter) {
      // 16.11：新增角色为空白表单，样貌区预填模板文本（可修改可清空）
      _ncAppearanceController.text = I18n.t('appearance_hint');
      return;
    }
    getPrompt().then((String value) {
      setState(() {
        controller.text = value;
      });
    });
    getAvatar().then((String value) {
      setState(() {
        studentAvatarController.text = value;
      });
    });
    getStudentName().then((String value) {
      setState(() {
        studentNameController.text = value;
      });
    });
    getOriginalMsg().then((String value) {
      setState(() {
        originMsgController.text = value;
      });
    });
    getDrawCharPrompt().then((String value) {
      setState(() {
        drawCharPromptController.text = value;
      });
    });
    getVoiceId().then((String value) {
      setState(() {
        voiceIdController.text = value;
      });
    });
    getRefImage().then((String value) {
      setState(() {
        _refImageKey = value;
      });
    });
    // 15.17：载入角色性格
    getPersonalityRaw().then((String value) {
      setState(() {
        _traits = parsePersonality(value).map(_TraitEntry.new).toList();
      });
    });
    // 16.10.4：音色创建来源（决定状态卡片的类型标签）
    getVoicePrompt().then((String value) {
      setState(() {
        _voicePrompt = value;
      });
    });
    getVoiceUrl().then((String value) {
      setState(() {
        _voiceUrl = value;
      });
    });
  }

  @override
  void dispose() {
    controller.dispose();
    studentNameController.dispose();
    originMsgController.dispose();
    studentAvatarController.dispose();
    drawCharPromptController.dispose();
    voiceIdController.dispose();
    _voiceDesignController.dispose();
    _ncNameController.dispose();
    _ncFirstMsgController.dispose();
    _ncDescController.dispose();
    _ncVoiceDescController.dispose();
    _ncAppearanceController.dispose();
    for (final entry in _traits) {
      entry.controller.dispose();
    }
    super.dispose();
  }

  /// 15.17：单条性格编辑行（关键词输入 + 0-10 滑块 + 删除）
  Widget _buildTraitRow(int index) {
    final entry = _traits[index];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: entry.controller,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: I18n.t('personality'),
              ),
            ),
          ),
          Expanded(
            flex: 5,
            child: Slider(
              value: entry.trait.level.toDouble(),
              min: 0,
              max: 10,
              divisions: 10,
              label: '${entry.trait.level}',
              onChanged: (value) =>
                  setState(() => entry.trait.level = value.round()),
            ),
          ),
          Text('${entry.trait.level}'),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () => setState(() {
              _traits.removeAt(index).controller.dispose();
            }),
          ),
        ],
      ),
    );
  }

  /// 15.17：性格编辑 UI（快捷 chips + 条目行 + 添加按钮），编辑/新增角色共用
  List<Widget> _buildPersonalityEditor() {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final preset in kPersonalityPresets)
              if (!_traits.any((t) => t.controller.text == preset))
                ActionChip(
                  label: Text(preset),
                  onPressed: () => setState(() => _traits.add(
                      _TraitEntry(
                          PersonalityTrait(trait: preset, level: 5)))),
                ),
          ],
        ),
      ),
      if (_traits.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: 16.0, vertical: 8.0),
          child: Text(
            I18n.t('personality_empty'),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      for (var i = 0; i < _traits.length; i++)
        _buildTraitRow(i),
      Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: OutlinedButton.icon(
          icon: const Icon(Icons.add, size: 18),
          label: Text(I18n.t('personality_add')),
          onPressed: () => setState(() => _traits.add(
              _TraitEntry(PersonalityTrait(trait: "", level: 5)))),
        ),
      ),
    ];
  }

  Future<void> _pickAvatar() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp']
    );

    if (result != null && result.files.single.bytes != null) {
      if (result.files.single.size > 1024 * 1024) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (BuildContext context) {
              return AlertDialog(
                title: Text(I18n.t('hint')),
                content: Text(I18n.t('image_size_limit')),
                actions: <Widget>[
                  TextButton(
                    child: Text(I18n.t('confirm')),
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                  ),
                ],
              );
            },
          );
        }
        return;
      }

      String base64Image = base64Encode(result.files.single.bytes!);
      final base64String = 'data:image/${result.files.single.extension};base64,$base64Image';
      setState(() {
        studentAvatarController.text = base64String;
      });
    }
  }

  // ===== 音色区（16.10.4/16.12.7 重写：状态卡片 + 切换方式，不提供手动输入 voice_id） =====

  /// 当前音色类型标签：声音设计 / 声音复刻 / 系统音色
  String get _voiceTypeLabel {
    if (_voicePrompt.isNotEmpty) return I18n.t('voice_type_design');
    if (_voiceUrl.isNotEmpty) return I18n.t('voice_type_clone');
    return I18n.t('voice_type_system');
  }

  /// 测试播放：用当前角色音色合成一句测试文本并播放
  Future<void> _testPlayVoice() async {
    if (_testingVoice) return;
    setState(() => _testingVoice = true);
    try {
      final path = await getAudio(context, "你好，这是一段测试语音，请听听这个声音。");
      if (path != null && path.isNotEmpty && mounted) {
        await playAudio(context, path);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("${I18n.t('voice_gen_failed')}: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _testingVoice = false);
    }
  }

  /// 清除音色：voice_id 清空，后续 TTS 走系统兜底音色
  Future<void> _clearVoice() async {
    await setVoiceId('');
    await saveVoiceId('');
    // 创建来源标记一并清除，避免类型标签误判
    await saveVoicePrompt('');
    await saveVoiceUrl('');
    setState(() {
      voiceIdController.text = "";
      _voicePrompt = "";
      _voiceUrl = "";
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('voice_cleared'))),
      );
    }
  }

  /// 直接选用系统音色（CosyVoice 内置公共音色，不走 enrollment）
  Future<void> _selectSystemVoice(String voiceId) async {
    await setVoiceId(voiceId);
    await saveVoiceId(voiceId);
    // 切系统音色后旧的创建来源标记一并清除
    await saveVoicePrompt('');
    await saveVoiceUrl('');
    setState(() {
      voiceIdController.text = voiceId;
      _voicePrompt = "";
      _voiceUrl = "";
    });
  }

  /// 调百炼声音设计创建音色，返回 voice_id（编辑/新增角色共用）
  Future<String> _createVoiceByPrompt(
      String voicePrompt, String roleName, String targetModel) async {
    // 19.3：音色注册（声音设计）改读独立槽位 key_tts
    final apiKey = await getTtsApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception(keyNotSetError('语音'));
    }
    final client = BailianTtsClient(apiKey: apiKey);
    return client.createVoice(
      voicePrompt: voicePrompt,
      targetModel: targetModel,
      prefix: roleName,
    );
  }

  /// 「输入声音描述创建音色」确认：声音设计 enrollment → 写工作态 + 持久化
  Future<void> _createVoiceFromDescription() async {
    final desc = _voiceDesignController.text.trim();
    if (desc.isEmpty || _creatingVoice) return;
    var targetModel = await getTtsModel();
    if (targetModel.trim().isEmpty) targetModel = 'cosyvoice-v3-flash';
    if (!mounted) return;
    setState(() => _creatingVoice = true);
    try {
      final voiceId = await _createVoiceByPrompt(
          desc, studentNameController.text.trim(), targetModel);
      await setVoiceId(voiceId);
      await saveVoiceId(voiceId);
      await saveVoicePrompt(desc);
      await saveVoiceUrl('');
      // 16.12.1：创建时的 target_model 必须与合成时一致，同步角色级合成模型
      await saveVoiceModel(targetModel);
      if (!mounted) return;
      setState(() {
        voiceIdController.text = voiceId;
        _voicePrompt = desc;
        _voiceUrl = "";
        _voiceDesignExpanded = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("${I18n.t('voice_enroll_failed')}: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _creatingVoice = false);
    }
  }

  /// 音色当前状态卡片：类型标签 + voice_id 前 8 位只读 + 测试播放/清除按钮
  Widget _buildVoiceStatusCard() {
    final voiceId = voiceIdController.text;
    if (voiceId.isEmpty) {
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Text(
            I18n.t('voice_type_none'),
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${I18n.t('voice_current')}：$_voiceTypeLabel',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              // voice_id 只读展示（前 8 位），用户不可手动输入
              'voice_id: ${voiceId.length > 8 ? voiceId.substring(0, 8) : voiceId}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton.icon(
                  icon: _testingVoice
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_circle_outline, size: 20),
                  label: Text(I18n.t('test_play')),
                  onPressed: _testingVoice ? null : _testPlayVoice,
                ),
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  label: Text(I18n.t('clear_voice')),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: _testingVoice ? null : _clearVoice,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 切换音色方式：系统女声/男声直接选用 + 声音描述创建（可展开）
  Widget _buildVoiceSwitchCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 8.0),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.female),
            title: Text(I18n.t('system_female')),
            subtitle: const Text('longanhuan_v3',
                style: TextStyle(fontSize: 12)),
            trailing: voiceIdController.text == 'longanhuan_v3'
                ? const Icon(Icons.check_circle, size: 20)
                : null,
            onTap: () => _selectSystemVoice('longanhuan_v3'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.male),
            title: Text(I18n.t('system_male')),
            subtitle:
                const Text('longanyang', style: TextStyle(fontSize: 12)),
            trailing: voiceIdController.text == 'longanyang'
                ? const Icon(Icons.check_circle, size: 20)
                : null,
            onTap: () => _selectSystemVoice('longanyang'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.edit_note),
            title: Text(I18n.t('create_voice_by_desc')),
            trailing: Icon(
              _voiceDesignExpanded ? Icons.expand_less : Icons.expand_more,
            ),
            onTap: () =>
                setState(() => _voiceDesignExpanded = !_voiceDesignExpanded),
          ),
          if (_voiceDesignExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _voiceDesignController,
                    maxLines: 4,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      hintText: I18n.t('voice_design_hint'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    icon: _creatingVoice
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check, size: 18),
                    label: Text(_creatingVoice
                        ? I18n.t('voice_enrolling')
                        : I18n.t('confirm')),
                    onPressed:
                        _creatingVoice ? null : _createVoiceFromDescription,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ===== 16.11：新增角色 =====

  /// 17.9：参考图点击 Dialog —— 显示大图 + 提示词可编辑 + 重新生成
  Future<void> _showRefImageDialog() async {
    final appearancePrompt = await getAppearancePrompt();
    final controller = TextEditingController(text: appearancePrompt);
    bool regenerating = false;

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setState) {
          return AlertDialog(
            title: const Text('参考图'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 大图预览
                  if (_refImageKey.isNotEmpty)
                    SizedBox(
                      height: 200,
                      child: _refImageKey.startsWith('http')
                          ? Image.network(_refImageKey, fit: BoxFit.contain)
                          : _refImageKey.startsWith('data:image/')
                              ? Image.memory(
                                  base64Decode(_refImageKey.split(',')[1]),
                                  fit: BoxFit.contain,
                                )
                              : Image.file(
                                  File(_refImageKey),
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) =>
                                      const Center(child: Icon(Icons.broken_image)),
                                ),
                    )
                  else
                    const SizedBox(
                      height: 100,
                      child: Center(child: Text('暂无参考图，下方描述后点重新生成')),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '样貌描述（可修改后重新生成）',
                      border: OutlineInputBorder(),
                      hintText: '描述角色的外观：性别、发型、眼睛、服装、风格等',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: regenerating ? null : () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed: regenerating
                    ? null
                    : () async {
                        final prompt = controller.text.trim();
                        if (prompt.isEmpty) {
                          snackBarAlert(ctx, '请输入样貌描述');
                          return;
                        }
                        setState(() => regenerating = true);
                        try {
                          final url = await generateWanxImage(
                            prompt: prompt, refImageBytes: null);
                          final localPath = await _downloadRefImage(url);
                          // 更新角色的参考图、头像、聊天背景（17.6 联动）
                          await saveRefImage(localPath);
                          await saveAppearancePrompt(prompt);
                          await setAvatar(localPath);
                          await setChatBackground(localPath);
                          await addBgImage(localPath);
                          if (!mounted) return;
                          setState(() {
                            _refImageKey = localPath;
                            studentAvatarController.text = localPath;
                          });
                          if (ctx.mounted) {
                            snackBarAlert(ctx, '参考图已更新，头像和背景已同步');
                            Navigator.pop(ctx);
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            snackBarAlert(ctx, '生成失败: $e');
                          }
                        } finally {
                          if (mounted) setState(() => regenerating = false);
                        }
                      },
                child: regenerating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('重新生成'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 下载万相生成的参考图到本地 ref_images 目录，返回本地路径
  Future<String> _downloadRefImage(String url) async {
    // 第十六章：OpenAI 协议 b64 兜底产物已是本地路径，直通不再发起 http
    if (!url.startsWith('http')) return url;
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw Exception('参考图下载失败: HTTP ${response.statusCode}');
    }
    final dir = await getApplicationDocumentsDirectory();
    final refDir = Directory('${dir.path}/ref_images');
    if (!await refDir.exists()) {
      await refDir.create(recursive: true);
    }
    final localPath =
        '${refDir.path}/ref_${DateTime.now().millisecondsSinceEpoch}.png';
    await File(localPath).writeAsBytes(response.bodyBytes);
    return localPath;
  }

  /// 16.11.3 / 18.2：新增角色保存流程
  /// 校验角色名 → 声音描述创建音色（失败降级兜底音色）→ 样貌描述生成参考图（失败降级留空）
  /// → addStudent 落角色记录（全字段，只入池不切换当前角色）→ character_saved → 返回
  Future<void> _saveNewCharacter() async {
    if (_newCharSaving != null) return;
    final name = _ncNameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('name_required'))),
      );
      return;
    }

    final firstMes = _ncFirstMsgController.text.trim();
    final description = _ncDescController.text.trim();
    final voicePrompt = _ncVoiceDescController.text.trim();
    final appearancePrompt = _ncAppearanceController.text.trim();

    // 16.12.1：创建时的 target_model 必须与合成时一致
    var targetModel = await getTtsModel();
    if (targetModel.trim().isEmpty) targetModel = 'cosyvoice-v3-flash';

    // (a) 声音描述非空 → 声音设计 enrollment；失败降级为 null（后续 TTS 走系统兜底音色）
    // 18.3：失败时用 AlertDialog 明确告知（原 SnackBar 4 秒消失用户不易察觉）
    String? voiceId;
    if (voicePrompt.isNotEmpty) {
      if (!mounted) return;
      setState(() => _newCharSaving = 'voice');
      try {
        voiceId = await _createVoiceByPrompt(voicePrompt, name, targetModel);
      } catch (e) {
        voiceId = null;
        debugPrint('[NewCharacter] createVoice failed: $e');
        if (mounted) {
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('音色生成失败'),
              content: Text('声音设计未成功（$e），该角色将使用系统兜底音色。'
                  '可在角色池中编辑该角色后重新创建音色。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('确定'),
                ),
              ],
            ),
          );
        }
      }
    }

    // (b) 样貌描述非空 → 万相文生图 → http 下载到本地 ref_images；失败降级为 null
    String? refImagePath;
    if (appearancePrompt.isNotEmpty) {
      if (!mounted) return;
      setState(() => _newCharSaving = 'image');
      try {
        final url = await generateWanxImage(
            prompt: appearancePrompt, refImageBytes: null);
        refImagePath = await _downloadRefImage(url);
      } catch (e) {
        refImagePath = null;
        debugPrint('[NewCharacter] generate ref image failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(I18n.t('ref_image_failed'))),
          );
        }
      }
    }

    try {
      // (c) 18.2：新增角色只入池，不切换当前角色、不写工作态
      // 所有字段一次性写入 student 记录，由用户在角色池点选后才切换
      final traits = _traits
          .where((t) => t.controller.text.trim().isNotEmpty)
          .map((t) => PersonalityTrait(
              trait: t.controller.text.trim(), level: t.trait.level))
          .toList();
      final personalityJson = encodePersonality(traits);

      // 17.6：参考图生成成功 → 头像 + 聊天背景 + 背景图列表都用参考图
      final refImg = refImagePath ?? '';
      final chatBg = refImg; // 新角色初始背景 = 参考图
      final bgImages = refImg; // 背景图列表首项

      await addStudent(
        name,
        refImg, // 索引 1：头像 = 参考图（修复池头像为空）
        firstMes,
        description,
        '', // draw_char_prompt
        voiceId: voiceId ?? '',
        refImage: refImg,
        voiceRefUrl: '',
        bgImages: bgImages,
        personality: personalityJson,
        voiceModel: voiceId != null ? targetModel : '',
        voiceUrl: '',
        voicePrompt: voicePrompt,
        appearancePrompt: appearancePrompt,
        chatBackground: chatBg,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _newCharSaving = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("保存失败: $e")),
        );
      }
      return;
    }

    // (e) 完成
    if (mounted) {
      setState(() => _newCharSaving = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('character_saved'))),
      );
      Navigator.pop(context);
    }
  }

  /// 16.11：新增角色四分区表单（基本信息 / 声音 / 样貌 / 性格）
  Widget _buildNewCharacterForm() {
    return ListView(
      padding: const EdgeInsets.all(8.0),
      children: <Widget>[
        // ===== 基本信息 =====
        ListTile(
          title: Text(I18n.t('char_basic_info')),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: TextField(
            controller: _ncNameController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: I18n.t('char_name'),
              hintText: I18n.t('char_name_hint'),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: TextField(
            controller: _ncFirstMsgController,
            maxLines: 3,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: I18n.t('char_first_msg'),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: TextField(
            controller: _ncDescController,
            maxLines: 5,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: I18n.t('char_description'),
            ),
          ),
        ),
        const Divider(),
        // ===== 声音区（文字描述创建，可留空） =====
        ListTile(
          title: Text(I18n.t('char_voice_section')),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: TextField(
            controller: _ncVoiceDescController,
            maxLines: 4,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: I18n.t('voice_design_hint'),
            ),
          ),
        ),
        const Divider(),
        // ===== 样貌区（自动生成参考图，可留空；预填模板文本） =====
        ListTile(
          title: Text(I18n.t('char_appearance_section')),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: TextField(
            controller: _ncAppearanceController,
            maxLines: 8,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const Divider(),
        // ===== 性格区（15.17 沿用：chips + 滑块） =====
        ListTile(
          title: Text(I18n.t('char_personality_section')),
          subtitle: Text(
            I18n.t('personality_hint'),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        ..._buildPersonalityEditor(),
      ],
    );
  }

  /// 选择参考图并保存到本地应用目录（15.12：OSS 移除，角色记录存本地路径）
  Future<void> _uploadRefImage() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (result == null || result.files.single.bytes == null) return;
    final file = result.files.single;

    // Base64 直传上限约 15MB（编码后 +33%，请求体 ≤20MB）
    if (file.bytes!.length > 15 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  "参考图过大（${(file.bytes!.length / 1024 / 1024).toStringAsFixed(1)}MB），上限 15MB，请压缩后重试")),
        );
      }
      return;
    }

    setState(() => _uploadingRefImage = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final refDir = Directory('${dir.path}/ref_images');
      if (!await refDir.exists()) {
        await refDir.create(recursive: true);
      }
      final localPath =
          '${refDir.path}/ref_${DateTime.now().millisecondsSinceEpoch}.${file.extension}';
      await File(localPath).writeAsBytes(file.bytes!);
      await saveRefImage(localPath);
      setState(() => _refImageKey = localPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(I18n.t('upload_success'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("${I18n.t('upload_failed')}: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingRefImage = false);
    }
  }

  Future<void> _showEditDialog(BuildContext context, String title,
      TextEditingController controller, {bool multiLine = false}) async {
    final TextEditingController dialogController =
        TextEditingController(text: controller.text);
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('${I18n.t('edit_title')}$title'),
          content: TextField(
            controller: dialogController,
            maxLines: multiLine ? 5 : 1,
            autofocus: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: title,
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
              child: Text(I18n.t('confirm')),
              onPressed: () {
                setState(() {
                  controller.text = dialogController.text;
                });
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  /// 抓取网页内容（Web 端通过多个 CORS Proxy fallback，原生端直连）
  ///
  /// 成功时返回提取后的纯文本；失败时返回以 [ERR] 开头的错误描述，
  /// 调用方据此弹出失败提示。
  Future<String> _fetchWebContent(String url) async {
    final errors = <String>[];

    final targetUri = Uri.tryParse(url);
    if (targetUri == null ||
        !targetUri.hasScheme ||
        (targetUri.scheme != 'http' && targetUri.scheme != 'https') ||
        targetUri.host.isEmpty) {
      return 'ERR: 请输入有效的 HTTP(S) URL';
    }

    if (kIsWeb) {
      // Web 端：多个 CORS Proxy 轮询（浏览器无法直接跨域请求）
      // proxy.cors.sh 格式: https://proxy.cors.sh/<url>
      // allorigins 格式:    https://api.allorigins.win/raw?url=<encoded>
      // corsproxy 格式:     https://corsproxy.io/?url=<encoded>
      final proxies = <({String name, Uri uri})>[
        // proxy.cors.sh 要求目标 URL 保持为路径的一部分，不能整体 encode。
        (
          name: 'proxy.cors.sh',
          uri: Uri.parse('https://proxy.cors.sh/$targetUri'),
        ),
        (
          name: 'allorigins.win',
          uri: Uri.parse(
            'https://api.allorigins.win/raw?url=${Uri.encodeComponent(targetUri.toString())}',
          ),
        ),
        (
          name: 'corsproxy.io',
          uri: Uri.parse(
            'https://corsproxy.io/?url=${Uri.encodeComponent(targetUri.toString())}',
          ),
        ),
      ];

      for (final proxy in proxies) {
        try {
          final response = await http.get(proxy.uri).timeout(
            const Duration(seconds: 8),
          );
          if (response.statusCode >= 200 &&
              response.statusCode < 300 &&
              response.body.isNotEmpty) {
            return _extractText(response.body);
          }
          errors.add(
            '${proxy.name} → HTTP ${response.statusCode} '
            '(body ${response.body.length}B)',
          );
        } catch (e) {
          errors.add('${proxy.name} → $e');
          continue;
        }
      }
      return 'ERR: 所有 CORS 代理均失败：\n${errors.join("\n")}';
    } else {
      // 原生端直连
      try {
        final dio = Dio();
        final response = await dio.get(
          targetUri.toString(),
          options: Options(
            responseType: ResponseType.plain,
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            },
          ),
        );
        final body = response.data.toString();
        if (body.isEmpty) {
          return 'ERR: 请求返回空内容';
        }
        return _extractText(body);
      } catch (e) {
        return 'ERR: $e';
      }
    }
  }

  /// 从 HTML 中提取纯文本，去除标签并截断
  String _extractText(String html) {
    final RegExp tagRegex = RegExp(r'<[^>]*>', multiLine: true);
    String text = html.replaceAll(tagRegex, ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length > 8000) {
      text = text.substring(0, 8000);
    }
    return text;
  }

  /// AI 生成角色卡对话框
  void _showAiGenerateDialog(BuildContext parentContext) {
    final TextEditingController inputController = TextEditingController();
    bool isUrlMode = false;

    showDialog(
      context: parentContext,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (sbContext, setDialogState) {
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 24),
                  const SizedBox(width: 8),
                  Text(I18n.t('character_editor')),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(isUrlMode ? '📄 网页模式' : '✏️ 文本模式'),
                        const Spacer(),
                        TextButton.icon(
                          icon: Icon(isUrlMode ? Icons.edit : Icons.link),
                          label: Text(isUrlMode ? '切换文本' : '切换网页'),
                          onPressed: () {
                            setDialogState(() {
                              isUrlMode = !isUrlMode;
                              inputController.clear();
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: inputController,
                      maxLines: isUrlMode ? 1 : 5,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        hintText: isUrlMode
                            ? '输入网页 URL（如 https://zh.moegirl.org.cn/...）'
                            : '输入角色描述（性格、背景、外貌等）',
                        labelText: isUrlMode ? 'URL' : '描述',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '提示：声纹与参考图不会被覆盖',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  child: Text(I18n.t('cancel')),
                  onPressed: () => Navigator.of(dialogContext).pop(),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: Text(I18n.t('confirm')),
                  onPressed: () async {
                    final input = inputController.text.trim();
                    if (input.isEmpty) return;

                    Navigator.of(dialogContext).pop();
                    _aiGenerate(parentContext, input, isUrlMode);
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 执行 AI 生成
  Future<void> _aiGenerate(
      BuildContext context, String input, bool isUrlMode) async {
    // 显示 loading（用 State 变量，不依赖 Navigator pop）
    setState(() => _isGenerating = true);

    bool finished = false;

    void showDialogMsg(String message) {
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(I18n.t('hint')),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(c).pop(),
                child: Text(I18n.t('confirm')),
              ),
            ],
          ),
        );
      }
    }

    void showError(String message) {
      if (finished) return;
      finished = true;
      if (mounted) setState(() => _isGenerating = false);
      showDialogMsg(message);
    }

    // 超时保护：60 秒后自动关 loading 并报错
    Future.delayed(const Duration(seconds: 60), () {
      if (!finished && mounted) {
        showError('生成超时，请检查网络或 API 配置后重试');
      }
    });

    try {
      String userContent = input;

      // URL 模式：先抓取网页
      if (isUrlMode) {
        final webContent = await _fetchWebContent(input);
        if (webContent.isEmpty || webContent.startsWith('ERR:')) {
          showError(webContent.isEmpty
              ? '无法抓取网页内容，请检查 URL 是否正确'
              : '无法抓取网页内容：\n${webContent.substring(4)}');
          return;
        }
        userContent = webContent;
      }

      debugPrint('[AI Generate] 即将发送给 LLM 的内容长度: ${userContent.length}');
      debugPrint('[AI Generate] 内容预览前500字:\n${userContent.length > 500 ? userContent.substring(0, 500) : userContent}');

      // 获取当前 LLM 配置
      final configs = await getApiConfigs();
      if (configs.isEmpty) {
        showError('请先在设置中配置 API');
        return;
      }

      final config = configs.first;

            final String systemPrompt = await getCharacterGenPrompt();

      final messages = [
        ['system', systemPrompt],
        ['user', userContent],
      ];

      StringBuffer responseBuffer = StringBuffer();

      debugPrint('[AI Generate] 开始 completion 调用');
      completion(config, messages, (chunk) {
        responseBuffer.write(chunk);
        debugPrint('[AI Generate] 接收到 LLM chunk: $chunk');
      }, () {
        debugPrint('[AI Generate] onDone 触发, context.mounted=${context.mounted}');
        if (finished) return;
        finished = true;
        if (mounted) setState(() => _isGenerating = false);

        try {
          // 解析 JSON
          String raw = responseBuffer.toString().trim();
          if (raw.isEmpty) {
            showDialogMsg('生成结果为空，请检查 API 配置或重试');
            return;
          }
          // 尝试提取 ```json 代码块
          final jsonMatch = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(raw);
          if (jsonMatch != null) {
            raw = jsonMatch.group(1)!.trim();
          }
          final Map<String, dynamic> result = jsonDecode(raw);
          debugPrint('[AI Generate] 解析后的 JSON: $result');

          setState(() {
            if (result['name'] != null && result['name'].toString().isNotEmpty) {
              studentNameController.text = result['name'].toString();
            }
            if (result['first_mes'] != null) {
              originMsgController.text = result['first_mes'].toString();
            }
            if (result['description'] != null) {
              controller.text = result['description'].toString();
            }
            if (result['draw_char_prompt'] != null) {
              drawCharPromptController.text = result['draw_char_prompt'].toString();
            }
          });

          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('角色卡生成成功！')),
            );
          }
        } catch (e) {
          final rawStr = responseBuffer.toString();
          final preview = rawStr.length > 500 ? rawStr.substring(0, 500) : rawStr;
          showDialogMsg('解析返回数据失败：$e\n\n原始返回：\n$preview');
        }
      }, (err) {
        debugPrint('[AI Generate] onErr 触发: $err');
        showError('API 调用失败：$err');
      });
    } catch (e) {
      debugPrint('[AI Generate] catch error: $e');
      showError('出错：$e');
    }
  }

  /// 编辑模式页面主体（原功能，音色区按 16.10.4/16.12.7 重写）
  Widget _buildEditorBody() {
    return ListView(
      padding: const EdgeInsets.all(8.0),
      children: <Widget>[
        // 17.8：头像由参考图自动生成，不允许用户手动更换
        ListTile(
          title: Text(I18n.t('character_avatar')),
          subtitle: const Text('头像由参考图自动生成，如需更换请修改参考图后重新生成'),
        ),
        Center(
          child: CircleAvatar(
            radius: 50,
            backgroundImage: studentAvatarController.text.startsWith('http')
              ? NetworkImage(studentAvatarController.text)
              : studentAvatarController.text.startsWith('data:image/')
                ? MemoryImage(base64Decode(studentAvatarController.text.split(',')[1]))
                : const AssetImage("assets/avatar.png")
          ),
        ),
        ListTile(
          title: Text(I18n.t('character_name')),
          subtitle: Text(
            studentNameController.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () =>
              _showEditDialog(context, I18n.t('character_name'), studentNameController),
        ),
        ListTile(
          title: Text(I18n.t('initial_dialogue')),
          subtitle: Text(
            originMsgController.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _showEditDialog(context, I18n.t('initial_dialogue'), originMsgController,
              multiLine: true),
        ),
        ListTile(
          title: Text(I18n.t('setting_prompt')),
          subtitle: Text(
            controller.text,
            maxLines: null,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: "Courier"),
          ),
          onTap: () =>
              _showEditDialog(context, I18n.t('setting_prompt'), controller, multiLine: true),
        ),
        ListTile(
          title: Text(I18n.t('draw_prompt')),
          subtitle: Text(
            drawCharPromptController.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _showEditDialog(context, I18n.t('draw_prompt'), drawCharPromptController,
              multiLine: true),
        ),
        const Divider(),
        // ===== 音色区（角色专属，16.10.4/16.12.7：状态卡片 + 切换方式） =====
        ListTile(
          leading: const Icon(Icons.record_voice_over),
          title: Text(I18n.t('voice_section')),
        ),
        _buildVoiceStatusCard(),
        _buildVoiceSwitchCard(),
        const Divider(),
        // ===== 参考图区（角色专属） =====
        ListTile(
          title: Text(I18n.t('ref_image_section')),
          subtitle: Text(
            I18n.t('ref_image_hint'),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        ListTile(
          leading: _uploadingRefImage
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.image),
          title: Text(I18n.t('ref_image_section')),
          subtitle: Text(
            // 15.12：本地路径只展示文件名
            _refImageKey.isEmpty
                ? "未上传"
                : _refImageKey.split(Platform.pathSeparator).last,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: _refImageKey.isEmpty ? Colors.grey : null,
            ),
          ),
          // 17.9：点击参考图改 Dialog（显示大图 + 提示词编辑 + 重新生成）
          onTap: _uploadingRefImage ? null : _showRefImageDialog,
        ),
        const Divider(),
        // ===== 性格区（15.17：关键词 + 0-10 程度） =====
        ListTile(
          title: Text(I18n.t('personality')),
          subtitle: Text(
            I18n.t('personality_hint'),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        ..._buildPersonalityEditor(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isNew = widget.isNewCharacter;
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: Text(
                isNew ? I18n.t('new_character') : I18n.t('character_editor')),
            actions: isNew
                ? [
                    // 保存新角色（16.11.3 保存流程）
                    IconButton(
                      icon: const Icon(Icons.save),
                      onPressed:
                          _newCharSaving == null ? _saveNewCharacter : null,
                    ),
                  ]
                : [
                    // AI 生成
                    IconButton(
                      icon: const Icon(Icons.auto_awesome),
                      tooltip: 'AI 生成角色卡',
                      onPressed: () => _showAiGenerateDialog(context),
                    ),
                    // 初始化
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: () async {
                        controller.text = await getPrompt(isDefault: true);
                        studentNameController.text = await getStudentName(isDefault: true);
                        originMsgController.text = await getOriginalMsg(isDefault: true);
                        studentAvatarController.text = await getAvatar(isDefault: true);
                        drawCharPromptController.text = await getDrawCharPrompt(isDefault: true);
                        setState(() {});
                      },
                    ),
                    // 保存
                    IconButton(
                      icon: const Icon(Icons.save),
                      onPressed: () async {
                        setPrompt(controller.text);
                        setStudentName(studentNameController.text);
                        setOriginalMsg(originMsgController.text);
                        setAvatar(studentAvatarController.text);
                        setDrawCharPrompt(drawCharPromptController.text);
                        // 17.6：头像非空 → 同步更新聊天背景 + 背景池（编辑模式用户可能通过 17.9 Dialog 改了参考图）
                        final avatarPath = studentAvatarController.text;
                        if (avatarPath.isNotEmpty &&
                            (avatarPath.startsWith('/') ||
                                avatarPath.contains('ref_images'))) {
                          await setChatBackground(avatarPath);
                          await addBgImage(avatarPath);
                        }
                        // 保存参考图路径（索引 7）——编辑模式可能通过 17.9 Dialog 改了
                        await saveRefImage(avatarPath);
                        // 音色区变更（系统音色/声音设计/清除）已即时持久化，此处兜底同步
                        await saveVoiceId(voiceIdController.text);
                        // 15.17：角色性格一并保存（过滤空关键词条目）
                        final traits = _traits
                            .where((t) => t.controller.text.trim().isNotEmpty)
                            .map((t) => PersonalityTrait(
                                trait: t.controller.text.trim(),
                                level: t.trait.level))
                            .toList();
                        await savePersonality(encodePersonality(traits));
                        if (!context.mounted) return;
                        Navigator.pop(context);
                      },
                    ),
                  ],
          ),
          body: isNew ? _buildNewCharacterForm() : _buildEditorBody(),
        ),
        // 新增角色保存进度遮罩（16.11.3）
        if (isNew && _newCharSaving != null)
          Container(
            color: Colors.black38,
            child: Center(
              child: AlertDialog(
                content: Row(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(width: 20),
                    Text(_newCharSaving == 'voice'
                        ? I18n.t('voice_enrolling')
                        : I18n.t('generating_ref_image')),
                  ],
                ),
              ),
            ),
          ),
        // AI 生成中的 loading 遮罩
        if (_isGenerating)
          Container(
            color: Colors.black38,
            child: const Center(
              child: AlertDialog(
                content: Row(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(width: 20),
                    Text('AI 正在生成角色卡...'),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
