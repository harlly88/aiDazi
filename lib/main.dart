import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/foundation.dart'
    show Uint8List, debugPrint, kIsWeb;
import 'package:shared_preferences/shared_preferences.dart'; // ignore: depend_on_referenced_packages
import 'package:url_launcher/url_launcher_string.dart' show launchUrlString;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'app_theme.dart';
import 'chatview.dart';
import 'configpage.dart';
import 'notifications.dart';
import 'popups.dart';
import 'prompteditor.dart';
import 'theme.dart';
import 'openai.dart';
import 'storage.dart';
import 'tts_provider.dart';
import 'utils.dart';
import 'backup_page.dart';
import 'storyeditor.dart';
import 'userprofile.dart';
import 'formatconfig.dart';
import 'display_settings_defaults.dart';
import 'vits.dart';
import 'image_provider.dart';
import 'video_provider.dart';
import 'i18n.dart';
import 'secure_key_store.dart' show migratePlainKeysOnce;
import 'lan_config_page.dart';
import 'device_mode.dart';

final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier(ThemeMode.system);
final ValueNotifier<int> displaySettingsVersion = ValueNotifier(0);
final ValueNotifier<int> appReloadVersion = ValueNotifier(0);

main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 19.4：旧明文密钥一次性静默迁移（io 平台；失败不阻塞启动，下次启动重试）
  unawaited(migratePlainKeysOnce());
  await _loadAppPreferences();
  runApp(const AiDaziApp());
}

Future<void> _loadAppPreferences() async {
  final prefs = await SharedPreferences.getInstance();
  // 读取保存的主题设置
  final saved = prefs.getString('theme_mode');
  if (saved == 'light') {
    themeModeNotifier.value = ThemeMode.light;
  } else if (saved == 'dark') {
    themeModeNotifier.value = ThemeMode.dark;
  } else {
    themeModeNotifier.value = ThemeMode.system;
  }
  // 读取显示设置
  // 17.11：拆为自己 / 对方两套独立配色（删除统一文字色和名字色）
  displaySettings.fontSize =
      prefs.getDouble('display_font_size') ?? defaultDisplayFontSize;
  displaySettings.userTextColorHex =
      prefs.getString('user_text_color') ?? defaultUserTextColorHex;
  displaySettings.aiTextColorHex =
      prefs.getString('ai_text_color') ?? defaultAiTextColorHex;
  displaySettings.textOutline =
      prefs.getBool('display_text_outline') ?? defaultDisplayTextOutline;
  displaySettings.outlineWidth =
      prefs.getDouble('display_outline_width') ?? defaultDisplayOutlineWidth;
  displaySettings.outlineColorHex =
      prefs.getString('display_outline_color') ?? defaultDisplayOutlineColorHex;
}

Future<void> reloadApplicationAfterRestore() async {
  await _loadAppPreferences();
  appReloadVersion.value++;
}

class AiDaziApp extends StatelessWidget {
  const AiDaziApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: appReloadVersion,
      builder: (context, reloadVersion, child) {
        return ValueListenableBuilder<ThemeMode>(
          valueListenable: themeModeNotifier,
          builder: (context, mode, child) {
            return MaterialApp(
              key: ValueKey(reloadVersion),
              title: 'AI搭子',
              home: const MainPage(),
              theme: lightTheme,
              darkTheme: darkTheme,
              themeMode: mode,
            );
          },
        );
      },
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  MainPageState createState() => MainPageState();
}

class MainPageState extends State<MainPage> with WidgetsBindingObserver {
  int _currentIndex = 0;
  bool _isListViewMode = true; // true for list view, false for single view
  int _singleViewIndex = 0;
  bool _isFullScreen = false; // Add a state variable to control fullscreen mode
  bool _isAutoVoice = false;
  bool _isAutoBackground = false; // 14.14 自动背景（原自动绘图改名）
  bool _showInputBar = false; // 输入框展开/收起
  int _displaySettingsKey = 0; // 递增以强制重建 chat 页面

  // Chat page variables
  final fn = FocusNode();
  final textController = TextEditingController();
  final scrollController = ScrollController();
  final notification = NotificationHelper();
  String studentName = "";
  String avatar = "";
  String userName = "";
  DecorationImage? backgroundImage;
  Config config = Config(name: "", baseUrl: "", apiKey: "", model: "");
  String userMsg = "";
  bool inputLock = false;
  bool keyboardOn = false;
  bool isForeground = true;
  bool isAutoNotification = false;
  bool _isToolsExpanded = false;
  List<Message> messages = [];
  List<List<String>> historys = [];
  List<String>? currentStory;
  List<List<String>> students = [];
  final Map<String, ImageProvider> _avatarImageCache = {};
  final Map<String, String> _voiceCache = {};
  final Map<String, Future<String?>> _voiceRequests = {};
  Future<void> _tempHistoryWrite = Future<void>.value();
  Future<void> _characterSwitchWrite = Future<void>.value();
  int _conversationVersion = 0;
  int _replyOperation = 0;
  int _inspireOperation = 0;
  int _drawOperation = 0;
  int _welcomeOperation = 0;
  int _voiceOperation = 0;
  int _historyRefreshOperation = 0;
  int _studentRefreshOperation = 0;
  int _characterSwitchOperation = 0;
  bool _isInspiring = false;
  bool _isDrawing = false;
  bool _isWelcoming = false;

  // 自动背景轮换（14.14）：每 2-5 轮对话切换角色 bgImages 中的背景
  int _autoBgRounds = 0;
  int _autoBgThreshold = 3;
  int _bgImageIndex = 0;
  bool _noBgHintShown = false; // 15.1 一次性提示「当前角色暂无背景图」

  List<Message> _copyMessages(Iterable<Message> source) => source
      .map((message) => Message(message: message.message, type: message.type))
      .toList();

  void _invalidateConversation() {
    _conversationVersion++;
    _replyOperation++;
    _inspireOperation++;
    _drawOperation++;
    _welcomeOperation++;
    _voiceOperation++;
    unawaited(stopAudio());
    inputLock = false;
    _isInspiring = false;
    _isDrawing = false;
    _isWelcoming = false;
  }

  bool _isCurrentConversation(int version) =>
      mounted && version == _conversationVersion;

  Future<void> _saveTempHistory() {
    final snapshot = msgListToJson(_copyMessages(messages));
    _tempHistoryWrite = _tempHistoryWrite.catchError((Object error) {
      debugPrint('Previous temporary history write failed: $error');
    }).then((_) => setTempHistory(snapshot));
    return _tempHistoryWrite;
  }

