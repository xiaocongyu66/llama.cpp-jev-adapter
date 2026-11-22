import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class GatewayKey {
  GatewayKey({required this.name, required this.secret, this.rpm = 60});
  final String name;
  final String secret;
  int rpm;
  bool enabled = true;
  int requests = 0;
  int inputTokens = 0;
  int outputTokens = 0;
  final List<DateTime> requestTimes = [];

  Map<String, Object> toJson() => {
        'name': name,
        'secret': secret,
        'rpm': rpm,
        'enabled': enabled,
        'requests': requests,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
      };

  static GatewayKey fromJson(Map<String, Object?> json) => GatewayKey(
        name: json['name']! as String,
        secret: json['secret']! as String,
        rpm: (json['rpm'] as num?)?.toInt() ?? 60,
      )
        ..enabled = json['enabled'] as bool? ?? true
        ..requests = (json['requests'] as num?)?.toInt() ?? 0
        ..inputTokens = (json['inputTokens'] as num?)?.toInt() ?? 0
        ..outputTokens = (json['outputTokens'] as num?)?.toInt() ?? 0;
}

class GatewayLog {
  const GatewayLog({
    required this.time,
    required this.keyName,
    required this.path,
    required this.status,
    required this.inputTokens,
    required this.outputTokens,
    required this.latencyMs,
  });

  final DateTime time;
  final String keyName;
  final String path;
  final int status;
  final int inputTokens;
  final int outputTokens;
  final int latencyMs;

  Map<String, Object> toJson() => {
        'time': time.toIso8601String(),
        'keyName': keyName,
        'path': path,
        'status': status,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'latencyMs': latencyMs,
      };

  static GatewayLog fromJson(Map<String, Object?> json) => GatewayLog(
        time: DateTime.parse(json['time']! as String),
        keyName: json['keyName']! as String,
        path: json['path']! as String,
        status: (json['status']! as num).toInt(),
        inputTokens: (json['inputTokens']! as num).toInt(),
        outputTokens: (json['outputTokens']! as num).toInt(),
        latencyMs: (json['latencyMs']! as num).toInt(),
      );
}

class ApiGateway {
  ApiGateway({required this.keys, required this.onLog}) : _client = HttpClient();

  final List<GatewayKey> keys;
  final void Function(GatewayLog log) onLog;
  final HttpClient _client;
  HttpServer? _server;
  Process? _engine;
  Uri? _upstream;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? 0;

  Future<void> launchEngine({
    required String executable,
    required String modelPath,
    required String backendArgs,
    int port = 8081,
  }) async {
    await stopEngine();
    final args = [
      '--model', modelPath,
      '--host', '127.0.0.1',
      '--port', '$port',
      ...backendArgs.split(RegExp(r'\s+')).where((arg) => arg.isNotEmpty),
    ];
    _engine = await Process.start(executable, args, runInShell: false);
    _engine!.stdout.listen((_) {});
    _engine!.stderr.listen((_) {});
    _upstream = Uri.parse('http://127.0.0.1:8081');
  }

  void setExternalEngine(int port) {
    _upstream = Uri.parse('http://127.0.0.1:$port');
  }

  Future<void> stopEngine() async {
    _engine?.kill();
    _engine = null;
    _upstream = null;
  }

