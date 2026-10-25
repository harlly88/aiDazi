import 'dart:async';
import 'dart:convert';
import 'package:eventflux/eventflux.dart';
import 'secure_key_store.dart';
import 'utils.dart' show Config;

String removeTailSlash(String input) {
  return input.trimRight().endsWith('/')
      ? input.trimRight().substring(0, input.trimRight().length - 1)
      : input.trimRight();
}

Future<void> completion(Config config, List<List<String>> message,
    Function onEevent, Function onDone, Function onErr) async {
  Map<String, dynamic> data = {
    'model': config.model,
    'messages': message
        .asMap()
        .map((index, e) {
          return MapEntry(index, {'role': e[0], 'content': e[1]});
        })
        .values
        .toList(),
    'stream': true,
    if (config.temperature != null &&
        double.tryParse(config.temperature!) != null)
      'temperature': double.parse(config.temperature!),
    if (config.frequencyPenalty != null &&
        double.tryParse(config.frequencyPenalty!) != null)
      'frequency_penalty': double.parse(config.frequencyPenalty!),
    if (config.presencePenalty != null &&
        double.tryParse(config.presencePenalty!) != null)
      'presence_penalty': double.parse(config.presencePenalty!),
    if (config.maxTokens != null && int.tryParse(config.maxTokens!) != null)
      'max_tokens': int.parse(config.maxTokens!),
  };
  // EventFlux.instance owns only one client, controller and subscription. Using
  // it for overlapping chat, inspire and draw requests makes those streams
  // overwrite each other's state. Give every completion its own SSE client.
  final eventFlux = EventFlux.spawn();
  final terminal = Completer<void>();
  bool finished = false;
  void safeDone() {
    if (!finished) {
      finished = true;
      try {
        onDone();
      } finally {
        unawaited(eventFlux.disconnect());
        if (!terminal.isCompleted) terminal.complete();
      }
    }
  }

  void safeErr(dynamic err) {
    if (!finished) {
      finished = true;
      try {
        onErr(err);
      } finally {
        unawaited(eventFlux.disconnect());
        if (!terminal.isCompleted) terminal.complete();
      }
    }
  }

  try {
    // 19.3：LLM 密钥改读独立槽位 key_llm_{name}（io 加密存储；Web 回落 config.apiKey）
    final apiKey = await getLlmApiKey(config);
    if (apiKey == null || apiKey.isEmpty) {
      safeErr(keyNotSetError('文字'));
      return;
    }
    eventFlux.connect(EventFluxConnectionType.post,
        "${removeTailSlash(config.baseUrl)}/chat/completions",
        header: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: data,
        onSuccessCallback: (EventFluxResponse? response) {
          final stream = response?.stream;
          if (stream == null) {
            safeErr('The server returned no response stream');
            return;
          }
          stream.listen((data) {
            try {
              final content =
                  json.decode(data.data)["choices"][0]["delta"]["content"];
              if (content != null) {
                onEevent(content);
              }
            } catch (e) {
              if (data.data.contains("DONE")) {
                safeDone();
              } else if (e is FormatException) {
                safeErr("Unexpected response: \n${data.data}");
              }
            }
          }, onDone: () {
            safeDone();
          }, onError: (e) {
            safeErr(e.toString());
          });
        },
        onError: (oops) => safeErr(oops.message));
  } catch (error) {
    safeErr(error);
  }

  await terminal.future;
}

Future<String> collectCompletion(
    Config config, List<List<String>> messages) async {
  final result = StringBuffer();
  Object? requestError;

  await completion(
    config,
    messages,
    (String chunk) => result.write(chunk),
    () {},
    (dynamic error) => requestError = error,
  );

  if (requestError != null) throw requestError!;
  return result.toString();
}