  Future<Route<dynamic>> _showProgressDialog(String message) {
    final routeReady = Completer<Route<dynamic>>();
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final route = ModalRoute.of(dialogContext)!;
        if (!routeReady.isCompleted) routeReady.complete(route);
        return AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(message),
            ],
          ),
        );
      },
    ));
    return routeReady.future;
  }

  void _closeDialogRoute(Route<dynamic>? route) {
    if (route != null && route.isActive && mounted) {
      Navigator.of(context, rootNavigator: true).removeRoute(route);
    }
  }

  Future<void> _refreshHistoryList() async {
    final operation = ++_historyRefreshOperation;
    final results = await getHistorys();
    if (!mounted || operation != _historyRefreshOperation) return;
    results.sort((a, b) => int.parse(b[1]).compareTo(int.parse(a[1])));
    setState(() => historys = results);
  }

  Future<void> _refreshStudentList() async {
    final operation = ++_studentRefreshOperation;
    final results = await getStudents();
    if (!mounted || operation != _studentRefreshOperation) return;
    results.sort((a, b) => a[0].compareTo(b[0]));
    setState(() => students = results);
  }

  /// 18.6：抢救已中毒安装——旧版本导入角色时把整张卡 base64（可达 43MB+）
  /// 存进 SharedPreferences 的 avatar 键，导致启动时全量加载 prefs XML OOM 白屏。
  /// 检测 avatar 为超大 data URI（>2MB）时，解码字节落盘为本地文件，
  /// 并把 avatar 替换为文件路径，避免每次启动都加载巨型字符串。
  Future<void> _sanitizeLargeAvatarDataUri() async {
    try {
      final avatarUri = await getAvatar();
      if (!avatarUri.startsWith('data:image')) return;
      final commaIdx = avatarUri.indexOf(',');
      if (commaIdx < 0) return;
      final base64Part = avatarUri.substring(commaIdx + 1);
      // base64 字符串长度 / 1.33 ≈ 字节数；>2MB 判定为中毒
      if (base64Part.length < 2 * 1024 * 1024 * 4 ~/ 3) return;
      final bytes = base64Decode(base64Part);
      final dir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${dir.path}/character_media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      final file = File(
          '${mediaDir.path}/sanitized_avatar_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes);
      await setAvatar(file.path);
      debugPrint(
          '[sanitize] large avatar data uri (${(base64Part.length / 1024 / 1024).toStringAsFixed(1)}MB) replaced with local file');
    } catch (e) {
      debugPrint('[sanitize] large avatar cleanup failed: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 18.6：抢救已中毒安装——旧版本导入角色时把整张卡 base64 存进 avatar，
    // 导致 SharedPreferences 启动时 OOM 白屏。启动时检测超大 data URI 并落盘替换为路径。
    unawaited(_sanitizeLargeAvatarDataUri());
    getTempHistory().then((msg) {
      if (!mounted) return;
      if (msg != null) {
        loadHistory(msg);
        // 16.5：冷启动恢复当前角色背景（clearMsg 分支内部已统一调用）
        unawaited(_restoreBackgroundForCurrentStudent());
      } else {
        clearMsg(true);
      }
    });
    getApiConfigs().then((configs) {
      if (configs.isNotEmpty) {
        config = configs[0];
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showWelcomeScreen();
        });
      }
    });
    getHistorys().then((List<List<String>> results) {
      setState(() {
        historys = results;
        historys.sort((a, b) => int.parse(b[1]).compareTo(int.parse(a[1])));
      });
    });
    getStudents().then((List<List<String>> results) async {
      // 18.2：确保当前工作态角色在池中有记录（默认角色/旧数据可能只存于工作态，
      // 切换角色后会丢失）。若池中无同名记录，则把当前工作态落池。
      final currentName = await getStudentName();
      final exists = results.any((s) => s.isNotEmpty && s[0] == currentName);
      if (!exists) {
        try {
          await addStudent(
            currentName,
            await getAvatar(),
            await getOriginalMsg(),
            await getPrompt(),
            await getDrawCharPrompt(),
            voiceId: await getVoiceId(),
            refImage: await getRefImage(),
            voiceRefUrl: await getVoiceRefUrl(),
            bgImages: (await getBgImages()).join(','),
            personality: await getPersonalityRaw(),
            voiceModel: await getVoiceModel(),
            voiceUrl: await getVoiceUrl(),
            voicePrompt: await getVoicePrompt(),
            appearancePrompt: await getAppearancePrompt(),
            chatBackground: await getChatBackground(),
          );
          final refreshed = await getStudents();
          if (!mounted) return;
          setState(() {
            students = refreshed;
            students.sort((a, b) => a[0].compareTo(b[0]));
          });
          return;
        } catch (e) {
          debugPrint('ensure current student in pool failed: $e');
        }
      }
      if (!mounted) return;
      setState(() {
        students = results;
        students.sort((a, b) => a[0].compareTo(b[0]));
      });
    });
    // 加载自动背景和自动语音设置
    getAutoBackground().then((value) {
      setState(() {
        _isAutoBackground = value;
      });
    });
    getAutoVoice().then((value) {
      setState(() {
        _isAutoVoice = value;
      });
    });
  }

  // 第二十四章：网页保存三要素后刷新当前 LLM 配置。config 仅在 initState 赋值
  // 一次，网页保存（setApiConfig/setLlmApiKey/setCurrentApiConfig）绕过 configpage
  // 的 updateFunc 回调——不刷新会导致对话仍用旧 Config（新用户场景 name 为空 →
  // getLlmApiKey 读空槽 → 误报「文字密钥未配置」）。getApiConfigs 首项即 current。
  Future<void> _reloadCurrentConfig() async {
    final configs = await getApiConfigs();
    if (!mounted) return;
    if (configs.isNotEmpty) {
      setState(() => config = configs[0]);
    }
  }

  void _showWelcomeScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => StatefulBuilder(builder: (context, setState) {
          return Scaffold(
            body: Stack(
              children: [
                Container(
                  width: double.infinity,
                  height: double.infinity,
                  decoration: const BoxDecoration(
                    color: primaryBlue,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        I18n.t('welcome'),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          shadows: [
                            Shadow(
                              offset: Offset(0, 2),
                              blurRadius: 4.0,
                              color: Color.fromARGB(64, 0, 0, 0),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(20),
                        child: Image.asset(
                          "assets/aidazi.png",
                          width: 200,
                          height: 200,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        I18n.t('no_model_config'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white70,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 60),
                      ElevatedButton(
                        onPressed: () async {
                        Navigator.pop(context);
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ConfigPage(
                                updateFunc: updateConfig,
                                currentConfig: config),
                          ),
                        );
                        // 第二十四章：首次配置完成（含网页保存）后刷新当前 Config
                        await _reloadCurrentConfig();
                      },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: primaryBlue,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 40, vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                          elevation: 4,
                        ),
                        child: Text(
                          I18n.t('start_config'),
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      isForeground = true;
      if (isAutoNotification) {
        isAutoNotification = false;
        notification.cancelAll();
      }
    } else {
      isForeground = false;
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final bottom = WidgetsBinding
        .instance.platformDispatcher.views.first.viewInsets.bottom;
    if (bottom > 10 && !keyboardOn) {
      debugPrint("keyboard on");
      keyboardOn = true;
      if (ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
    } else if (bottom < 10 && keyboardOn) {
      debugPrint("keyboard off");
      keyboardOn = false;
    }
  }

  void updateConfig(Config c) {
    setState(() {
      _invalidateConversation();
      config = c;
    });
    debugPrint("update config: ${c.toString()}");
  }

  void onMsgPressed(int index, LongPressStartDetails details) {
    HapticFeedback.heavyImpact();
    if (messages[index].type == Message.assistant) {
      assistantPopup(context, messages[index].message, details, studentName,
          (String edited) {
        debugPrint("edited: $edited");
        edited = edited.replaceAll("\n", "\\");
        if (edited == "INSPIRE") {
          getMsg();
          return;
        }
        if (edited == "DRAW") {
          getDraw(beforeIndex: index);
          return;
        }
        if (edited == "VIDEO") {
          getVideo(beforeIndex: index);
          return;
        }
        if (edited == "FORMAT") {
          String msg = messages[index].message.replaceAll(":", "：");
          String var1 = "$studentName：", var2 = "$userName：";
          List<String> msgs = splitString(msg, [var1, var2]);
          debugPrint("msgs: $msgs");
          setState(() {
            _invalidateConversation();
            messages.removeAt(index);
            for (int i = 0; i < msgs.length; i++) {
              if (msgs[i].startsWith(var1)) {
                messages.insert(
                    index + i,
                    Message(
                        message: msgs[i].substring(var1.length),
                        type: Message.assistant));
              } else if (msgs[i].startsWith(var2)) {
                messages.insert(
                    index + i,
                    Message(
                        message: msgs[i]
                            .substring(var2.length)
                            .replaceAll("\\\\", "\\"),
                        type: Message.user));
              }
            }
          });
          return;
        }
        if (edited == "DELETE") {
          setState(() {
            _invalidateConversation();
            messages.removeRange(index, messages.length);
          });
          return;
        }
        setState(() {
          _invalidateConversation();
          messages[index].message = edited;
        });
      });
    } else if (messages[index].type == Message.user) {
      userPopup(context, messages[index].message, details,
          (String edited, bool isResend) {
        debugPrint("edited: $edited");
        if (edited == "INSPIRE") {
          getMsg();
          return;
        }
        if (edited == "DRAW") {
          getDraw(beforeIndex: index);
          return;
        }
        if (edited == "VIDEO") {
          getVideo(beforeIndex: index);
          return;
        }
        edited = edited.replaceAll("\n", "\\");
        if (edited.isEmpty) {
          setState(() {
            _invalidateConversation();
            messages.removeRange(index, messages.length);
          });
          return;
        }
        setState(() {
          _invalidateConversation();
          messages[index].message = edited;
        });
        if (mounted) {
          textController.clear();
          messages.removeRange(index + 1, messages.length);
          sendMsg(true);
        }
      });
    } else if (messages[index].type == Message.timestamp) {
      timePopup(context, int.parse(messages[index].message), details,
          (bool ifTransfer, DateTime? newTime) {
        if (ifTransfer) {
          setState(() {
            _invalidateConversation();
            messages[index].type = Message.system;
            messages[index].message =
                timestampToSystemMsg(messages[index].message);
          });
        } else {
          debugPrint(newTime.toString());
          setState(() {
            _invalidateConversation();
            messages[index].message =
                newTime!.millisecondsSinceEpoch.toString();
          });
        }
      });
    } else if (messages[index].type == Message.system) {
      systemPopup(context, messages[index].message,
          (String edited, bool isSend) {
        debugPrint("edited: $edited");
        if (edited == "DRAW") {
          getDraw(beforeIndex: index);
          return;
        }
        if (edited.isEmpty) {
          setState(() {
            _invalidateConversation();
            messages.removeAt(index);
          });
        } else {
          setState(() {
            _invalidateConversation();
            messages[index].message = edited;
          });
          if (isSend) {
            messages.removeRange(index + 1, messages.length);
            sendMsg(true, forceSend: true);
          }
        }
      });
    } else if (messages[index].type == Message.image) {
      imagePopup(context, details, (int edited) {
        if (edited == 0) {
          // 设为背景：下载到本地应用目录并记入角色 bgImages（14.14）
          unawaited(_setAsBackground(messages[index].message));
        }
        if (edited == 2) {
          // 15.12：消息存本地路径，需转 file URI 由系统查看器打开
          final msg = messages[index].message;
          launchUrlString(msg.startsWith('http')
              ? msg
              : Uri.file(msg).toString());
        }
        if (edited == 1) {
          setState(() {
            _invalidateConversation();
            messages.removeAt(index);
          });
          unawaited(_saveTempHistory());
        }
      });
    }
  }

  void loadHistory(String msg) {
    List<Message> msgs = jsonToMsg(msg);
    setState(() {
      _invalidateConversation();
      messages
        ..clear()
        ..addAll(msgs);
      _voiceCache.clear();
      _voiceRequests.clear();
      _singleViewIndex = 0;
      _isListViewMode = false;
    });
    unawaited(_saveTempHistory());
  }

  void updateResponse(String response) {
    setState(() {
      response =
          response.replaceAll(RegExp(r'[\\]+'), r'\'); // make all \\ count as 1
      for (var m in response.split("\\")) {
        if (m.isEmpty) continue;
        debugPrint("response chunk: $m");
        messages.add(Message(message: m, type: Message.assistant));
      }
      _conversationVersion++;
    });
  }

  /// 16.5 统一背景恢复：当前角色持久化背景有效 → 应用（不重复持久化）；
  /// 路径失效 → 清理失效记录并回退头像背景（http 头像 / base64 / assets/avatar.png）
  ///
  /// 冷启动（initState）、角色切换（clearMsg）、开始新聊天三入口统一调用
  Future<void> _restoreBackgroundForCurrentStudent() async {
    final bgPath = await getChatBackground();
    if (bgPath.isNotEmpty) {
      if (File(bgPath).existsSync()) {
        if (!mounted) return;
        _applyBackground(FileImage(File(bgPath))); // 已持久化过，不再重复写
        return;
      }
      // 清理失效记录（卸载重装等场景本地文件丢失）
      await setChatBackground('');
    }
    if (!mounted) return;
    final avatarUri = await getAvatar();
    final ImageProvider avatarImage =
        (avatarUri.isNotEmpty && avatarUri.startsWith('http'))
            ? NetworkImage(avatarUri)
            : avatarUri.startsWith('data:image/')
                ? MemoryImage(base64Decode(avatarUri.split(',')[1]))
                : const AssetImage("assets/avatar.png");
    setState(() {
      backgroundImage = DecorationImage(
        image: avatarImage,
        fit: BoxFit.cover,
        colorFilter: ColorFilter.mode(
          Colors.white.withOpacity(0.8),
          BlendMode.dstATop,
        ),
      );
    });
  }

  Future<void> clearMsg(bool clear) async {
    late final int version;
    setState(() {
      _invalidateConversation();
      version = _conversationVersion;
      if (clear) messages.clear();
      _voiceCache.clear();
      _voiceRequests.clear();
    });

    final values = await Future.wait<String>([
      getUserName(),
      getStudentName(),
      getAvatar(),
      getOriginalMsg(),
    ]);
    if (!_isCurrentConversation(version)) return;

    setState(() {
      userName = values[0];
      studentName = values[1];
      avatar = values[2];
      if (clear) {
        final originalMsg = values[3];
        for (var m in originalMsg.split("\\")) {
          messages.add(Message(message: m, type: Message.assistant));
        }
        _conversationVersion++;
        _singleViewIndex = 0;
      }
    });
    // 16.5：背景恢复统一入口（含失效记录清理与头像回退）
    await _restoreBackgroundForCurrentStudent();
    await _saveTempHistory();
  }

  void logMsg(List<List<String>> msg) {
    for (var m in msg) {
      debugPrint("${m[0]}: ${m[1]}");
    }
    debugPrint("model: ${config.model}");
  }

  Future<void> sendMsg(bool realSend, {bool forceSend = false}) async {
    if (inputLock) {
      return;
    }
    if (!forceSend) {
      if ((!realSend) || (realSend && textController.text.isNotEmpty)) {
        setState(() {
          _invalidateConversation();
          if (messages.isNotEmpty && messages.last.type == Message.user) {
            userMsg = "$userMsg\\${textController.text}";
            messages.last.message = userMsg;
          } else {
            userMsg = textController.text;
            messages.add(Message(message: userMsg, type: Message.user));
          }
          textController.clear();
        });
        debugPrint(userMsg);
        setState(() {
          _singleViewIndex = messages.isNotEmpty ? messages.length - 1 : 0;
        });
        if (!realSend) {
          unawaited(_saveTempHistory());
          return;
        }
      }
      userMsg = "";
    }
    late final int requestVersion;
    late final int operation;
    setState(() {
      inputLock = true;
      operation = ++_replyOperation;
      requestVersion = _conversationVersion;
      debugPrint("inputLocked");
    });
    final requestMessages = _copyMessages(messages);

    void unlockInput() {
      if (mounted && operation == _replyOperation && inputLock) {
        setState(() => inputLock = false);
        debugPrint("inputUnlocked");
      }
    }

    try {
      final msg = await parseMsg(
          requestMessages,
          currentStory != null ? jsonToMsg(currentStory![2]) : [],
          [Message(message: await getEndPrompt(), type: Message.system)]);
      if (!_isCurrentConversation(requestVersion) ||
          operation != _replyOperation) {
        return;
      }
      logMsg(msg);
      String response = await collectCompletion(config, msg);
      if (!_isCurrentConversation(requestVersion) ||
          operation != _replyOperation) {
        return;
      }
      // 15.9：模型偶发输出字面转义序列（\n、\t、\"），先归一为真实字符，
      // 再统一把换行/反斜杠压成分段符，避免残留进气泡文本
      response = response.replaceAll(r'\n', '\n');
      response = response.replaceAll(r'\t', ' ');
      response = response.replaceAll(r'\"', '"');
      response = response.replaceAll(RegExp(r'[\n\\]+'), r'\');
      response = randomizeBackslashes(response);
      response = response.replaceAll(RegExp(await getResponseRegex()), '');
      if (!_isCurrentConversation(requestVersion) ||
          operation != _replyOperation) {
        return;
      }

      updateResponse(response);
      debugPrint("done.");
      await _saveTempHistory();
      unlockInput();

      // 自动发声：开关开启时，AI 回复完成即合成并播放（仅自动，无手动入口）
      // 15.9：分段符（\）不是朗读内容，归一为「，」再合成，避免读出反斜杠
      if (_isAutoVoice) {
        unawaited(getVoice(response.replaceAll(RegExp(r'\\+'), '，')));
      }
      // 自动背景（14.14）：每 2-5 轮对话自动切换角色背景
      unawaited(_maybeRotateBackground());
    } catch (e) {
      debugPrint(e.toString());
      if (_isCurrentConversation(requestVersion) &&
          operation == _replyOperation) {
        snackBarAlert(context, e.toString());
      }
    } finally {
      unlockInput();
    }
  }

  /// 设置聊天页背景（自动背景轮换与「设为背景」共用）
  /// 15.1：localPath 非空时同步持久化到当前角色，重启后可恢复
  void _applyBackground(ImageProvider provider, {String? localPath}) {
    if (localPath != null) {
      unawaited(setChatBackground(localPath));
    }
    setState(() {
      backgroundImage = DecorationImage(
        image: provider,
        fit: BoxFit.cover,
        colorFilter: ColorFilter.mode(
          Colors.white.withOpacity(0.8),
          BlendMode.dstATop,
        ),
      );
    });
  }

  /// 17.10 helper：根据消息路径构造图片 provider，优先本地 FileImage 避免 NetworkImage 过期变灰
  ImageProvider? _imageProvider(String path) {
    if (path.isEmpty) return null;
    if (path.startsWith('http')) return NetworkImage(path);
    if (path.startsWith('data:image/')) {
      try {
        return MemoryImage(base64Decode(path.split(',')[1]));
      } catch (_) {}
    }
    if (File(path).existsSync()) return FileImage(File(path));
    return null; // 无效路径，返回 null 让调用方跳过
  }

  /// 下载图片到本地应用目录（避免百炼临时 URL 过期后背景丢失）
  Future<String> _downloadImageToLocal(String url) async {
    // 第十六章：OpenAI 协议 b64 兜底产物已是本地路径，直通不再发起 http
    if (!url.startsWith('http')) return url;
    final dir = await getApplicationDocumentsDirectory();
    final bgDir = Directory('${dir.path}/backgrounds');
    if (!await bgDir.exists()) {
      await bgDir.create(recursive: true);
    }
    final name = url.hashCode.toRadixString(16);
    final file = File('${bgDir.path}/bg_$name.png');
    if (await file.exists()) return file.path;
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception('下载图片失败: HTTP ${response.statusCode}');
    }
    await file.writeAsBytes(response.bodyBytes);
    return file.path;
  }

  /// 设为背景：下载到本地 → 记入角色 bgImages → 立即应用并持久化（14.14/15.1）
  ///
  /// 15.12：消息本身可能是本地路径（生成产物已下载），直接使用
  Future<void> _setAsBackground(String imageUrl) async {
    try {
      final localPath = imageUrl.startsWith('http')
          ? await _downloadImageToLocal(imageUrl)
          : imageUrl; // 已是本地文件
      await addBgImage(localPath);
      if (!mounted) return;
      _applyBackground(FileImage(File(localPath)), localPath: localPath);
    } catch (e) {
      if (mounted) {
        if (imageUrl.startsWith('http')) {
          _applyBackground(NetworkImage(imageUrl));
        }
        snackBarAlert(context, "${I18n.t('error')} $e");
      }
    }
  }

  /// 自动背景（14.14）：开关开启时每 2-5 轮对话自动切换角色 bgImages
  Future<void> _maybeRotateBackground() async {
    if (!_isAutoBackground) return;
    _autoBgRounds++;
    if (_autoBgRounds < _autoBgThreshold) return;
    _autoBgRounds = 0;
    _autoBgThreshold = 2 + (DateTime.now().millisecondsSinceEpoch % 4); // 2-5
    final images = await getBgImages();
    if (images.isEmpty) {
      // 15.1：角色从未生成/设过背景图则静默不换，一次性提示辅助理解
      if (mounted && !_noBgHintShown) {
        _noBgHintShown = true;
        snackBarAlert(context, I18n.t('no_bg_images_hint'));
      }
      return;
    }
    if (_bgImageIndex >= images.length) _bgImageIndex = 0;
    final path = images[_bgImageIndex++];
    if (!mounted) return;
    _applyBackground(FileImage(File(path)), localPath: path);
  }

  Future<void> getVoice(String text) async {
    if (text.isEmpty) {
      snackBarAlert(context, I18n.t('msg_empty'));
      return;
    }

    final operation = ++_voiceOperation;
    final conversationVersion = _conversationVersion;

    if (_voiceCache.containsKey(text)) {
      try {
        if (operation == _voiceOperation) {
          await playAudio(context, _voiceCache[text]!);
        }
        return;
      } catch (e) {
        _voiceCache.remove(text);
      }
    }

    var request = _voiceRequests[text];
    if (request == null) {
      request = getAudio(context, text);
      _voiceRequests[text] = request;
    }

    try {
      final path = await request;
      if (path != null &&
          path.isNotEmpty &&
          _isCurrentConversation(conversationVersion)) {
        _voiceCache[text] = path;
      }
      if (path != null &&
          path.isNotEmpty &&
          operation == _voiceOperation &&
          _isCurrentConversation(conversationVersion)) {
        await playAudio(context, path);
      }
    } catch (e) {
      if (!context.mounted) return;
      snackBarAlert(context, "${I18n.t('voice_gen_failed')}: $e");
    } finally {
      if (identical(_voiceRequests[text], request)) {
        _voiceRequests.remove(text);
      }
    }
  }

  Future<void> getMsg() async {
    if (_isInspiring) return;
    final operation = ++_inspireOperation;
    final conversationVersion = _conversationVersion;
    setState(() => _isInspiring = true);
    Route<dynamic>? progressRoute;
    try {
      final requestMessages = _copyMessages(messages);
      final msg = await parseMsg(
        requestMessages,
        currentStory != null ? jsonToMsg(currentStory![2]) : [],
        [Message(message: await getInspirePrompt(), type: Message.system)],
      );
      if (!_isCurrentConversation(conversationVersion) ||
          operation != _inspireOperation) {
        return;
      }

      logMsg(msg);
      progressRoute = await _showProgressDialog(I18n.t('gen_candidate_resp'));
      final result = await collectCompletion(config, msg);
      _closeDialogRoute(progressRoute);
      progressRoute = null;
      if (!_isCurrentConversation(conversationVersion) ||
          operation != _inspireOperation) {
        return;
      }

      final responseRegex = RegExp(await getResponseRegex());
      List<String> candidates = result
          .replaceAll(responseRegex, '')
          .split('||')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (candidates.isEmpty) {
        final fallback = result.replaceAll(responseRegex, '').trim();
        if (fallback.isNotEmpty) {
          candidates = [fallback];
        }
      }
      if (candidates.isEmpty) {
        throw Exception(I18n.t('msg_empty'));
      }

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(I18n.t('select_reply')),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: candidates.length,
              itemBuilder: (context, index) => Card(
                child: ListTile(
                  title: Text(
                    '${I18n.t('option')} ${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(candidates[index]),
                  onTap: () {
                    if (_isCurrentConversation(conversationVersion)) {
                      textController.text = candidates[index];
                    }
                    Navigator.of(dialogContext).pop();
                    if (_isCurrentConversation(conversationVersion)) {
                      sendMsg(true);
                    }
                  },
                  onLongPress: () {
                    if (_isCurrentConversation(conversationVersion)) {
                      textController.text = candidates[index];
                      FocusScope.of(context).requestFocus(fn);
                    }
                    Navigator.of(dialogContext).pop();
                  },
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(I18n.t('cancel')),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                if (_isCurrentConversation(conversationVersion)) {
                  _isInspiring = false;
                  getMsg();
                }
              },
              child: Text(I18n.t('regenerate')),
            ),
          ],
        ),
      );
    } catch (e) {
      if (_isCurrentConversation(conversationVersion) &&
          operation == _inspireOperation) {
        snackBarAlert(context, e.toString());
      }
    } finally {
      _closeDialogRoute(progressRoute);
      if (mounted && operation == _inspireOperation) {
        setState(() => _isInspiring = false);
      }
    }
  }

  Future<void> getWelcomeMsg() async {
    if (_isWelcoming) return;
    final operation = ++_welcomeOperation;
    final conversationVersion = _conversationVersion;
    setState(() => _isWelcoming = true);
    Route<dynamic>? progressRoute;

    // 获取当前日期和时间
    final now = DateTime.now();
    final dateStr = '${now.year}年${now.month}月${now.day}日';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    try {
      // 获取欢迎语提示词并替换变量
      String welcomePrompt = await getWelcomePrompt();
      welcomePrompt = welcomePrompt
          .replaceAll('{{date}}', dateStr)
          .replaceAll('{{time}}', timeStr);
      final msg = await parseMsg(
        const <Message>[],
        currentStory != null ? jsonToMsg(currentStory![2]) : [],
        [Message(message: welcomePrompt, type: Message.system)],
      );
      if (!_isCurrentConversation(conversationVersion) ||
          operation != _welcomeOperation) {
        return;
      }
      logMsg(msg);

      progressRoute = await _showProgressDialog(I18n.t('gen_candidate_resp'));
      final result = await collectCompletion(config, msg);
      _closeDialogRoute(progressRoute);
      progressRoute = null;
      if (!_isCurrentConversation(conversationVersion) ||
          operation != _welcomeOperation) {
        return;
      }

      final responseRegex = RegExp(await getResponseRegex());
      List<String> candidates = result
          .replaceAll(responseRegex, '')
          .split('||')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (candidates.isEmpty) {
        final fallback = result.replaceAll(responseRegex, '').trim();
        if (fallback.isNotEmpty) candidates = [fallback];
      }

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(I18n.t('welcome')),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: candidates.length,
              itemBuilder: (context, index) => Card(
                child: ListTile(
                  title: Text(
                    '${I18n.t('option')} ${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(candidates[index]),
                  onTap: () {
                    Navigator.of(dialogContext).pop();
                    if (!_isCurrentConversation(conversationVersion)) return;
                    setState(() {
                      _invalidateConversation();
                      messages.clear();
                      _voiceCache.clear();
                      _voiceRequests.clear();
                      for (final part in candidates[index].split("\\")) {
                        if (part.isNotEmpty) {
                          messages.add(Message(
                            message: part,
                            type: Message.assistant,
                          ));
                        }
                      }
                      _conversationVersion++;
                      _singleViewIndex = 0;
                    });
                    unawaited(_saveTempHistory());
                  },
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(I18n.t('cancel')),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                if (_isCurrentConversation(conversationVersion)) {
                  _isWelcoming = false;
                  getWelcomeMsg();
                }
              },
              child: Text(I18n.t('regenerate')),
            ),
          ],
        ),
      );
    } catch (e) {
      if (_isCurrentConversation(conversationVersion) &&
          operation == _welcomeOperation) {
        snackBarAlert(context, e.toString());
      }
    } finally {
      _closeDialogRoute(progressRoute);
      if (mounted && operation == _welcomeOperation) {
        setState(() => _isWelcoming = false);
      }
    }
  }

  Future<void> getDraw({int? beforeIndex}) async {
    if (_isDrawing) return;
    final operation = ++_drawOperation;
    final conversationVersion = _conversationVersion;
    setState(() => _isDrawing = true);
    try {
      await _runDraw(
        beforeIndex: beforeIndex,
        conversationVersion: conversationVersion,
        operation: operation,
      );
    } catch (error) {
      if (_isCurrentConversation(conversationVersion) &&
          operation == _drawOperation) {
        snackBarAlert(context, "${I18n.t('error')} $error");
      }
    } finally {
      if (mounted && operation == _drawOperation) {
        setState(() => _isDrawing = false);
      }
    }
  }

  /// LLM 总结选中的消息 → 生成绘画/视频提示词（重试最多 4 次）
  Future<String> _generateDrawPromptText({
    required List<List<String>> msg,
    required int conversationVersion,
    required int operation,
  }) async {
    const int maxRetries = 4;
    final String responseRegex = await getResponseRegex();
    String lastPromptError = '';
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      if (!_isCurrentConversation(conversationVersion) ||
          operation != _drawOperation) {
        return '';
      }
      try {
        final Completer<String> promptCompleter = Completer<String>();
        String result = '';
        completion(config, msg, (String data) {
          result += data.replaceAll("\n", " ");
        }, () {
          final cand = result
              .split('||')
              .last
              .replaceAll(RegExp(responseRegex), '')
              .trim();
          if (!promptCompleter.isCompleted) {
            promptCompleter.complete(cand);
          }
        }, (String error) {
          lastPromptError = error;
          if (!promptCompleter.isCompleted) {
            promptCompleter.completeError(error);
          }
        });
        final String cand = await promptCompleter.future.timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            lastPromptError = 'timeout';
            return '';
          },
        );
        if (cand.isNotEmpty) {
          return cand;
        } else if (lastPromptError.isEmpty) {
          lastPromptError = 'empty response';
        }
      } catch (e) {
        lastPromptError = e.toString();
        debugPrint('prompt generation attempt $attempt failed: $e');
      }
    }
    throw Exception("${I18n.t('draw_prompt_failed')}: $lastPromptError");
  }

  Future<void> _runDraw({
    int? beforeIndex,
    required int conversationVersion,
    required int operation,
  }) async {
    // 15.8：长按消息生图只总结所选消息前后各 3 条（前3+所选+后3）；null 兜底取全部
    final List<Message> drawMessages = beforeIndex == null
        ? _copyMessages(messages)
        : _copyMessages(messages.sublist(
            (beforeIndex - 3).clamp(0, messages.length),
            (beforeIndex + 4).clamp(0, messages.length)));
    List<List<String>> msg = await parseMsg(
        drawMessages,
        currentStory != null ? jsonToMsg(currentStory![2]) : [],
        [Message(message: await getDrawPrompt(), type: Message.system)]);
    if (!_isCurrentConversation(conversationVersion) ||
        operation != _drawOperation) {
      return;
    }

    // 1. LLM 总结选中消息生成提示词
    final promptText = await _generateDrawPromptText(
      msg: msg,
      conversationVersion: conversationVersion,
      operation: operation,
    );
    if (promptText.isEmpty ||
        !_isCurrentConversation(conversationVersion) ||
        operation != _drawOperation) {
      return;
    }

    // 2. 生图逻辑：有参考图 → 图生图（仅用场景提示词，不用角色绘图提示词）；
    //    无参考图 → 文生图（角色外貌描述 + 场景提示词）
    final charPrompt = await getDrawCharPrompt();
    final refImageBytes = await _readRefImageBytes();
    final drawPrompt = refImageBytes != null ? promptText : '$charPrompt, $promptText';
    snackBarAlert(context, I18n.t('generating'));
    final url = await generateWanxImage(
      prompt: drawPrompt,
      refImageBytes: refImageBytes,
    );

    // 3. 下载到本地（15.12：百炼临时 URL 24h 过期，消息只存本地路径）→ 设为背景并插入消息流
    if (!_isCurrentConversation(conversationVersion) ||
        operation != _drawOperation) {
      return;
    }
    if (!isForeground) {
      notification.showNotification(
        title: '绘画',
        body: '绘画完成！',
        showAvator: false,
      );
    }
    String imagePath = url;
    try {
      imagePath = await _downloadImageToLocal(url);
      await addBgImage(imagePath); // 记入角色背景池供自动轮换
    } catch (e) {
      debugPrint('draw image download failed: $e'); // 下载失败回落临时 URL
    }
    if (!mounted ||
        !_isCurrentConversation(conversationVersion) ||
        operation != _drawOperation) {
      return;
    }
    if (imagePath != url || !imagePath.startsWith('http')) {
      // 已下载到本地 / 第十六章 b64 兜底本就是本地路径 → 文件背景
      _applyBackground(FileImage(File(imagePath)), localPath: imagePath);
      // 16.2：图片已自动设为背景，提示用户
      snackBarAlert(context, I18n.t('story_bg_generated'));
    } else {
      _applyBackground(NetworkImage(url));
    }
    setState(() {
      messages.add(Message(message: imagePath, type: Message.image));
      _conversationVersion++;
    });
    await _saveTempHistory();
  }

  /// 读取当前角色参考图字节（15.12：本地路径 → Base64 直传；OSS 已移除）
  ///
  /// 参考图不存在或读取失败返回 null（降级为纯文生图/文生视频）
  Future<Uint8List?> _readRefImageBytes() async {
    final refImage = await getRefImage();
    if (refImage.isEmpty) return null;
    try {
      final file = File(refImage);
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (e) {
      debugPrint('read ref image failed: $e');
    }
    return null;
  }

  /// 下载视频到本地应用目录（15.12：百炼临时 URL 24h 过期，消息只存本地路径）
  Future<String> _downloadVideoToLocal(String url) async {
    final dir = await getApplicationDocumentsDirectory();
    final videoDir = Directory('${dir.path}/videos');
    if (!await videoDir.exists()) {
      await videoDir.create(recursive: true);
    }
    final name = url.hashCode.toRadixString(16);
    final file = File('${videoDir.path}/video_$name.mp4');
    if (await file.exists()) return file.path;
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception('下载视频失败: HTTP ${response.statusCode}');
    }
    await file.writeAsBytes(response.bodyBytes);
    return file.path;
  }

  /// 长按消息 → 视频（14.13）：LLM 总结提示词 → 万相文生视频 → 插入消息流
  Future<void> getVideo({int? beforeIndex}) async {
    if (_isDrawing) return; // 复用生成锁，避免并发调用
    final operation = ++_drawOperation;
    final conversationVersion = _conversationVersion;
    setState(() => _isDrawing = true);
    try {
      // 15.8：长按消息生视频只总结所选消息前后各 3 条（前3+所选+后3）；null 兜底取全部
      final List<Message> videoMessages = beforeIndex == null
          ? _copyMessages(messages)
          : _copyMessages(messages.sublist(
              (beforeIndex - 3).clamp(0, messages.length),
              (beforeIndex + 4).clamp(0, messages.length)));
      List<List<String>> msg = await parseMsg(
          videoMessages,
          currentStory != null ? jsonToMsg(currentStory![2]) : [],
          [Message(message: await getDrawPrompt(), type: Message.system)]);
      if (!_isCurrentConversation(conversationVersion) ||
          operation != _drawOperation) {
        return;
      }

      final promptText = await _generateDrawPromptText(
        msg: msg,
        conversationVersion: conversationVersion,
        operation: operation,
      );
      if (promptText.isEmpty ||
          !_isCurrentConversation(conversationVersion) ||
          operation != _drawOperation) {
        return;
      }

      // 万相视频（异步任务，轮询等待，耗时较长）；
      // 15.8：提示词统一为「角色外貌 + 场景」（与生图文生图分支一致）；
      // 有参考图 → 图生视频（参考图约束主角形象，Base64 直传），无 → 纯文生视频
      snackBarAlert(context, I18n.t('video_generating'));
      final charPrompt = await getDrawCharPrompt();
      final refImageBytes = await _readRefImageBytes();
      final url = await generateWanxVideo(
        prompt: '$charPrompt, $promptText',
        refImageBytes: refImageBytes,
      );

      if (!mounted ||
          !_isCurrentConversation(conversationVersion) ||
          operation != _drawOperation) {
        return;
      }
      if (!isForeground) {
        notification.showNotification(
          title: '视频',
          body: '视频生成完成！',
          showAvator: false,
        );
      }
      // 15.12：下载到本地（百炼临时 URL 24h 过期），消息只存本地路径
      String videoPath = url;
      try {
        videoPath = await _downloadVideoToLocal(url);
      } catch (e) {
        debugPrint('video download failed: $e'); // 下载失败回落临时 URL
      }
      if (!mounted ||
          !_isCurrentConversation(conversationVersion) ||
          operation != _drawOperation) {
        return;
      }
      setState(() {
        messages.add(Message(message: videoPath, type: Message.video));
        _conversationVersion++;
      });
      await _saveTempHistory();
    } catch (error) {
      if (mounted &&
          _isCurrentConversation(conversationVersion) &&
          operation == _drawOperation) {
        snackBarAlert(context, "${I18n.t('video_gen_failed')} $error");
      }
    } finally {
      if (mounted && operation == _drawOperation) {
        setState(() => _isDrawing = false);
      }
    }
  }

  /// 15.5：当前故事 → 生成背景图
  /// LLM 总结故事内容为英文生图提示词（复用选消息生图流程）→ 万相文生图（9:16）
  /// → 下载到本地应用目录 → 写入当前角色 bgImages → 设为当前聊天背景
  Future<void> _generateStoryBackground() async {
    if (currentStory == null) return;
    if (_isDrawing) return; // 复用生成锁，避免并发调用
    final operation = ++_drawOperation;
    setState(() => _isDrawing = true);
    try {
      final storyText =
          jsonToMsg(currentStory![2]).map((m) => m.message).join('\n').trim();
      if (storyText.isEmpty) {
        snackBarAlert(context, I18n.t('story_empty'));
        return;
      }

      // 1. LLM 总结故事内容为生图提示词
      final msg = await parseMsg(
        [Message(message: storyText, type: Message.system)],
        [],
        [Message(message: await getDrawPrompt(), type: Message.system)],
      );
      if (operation != _drawOperation) return;
      final promptText = await _generateDrawPromptText(
        msg: msg,
        conversationVersion: _conversationVersion,
        operation: operation,
      );
      if (promptText.isEmpty || operation != _drawOperation) return;

      // 2. 生图逻辑：有参考图 → 图生图（仅用故事场景提示词，不用角色绘图提示词）；
      //    无参考图 → 文生图（角色外貌描述 + 故事场景）
      final charPrompt = await getDrawCharPrompt();
      final refImageBytes = await _readRefImageBytes();
      final drawPrompt = refImageBytes != null ? promptText : '$charPrompt, $promptText';
      snackBarAlert(context, I18n.t('generating'));
      final url = await generateWanxImage(
        prompt: drawPrompt,
        refImageBytes: refImageBytes,
      );
      if (!mounted || operation != _drawOperation) return;

      // 3. 下载到本地 → 写入角色背景池 → 设为当前聊天背景
      String imagePath = url;
      try {
        imagePath = await _downloadImageToLocal(url);
        await addBgImage(imagePath);
      } catch (e) {
        debugPrint('story background download failed: $e'); // 下载失败回落临时 URL
      }
      if (!mounted || operation != _drawOperation) return;
      if (imagePath != url || !imagePath.startsWith('http')) {
        // 已下载到本地 / 第十六章 b64 兜底本就是本地路径 → 文件背景
        _applyBackground(FileImage(File(imagePath)), localPath: imagePath);
      } else {
        _applyBackground(NetworkImage(url));
      }
      snackBarAlert(context, I18n.t('story_bg_generated'));
    } catch (error) {
      // 生成失败静默降级提示错误信息，不阻断聊天
      if (mounted && operation == _drawOperation) {
        snackBarAlert(context, "${I18n.t('image_gen_failed')} $error");
      }
    } finally {
      if (mounted && operation == _drawOperation) {
        setState(() => _isDrawing = false);
      }
    }
  }

  void _showDisplaySettings() {
    double fontSize = displaySettings.fontSize;
    String userTextColorHex = displaySettings.userTextColorHex;
    String aiTextColorHex = displaySettings.aiTextColorHex;
    bool textOutline = displaySettings.textOutline;
    double outlineWidth = displaySettings.outlineWidth;
    String outlineColorHex = displaySettings.outlineColorHex;

    final TextEditingController userColorCtrl =
        TextEditingController(text: userTextColorHex);
    final TextEditingController aiColorCtrl =
        TextEditingController(text: aiTextColorHex);
    final TextEditingController outlineColorCtrl =
        TextEditingController(text: outlineColorHex);

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text(I18n.t('display_settings')),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ===== 字体大小 =====
                    Text(I18n.t('font_size'),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () => fontSize > 10
                              ? setDialogState(() => fontSize -= 1)
                              : null,
                        ),
                        Expanded(
                          child: Slider(
                            value: fontSize,
                            min: 10,
                            max: 48,
                            divisions: 38,
                            label: '${fontSize.round()}',
                            onChanged: (v) => setDialogState(
                                () => fontSize = v.roundToDouble()),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () => fontSize < 48
                              ? setDialogState(() => fontSize += 1)
                              : null,
                        ),
                      ],
                    ),
                    Center(
                        child: Text('${fontSize.round()}px',
                            style: TextStyle(
                                fontSize: fontSize.clamp(12.0, 48.0)))),
                    const SizedBox(height: 16),

                    // ===== 自己的文字颜色（17.11：与对方分开独立配置）=====
                    const Text('自己的文字颜色',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _colorRow(ctx, setDialogState, userColorCtrl, userTextColorHex),
                    const SizedBox(height: 8),
                    TextField(
                      controller: userColorCtrl,
                      decoration: const InputDecoration(
                        labelText: '自己的文字 Hex（留空 = 默认深蓝）',
                        hintText: '留空用默认值',
                        border: OutlineInputBorder(),
                        isCollapsed: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ===== 对方的文字颜色 =====
                    const Text('对方的文字颜色',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _colorRow(ctx, setDialogState, aiColorCtrl, aiTextColorHex),
                    const SizedBox(height: 8),
                    TextField(
                      controller: aiColorCtrl,
                      decoration: const InputDecoration(
                        labelText: '对方的文字 Hex（留空 = 默认黑色）',
                        hintText: '留空用默认值',
                        border: OutlineInputBorder(),
                        isCollapsed: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ===== 描边开关 =====
                    Row(
                      children: [
                        Text(I18n.t('text_outline'),
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        const Spacer(),
                        Switch(
                          value: textOutline,
                          onChanged: (v) =>
                              setDialogState(() => textOutline = v),
                        ),
                      ],
                    ),
                    if (textOutline) ...[
                      const SizedBox(height: 4),
                      Text(I18n.t('outline_width'),
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () => outlineWidth > 0.5
                                ? setDialogState(() => outlineWidth -= 0.5)
                                : null,
                          ),
                          Expanded(
                            child: Slider(
                              value: outlineWidth,
                              min: 0.5,
                              max: 6.0,
                              divisions: 11,
                              label: outlineWidth.toStringAsFixed(1),
                              onChanged: (v) => setDialogState(() =>
                                  outlineWidth =
                                      double.parse(v.toStringAsFixed(1))),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline),
                            onPressed: () => outlineWidth < 6.0
                                ? setDialogState(() => outlineWidth += 0.5)
                                : null,
                          ),
                        ],
                      ),
                      Center(
                          child: Text('${outlineWidth.toStringAsFixed(1)}px')),
                      const SizedBox(height: 12),

                      // ===== 描边颜色 =====
                      Text(I18n.t('outline_color'),
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      _colorRow(ctx, setDialogState, outlineColorCtrl,
                          outlineColorHex),
                      const SizedBox(height: 8),
                      TextField(
                        controller: outlineColorCtrl,
                        decoration: InputDecoration(
                          labelText: '${I18n.t('outline_color')} Hex',
                          hintText: '666666',
                          border: const OutlineInputBorder(),
                          isCollapsed: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 12),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(I18n.t('cancel')),
                ),
                TextButton(
                  onPressed: () async {
                    final userColor = userColorCtrl.text.trim();
                    final aiColor = aiColorCtrl.text.trim();
                    final outlineColor = outlineColorCtrl.text.trim();
                    await Future.wait<void>([
                      setDisplayFontSize(fontSize),
                      // 17.11：拆为自己 / 对方两套独立配色
                      setUserTextColor(userColor),
                      setAiTextColor(aiColor),
                      setDisplayTextOutline(textOutline),
                      setDisplayOutlineWidth(outlineWidth),
                      setDisplayOutlineColor(outlineColor),
                    ]);
                    if (!mounted || !ctx.mounted) return;
                    displaySettings.fontSize = fontSize;
                    displaySettings.userTextColorHex = userColor;
                    displaySettings.aiTextColorHex = aiColor;
                    displaySettings.textOutline = textOutline;
                    displaySettings.outlineWidth = outlineWidth;
                    displaySettings.outlineColorHex = outlineColor;
                    displaySettingsVersion.value++;
                    setState(() => _displaySettingsKey++);
                    Navigator.pop(ctx);
                  },
                  child: Text(I18n.t('confirm')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _colorRow(BuildContext ctx, StateSetter setDialogState,
      TextEditingController controller, String currentHex) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _colorChip2(ctx, setDialogState, controller, '', I18n.t('auto')),
        _colorChip2(ctx, setDialogState, controller, 'FFFFFF', I18n.t('white')),
        _colorChip2(ctx, setDialogState, controller, '000000', I18n.t('black')),
        _colorChip2(ctx, setDialogState, controller, 'FF4444', I18n.t('red')),
        _colorChip2(ctx, setDialogState, controller, '44AAFF', I18n.t('blue')),
        _colorChip2(ctx, setDialogState, controller, 'FFD700', I18n.t('gold')),
        _colorChip2(ctx, setDialogState, controller, 'FF69B4', I18n.t('pink')),
      ],
    );
  }

  Widget _colorChip2(BuildContext ctx, StateSetter setDialogState,
      TextEditingController controller, String hex, String label) {
    return GestureDetector(
      onTap: () => setDialogState(() => controller.text = hex),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: hex.isEmpty
              ? Colors.grey.shade300
              : Color(int.parse('FF$hex', radix: 16)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color:
                  controller.text == hex ? Colors.blue : Colors.grey.shade400,
              width: controller.text == hex ? 2 : 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            color:
                hex.isEmpty || hex == 'FFFFFF' ? Colors.black87 : Colors.white,
            fontWeight:
                controller.text == hex ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  /// 16.6 开始新聊天：确认后清空消息并重建开场白（原 refresh 按钮功能）
  void _confirmNewChat() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(I18n.t('reset_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(I18n.t('cancel')),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: primaryBlue),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              clearMsg(true);
              snackBarAlert(context, I18n.t('reset'));
            },
            child: Text(I18n.t('confirm')),
          ),
        ],
      ),
    );
  }

  /// 16.6 当前角色在 student_ 记录中的存储 key（与角色列表删除逻辑同格式）
  Future<String> _getCurrentStudentKey() async {
    final results = await getStudents();
    for (final student in results) {
      if (student[0] == studentName) {
        return "student_${student[4]}_${student[0]}";
      }
    }
    return "";
  }

  /// 16.6 保存本次聊天：输入名称 → 存本地文件（独立于故事池，不再走 addHistory）
  Future<void> _showSaveChatDialog() async {
    final nameController = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(I18n.t('menu_save_chat')),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: I18n.t('chat_name_hint'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(I18n.t('cancel')),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: primaryBlue),
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                snackBarAlert(context, I18n.t('chat_name_hint'));
                return;
              }
              Navigator.of(dialogContext).pop();
              try {
                await saveChatToFile(
                  name,
                  await _getCurrentStudentKey(),
                  msgListToJson(_copyMessages(messages)),
                );
                if (mounted) snackBarAlert(context, I18n.t('chat_saved'));
              } catch (e) {
                if (mounted) snackBarAlert(context, "${I18n.t('error')} $e");
              }
            },
            child: Text(I18n.t('confirm')),
          ),
        ],
      ),
    );
  }

  /// 16.6 提取聊天记录：列出已保存聊天（可删除），点选恢复到当前聊天
  Future<void> _showLoadChatDialog() async {
    final chats = await listSavedChats();
    if (!mounted) return;
    final listChats = List<SavedChat>.from(chats);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(I18n.t('select_chat')),
          content: listChats.isEmpty
              ? Text(I18n.t('no_saved_chats'))
              : SizedBox(
                  width: double.maxFinite,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: listChats.length,
                    itemBuilder: (context, index) {
                      final chat = listChats[index];
                      return ListTile(
                        title: Text(chat.name),
                        subtitle: Text(getTimeStr(chat.timestamp)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () {
                            showDialog<void>(
                              context: dialogContext,
                              builder: (confirmContext) => AlertDialog(
                                content: Text(I18n.t('delete_chat_confirm')),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(
                                            confirmContext)
                                        .pop(),
                                    child: Text(I18n.t('cancel')),
                                  ),
                                  TextButton(
                                    style: TextButton.styleFrom(
                                        foregroundColor: primaryBlue),
                                    onPressed: () async {
                                      await deleteSavedChat(chat.filename);
                                      if (!confirmContext.mounted) return;
                                      Navigator.of(confirmContext).pop();
                                      setDialogState(
                                          () => listChats.removeAt(index));
                                    },
                                    child: Text(I18n.t('delete')),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        onTap: () {
                          Navigator.of(dialogContext).pop();
                          _loadSavedChat(chat.filename);
                        },
                      );
                    },
                  ),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(I18n.t('cancel')),
            ),
          ],
        ),
      ),
    );
  }

  /// 16.6 按存储 key 切换当前角色（参考角色列表点选切换逻辑）
  Future<bool> _switchToStudentByKey(String studentKey) async {
    final results = await getStudents();
    for (final student in results) {
      if ("student_${student[4]}_${student[0]}" == studentKey) {
        await Future.wait<void>([
          setStudentName(student[0]),
          setAvatar(student[1]),
          setOriginalMsg(student[2]),
          setPrompt(student[3]),
          setDrawCharPrompt(student[5]),
          setVoiceId(student[6]),
          setRefImage(student[7]),
          setVoiceRefUrl(student[9]),
          setVoiceModel(student[15]), // 15.16.1：角色级 TTS 模型
          setPersonality(student[14]), // 15.17：角色性格
          setChatBackground(student.length > 13 ? student[13] : ''), // 18.2：角色背景
          setVoiceUrl(student.length > 16 ? student[16] : ''), // 18.x：声音复刻 URL
          setVoicePrompt(student.length > 17 ? student[17] : ''), // 18.x：声音设计描述
          setAppearancePrompt(student.length > 18 ? student[18] : ''), // 18.x：样貌描述
        ]);
        if (!mounted) return true;
        await clearMsg(true);
        return true;
      }
    }
    return false;
  }

  /// 16.6 加载已保存聊天 → 必要时切换到保存时的角色 → 恢复消息流
  Future<void> _loadSavedChat(String filename) async {
    try {
      final (info, messagesJson) = await loadChatFromFile(filename);
      // 保存时的角色与当前不同 → 先切换到该角色（角色缺失则留在当前角色）
      if (info.studentKey.isNotEmpty &&
          info.studentKey != await _getCurrentStudentKey()) {
        await _switchToStudentByKey(info.studentKey);
      }
      if (!mounted) return;
      loadHistory(messagesJson);
      setState(() => _currentIndex = 0); // 切回聊天页
      snackBarAlert(context, "${I18n.t('chat_loaded')}${info.name}");
    } catch (e) {
      if (mounted) snackBarAlert(context, "${I18n.t('error')} $e");
    }
  }

  Widget _buildChatPage() {
    // 顶部 AppBar 已整体移除（小屏省空间）：背景图延伸到状态栏后面，
    // 聊天内容用 SafeArea 顶边避开状态栏，从屏幕最顶部开始就是背景和聊天
    return Scaffold(
      key: ValueKey(_displaySettingsKey),
      body: Container(
        decoration: BoxDecoration(image: backgroundImage),
        child: GestureDetector(
          onTap: () {
            fn.unfocus();
            setState(() {
              _isToolsExpanded = false;
            });
          },
          child: SafeArea(
            top: true,
            bottom: false,
            child: Column(
            children: [
              Expanded(
                child: _isListViewMode
                    ? Container(
                        color: Colors.black.withOpacity(0.3),
                        child: Builder(builder: (context) {
                          // Scroll to bottom only once when the widget builds
                          SchedulerBinding.instance.addPostFrameCallback((_) {
                            if (scrollController.hasClients) {
                              scrollController.animateTo(
                                scrollController.position.maxScrollExtent *
                                    _singleViewIndex /
                                    (messages.isEmpty ? 1 : messages.length),
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOut,
                              );
                            }
                          });

                          return ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            controller: scrollController,
                            itemCount: messages.length,
                            itemBuilder: (context, index) {
                              final message = messages[index];
                              return GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _isListViewMode = false;
                                    _singleViewIndex = index;
                                    if (messages[_singleViewIndex].type ==
                                        Message.image) {
                                      // change background
                                      final imgProvider = _imageProvider(messages[_singleViewIndex].message);
                                      if (imgProvider != null) {
                                        backgroundImage = DecorationImage(
                                          image: imgProvider,
                                          fit: BoxFit.cover,
                                          colorFilter: ColorFilter.mode(
                                            Colors.white.withOpacity(0.8),
                                            BlendMode.dstATop,
                                          ),
                                        );
                                      }
                                      // skip image
                                      _singleViewIndex = _singleViewIndex ==
                                              messages.length - 1
                                          ? _singleViewIndex - 1
                                          : _singleViewIndex + 1;
                                    }
                                  });
                                },
                                onLongPressStart: (details) {
                                  onMsgPressed(index, details);
                                  fn.unfocus();
                                },
                                child: ChatElement(
                                  message: message.message,
                                  type: message.type,
                                  userName: userName,
                                  stuName: studentName,
                                  isBacklog: true,
                                ),
                              );
                            },
                          );
                        }),
                      )
                    : (messages.isEmpty
                        ? Align(
                            alignment: Alignment.bottomCenter,
                            child: Text(I18n.t('no_messages')))
                        : GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              setState(() {
                                if (messages.isNotEmpty) {
                                  _singleViewIndex =
                                      _singleViewIndex == messages.length - 1
                                          ? _singleViewIndex
                                          : _singleViewIndex + 1;
                                  if (messages[_singleViewIndex].type ==
                                      Message.image) {
                                    // change background
                                    backgroundImage = DecorationImage(
                                      image: NetworkImage(
                                          messages[_singleViewIndex].message),
                                      fit: BoxFit.cover,
                                      colorFilter: ColorFilter.mode(
                                        Colors.white.withOpacity(0.8),
                                        BlendMode.dstATop,
                                      ),
                                    );
                                    // skip image
                                    _singleViewIndex =
                                        _singleViewIndex == messages.length - 1
                                            ? _singleViewIndex - 1
                                            : _singleViewIndex + 1;
                                  }
                                }
                              });
                            },
                            onLongPress: () {
                              setState(() {
                                _isListViewMode = true;
                              });
                              // 17.10：退出 singleView 时恢复持久化背景（之前临时设的 NetworkImage 可能已加载失败变灰）
                              unawaited(_restoreBackgroundForCurrentStudent());
                            },
                            child: Column(children: [
                              const Spacer(),
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: SingleChildScrollView(
                                  child: Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: ChatElement(
                                      message:
                                          messages[_singleViewIndex].message,
                                      type: messages[_singleViewIndex].type,
                                      userName: userName,
                                      stuName: studentName,
                                    ),
                                  ),
                                ),
                              ),
                            ]))),
              ),
              // 折叠/展开输入栏按钮（backlog时用暗色背景）
              Container(
                padding: EdgeInsets.zero,
                color: _isListViewMode
                    ? Colors.black.withOpacity(0.3)
                    : Colors.transparent,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(_showInputBar
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_up),
                      color: accentBlue,
                      onPressed: () {
                        setState(() {
                          _showInputBar = !_showInputBar;
                          if (_showInputBar) {
                            FocusScope.of(context).requestFocus(fn);
                          } else {
                            _isToolsExpanded = false;
                          }
                        });
                      },
                    ),
                  ],
                ),
              ),
              // 输入栏（折叠时全部隐藏）
              Container(
                padding:
                    _showInputBar ? const EdgeInsets.all(8.0) : EdgeInsets.zero,
                color: _showInputBar
                    ? Theme.of(context).colorScheme.surfaceBright
                    : Colors.transparent,
                child: _showInputBar
                    ? Row(
                        children: [
                          // text input field
                          Expanded(
                              child: TextField(
                                  focusNode: fn,
                                  controller: textController,
                                  onEditingComplete: () {
                                    if (textController.text.isEmpty &&
                                        userMsg.isNotEmpty) {
                                      sendMsg(true);
                                    } else if (textController.text.isNotEmpty) {
                                      sendMsg(false);
                                    }
                                  },
                                  decoration: InputDecoration(
                                    border: const OutlineInputBorder(),
                                    isCollapsed: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    hintText: inputLock
                                        ? I18n.t('replying')
                                        : I18n.t('enter_message'),
                                  ))),
                          const SizedBox(width: 5),
                          // tools button
                          IconButton(
                            onPressed: () {
                              setState(() {
                                _isToolsExpanded = !_isToolsExpanded;
                              });
                            },
                            icon: const Icon(Icons.add_circle),
                            color: accentBlue,
                          ),
                          const SizedBox(width: 5),
                          // send button
                          IconButton(
                            onPressed: () => sendMsg(true),
                            icon: const Icon(Icons.send),
                            color: accentBlue,
                          )
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
              // 工具栏展开区域
              // 原顶部菜单三项（保存聊天/提取聊天/新聊天）随 AppBar 移除一并收口到这里；
              // 固定两行 3+3 布局（上行：自动背景/自动发声/全屏，下行：聊天三项）
              if (_isToolsExpanded)
                Container(
                  padding: const EdgeInsets.all(8.0),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceBright,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          // 15.1/14.14：自动背景开关（开启态视觉强调：实心图标着色 + 文字标注开/关）
                          _buildToolButton(
                            icon: _isAutoBackground
                                ? Icons.wallpaper
                                : Icons.wallpaper_outlined,
                            label:
                                "${I18n.t('auto_background')}：${I18n.t(_isAutoBackground ? 'on' : 'off')}",
                            highlighted: _isAutoBackground,
                            onTap: () {
                              setState(() {
                                _isAutoBackground = !_isAutoBackground;
                                _isToolsExpanded = false;
                              });
                              setAutoBackground(_isAutoBackground);
                            },
                          ),
                          _buildToolButton(
                            icon: _isAutoVoice
                                ? Icons.volume_up
                                : Icons.volume_off,
                            label:
                                "${I18n.t('auto_voice')}：${I18n.t(_isAutoVoice ? 'on' : 'off')}",
                            highlighted: _isAutoVoice,
                            onTap: () {
                              setState(() {
                                _isAutoVoice = !_isAutoVoice;
                                _isToolsExpanded = false;
                              });
                              setAutoVoice(_isAutoVoice);
                              // 关闭自动发声时立即停止当前播放
                              if (!_isAutoVoice) {
                                unawaited(stopAudio());
                              }
                            },
                          ),
                          // Fullscreen button
                          _buildToolButton(
                            icon: _isFullScreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                            label: _isFullScreen
                                ? I18n.t('exit_fullscreen')
                                : I18n.t('enter_fullscreen'),
                            onTap: () {
                              setState(() {
                                _isFullScreen = !_isFullScreen;
                                _isToolsExpanded = false; // 点击后收起工具栏
                              });
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          // 16.6 原顶部菜单三项收口到 + 菜单
                          _buildToolButton(
                            icon: Icons.save,
                            label: I18n.t('menu_save_chat'),
                            onTap: () {
                              setState(() => _isToolsExpanded = false);
                              _showSaveChatDialog();
                            },
                          ),
                          _buildToolButton(
                            icon: Icons.folder_open,
                            label: I18n.t('menu_load_chat'),
                            onTap: () {
                              setState(() => _isToolsExpanded = false);
                              _showLoadChatDialog();
                            },
                          ),
                          _buildToolButton(
                            icon: Icons.refresh,
                            label: I18n.t('menu_new_chat'),
                            onTap: () {
                              setState(() => _isToolsExpanded = false);
                              _confirmNewChat();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
            ),
          ),
        ),
      ),
    );
  }

  /// 工具栏按钮（15.1：highlighted=true 时开启态视觉强调——实心图标着主题色，
  /// 关闭态灰色描边图标；文字标注开关状态）
  Widget _buildToolButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool highlighted = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: highlighted
                  ? primaryBlue
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: highlighted ? Border.all(color: primaryBlue, width: 2) : null,
            ),
            child: Icon(
              icon,
              color: highlighted ? Colors.white : Theme.of(context).colorScheme.onSurfaceVariant,
              size: 20,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: highlighted ? FontWeight.bold : FontWeight.normal,
              color: highlighted
                  ? primaryBlue
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 15.4 新增故事：输入名称 → 纯文本编辑框书写故事背景 → 保存
  void _showAddStoryDialog() {
    final nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(I18n.t('add_story')),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: I18n.t('story_name'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(I18n.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                snackBarAlert(context, I18n.t('story_name_empty'));
                return;
              }
              Navigator.pop(context);
              _editNewStory(name);
            },
            child: Text(I18n.t('confirm')),
          ),
        ],
      ),
    );
  }

  /// 15.4 打开纯文本编辑器编辑新故事，返回后包装为单条 system Message 保存
  Future<void> _editNewStory(String name) async {
    final text = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StoryTextEditor(title: name),
      ),
    );
    if (text is String && text.isNotEmpty) {
      final msgs = [Message(message: text, type: Message.system)];
      await addHistory(msgListToJson(msgs), name);
      await _refreshHistoryList();
      if (mounted) snackBarAlert(context, I18n.t('story_saved'));
    }
  }

  // 分离故事页面
  Widget _buildStoryPage() {
    return Scaffold(
      appBar: AppBar(
        title: Text(I18n.t('story_list'),
            style: const TextStyle(color: Colors.white)),
        flexibleSpace: Container(
          decoration: const BoxDecoration(color: primaryBlue),
        ),
      ),
      body: Column(
        children: [
          ListTile(
            title: Text(I18n.t('story_operations'),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey)),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // 15.4 新增故事：纯文本编辑框书写后保存
                // （故事导入/导出已收口局域网网页，App 内不再提供——15.5）
                ElevatedButton.icon(
                  icon: const Icon(Icons.add),
                  label: Text(I18n.t('add_story')),
                  onPressed: () => _showAddStoryDialog(),
                ),
              ],
            ),
          ),
          const Divider(),
          if (currentStory != null) ...[
            ListTile(
              title: Text(I18n.t('current_story'),
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey)),
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12.0),
                ),
                child: ListTile(
                  leading: const Icon(Icons.book, color: primaryBlue),
                  title: Text(currentStory![0]),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 15.5：生成背景图（LLM 总结故事 → 万相文生图 9:16 → 设为当前背景）
                      IconButton(
                        icon: _isDrawing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.auto_awesome),
                        tooltip: I18n.t('generate_story_bg'),
                        onPressed: _isDrawing ? null : _generateStoryBackground,
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          setState(() {
                            _invalidateConversation();
                            currentStory = null;
                          });
                          snackBarAlert(context, I18n.t('story_unloaded'));
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(),
          ],
          ListTile(
            title: Text(I18n.t('story_pool'),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey)),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              itemCount: historys.length,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16.0, vertical: 4.0),
                  child: Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12.0),
                    ),
                    child: PopupMenuTheme(
                      data: PopupMenuThemeData(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12.0),
                        ),
                      ),
                      child: ListTile(
                        leading: const Icon(Icons.book),
                        title: Text(getTimeStr(int.parse(historys[index][1]))),
                        subtitle: Text(historys[index][0]),
                        onTap: () {
                          setState(() {
                            _invalidateConversation();
                            currentStory = historys[index];
                          });
                          snackBarAlert(
                              context,
                              I18n.t('set_as_current_story')
                                  .replaceFirst('...', historys[index][0]));
                        },
                        onLongPress: () {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(historys[index][0]),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    leading: const Icon(Icons.download),
                                    title: Text(I18n.t('load_into_chat')),
                                    onTap: () {
                                      Navigator.pop(context);
                                      loadHistory(historys[index][2]);
                                      setState(() {
                                        _currentIndex =
                                            0; // Switch to chat page
                                      });
                                    },
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.edit),
                                    title: Text(I18n.t('edit')),
                                    onTap: () {
                                      Navigator.pop(context);
                                      // 15.4：改用纯文本编辑框，回填取消息列表全部文本按 \n 连接
                                      List<Message> storyMsgs =
                                          jsonToMsg(historys[index][2]);
                                      final initialText = storyMsgs
                                          .map((m) => m.message)
                                          .join('\n');
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              StoryTextEditor(
                                            title: historys[index][0],
                                            initialText: initialText,
                                          ),
                                        ),
                                      ).then((text) async {
                                        if (text is String &&
                                            text.isNotEmpty) {
                                          final msgs = [
                                            Message(
                                                message: text,
                                                type: Message.system)
                                          ];
                                          await deleteHistory(
                                              "history_${historys[index][1]}");
                                          await addHistory(
                                              msgListToJson(msgs),
                                              historys[index][0]);
                                          await _refreshHistoryList();
                                        }
                                      });
                                    },
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.delete),
                                    title: Text(I18n.t('delete')),
                                    onTap: () {
                                      Navigator.pop(context);
                                      showDialog(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: Text(I18n.t('delete_story')),
                                          content: Text(
                                              I18n.t('delete_story_confirm')),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              child: Text(I18n.t('cancel')),
                                            ),
                                            TextButton(
                                              onPressed: () async {
                                                final story = List<String>.from(
                                                    historys[index]);
                                                await deleteHistory(
                                                    "history_${story[1]}");
                                                if (!mounted) return;
                                                setState(() {
                                                  if (currentStory != null &&
                                                      currentStory![1] ==
                                                          story[1]) {
                                                    _invalidateConversation();
                                                    currentStory = null;
                                                  }
                                                  historys.removeWhere((item) =>
                                                      item[1] == story[1]);
                                                });
                                                Navigator.pop(context);
                                              },
                                              child: Text(I18n.t('delete')),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // 分离角色页面
  Widget _buildStudentsPage() {
    ImageProvider getAvatarImage(String avatar) {
      if (_avatarImageCache.containsKey(avatar)) {
        return _avatarImageCache[avatar]!;
      }
      final ImageProvider imageProvider;
      if (avatar.isNotEmpty && avatar.startsWith('http')) {
        imageProvider = NetworkImage(avatar);
      } else if (avatar.startsWith('data:image/')) {
        imageProvider = MemoryImage(base64Decode(avatar.split(',')[1]));
      } else {
        imageProvider = const AssetImage("assets/avatar.png");
      }
      _avatarImageCache[avatar] = imageProvider;
      return imageProvider;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(I18n.t('character_list'),
            style: const TextStyle(color: Colors.white)),
        flexibleSpace: Container(
          decoration: const BoxDecoration(color: primaryBlue),
        ),
      ),
      // 16.11：新增角色入口（右下角 FAB，跳转新增角色表单）
      floatingActionButton: FloatingActionButton(
        heroTag: 'add_character_fab',
        backgroundColor: primaryBlue,
        foregroundColor: Colors.white,
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const PromptEditor(isNewCharacter: true),
            ),
          ).then((_) {
            // 18.2：新增角色只入池不切换当前角色，返回后无需 clearMsg
            // （当前角色态不变，仅刷新角色列表）
            getStudents().then((List<List<String>> results) {
              if (!mounted) return;
              setState(() {
                students = results;
                students.sort((a, b) => a[0].compareTo(b[0]));
              });
            });
          });
        },
        child: const Icon(Icons.add_circle),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        children: [
          ListTile(
            title: Text(I18n.t('character_operations'),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                    icon: const Icon(Icons.file_upload),
                    label: Text(I18n.t(
                        kIsWeb ? 'import_character' : 'web_import_character')),
                    onPressed: () async {
                      // 19.7：io 平台统一走局域网网页导入（上传/入池/enrollment
                      // 均在配置服务内完成）；Web 保留原 file_picker 路径
                      if (!kIsWeb) {
                        await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const LanConfigPage(
                                    forCharacterImport: true)));
                        // 第二十四章：角色导入页与密钥配置共用服务，保险刷新
                        await _reloadCurrentConfig();
                        if (mounted) {
                          // 刷新角色池列表（当前角色不变，不 clearMsg）
                          getStudents().then((List<List<String>> results) {
                            if (!mounted) return;
                            setState(() {
                              students = results;
                              students.sort((a, b) => a[0].compareTo(b[0]));
                            });
                          });
                        }
                        return;
                      }
                      // 18.2 / 18.6：导入角色卡 → 入池（不切换当前角色）
                      // try/finally 确保任何异常都能关闭加载对话框（防卡死）
                      showDialog(
                        context: context,
                        barrierDismissible: false,
                        builder: (BuildContext context) {
                          return AlertDialog(
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                const SizedBox(height: 16),
                                Text(I18n.t('importing_character')),
                              ],
                            ),
                          );
                        },
                      );
                      String? newStudentKey;
                      try {
                        newStudentKey = await loadCharacterCard(context);
                        // 导入后处理：角色卡带 voice_url / voice_prompt /
                        // appearance_prompt 时自动 enrollment（voice_id/refImage
                        // 直接写入新池记录，不经过工作态）
                        if (newStudentKey != null) {
                          final voiceUrl = await getStudentFieldByKey(
                              newStudentKey, 16);
                          final voicePrompt = await getStudentFieldByKey(
                              newStudentKey, 17);
                          final appearancePrompt = await getStudentFieldByKey(
                              newStudentKey, 18);
                          if (voiceUrl.isNotEmpty ||
                              voicePrompt.isNotEmpty ||
                              appearancePrompt.isNotEmpty) {
                            if (mounted) {
                              snackBarAlert(
                                  context, I18n.t('voice_enrolling'));
                            }
                            await enrollImportedCharacter(
                              studentKey: newStudentKey,
                              voiceUrl: voiceUrl.isNotEmpty ? voiceUrl : null,
                              voicePrompt:
                                  voicePrompt.isNotEmpty ? voicePrompt : null,
                              appearancePrompt: appearancePrompt.isNotEmpty
                                  ? appearancePrompt
                                  : null,
                              roleName: await getStudentFieldByKey(
                                  newStudentKey, 0),
                            );
                          }
                        }
                      } catch (e) {
                        debugPrint('import character failed: $e');
                        if (mounted) {
                          snackBarAlert(context, '导入失败：$e');
                        }
                      } finally {
                        if (context.mounted) Navigator.pop(context);
                      }
                      // 刷新角色池列表（当前角色不变，不 clearMsg）
                      if (mounted) {
                        getStudents().then((List<List<String>> results) {
                          if (!mounted) return;
                          setState(() {
                            students = results;
                            students.sort((a, b) => a[0].compareTo(b[0]));
                          });
                        });
                        if (newStudentKey != null) {
                          snackBarAlert(context, '角色已加入角色池');
                        }
                      }
                    }),
                // （角色导出已收口局域网网页卡片⑥，App 内不再提供——15.6）
              ],
            ),
          ),
          const Divider(),
          ListTile(
            title: Text(I18n.t('current_character'),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey)),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            child: Card(
              elevation: 2,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0),
              ),
              child: Container(
                decoration: BoxDecoration(
                  image: DecorationImage(
                    image: getAvatarImage(avatar),
                    fit: BoxFit.cover,
                    colorFilter: ColorFilter.mode(
                        Colors.black.withOpacity(0.4), BlendMode.darken),
                  ),
                ),
                child: ListTile(
                  title: Text(studentName,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    messages.isNotEmpty ? messages.first.message : "",
                    style: const TextStyle(color: Colors.white70),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Edit Prompt
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.white),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const PromptEditor(),
                            ),
                          ).then((_) {
                            clearMsg(false);
                            getStudents().then((List<List<String>> results) {
                              setState(() {
                                students = results;
                                students.sort((a, b) => a[0].compareTo(b[0]));
                              });
                            });
                          });
                        },
                      ),
                      // Save Character
                      IconButton(
                        icon: const Icon(Icons.save_as, color: Colors.white),
                        onPressed: () async {
                          // 18.2：保存当前角色到角色池（全字段）
                          addStudent(
                            studentName,
                            avatar,
                            await getOriginalMsg(),
                            await getPrompt(),
                            await getDrawCharPrompt(),
                            voiceId: await getVoiceId(),
                            refImage: await getRefImage(),
                            voiceRefUrl: await getVoiceRefUrl(),
                            bgImages: (await getBgImages()).join(','),
                            personality: await getPersonalityRaw(),
                            voiceModel: await getVoiceModel(),
                            voiceUrl: await getVoiceUrl(),
                            voicePrompt: await getVoicePrompt(),
                            appearancePrompt: await getAppearancePrompt(),
                            chatBackground: await getChatBackground(),
                          );
                          if (mounted) {
                            snackBarAlert(context, '已保存到角色池');
                            getStudents().then((List<List<String>> results) {
                              if (!mounted) return;
                              setState(() {
                                students = results;
                                students.sort((a, b) => a[0].compareTo(b[0]));
                              });
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Divider(),
          ListTile(
            title: Text(I18n.t('character_pool'),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey)),
          ),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: students.length,
            itemBuilder: (context, index) {
              final studentAvatar = students[index][1];
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                child: Card(
                  elevation: 2,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12.0),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      image: DecorationImage(
                        image: getAvatarImage(studentAvatar),
                        fit: BoxFit.cover,
                        colorFilter: ColorFilter.mode(
                            Colors.black.withOpacity(0.4), BlendMode.darken),
                      ),
                    ),
                    child: ListTile(
                      title: Text(students[index][0],
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                      subtitle: Text(
                        students[index][2],
                        style: const TextStyle(color: Colors.white70),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () async {
                        final student = List<String>.from(students[index]);
                        final operation = ++_characterSwitchOperation;
                        _characterSwitchWrite =
                            _characterSwitchWrite.catchError((Object error) {
                          debugPrint(
                              'Previous character switch failed: $error');
                        }).then((_) async {
                          if (operation != _characterSwitchOperation) {
                            return;
                          }
                          await Future.wait<void>([
                            setStudentName(student[0]),
                            setAvatar(student[1]),
                            setOriginalMsg(student[2]),
                            setPrompt(student[3]),
                            setDrawCharPrompt(student[5]),
                            setVoiceId(student[6]),
                            setRefImage(student[7]),
                            setVoiceRefUrl(student[9]),
                            setVoiceModel(student[15]), // 15.16.1：角色级 TTS 模型
                            setPersonality(student[14]), // 15.17：角色性格
                            setChatBackground(student.length > 13 ? student[13] : ''), // 18.2：角色背景
                            setVoiceUrl(student.length > 16 ? student[16] : ''), // 18.x：声音复刻 URL
                            setVoicePrompt(student.length > 17 ? student[17] : ''), // 18.x：声音设计描述
                            setAppearancePrompt(student.length > 18 ? student[18] : ''), // 18.x：样貌描述
                          ]);
                          if (!mounted ||
                              operation != _characterSwitchOperation) {
                            return;
                          }
                          await clearMsg(true);
                          if (!mounted ||
                              operation != _characterSwitchOperation) {
                            return;
                          }
                          setState(() {
                            _currentIndex = 0; // Switch to chat page
                          });
                        });
                        await _characterSwitchWrite;
                      },
                      onLongPress: () => showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(I18n.t('delete_character')),
                          content: Text(I18n.t('delete_character_confirm')),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(I18n.t('cancel')),
                            ),
                            TextButton(
                              onPressed: () async {
                                final key =
                                    "student_${students[index][4]}_${students[index][0]}";
                                await deleteStudent(key);
                                if (!mounted) return;
                                setState(() {
                                  students.removeWhere((student) =>
                                      "student_${student[4]}_${student[0]}" ==
                                      key);
                                });
                                Navigator.pop(context);
                              },
                              child: Text(I18n.t('delete')),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // Settings page
  Widget _buildSettingsPage() {
    return Scaffold(
      appBar: AppBar(
        title: Text(I18n.t('settings'),
            style: const TextStyle(color: Colors.white)),
        flexibleSpace: Container(
          decoration: const BoxDecoration(color: primaryBlue),
        ),
        actions: [
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (context, mode, child) {
              final isDark = mode == ThemeMode.dark ||
                  (mode == ThemeMode.system &&
                      MediaQuery.platformBrightnessOf(context) ==
                          Brightness.dark);
              return IconButton(
                icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
                color: Colors.white,
                tooltip: isDark ? I18n.t('light_mode') : I18n.t('dark_mode'),
                onPressed: () {
                  final newMode = isDark ? ThemeMode.light : ThemeMode.dark;
                  themeModeNotifier.value = newMode;
                  SharedPreferences.getInstance().then((prefs) {
                    prefs.setString('theme_mode',
                        newMode == ThemeMode.light ? 'light' : 'dark');
                  });
                },
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        children: [
          ListTile(
            title: Text(I18n.t('general_settings'),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey)),
          ),
          const SizedBox(height: 8),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0)),
            child: ListTile(
              leading: const Icon(Icons.backup),
              title: Text(I18n.t('backup_config')),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => BackupPage(
                      currentMessages: msgListToJson(messages),
                      onConfigRestored: reloadApplicationAfterRestore,
                      onRefresh: (String jsonString) {
                        setState(() {
                          _invalidateConversation();
                          messages.clear();
                          messages.addAll(jsonToMsg(jsonString));
                        });
                        unawaited(_saveTempHistory());
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0)),
            child: ListTile(
              leading: const Icon(Icons.settings),
              title: Text(I18n.t('model_config')),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ConfigPage(
                        updateFunc: updateConfig, currentConfig: config),
                  ),
                );
                // 第二十四章：设置页内网页保存三要素后刷新（绕过 updateFunc 回调）
                await _reloadCurrentConfig();
              },
            ),
          ),
          const SizedBox(height: 8),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0)),
            child: ListTile(
              leading: const Icon(Icons.person),
              title: Text(I18n.t('my_profile')),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const UserProfilePage()),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0)),
            child: ListTile(
              leading: const Icon(Icons.format_shapes),
              title: Text(I18n.t('format_config')),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const FormatConfigPage(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0)),
            child: ListTile(
              leading: const Icon(Icons.display_settings),
              title: Text(I18n.t('display_settings')),
              onTap: () {
                _showDisplaySettings();
              },
            ),
          ),
          ListTile(
            title: Text(I18n.t('about'),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey)),
          ),
          const SizedBox(height: 8),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0)),
            child: ListTile(
              leading: const Icon(Icons.info),
              title: Text(I18n.t('about')),
              onTap: () async {
                // 14.x 设备模式：预读开关状态（开启时关于弹窗常显开关行，便于关闭）
                final bool dmEnabled = await DeviceMode.isEnabled();
                final SharedPreferences dmPrefs =
                    await SharedPreferences.getInstance();
                bool dmGuideShown =
                    dmPrefs.getBool('device_mode_guide_shown') ?? false;
                int dmTaps = 0;
                bool dmUnlocked = false;
                bool dmOn = dmEnabled;
                if (!mounted) return;
                showDialog(
                  context: context,
                  builder: (context) => StatefulBuilder(
                    builder: (context, setDialogState) => AlertDialog(
                      title: Text(I18n.t('about')),
                      content: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(I18n.t('about_text')),
                            const SizedBox(height: 16),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8.0),
                              child: Image.asset(
                                'assets/wechat_qr.jpg',
                                width: 200,
                                height: 200,
                                fit: BoxFit.cover,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              I18n.t('author_wechat'),
                              style: const TextStyle(
                                  fontSize: 13, color: Colors.grey),
                            ),
                            const SizedBox(height: 16),
                            // 14.x 隐藏入口：仅 Android，连点介绍文字 7 次解锁设备模式开关
                            if (DeviceMode.isSupported)
                              GestureDetector(
                                onTap: () {
                                  dmTaps++;
                                  if (dmTaps >= 7 && !dmUnlocked) {
                                    setDialogState(() => dmUnlocked = true);
                                  }
                                },
                                child: const Text(
                                  '提供角色人物复刻、减脂搭子、健身搭子、瑜伽搭子、育儿搭子、亲密搭子等。',
                                  style: TextStyle(fontSize: 13),
                                  textAlign: TextAlign.center,
                                ),
                              )
                            else
                              const Text(
                                '提供角色人物复刻、减脂搭子、健身搭子、瑜伽搭子、育儿搭子、亲密搭子等。',
                                style: TextStyle(fontSize: 13),
                                textAlign: TextAlign.center,
                              ),
                            // 开关行：仅连点 7 次解锁后显示（与开关状态无关，
                            // 关闭已开启的模式也需再次解锁，确保普通用户永远看不到）
                            if (DeviceMode.isSupported && dmUnlocked) ...[
                              const Divider(height: 24),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(I18n.t('device_mode_title')),
                                subtitle: Text(
                                  I18n.t('device_mode_subtitle'),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                value: dmOn,
                                onChanged: (v) async {
                                  final ok = await DeviceMode.setEnabled(v);
                                  if (!ok) return;
                                  setDialogState(() => dmOn = v);
                                  // 首次开启弹一次性须知
                                  if (v && !dmGuideShown) {
                                    dmGuideShown = true;
                                    await dmPrefs.setBool(
                                        'device_mode_guide_shown', true);
                                    if (!context.mounted) return;
                                    showDialog(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: Text(
                                            I18n.t('device_mode_guide_title')),
                                        content: SingleChildScrollView(
                                          child: Text(
                                              I18n.t('device_mode_guide_body')),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            child: const Text('OK'),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget currentPage;
    switch (_currentIndex) {
      case 0:
        currentPage = _buildChatPage();
        break;
      case 1:
        currentPage = _buildStoryPage();
        break;
      case 2:
        currentPage = _buildStudentsPage();
        break;
      case 3:
        currentPage = _buildSettingsPage();
        break;
      default:
        currentPage = _buildChatPage();
    }

    return Scaffold(
      body: currentPage,
      bottomNavigationBar: _isFullScreen
          ? null
          : BottomNavigationBar(
              currentIndex: _currentIndex,
              onTap: (index) {
                setState(() {
                  _currentIndex = index;
                });
                if (index == 1) unawaited(_refreshHistoryList());
                if (index == 2) unawaited(_refreshStudentList());
              },
              type: BottomNavigationBarType.fixed,
              selectedItemColor: primaryBlue,
              unselectedItemColor: Colors.grey,
              items: [
                BottomNavigationBarItem(
                  icon: const Icon(Icons.chat),
                  label: I18n.t('chat'),
                ),
                BottomNavigationBarItem(
                  icon: const Icon(Icons.book),
                  label: I18n.t('story'),
                ),
                BottomNavigationBarItem(
                  icon: const Icon(Icons.people),
                  label: I18n.t('role'),
                ),
                BottomNavigationBarItem(
                  icon: const Icon(Icons.settings),
                  label: I18n.t('settings'),
                ),
              ],
            ),
    );
  }
}
