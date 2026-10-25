// 19.5：局域网配置条件导出壳（模式与原 voice_input.dart 相同）
// io 平台（Android / iOS / 桌面）导出真实 HttpServer 实现；Web 导出空实现
export 'lan_server_stub.dart' if (dart.library.io) 'lan_server.dart';
