import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
// 用于 Uint8List
import 'package:image/image.dart' as img; // 导入 image 包并重命名，避免冲突
import 'utils.dart';
import 'display_settings_defaults.dart';
import 'package:http/http.dart' as http;
import 'non_web_utils.dart' if (dart.library.html) 'web_utils.dart';
import 'i18n.dart';

// List 0:base_url 1:api_key 2:model_name 3:temperature 4:frequency_penalty 5:presence_penalty 6:max_tokens
// 19.3：LLM 密钥改存 secure storage（key_llm_{name}）；io 平台保存时 apiKey 恒写空串占位
// （保持 Config 结构兼容不迁移 schema）；Web 平台保留旧行为（回落 Config.apiKey）
Future<void> setApiConfig(Config config) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final String storedKey = kIsWeb ? config.apiKey : '';
  List<String> configList = [config.baseUrl, storedKey, config.model];
  if (config.temperature != null) {
    configList.add(config.temperature!);
  } else {
    configList.add('');
  }
  if (config.frequencyPenalty != null) {
    configList.add(config.frequencyPenalty!);
  } else {
    configList.add('');
  }
  if (config.presencePenalty != null) {
    configList.add(config.presencePenalty!);
  } else {
    configList.add('');
  }
  if (config.maxTokens != null) {
    configList.add(config.maxTokens!);
  } else {
    configList.add('');
  }
  await prefs.setStringList("api_${config.name}", configList);
  debugPrint("set api ${config.name}: ${config.toString()}");
}

Future<void> setCurrentApiConfig(String name) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("current_api", "api_$name");
}

// ===== 预置 LLM 模板（第二十二章：原 configpage 私有 _presetConfigs 移此公开，
// 供设置页补齐与局域网配置服务共用；预设项不可删除，与 agent.md 第三章 3.1 一致） =====

final List<Config> presetConfigs = [
  Config(name: "qwen", baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1", apiKey: "", model: "qwen3.7-flash", temperature: "1", frequencyPenalty: "", presencePenalty: "", maxTokens: "8192"),
  Config(name: "deepseek", baseUrl: "https://api.deepseek.com/v1", apiKey: "", model: "deepseek-chat", temperature: "1", frequencyPenalty: "", presencePenalty: "", maxTokens: "8192"),
  Config(name: "doubao", baseUrl: "https://ark.cn-beijing.volces.com/api/v3", apiKey: "", model: "doubao-seed-1-6", temperature: "1", frequencyPenalty: "", presencePenalty: "", maxTokens: "8192"),
  Config(name: "glm", baseUrl: "https://open.bigmodel.cn/api/paas/v4", apiKey: "", model: "glm-4.6", temperature: "1", frequencyPenalty: "", presencePenalty: "", maxTokens: "8192"),
  Config(name: "kimi", baseUrl: "https://api.moonshot.cn/v1", apiKey: "", model: "kimi-k2-turbo-preview", temperature: "1", frequencyPenalty: "", presencePenalty: "", maxTokens: "8192"),
  Config(name: "custom", baseUrl: "", apiKey: "", model: "", temperature: "1", frequencyPenalty: "", presencePenalty: "", maxTokens: "8192"),
];

/// 按名称取预置模板（找不到返回 null）
Config? findPresetConfig(String name) {
  for (final c in presetConfigs) {
    if (c.name == name) return c;
  }
  return null;
}

Future<void> deleteApiConfig(String name) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.remove("api_$name");
  debugPrint("delete api $name");
}

Future<List<Config>> getApiConfigs() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  List<Config> configs = [];
  String current = prefs.getString("current_api") ?? "";
  Set<String> keys = prefs.getKeys();
  if (current.isNotEmpty) {
    if (prefs.getStringList(current) == null) {
      await prefs.remove("current_api");
    } else {
      List<String> currentConfig =
          prefs.getStringList(current) ?? ['', '', '', ''];
      if (currentConfig.length == 3) {
        configs.add(Config(
            name: current.replaceFirst("api_", ""),
            baseUrl: currentConfig[0],
            apiKey: currentConfig[1],
            model: currentConfig[2]));
      } else if (currentConfig.length == 7) {
        configs.add(Config(
            name: current.replaceFirst("api_", ""),
            baseUrl: currentConfig[0],
            apiKey: currentConfig[1],
            model: currentConfig[2],
            temperature: currentConfig[3],
            frequencyPenalty: currentConfig[4],
            presencePenalty: currentConfig[5],
            maxTokens: currentConfig[6]));
      }
    }
  }
  for (String key in keys) {
    if (key.startsWith("api_") && key != current) {
      List<String> currentConfig = prefs.getStringList(key) ?? ['', '', '', ''];
      if (currentConfig.length == 3) {
        configs.add(Config(
            name: key.replaceFirst("api_", ""),
            baseUrl: currentConfig[0],
            apiKey: currentConfig[1],
            model: currentConfig[2]));
      } else if (currentConfig.length == 7) {
        configs.add(Config(
            name: key.replaceFirst("api_", ""),
            baseUrl: currentConfig[0],
            apiKey: currentConfig[1],
            model: currentConfig[2],
            temperature: currentConfig[3],
            frequencyPenalty: currentConfig[4],
            presencePenalty: currentConfig[5],
            maxTokens: currentConfig[6]));
      }
    }
  }
  debugPrint("query api configs: ${configs.toString()}");
  return configs;
}

// 0:name 1:avatar 2:first_mes 3:description 4:timestamp
// 5:draw_char_prompt 6:voice_id 7:ref_image(本地路径) 8:预留
// 9:voice_ref_url 10:bg_images(逗号分隔本地路径) 11:预留 12:预留
// 13:chat_background(当前聊天背景本地路径) 14:personality(性格JSON) 15:voice_model(TTS合成模型)
// 16:voice_url(声音复刻URL) 17:voice_prompt(声音设计描述) 18:appearance_prompt(样貌描述)
Future<List<List<String>>> getStudents() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  List<List<String>> students = [];
  Set<String> keys = prefs.getKeys();
  for (String key in keys) {
    if (key.startsWith("student_")) {
      List<String> data = prefs.getStringList(key) ?? ["", "", "", "", ""];
      while (data.length < 19) {
        data.add("");
      }
      students.add(data);
    }
  }
  return students;
}