  Future<void> start({int port = 8080}) async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    unawaited(_serve(_server!));
  }

  Future<void> stop({bool stopEngine = true}) async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    if (stopEngine) await this.stopEngine();
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final started = DateTime.now();
    final path = request.uri.path;
    if (request.method == 'OPTIONS') {
      request.response
        ..statusCode = HttpStatus.noContent
        ..headers.set('Access-Control-Allow-Origin', '*')
        ..headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        ..headers.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
      await request.response.close();
      return;
    }

    final token = _bearerToken(request.headers.value(HttpHeaders.authorizationHeader));
    final key = token == null ? null : _findKey(token);
    if (key == null || !key.enabled) {
      await _writeJson(request.response, HttpStatus.unauthorized, {'error': {'message': 'Invalid API key'}});
      onLog(GatewayLog(
        time: started,
        keyName: '未授权',
        path: path,
        status: HttpStatus.unauthorized,
        inputTokens: 0,
        outputTokens: 0,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
      ));
      return;
    }
    final now = DateTime.now();
    key.requestTimes.removeWhere((time) => now.difference(time) >= const Duration(minutes: 1));
    if (key.requestTimes.length >= key.rpm) {
      await _writeJson(request.response, HttpStatus.tooManyRequests, {'error': {'message': 'Rate limit exceeded'}});
      onLog(GatewayLog(
        time: started,
        keyName: key.name,
        path: path,
        status: HttpStatus.tooManyRequests,
        inputTokens: 0,
        outputTokens: 0,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
      ));
      return;
    }
    key.requestTimes.add(now);
    key.requests++;

    final upstream = _upstream;
    if (path == '/health') {
      await _writeJson(request.response, HttpStatus.ok, {'status': 'ok', 'engine': upstream != null});
      onLog(GatewayLog(time: started, keyName: key.name, path: path, status: HttpStatus.ok, inputTokens: 0, outputTokens: 0, latencyMs: DateTime.now().difference(started).inMilliseconds));
      return;
    }
    if (upstream == null || !(path == '/v1/chat/completions' || path == '/v1/completions' || path == '/v1/embeddings' || path == '/v1/systemone')) {
      await _writeJson(request.response, HttpStatus.serviceUnavailable, {'error': {'message': 'No model engine running'}});
      onLog(GatewayLog(time: started, keyName: key.name, path: path, status: HttpStatus.serviceUnavailable, inputTokens: 0, outputTokens: 0, latencyMs: DateTime.now().difference(started).inMilliseconds));
      return;
    }

    late HttpClientResponse upstreamResponse;
    try {
      final upstreamRequest = await _client.openUrl(request.method, upstream.resolve(path));
      request.headers.forEach((name, values) {
        if (name.toLowerCase() != HttpHeaders.hostHeader && name.toLowerCase() != HttpHeaders.authorizationHeader) {
          for (final value in values) {
            upstreamRequest.headers.add(name, value);
          }
        }
      });
      await request.listen(upstreamRequest.add).asFuture<void>();
      upstreamResponse = await upstreamRequest.close();
    } on SocketException catch (error) {
      await _writeJson(request.response, HttpStatus.badGateway, {'error': {'message': 'Model engine unavailable: $error'}});
      onLog(GatewayLog(time: started, keyName: key.name, path: path, status: HttpStatus.badGateway, inputTokens: 0, outputTokens: 0, latencyMs: DateTime.now().difference(started).inMilliseconds));
      return;
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in upstreamResponse) {
      body.add(chunk);
    }
    final bytes = body.takeBytes();
    request.response
      ..statusCode = upstreamResponse.statusCode
      ..headers.set('Access-Control-Allow-Origin', '*')
      ..headers.contentType = upstreamResponse.headers.contentType ?? ContentType.json
      ..add(bytes);
    await request.response.close();

    var inputTokens = 0;
    var outputTokens = 0;
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final usage = json['usage'] as Map<String, dynamic>?;
      inputTokens = (usage?['prompt_tokens'] ?? usage?['input_tokens'] ?? 0) as int;
      outputTokens = (usage?['completion_tokens'] ?? usage?['output_tokens'] ?? 0) as int;
    } catch (_) {}
    key.inputTokens += inputTokens;
    key.outputTokens += outputTokens;
    onLog(GatewayLog(
      time: started,
      keyName: key.name,
      path: path,
      status: upstreamResponse.statusCode,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      latencyMs: DateTime.now().difference(started).inMilliseconds,
    ));
  }

  GatewayKey? _findKey(String supplied) {
    final digest = sha256.convert(utf8.encode(supplied)).toString();
    for (final key in keys) {
      if (sha256.convert(utf8.encode(key.secret)).toString() == digest) return key;
    }
    return null;
  }

  String? _bearerToken(String? header) {
    if (header == null || !header.startsWith('Bearer ')) return null;
    return header.substring(7);
  }

  Future<void> _writeJson(HttpResponse response, int status, Object body) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..headers.set('Access-Control-Allow-Origin', '*')
      ..write(jsonEncode(body));
    await response.close();
  }

  Future<void> dispose() async {
    await stop();
    _client.close(force: true);
  }
}

Future<List<int>> consolidateHttpClientResponseBytes(HttpClientResponse response) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
