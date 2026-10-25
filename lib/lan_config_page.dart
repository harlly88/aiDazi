import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'app_theme.dart' show accentBlue, primaryBlue;
import 'i18n.dart';
import 'lan_config.dart';

/// 19.7：局域网配置页（设置「网页配置」与角色导入共用一个页面）
///
/// 状态机：启动中 → 运行中（大号等宽地址 + 点击复制）→ 已保存（2 秒自动返回）
/// / 超时 / 启动失败（明确错误文案）。
/// 密钥保存成功 → 服务自动关闭 → 展示结果摘要后返回；
/// 角色导入 → 服务保持开启（网页可连续导入），页面实时显示已导入角色。
/// dispose → 服务 close()。
class LanConfigPage extends StatefulWidget {
  const LanConfigPage({super.key, this.forCharacterImport = false});

  /// true = 从角色菜单进入（提示语侧重「上传角色卡」）
  final bool forCharacterImport;

  @override
  State<LanConfigPage> createState() => _LanConfigPageState();
}

class _LanConfigPageState extends State<LanConfigPage> {
  final LanConfigServer _server = LanConfigServer();
  String? _address; // 形如 192.168.x.x:8888
  String? _error; // 启动失败 / 超时文案
  bool _saved = false;
  List<String> _savedSlots = [];
  final List<String> _importedNames = [];
  Timer? _autoPopTimer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final addr = await _server.start(onEvent: _onEvent);
      if (!mounted) return;
      setState(() => _address = addr);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    }
  }

  void _onEvent(LanEvent event) {
    if (!mounted) return;
    if (event is LanKeysSaved) {
      setState(() {
        _saved = true;
        _savedSlots = event.slots;
      });
      _autoPopTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) Navigator.pop(context);
      });
    } else if (event is LanCharacterImported) {
      setState(() => _importedNames.add(event.name));
    } else if (event is LanIdleTimeout) {
      setState(() => _error = I18n.t('lan_config_timeout'));
    }
  }

  @override
  void dispose() {
    _autoPopTimer?.cancel();
    unawaited(_server.close());
    super.dispose();
  }

  Future<void> _copyAddress() async {
    await Clipboard.setData(ClipboardData(text: 'http://$_address'));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已复制')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isImport = widget.forCharacterImport;
    return Scaffold(
      appBar: AppBar(
        title: Text(I18n.t(isImport ? 'web_import_character' : 'lan_config_title')),
        backgroundColor: primaryBlue,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  I18n.t('lan_config_lan_only'),
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                const SizedBox(height: 24),
                if (_error != null) ...[
                  const Icon(Icons.wifi_off, size: 56, color: Colors.redAccent),
                  const SizedBox(height: 16),
                  Text('${I18n.t('lan_config_start_fail')}\n$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 15)),
                ] else if (_saved) ...[
                  const Icon(Icons.check_circle,
                      size: 56, color: Colors.green),
                  const SizedBox(height: 16),
                  Text(I18n.t('lan_config_saved'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  if (_savedSlots.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_savedSlots.join('、'),
                        style: TextStyle(
                            fontSize: 13, color: Colors.grey[600])),
                  ],
                ] else if (_address == null) ...[
                  const CircularProgressIndicator(color: primaryBlue),
                  const SizedBox(height: 16),
                  Text(I18n.t('lan_config_waiting'),
                      style: const TextStyle(fontSize: 15)),
                ] else ...[
                  Icon(
                      isImport
                          ? Icons.upload_file
                          : Icons.settings_remote,
                      size: 56,
                      color: accentBlue),
                  const SizedBox(height: 16),
                  Text(I18n.t('lan_config_url_hint'),
                      style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 16),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: _copyAddress,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: primaryBlue, width: 1.5),
                      ),
                      child: SelectableText(
                        'http://$_address',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                          color: primaryBlue,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _copyAddress,
                    icon: const Icon(Icons.copy, size: 16),
                    label: Text(I18n.t('lan_config_copy')),
                  ),
                  const SizedBox(height: 16),
                  Text(I18n.t('lan_config_same_wifi'),
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey[600])),
                  const SizedBox(height: 4),
                  Text(
                      isImport
                          ? I18n.t('lan_config_close_hint')
                          : '${I18n.t('lan_config_close_hint')}（角色导入后保持开启，可连续导入）',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey[600])),
                  if (_importedNames.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Text('${I18n.t('lan_config_imported')}（${_importedNames.length}）',
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green)),
                          const SizedBox(height: 4),
                          Text(_importedNames.join('、'),
                              style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