Future<String> addStudent(String name, String avatar, String firstMes,
    String description, String drawCharPrompt,
    {String voiceId = "",
    String refImage = "",
    String voiceRefUrl = "",
    String bgImages = "",
    String personality = "",
    String voiceModel = "",
    String voiceUrl = "",
    String voicePrompt = "",
    String appearancePrompt = "",
    String chatBackground = ""}) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String timeStamp = DateTime.now().millisecondsSinceEpoch.toString();
  final key = "student_${timeStamp}_$name";
  // 索引 16-18：voice_url / voice_prompt / appearance_prompt
  // 索引 13：chat_background
  await prefs.setStringList(key, [
    name,
    avatar,
    firstMes,
    description,
    timeStamp,
    drawCharPrompt,
    voiceId,
    refImage,
    "",
    voiceRefUrl,
    bgImages,
    "",
    "",
    chatBackground,
    personality,
    voiceModel,
    voiceUrl,
    voicePrompt,
    appearancePrompt,
  ]);
  return key;
}

/// 18.2：定位当前角色对应的 student 记录 key（同名时取 timestamp 最大的最新一条）
Future<String?> _findCurrentStudentKey() async {
  final prefs = await SharedPreferences.getInstance();
  final currentName = await getStudentName();
  final keys = prefs.getKeys().where((k) => k.startsWith("student_"));
  String? matchedKey;
  int matchedTs = -1;
  for (String key in keys) {
    final data = prefs.getStringList(key);
    if (data == null || data.isEmpty || data[0] != currentName) continue;
    final ts = int.tryParse(data.length > 4 ? data[4] : "") ?? 0;
    if (ts > matchedTs) {
      matchedTs = ts;
      matchedKey = key;
    }
  }
  return matchedKey;
}

/// 更新当前角色的 student 记录指定槽位（角色级属性直写）
/// 18.2：同名记录取最新一条（timestamp 最大），避免写串
Future<void> updateCurrentStudentField(int fieldIndex, String value) async {
  final prefs = await SharedPreferences.getInstance();
  final key = await _findCurrentStudentKey();
  if (key == null) return;
  final data = prefs.getStringList(key) ?? [];
  while (data.length <= fieldIndex) {
    data.add("");
  }
  data[fieldIndex] = value;
  await prefs.setStringList(key, data);
}

/// 读取当前角色 student 记录指定槽位
Future<String> getCurrentStudentField(int fieldIndex) async {
  final prefs = await SharedPreferences.getInstance();
  final key = await _findCurrentStudentKey();
  if (key == null) return "";
  final data = prefs.getStringList(key);
  if (data == null || data.length <= fieldIndex) return "";
  return data[fieldIndex];
}

/// 18.2：按完整 student key（student_<ts>_<name>）更新指定槽位
/// 用于导入角色后 enrollment 直接写该池记录，不经过工作态
Future<void> updateStudentFieldByKey(
    String key, int fieldIndex, String value) async {
  final prefs = await SharedPreferences.getInstance();
  final data = prefs.getStringList(key) ?? [];
  while (data.length <= fieldIndex) {
    data.add("");
  }
  data[fieldIndex] = value;
  await prefs.setStringList(key, data);
}

/// 18.2：按完整 student key 读取指定槽位
Future<String> getStudentFieldByKey(String key, int fieldIndex) async {
  final prefs = await SharedPreferences.getInstance();
  final data = prefs.getStringList(key);
  if (data == null || data.length <= fieldIndex) return "";
  return data[fieldIndex];
}

Future<void> deleteStudent(String key) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  if (prefs.containsKey(key)) {
    await prefs.remove(key);
  } else {
    debugPrint("key not found: $key");
  }
}

// 0:intro 1:timestamp 2:msg
Future<List<List<String>>> getHistorys() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  List<List<String>> historys = [];
  Set<String> keys = prefs.getKeys();
  for (String key in keys) {
    if (key.startsWith("history_")) {
      String timeStamp = key.replaceFirst("history_", "");
      List<String> history = prefs.getStringList(key) ?? ["", ""];
      historys.add([history[0], timeStamp, history[1]]);
    }
  }
  return historys;
}

Future<void> addHistory(String msg, String name) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String timeStamp = DateTime.now().millisecondsSinceEpoch.toString();
  await prefs.setStringList("history_$timeStamp", [name, msg]);
}

Future<void> deleteHistory(String key) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  if (prefs.containsKey(key)) {
    await prefs.remove(key);
  } else {
    debugPrint("key not found: $key");
  }
}

Future<void> setAvatar(String imgUri) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("avatar", imgUri);
}

Future<String> getAvatar({bool isDefault = false}) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? avatar = prefs.getString("avatar");
  if (avatar == null || isDefault) {
    return "assets/avatar.png";
  }
  return avatar;
}

Future<void> setTempHistory(String msg) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("temp_history", msg);
}

Future<String?> getTempHistory() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("temp_history");
}

Future<String> convertToJson() async {
  final prefs = await SharedPreferences.getInstance();
  final keys = prefs.getKeys();

  Map<String, dynamic> allPrefs = Map.from(displaySettingsBackupDefaults);
  for (String key in keys) {
    allPrefs[key] = prefs.get(key);
  }
  return jsonEncode(allPrefs);
}

Future<void> setUserName(String name) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("user_name", name);
}

Future<String> getUserName() async {
  // 15.9：我的设定中的称呼优先于旧 user_name（作为 {{user}} 宏取值来源）
  final profile = await getUserProfile();
  if (profile.name.isNotEmpty) {
    return profile.name;
  }
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? name = prefs.getString("user_name");
  if (name == null || name.isEmpty) {
    return I18n.t('default_user_name');
  }
  return name;
}

// ===== 我的设定（15.9：用户画像）：单独 key 存 JSON，随本地备份/恢复整体导出导入 =====

class UserProfile {
  String name; // 对我的称呼（非空时替换 {{user}} 宏取值来源）
  String occupation; // 职业
  String age; // 年龄
  String other; // 其他个人信息

  UserProfile({
    this.name = "",
    this.occupation = "",
    this.age = "",
    this.other = "",
  });

  bool get isEmpty =>
      name.isEmpty &&
      occupation.isEmpty &&
      age.isEmpty &&
      other.isEmpty;

  Map<String, dynamic> toJson() => {
        'name': name,
        'occupation': occupation,
        'age': age,
        'other': other,
      };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        name: json['name']?.toString() ?? "",
        occupation: json['occupation']?.toString() ?? "",
        age: json['age']?.toString() ?? "",
        // 26.1-4：birthday 字段已删除（隐私），旧数据静默忽略
        other: json['other']?.toString() ?? "",
      );
}

