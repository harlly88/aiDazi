import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:aidazi/storage.dart';


// type 1:asstant 2:user 3:system 4:timestamp
class Message {
  String message;
  int type;
  static const int assistant = 1;
  static const int user = 2;
  static const int system = 3;
  static const int timestamp = 4;
  static const int image = 5;
  static const int video = 6;

  Message({required this.message, required this.type});

  Map<String, dynamic> toJson() {
    return {
      'message': message,
      'type': type,
    };
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      message: json['message'],
      type: json['type'],
    );
  }
}

class Config {
  String name;
  String baseUrl;
  String apiKey;
  String model;
  String? temperature;
  String? frequencyPenalty;
  String? presencePenalty;
  String? maxTokens;

  Config({required this.name, required this.baseUrl, 
    required this.apiKey, required this.model,
    this.temperature, this.frequencyPenalty, 
    this.presencePenalty, this.maxTokens});

  @override
  String toString() {
    return 'Config{name: $name, baseUrl: $baseUrl, apiKey: $apiKey, model: $model, '
    'temperature: $temperature, frequencyPenalty: $frequencyPenalty, '
    'presencePenalty: $presencePenalty, maxTokens: $maxTokens}';
  }
}

String msgListToJson(List<Message> messages) {
  List<Map<String, dynamic>> jsonList = messages.map((message) => message.toJson()).toList();
  return jsonEncode(jsonList);
}

List<Message> jsonToMsg(String jsonString) {
  List<dynamic> jsonList = jsonDecode(jsonString);
  return jsonList.map((json) => Message.fromJson(json)).toList();
}

String timestampToSystemMsg(String timestr) {
  DateTime t = DateTime.fromMillisecondsSinceEpoch(int.parse(timestr));
  const weekday = ["", "一", "二", "三", "四", "五", "六", "日"];
  var result =
      "${t.year}年${t.month}月${t.day}日星期${weekday[t.weekday]}"
      "${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}";
  return "下面的对话开始于 $result";
}

/// 16.4：当前时间注入文本（始终注入；configpage 环境预览复用同一格式）
String buildTimeInjection([DateTime? now]) {
  now ??= DateTime.now();
  const weekday = ["日", "一", "二", "三", "四", "五", "六"];
  return '【当前时间】${now.year}年${now.month}月${now.day}日 '
      '星期${weekday[now.weekday % 7]} '
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
}

/// 组装上下文注入消息（15.9/15.17/16.4）：时间、用户信息、角色性格
///
/// 插入位置：角色描述之后、世界观/聊天记录之前；全部为空时返回空列表
/// 26.1-4/5：生日与位置/天气注入已删除（隐私收敛）
Future<List<String>> buildContextInjections() async {
  final injections = <String>[];

  // 16.4：当前时间（始终注入，放在用户信息之前）
  injections.add(buildTimeInjection());

  // 15.9：我的设定（用户画像）
  final profile = await getUserProfile();
  if (!profile.isEmpty) {
    final parts = <String>[
      if (profile.name.isNotEmpty) '称呼：${profile.name}',
      if (profile.occupation.isNotEmpty) '职业：${profile.occupation}',
      if (profile.age.isNotEmpty) '年龄：${profile.age}',
      if (profile.other.isNotEmpty) '其他：${profile.other}',
    ];
    injections.add(
        '【用户信息】${parts.join('；')}。请在合适的时机自然使用这些信息（如以称呼相称）。');
  }

  // 15.17：角色性格
  final traits = parsePersonality(await getPersonalityRaw());
  if (traits.isNotEmpty) {
    final desc =
        traits.map((t) => '${t.trait}(${t.level}/10)').join('、');
    injections
        .add('【角色性格】$desc。数字越高该性格越明显，回复中自然体现。');
  }

  return injections;
}

Future<List<List<String>>> parseMsg(List<Message> messages, List<Message> story, List<Message> function) async {
  final List<Message> template = await getContextTemplate();

  final List<List<String>> msg = [];

  for (var t in template) {
    if (t.message == "charDescription") {
      final prompt = await getPrompt();
      msg.add(["system", prompt]);
      // 15.9/15.11/15.17：用户信息、环境、角色性格（角色描述之后、世界观/聊天记录之前）
      final injections = await buildContextInjections();
      for (var inj in injections) {
        msg.add(["system", inj]);
      }
    } else if (t.message == "chatHistory") {
      for (var m in messages) {
        if (m.type == Message.assistant) {
          msg.add(["assistant",m.message]);
        } else if (m.type == Message.user) {
          msg.add(["user",m.message]);
        } else if (m.type == Message.system) {
          msg.add(["system",m.message]);
        } else if (m.type == Message.timestamp) {
          var timestr = timestampToSystemMsg(m.message);
          msg.add(["system","下面的对话开始于$timestr"]);
        }
      }
    } else if (t.message == "worldInfo") {
      for (var m in story) {
        msg.add(["system", m.message]);
      }
    } else if (t.message == "callFunction") {
      for (var m in function) {
        msg.add(["user", m.message]);
      } 
    }else {
      String role = "system";
      if (t.type == Message.user) {
        role = "user";
      } else if (t.type == Message.assistant) {
        role = "assistant";
      }
      msg.add([role, t.message]);
    }
  }

  // replace placeholders
  final userName = await getUserName();
  final stuName = await getStudentName();
  for (var m in msg) {
    m[1] = m[1].replaceAll("{{user}}", userName);
    m[1] = m[1].replaceAll("{{char}}", stuName);
  }
  return msg;
}

String randomizeBackslashes(String resp) {
  Random random = Random();
  StringBuffer result = StringBuffer();

  for (int i = 0; i < resp.length; i++) {
    if (resp[i] == '\\') {
      if (random.nextInt(3) == 0) {
        result.write('\\\\');
      } else {
        result.write('\\');
      }
    } else {
      result.write(resp[i]);
    }
  }

  return result.toString();
}

List<String> splitString(String input, List<String> patterns) {
  String var1 = patterns[0], var2 = patterns[1];
    List<String> result = [];
  int i = 0;
  while (i < input.length) {
    if (input.startsWith(var1, i)) {
      int nextIndex = input.indexOf(var2, i);
      if (nextIndex == -1) {
        result.add(input.substring(i));
        break;
      }
      result.add(input.substring(i, nextIndex));
      i = nextIndex;
    }
    else if (input.startsWith(var2, i)) {
      int nextIndex = input.indexOf(var1, i);
      if (nextIndex == -1) {
        result.add(input.substring(i));
        break;
      }
      result.add(input.substring(i, nextIndex));
      i = nextIndex;
    }
  }
  return result;
}

void snackBarAlert(BuildContext context, String msg) {
  if(!context.mounted) return;
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(msg),
      showCloseIcon: true
    ),
  );
}

class DecimalTextInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final newText = newValue.text;
    if (newText.isEmpty || newText == '.') {
      return newValue;
    }
    final newDouble = double.tryParse(newText);
    if (newDouble == null) {
      return oldValue;
    }
    return newValue;
  }
}

String getTimeStr(int timeStamp) {
  DateTime t = DateTime.fromMillisecondsSinceEpoch(timeStamp);
  return "${t.year}_${t.month}_${t.day}_${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}";
}
