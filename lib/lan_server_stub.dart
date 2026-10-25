// 19.5：局域网配置服务（Web 空实现）
//
// Web 构建无 dart:io，不提供局域网配置服务；类型签名与 lan_server.dart 保持一致。
// 「网页配置」入口在 Web 端隐藏（agent.md 19.7 平台差异）。

sealed class LanEvent {}

class LanKeysSaved extends LanEvent {
  final List<String> slots;
  LanKeysSaved(this.slots);
}

class LanCharacterImported extends LanEvent {
  final String? studentKey;
  final String name;
  final List<String> warnings;
  LanCharacterImported(this.studentKey, this.name, this.warnings);
}

class LanIdleTimeout extends LanEvent {}

class LanConfigServer {
  Future<String> start({void Function(LanEvent event)? onEvent}) async {
    throw UnsupportedError('Web 平台不支持局域网配置服务');
  }

  Future<void> close() async {}
}