Future<UserProfile> getUserProfile() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString("user_profile");
  if (raw == null || raw.isEmpty) return UserProfile();
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return UserProfile.fromJson(decoded);
    }
  } catch (_) {
    // 损坏数据回退为空画像
  }
  return UserProfile();
}

Future<void> setUserProfile(UserProfile profile) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("user_profile", jsonEncode(profile.toJson()));
}

Future<String> getStudentName({bool isDefault = false}) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? name = prefs.getString("name");
  if (name == null || isDefault) {
    return I18n.t('default_student_name');
  }
  return name;
}

Future<void> setStudentName(String name) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("name", name);
}

Future<String> getOriginalMsg({bool isDefault = false}) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? msg = prefs.getString("first_mes");
  if (msg == null || isDefault) {
    return I18n.t('default_first_msg');
  }
  return msg;
}

Future<void> setOriginalMsg(String msg) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("first_mes", msg);
}

Future<String> getPrompt({bool isDefault = false}) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? prompt = prefs.getString("description");
  if (prompt == null || isDefault) {
    prompt = I18n.t('default_prompt');
  }
  return prompt.trimLeft();
}

Future<void> setPrompt(String prompt) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("description", prompt);
}

// ===== 声纹（角色级）：索引 6 = voice_id，索引 9 = voiceRefUrl =====
// 全局 pref 存当前工作态（切换角色时由记录载入），student 记录存角色持久属性

/// 当前角色 voice_id（阿里 CosyVoice 注册返回；空 = 未注册）
Future<String> getVoiceId() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("voice_id") ?? "";
}

/// 写当前工作态 voice_id（切换角色载入 / 通用 setter）
Future<void> setVoiceId(String voiceId) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("voice_id", voiceId);
}

/// 声纹注册成功：写工作态 + 持久化到当前角色记录
Future<void> saveVoiceId(String voiceId) async {
  await setVoiceId(voiceId);
  await updateCurrentStudentField(6, voiceId);
}

// ===== 角色级 TTS 合成模型（15.16.1）：索引 15 = voice_model =====
// 复用外部注册的 voice_id 时，合成模型必须与注册时一致；
// 角色卡导入时自动带入，优先级：角色级 > 全局 tts_model > 默认 cosyvoice-v3-flash

/// 当前角色 voice_model（空 = 跟随全局配置）
Future<String> getVoiceModel() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("voice_model") ?? "";
}

Future<void> setVoiceModel(String model) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("voice_model", model);
}

/// 保存角色级合成模型：写工作态 + 持久化到当前角色记录
Future<void> saveVoiceModel(String model) async {
  await setVoiceModel(model);
  await updateCurrentStudentField(15, model);
}

// ===== 角色卡声音来源与样貌描述（16.10）=====
// 索引 16 = voice_url（声音复刻用公网声音文件 URL，导入角色）
// 索引 17 = voice_prompt（声音设计自然语言描述，自建角色）
// 索引 18 = appearance_prompt（自建角色样貌描述，用于生成参考图）
// 两者二选一：voice_url 走声音复刻 enrollment，voice_prompt 走声音设计 enrollment

/// 当前角色 voice_url（公网声音文件 URL；空 = 无）
Future<String> getVoiceUrl() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("voice_url") ?? "";
}

Future<void> setVoiceUrl(String url) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("voice_url", url);
}

/// 保存角色卡声音复刻 URL：写工作态 + 持久化到当前角色记录
Future<void> saveVoiceUrl(String url) async {
  await setVoiceUrl(url);
  await updateCurrentStudentField(16, url);
}

/// 当前角色 voice_prompt（声音设计描述；空 = 无）
Future<String> getVoicePrompt() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("voice_prompt") ?? "";
}

Future<void> setVoicePrompt(String prompt) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("voice_prompt", prompt);
}

/// 保存角色卡声音设计描述：写工作态 + 持久化到当前角色记录
Future<void> saveVoicePrompt(String prompt) async {
  await setVoicePrompt(prompt);
  await updateCurrentStudentField(17, prompt);
}

/// 当前角色 appearance_prompt（样貌描述；空 = 无）
Future<String> getAppearancePrompt() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("appearance_prompt") ?? "";
}

Future<void> setAppearancePrompt(String prompt) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("appearance_prompt", prompt);
}

/// 保存角色卡样貌描述：写工作态 + 持久化到当前角色记录
Future<void> saveAppearancePrompt(String prompt) async {
  await setAppearancePrompt(prompt);
  await updateCurrentStudentField(18, prompt);
}

// ===== 角色性格（15.17）：索引 14 = personality（JSON 数组字符串） =====
// 性格 = 关键词 + 程度值（0-10 整数），如 乐观 8、妒忌 3、撒娇 5

class PersonalityTrait {
  String trait; // 性格关键词
  int level; // 程度 0-10

  PersonalityTrait({required this.trait, required this.level});

  Map<String, dynamic> toJson() => {'trait': trait, 'level': level};

  factory PersonalityTrait.fromJson(Map<String, dynamic> json) =>
      PersonalityTrait(
        trait: json['trait']?.toString() ?? "",
        level: (json['level'] is num ? json['level'] : int.tryParse(json['level']?.toString() ?? "") ?? 5)
            .clamp(0, 10),
      );
}

/// 解析性格 JSON 字符串为条目列表（空/损坏返回空列表）
List<PersonalityTrait> parsePersonality(String jsonStr) {
  if (jsonStr.isEmpty) return [];
  try {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(PersonalityTrait.fromJson)
        .where((t) => t.trait.isNotEmpty)
        .toList();
  } catch (_) {
    return [];
  }
}

/// 性格条目列表序列化为 JSON 字符串
String encodePersonality(List<PersonalityTrait> traits) =>
    jsonEncode(traits.map((t) => t.toJson()).toList());

/// 当前角色性格（工作态，切换角色时由记录载入）
Future<String> getPersonalityRaw() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("personality") ?? "";
}

Future<void> setPersonality(String jsonStr) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("personality", jsonStr);
}

/// 保存角色性格：写工作态 + 持久化到当前角色记录
Future<void> savePersonality(String jsonStr) async {
  await setPersonality(jsonStr);
  await updateCurrentStudentField(14, jsonStr);
}

/// 声纹原始参考音频（15.12 起存本地路径；旧数据可能是 OSS key/URL，仅作来源记录）
Future<String> getVoiceRefUrl() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("voice_ref_url") ?? "";
}

Future<void> setVoiceRefUrl(String url) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("voice_ref_url", url);
}

/// 上传声纹参考音频成功：写工作态 + 持久化到当前角色记录
Future<void> saveVoiceRefUrl(String url) async {
  await setVoiceRefUrl(url);
  await updateCurrentStudentField(9, url);
}

// ===== 参考图（角色级）：索引 7 =====

Future<String> getRefImage() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("ref_image") ?? "";
}

Future<void> setRefImage(String refImage) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("ref_image", refImage);
}

/// 上传参考图成功：写工作态 + 持久化到当前角色记录
Future<void> saveRefImage(String refImage) async {
  await setRefImage(refImage);
  await updateCurrentStudentField(7, refImage);
}

// ===== 角色专属背景图（角色级）：索引 10，逗号分隔多个本地路径（15.12 起 OSS 移除） =====

Future<List<String>> getBgImages() async {
  final raw = await getCurrentStudentField(10);
  if (raw.isEmpty) return [];
  return raw.split(',').where((s) => s.isNotEmpty).toList();
}

Future<void> setBgImages(List<String> images) async {
  await updateCurrentStudentField(10, images.join(','));
}

Future<void> addBgImage(String imageKey) async {
  final images = await getBgImages();
  if (!images.contains(imageKey)) {
    images.add(imageKey);
    await setBgImages(images);
  }
}

Future<void> removeBgImage(String imageKey) async {
  final images = await getBgImages();
  images.removeWhere((s) => s == imageKey);
  await setBgImages(images);
}

// ===== 当前聊天背景持久化（15.1）：索引 13，本地图片路径，按角色隔离 =====

Future<void> setChatBackground(String path) async {
  await updateCurrentStudentField(13, path);
}

Future<String> getChatBackground() async {
  return getCurrentStudentField(13);
}

Future<void> setDrawCharPrompt(String url) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("draw_char_prompt", url);
}

Future<String> getDrawCharPrompt({bool isDefault = false}) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? prompt = prefs.getString("draw_char_prompt");
  if (prompt == null || prompt.isEmpty || isDefault) {
    return "red hair, blue eyes, cat ears, fluffy animal ears";
  }
  return prompt;
}

// ===== 模型名配置（15.16：官方可能下线/升级模型，全部可编辑） =====

// TTS 合成模型（默认 cosyvoice-v3-flash；复用外部注册的 voice_id 时须与注册时一致）
Future<void> setTtsModel(String model) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("tts_model", model);
}

Future<String> getTtsModel() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("tts_model") ?? "cosyvoice-v3-flash";
}

// 生视频模型（默认 wan3.0-video-prime，文生/图生均支持）
Future<void> setVideoModel(String model) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("video_model", model);
}

Future<String> getVideoModel() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("video_model") ?? "wan3.0-video-prime";
}

// ===== 接口地址配置（第二十章：每项能力可指向独立服务，空 = 官方默认） =====

const String defaultTtsBaseUrl = 'https://dashscope.aliyuncs.com';
const String defaultImageBaseUrl = 'https://dashscope.aliyuncs.com';
const String defaultVideoBaseUrl = 'https://dashscope.aliyuncs.com';

Future<void> setTtsBaseUrl(String url) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("tts_base_url", url);
}

Future<String> getTtsBaseUrl() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final url = prefs.getString("tts_base_url") ?? '';
  return url.isEmpty ? defaultTtsBaseUrl : url;
}

Future<void> setImageBaseUrl(String url) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("image_base_url", url);
}

Future<String> getImageBaseUrl() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final url = prefs.getString("image_base_url") ?? '';
  return url.isEmpty ? defaultImageBaseUrl : url;
}

Future<void> setVideoBaseUrl(String url) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("video_base_url", url);
}

Future<String> getVideoBaseUrl() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final url = prefs.getString("video_base_url") ?? '';
  return url.isEmpty ? defaultVideoBaseUrl : url;
}

// TTS 兜底音色（角色无专属音色/声纹失效时回落使用，见 tts_provider.dart systemVoices）
Future<void> setTtsFallbackVoice(String voice) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("tts_fallback_voice", voice);
}

Future<String> getTtsFallbackVoice() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("tts_fallback_voice") ?? "longanhuan_v3";
}

// 万相文生图配置（wan2.7-image / wan2.7-image-pro，size 为 宽*高 竖版 9:16 档）
Future<void> setWanImageConfig(String model, String size) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("wan_image_model", model);
  await prefs.setString("wan_image_size", size);
}

Future<(String, String)> getWanImageConfig() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final model = prefs.getString("wan_image_model") ?? "wan2.7-image";
  var size = prefs.getString("wan_image_size");
  // 15.6：旧正方档位（1K/2K/4K）加载时迁移为 9:16 竖版默认
  if (size == null || size.isEmpty || size == '1K' || size == '2K' || size == '4K') {
    size = '1080*1920';
  }
  return (model, size);
}

// 万相文生视频配置（wan3.0-video-prime：分辨率 720P/1080P，比例，时长 2-15 秒）
Future<void> setWanVideoConfig(String resolution, String ratio, int duration) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("wan_video_resolution", resolution);
  await prefs.setString("wan_video_ratio", ratio);
  await prefs.setInt("wan_video_duration", duration);
}

Future<(String, String, int)> getWanVideoConfig() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final resolution = prefs.getString("wan_video_resolution") ?? "720P";
  final ratio = prefs.getString("wan_video_ratio") ?? "9:16";
  final duration = prefs.getInt("wan_video_duration") ?? 5;
  return (resolution, ratio, duration);
}

Future<void> setDrawPrompt(String format) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("draw_prompt", format);
}

Future<String> getDrawPrompt() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? format = prefs.getString("draw_prompt");
  if (format == null || format.isEmpty) {
    return I18n.t('default_draw_prompt');
  }
  return format;
}

Future<void> setInspirePrompt(String format) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("inspire_prompt", format);
}

Future<String> getInspirePrompt() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? format = prefs.getString("inspire_prompt");
  if (format == null || format.isEmpty) {
    return I18n.t('default_inspire_prompt');
  }
  return format;
}

Future<void> setWelcomePrompt(String format) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("welcome_prompt", format);
}

Future<String> getWelcomePrompt() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? format = prefs.getString("welcome_prompt");
  if (format == null || format.isEmpty) {
    return I18n.t('default_welcome_prompt');
  }
  return format;
}

Future<void> setSummaryPrompt(String format) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("summary_prompt", format);
}

Future<String> getSummaryPrompt() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? format = prefs.getString("summary_prompt");
  if (format == null || format.isEmpty) {
    return I18n.t('default_summary_prompt');
  }
  return format;
}

Future<void> setCharacterGenPrompt(String format) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("character_gen_prompt", format);
}

Future<String> getCharacterGenPrompt() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? format = prefs.getString("character_gen_prompt");
  if (format == null || format.isEmpty) {
    return '''你是一个角色设定卡生成助手。请根据用户提供的内容，生成一个完整的角色设定卡。

请严格按照以下 JSON 格式返回，只返回 JSON，不要包含其他文字：
{
  "name": "角色名称",
  "avatar_description": "角色外貌的详细描述（中文），用于生成角色头像",
  "first_mes": "角色对用户的初次问候语或开场白，自然生动",
  "description": "完整的角色设定提示词（System Prompt），包含性格、背景故事、说话方式、兴趣爱好等，详细而完整",
  "draw_char_prompt": "用于 AI 绘图的英文 prompt，描述角色外貌特征，包含服装、发型、表情等"
}''';
  }
  return format;
}

Future<void> setEndPrompt(String format) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("system_prompt", format);
}

Future<String> getEndPrompt() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? format = prefs.getString("system_prompt");
  if (format == null || format.isEmpty) {
    return I18n.t('default_end_prompt');
  }
  return format;
}

Future<void> setContextTemplate(List<Message> messages) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("context_template", msgListToJson(messages));
}

Future<List<Message>> getContextTemplate() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? json = prefs.getString("context_template");
  if (json == null || json.isEmpty) {
    return [
      Message(type: Message.system, message: I18n.t('context_template_system')),
      Message(
          type: Message.system,
          message: I18n.t('context_template_description')),
      Message(type: Message.system, message: I18n.t('context_template_world')),
      Message(
          type: Message.system, message: I18n.t('context_template_world_info')),
      Message(
          type: Message.system, message: I18n.t('context_template_history')),
      Message(
          type: Message.system,
          message: I18n.t('context_template_chat_history')),
      Message(type: Message.system, message: I18n.t('context_template_task')),
      Message(
          type: Message.system,
          message: I18n.t('context_template_call_function')),
    ];
  }
  return jsonToMsg(json);
}

Future<void> setResponseRegex(String format) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("response_regex", format);
}

Future<String> getResponseRegex() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? format = prefs.getString("response_regex");
  if (format == null || format.isEmpty) {
    return "<think>.*?</think>";
  }
  return format;
}

// 自动背景开关（原「自动绘图」改名，旧 key auto_draw 值迁移为关闭）
Future<void> setAutoBackground(bool enabled) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setBool("auto_background", enabled);
}

Future<bool> getAutoBackground() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final value = prefs.getBool("auto_background");
  if (value != null) return value;
  // 旧数据迁移：从未设置过新 key 时不继承旧「自动绘图」状态，默认关闭
  return false;
}

Future<void> setAutoVoice(bool enabled) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setBool("auto_voice", enabled);
}

Future<bool> getAutoVoice() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getBool("auto_voice") ?? false;
}

Future<void> restoreFromJson(jsonString) async {
  if (jsonString.isEmpty) return;

  final decoded = jsonDecode(jsonString);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Backup must contain a JSON object.');
  }

  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();

  for (String key in decoded.keys) {
    var value = decoded[key];
    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is List) {
      await prefs.setStringList(
          key, value.map((item) => item.toString()).toList());
    }
  }
}

Future<void> restoreHistoryFromJson(jsonString) async {
  if (jsonString.isEmpty) return;

  Map<String, dynamic> data = jsonDecode(jsonString);
  // get name and entries fields, and get content in entries as system msg
  String name = data['name'] ?? '未命名故事';
  List<dynamic> entries = data['entries'] ?? [];

  List<Message> messages = [];
  for (var entry in entries) {
    if (entry is Map<String, dynamic> && entry.containsKey('content')) {
      messages.add(Message(message: entry['content'], type: Message.system));
    }
  }

  if (messages.isNotEmpty) {
    String msgJson = msgListToJson(messages);
    await addHistory(msgJson, name);
  }
}

/// 19.8：导入结果（studentKey = 新入池记录完整 key；warnings = 非致命提示）
class CharacterImportResult {
  final String studentKey;
  final String name;
  final String voiceUrl;
  final String voicePrompt;
  final String appearancePrompt;
  final List<String> warnings;
  const CharacterImportResult({
    required this.studentKey,
    required this.name,
    required this.voiceUrl,
    required this.voicePrompt,
    required this.appearancePrompt,
    required this.warnings,
  });
}

/// 19.8：角色卡核心解析与入池（无 file_picker 依赖），网页导入与 Web 壳共用。
///
/// PNG tEXt 'chara' 块 / JSON 解析 → 18.2 / 18.6 入池规则（不切换当前角色、
/// 不写工作态、按完整 key 唯一匹配、大卡头像落本地文件不进 SharedPreferences）
/// → 返回新角色 key 与 warnings；致命错误（解码失败 / 格式无效 / 缺名称）直接
/// throw，由调用方转提示。[context] 非空时保留 character_book 确认 Dialog 与
/// SnackBar 提示（Web 壳路径行为不变）；网页路径（无 context）角色书跳过并记 warning。
Future<CharacterImportResult> importCharacterCardBytes(
    Uint8List fileBytes, String filename,
    {BuildContext? context}) async {
  final warnings = <String>[];
  void warn(String msg) {
    warnings.add(msg);
    if (context != null) snackBarAlert(context, msg);
  }

  String jsonString = '';
  final isPng = filename.toLowerCase().endsWith('.png');
  if (isPng) {
    // 解码 PNG → 读取 'chara' tEXt → base64 → utf8
    final image = img.decodePng(fileBytes);
    if (image == null) {
      throw Exception("无法解码 PNG。");
    }
    final rawData = image.textData?['chara'];
    if (rawData == null) {
      throw Exception(I18n.t('chara_metadata_not_found'));
    }
    try {
      jsonString = utf8.decode(base64Decode(rawData));
    } catch (e) {
      throw Exception("${I18n.t('decode_chara_error')}$e");
    }
  } else {
    jsonString = utf8.decode(fileBytes);
  }

  if (jsonString.isEmpty) {
    throw Exception(I18n.t('json_empty'));
  }

  // 解析 JSON，收集字段到局部变量（不写工作态，最后统一入池）
  final allPrefs = jsonDecode(jsonString);
  if (allPrefs is! Map<String, dynamic> || !allPrefs.containsKey("data")) {
    throw Exception("角色卡格式无效。");
  }

  final data = allPrefs["data"] as Map<String, dynamic>;
  String name = (data["name"] ?? "").toString();
  String firstMes = (data["first_mes"] ?? "").toString();
  String description = (data["description"] ?? "").toString();
  // <user> 宏兼容
  firstMes = firstMes.replaceAll('<user>', '{{user}}');
  description = description.replaceAll('<user>', '{{user}}');

  String drawCharPrompt = '';
  String voiceId = '';
  String voiceModel = '';
  String personality = '';
  String voiceUrl = '';
  String voicePrompt = '';
  String appearancePrompt = '';
  String voiceRefUrl = '';
  String refImageUrl = '';

  // character_book 导入（19.8：context 非空保留确认 Dialog；网页路径跳过 + warning）
  if (data.containsKey("character_book")) {
    final characterBook = data['character_book'];
    if (characterBook != null && characterBook is Map<String, dynamic>) {
      if (context != null) {
        final bool? confirmImport = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: Text(I18n.t('import_character_book')),
              content: Text(I18n.t('import_character_book_msg')),
              actions: <Widget>[
                TextButton(
                  child: Text(I18n.t('cancel')),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
                TextButton(
                  child: Text(I18n.t('import_character')),
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ],
            );
          },
        );
        if (confirmImport == true) {
          await restoreHistoryFromJson(jsonEncode(characterBook));
          snackBarAlert(context, I18n.t('character_book_imported'));
        }
      } else {
        warn('角色书导入已跳过（角色书请通过 App 内聊天记录导入入口处理）');
      }
    }
  }

  if (data.containsKey("extensions")) {
    final extensions = data["extensions"];
    if (extensions is Map<String, dynamic>) {
      drawCharPrompt = (extensions["draw_prompt"] ?? '').toString();
      voiceId = (extensions["voice_id"] ?? '').toString();
      voiceModel = (extensions["voice_model"] ?? '').toString();
      personality = (extensions["personality"] ?? '').toString();
      voiceUrl = (extensions["voice_url"] ?? '').toString();
      voicePrompt = (extensions["voice_prompt"] ?? '').toString();
      appearancePrompt = (extensions["appearance_prompt"] ?? '').toString();
      voiceRefUrl = (extensions["voice_ref_url"] ?? '').toString();
      refImageUrl = (extensions["ref_image_url"] ?? '').toString();
    }
  }

  // 15.12：ref_image_data base64 落地为本地文件
  String refImagePath = '';
  final refImageData = data["extensions"]?["ref_image_data"];
  if (refImageData is String && refImageData.isNotEmpty) {
    try {
      refImagePath = await _writeLocalMediaFile(
          "ref_image_${DateTime.now().millisecondsSinceEpoch}.png",
          base64Decode(refImageData));
    } catch (e) {
      debugPrint("ref_image_data import failed: $e");
      warn("参考图导入失败：$e");
    }
  }
  // 若没有内嵌图，回退到 URL 字段（同账号备份恢复线索）
  if (refImagePath.isEmpty && refImageUrl.isNotEmpty) {
    refImagePath = refImageUrl;
  }

  // 25.4：bg_images_data base64 逐张落地为本地文件（空则回退参考图作首张背景，维持旧行为）
  String bgImagesValue = '';
  final bgImagesData = data["extensions"]?["bg_images_data"];
  if (bgImagesData is List && bgImagesData.isNotEmpty) {
    final paths = <String>[];
    for (final b in bgImagesData) {
      if (b is String && b.isNotEmpty) {
        try {
          paths.add(await _writeLocalMediaFile(
              "bg_image_${DateTime.now().millisecondsSinceEpoch}_${paths.length}.png",
              base64Decode(b)));
        } catch (e) {
          debugPrint("bg_image import failed: $e");
          warn("背景图导入失败：$e");
        }
      }
    }
    bgImagesValue = paths.join(',');
  }

  // 18.6：头像不再用整张卡 base64 存 SharedPreferences（会导致启动 OOM 白屏）。
  // PNG 载体像素即头像，直接写本地文件，存路径；JSON 卡无图则用 refImage 或空。
  String avatarPath = refImagePath;
  if (isPng) {
    try {
      avatarPath = await _writeLocalMediaFile(
          "avatar_${DateTime.now().millisecondsSinceEpoch}.png", fileBytes);
    } catch (e) {
      debugPrint("avatar import failed: $e");
    }
  }

  if (name.isEmpty) {
    throw Exception("角色卡缺少名称。");
  }

  // 18.2：入池，不覆写当前工作态
  final newKey = await addStudent(
    name,
    avatarPath,
    firstMes,
    description,
    drawCharPrompt,
    voiceId: voiceId,
    refImage: refImagePath,
    voiceRefUrl: voiceRefUrl,
    bgImages: bgImagesValue.isNotEmpty ? bgImagesValue : refImagePath,
    personality: personality,
    voiceModel: voiceModel,
    voiceUrl: voiceUrl,
    voicePrompt: voicePrompt,
    appearancePrompt: appearancePrompt,
    chatBackground: refImagePath,
  );

  return CharacterImportResult(
    studentKey: newKey,
    name: name,
    voiceUrl: voiceUrl,
    voicePrompt: voicePrompt,
    appearancePrompt: appearancePrompt,
    warnings: warnings,
  );
}

/// 18.2 / 18.6 / 19.8：导入角色卡（Web 专用 file_picker 壳）
/// 19.7：App 内已移除手动导入入口，统一走局域网网页；Web 构建保留此旧路径仅保证可运行。
/// 返回新入池记录的 student key（供 main.dart 后续 enrollment 写 voice_id/refImage）
Future<String?> loadCharacterCard(context) async {
  // 1. 让用户选择一个 PNG 或 JSON 文件
  FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['png', 'json'],
    withData: true,
  );

  if (result == null || result.files.single.bytes == null) {
    snackBarAlert(context, "未选择文件。");
    return null;
  }

  try {
    final r = await importCharacterCardBytes(
        result.files.single.bytes!, result.files.single.name,
        context: context);
    return r.studentKey;
  } catch (e) {
    snackBarAlert(context, "$e");
    return null;
  }
}

/// 25.3：从角色字段构造 SillyTavern V2 PNG 角色卡字节（本地导出 / 网页导出共用，
/// 单点维护）。avatarUri 兼容 data URI / http(s) / assets/ / 本地文件路径。
/// 图片读取失败仅 debugPrint 跳过（无 context，不弹提示）。
Future<Uint8List> buildCharacterCardBytes({
  required String name,
  required String description,
  required String firstMes,
  required String drawCharPrompt,
  String voiceRefUrl = "",
  String refImage = "",
  List<String> bgImages = const [],
  String personality = "",
  String voiceModel = "",
  String voiceUrl = "",
  String voicePrompt = "",
  String appearancePrompt = "",
  required String avatarUri,
}) async {
  // 参考图压缩（最长边 1024，18.5）后 base64 内嵌
  String refImageData = "";
  if (refImage.isNotEmpty) {
    try {
      refImageData =
          base64Encode(_compressImageForCard(await _readLocalMediaBytes(refImage)));
    } catch (e) {
      debugPrint("fetch ref_image failed: $e");
    }
  }
  // 25.2：背景图逐张压缩内嵌
  final bgImagesData = <String>[];
  for (final bg in bgImages) {
    if (bg.isEmpty) continue;
    try {
      bgImagesData
          .add(base64Encode(_compressImageForCard(await _readLocalMediaBytes(bg))));
    } catch (e) {
      debugPrint("fetch bg_image failed: $e");
    }
  }

  final characterData = {
    "spec": "chara_card_v2",
    "spec_version": "2.0",
    "data": {
      "name": name,
      "description": description,
      "first_mes": firstMes,
      "extensions": {
        "draw_prompt": drawCharPrompt,
        // 16.10：声音来源（复刻 URL / 设计描述，二选一；voice_id 账号隔离不导出）
        "voice_url": voiceUrl,
        "voice_prompt": voicePrompt,
        "appearance_prompt": appearancePrompt,
        // 15.16.1：导出注册时模型名，导入即免配置
        "voice_model": voiceModel,
        // 15.17：角色性格条目（JSON 数组字符串）
        "personality": personality,
        "voice_ref_url": voiceRefUrl,
        "ref_image_url": refImage,
        if (refImageData.isNotEmpty) "ref_image_data": refImageData,
        if (bgImagesData.isNotEmpty) "bg_images_data": bgImagesData,
      }
    }
  };

  final base64String =
      base64Encode(utf8.encode(jsonEncode(characterData)));

  // 头像（PNG 载体）：data URI / http(s) / assets / 本地路径四类取值
  Uint8List imageBytes;
  if (avatarUri.startsWith('data:image')) {
    imageBytes = base64Decode(avatarUri.split(',')[1]);
  } else if (avatarUri.startsWith('http://') || avatarUri.startsWith('https://')) {
    imageBytes = await _fetchBytes(Uri.parse(avatarUri));
  } else if (avatarUri.startsWith('assets/')) {
    final byteData = await rootBundle.load(avatarUri);
    imageBytes = byteData.buffer.asUint8List();
  } else {
    imageBytes = await File(avatarUri).readAsBytes();
  }

  final decoded = img.decodeImage(imageBytes);
  if (decoded == null) {
    throw Exception("无法解码头像图片。");
  }

  // 18.5：头像（PNG 载体）压缩（最长边 1024），避免载体本身过大
  img.Image cardImage = decoded;
  final longest = cardImage.width > cardImage.height
      ? cardImage.width
      : cardImage.height;
  if (longest > 1024) {
    cardImage = cardImage.width >= cardImage.height
        ? img.copyResize(cardImage, width: 1024)
        : img.copyResize(cardImage, height: 1024);
  }

  cardImage.textData = {'chara': base64String};
  return Uint8List.fromList(img.encodePng(cardImage));
}

/// 拉取 URL 字节（Web 用 http 包，其他平台用 HttpClient）
Future<Uint8List> _fetchBytes(Uri uri) async {
  if (kIsWeb) {
    final response = await http.get(uri);
    return response.bodyBytes;
  }
  final request = await HttpClient().getUrl(uri);
  final response = await request.close();
  return consolidateHttpClientResponseBytes(response);
}

/// 15.12：读取本地媒体字节（角色卡导出内嵌用）
///
/// 兼容三种取值：本地文件路径 / http(s) URL（旧数据）/ data URI
Future<Uint8List> _readLocalMediaBytes(String value) async {
  if (value.startsWith('data:')) {
    return base64Decode(value.split(',')[1]);
  }
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return _fetchBytes(Uri.parse(value)); // 旧记录残留的远程 URL
  }
  final file = File(value);
  if (await file.exists()) {
    return await file.readAsBytes();
  }
  throw Exception('本地媒体文件不存在: $value');
}

/// 18.5：角色卡导出前压缩图片（最长边 ≤ maxDim，PNG 重新编码）
/// 避免参考图/头像过大导致角色卡膨胀（双重 base64 后单卡可达数十 MB）
Uint8List _compressImageForCard(Uint8List bytes, {int maxDim = 1024}) {
  final image = img.decodeImage(bytes);
  if (image == null) return bytes;
  final longest = image.width > image.height ? image.width : image.height;
  if (longest <= maxDim) {
    // 尺寸已合规，但仍重新编码以统一压缩（去除原图元数据/大 filter）
    return Uint8List.fromList(img.encodePng(image));
  }
  // 等比缩放到最长边 = maxDim（另一维度传 null 保持比例）
  final img.Image resized = image.width >= image.height
      ? img.copyResize(image, width: maxDim)
      : img.copyResize(image, height: maxDim);
  return Uint8List.fromList(img.encodePng(resized));
}

/// 15.12：base64 媒体数据落地为本地文件（角色卡导入用），返回本地路径
Future<String> _writeLocalMediaFile(String fileName, Uint8List bytes) async {
  final dir = await getApplicationDocumentsDirectory();
  final mediaDir = Directory('${dir.path}/character_media');
  if (!await mediaDir.exists()) {
    await mediaDir.create(recursive: true);
  }
  final file = File('${mediaDir.path}/$fileName');
  await file.writeAsBytes(bytes);
  return file.path;
}

// ===== 本地聊天记录（16.6）：独立于故事池，存 {appDocs}/chat_saves/*.json =====

/// 本地保存的聊天记录条目（列表展示用元信息）
class SavedChat {
  final String filename; // chat_saves/ 下的文件名
  final String name; // 用户输入的名称
  final int timestamp; // 毫秒
  final String studentKey;

  const SavedChat({
    required this.filename,
    required this.name,
    required this.timestamp,
    required this.studentKey,
  });
}

/// 列出 {appDocs}/chat_saves/ 下全部本地聊天记录，按时间倒序（损坏文件跳过）
Future<List<SavedChat>> listSavedChats() async {
  final dir = await getApplicationDocumentsDirectory();
  final savesDir = Directory('${dir.path}/chat_saves');
  if (!await savesDir.exists()) return [];
  final chats = <SavedChat>[];
  await for (final entity in savesDir.list()) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    try {
      final data = jsonDecode(await entity.readAsString());
      if (data is! Map<String, dynamic>) continue;
      chats.add(SavedChat(
        filename: entity.path.split(Platform.pathSeparator).last,
        name: data['name']?.toString() ?? "",
        timestamp: data['timestamp'] is num
            ? (data['timestamp'] as num).toInt()
            : int.tryParse(data['timestamp']?.toString() ?? "") ?? 0,
        studentKey: data['student_key']?.toString() ?? "",
      ));
    } catch (e) {
      debugPrint("saved chat parse failed (${entity.path}): $e");
    }
  }
  chats.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return chats;
}

/// 聊天记录文件名安全化（剔除路径非法字符，空白折叠为下划线，限长防超路径上限）
String _sanitizeChatFileName(String name) {
  final safe = name
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '_');
  if (safe.isEmpty) return 'unnamed';
  return safe.length > 50 ? safe.substring(0, 50) : safe;
}

/// 保存聊天记录到 {appDocs}/chat_saves/chat_{timestamp}_{安全化name}.json
///
/// [messagesJson] 为 msgListToJson(messages) 的产物（List<Map> 数组的 JSON 字符串）
Future<void> saveChatToFile(
    String name, String studentKey, String messagesJson) async {
  final dir = await getApplicationDocumentsDirectory();
  final savesDir = Directory('${dir.path}/chat_saves');
  if (!await savesDir.exists()) {
    await savesDir.create(recursive: true);
  }
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final file = File(
      '${savesDir.path}/chat_${timestamp}_${_sanitizeChatFileName(name)}.json');
  await file.writeAsString(jsonEncode({
    'name': name,
    'timestamp': timestamp,
    'student_key': studentKey,
    'messages': jsonDecode(messagesJson),
  }));
}

/// 读取本地聊天记录，返回 (info, messagesJson=jsonEncode(data['messages']))
Future<(SavedChat, String)> loadChatFromFile(String filename) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/chat_saves/$filename');
  if (!await file.exists()) {
    throw Exception('聊天记录文件不存在: $filename');
  }
  final data = jsonDecode(await file.readAsString());
  if (data is! Map<String, dynamic>) {
    throw const FormatException('聊天记录文件格式无效');
  }
  final info = SavedChat(
    filename: filename,
    name: data['name']?.toString() ?? "",
    timestamp: data['timestamp'] is num
        ? (data['timestamp'] as num).toInt()
        : int.tryParse(data['timestamp']?.toString() ?? "") ?? 0,
    studentKey: data['student_key']?.toString() ?? "",
  );
  return (info, jsonEncode(data['messages'] ?? []));
}

/// 删除本地聊天记录文件（不存在时静默跳过）
Future<void> deleteSavedChat(String filename) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/chat_saves/$filename');
  if (await file.exists()) {
    await file.delete();
  }
}

// 显示设置
Future<void> setDisplayFontSize(double size) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setDouble("display_font_size", size);
}

Future<double> getDisplayFontSize() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getDouble("display_font_size") ?? defaultDisplayFontSize;
}

// 17.11：拆为自己 / 对方两套独立配色，删除统一文字色和名字色
Future<void> setUserTextColor(String colorHex) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("user_text_color", colorHex);
}

Future<String> getUserTextColor() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("user_text_color") ?? defaultUserTextColorHex;
}

Future<void> setAiTextColor(String colorHex) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("ai_text_color", colorHex);
}

Future<String> getAiTextColor() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("ai_text_color") ?? defaultAiTextColorHex;
}

Future<void> setDisplayTextOutline(bool enable) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setBool("display_text_outline", enable);
}

Future<bool> getDisplayTextOutline() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getBool("display_text_outline") ?? defaultDisplayTextOutline;
}

Future<void> setDisplayOutlineWidth(double width) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setDouble("display_outline_width", width);
}

Future<double> getDisplayOutlineWidth() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getDouble("display_outline_width") ?? defaultDisplayOutlineWidth;
}

Future<void> setDisplayOutlineColor(String colorHex) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("display_outline_color", colorHex);
}

Future<String> getDisplayOutlineColor() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString("display_outline_color") ??
      defaultDisplayOutlineColorHex;
}

// ===== 17.12 备份恢复：统一内部存储 backups/ 目录 =====

Future<String> _backupDir() async {
  final dir = await getApplicationDocumentsDirectory();
  final backupDir = Directory('${dir.path}/backups');
  if (!await backupDir.exists()) await backupDir.create(recursive: true);
  return backupDir.path;
}

/// 保存配置 JSON 到内部存储 backups/ 目录，返回保存的文件路径
Future<String> saveBackupLocally(String json, {String? name}) async {
  final path = await _backupDir();
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final safeName = (name ?? 'aiDaziBackup').replaceAll(RegExp(r'[^\w\u4e00-\u9fff]'), '_');
  final file = File('$path/${safeName}_$timestamp.json');
  await file.writeAsString(json);
  return file.path;
}

/// 列出 backups/ 目录下所有 JSON 备份文件
Future<List<Map<String, dynamic>>> listBackupFiles() async {
  try {
    final path = await _backupDir();
    final dir = Directory(path);
    if (!await dir.exists()) return [];
    final files = await dir
        .list()
        .where((e) => e is File)
        .cast<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    // 按修改时间倒序
    files.sort((a, b) {
      try {
        return b.lastModifiedSync().compareTo(a.lastModifiedSync());
      } catch (_) {
        return 0;
      }
    });
    return files.map((f) {
      final stat = f.statSync();
      return {
        'path': f.path,
        'name': f.path.split(Platform.pathSeparator).last,
        'size': stat.size,
        'modified': stat.modified,
      };
    }).toList();
  } catch (e) {
    debugPrint('listBackupFiles error: $e');
    return [];
  }
}

Future<String?> readBackupFile(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    return await file.readAsString();
  } catch (e) {
    debugPrint('readBackupFile error: $e');
    return null;
  }
}

Future<void> deleteBackupFile(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (e) {
    debugPrint('deleteBackupFile error: $e');
  }
}
