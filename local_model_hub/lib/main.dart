import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' as widgets;

import 'package:file_picker/file_picker.dart';
import 'package:dynamic_color/dynamic_color.dart' as dynamic_color;
import 'package:material_ui/material_ui.dart' as material;
import 'package:material_3_expressive/material_3_expressive.dart' as m3e;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_model_hub/api_gateway.dart';

void main() {
  widgets.runApp(const ModelHubApp());
}

class ModelHubApp extends material.StatelessWidget {
  const ModelHubApp({super.key});

  @override
  material.Widget build(material.BuildContext context) => dynamic_color.DynamicColorBuilder(
        builder: (lightDynamic, darkDynamic) {
          const fallbackSeed = material.Color(0xFF426B58);
          final lightScheme = lightDynamic ?? material.ColorScheme.fromSeed(seedColor: fallbackSeed);
          final darkScheme = darkDynamic ?? material.ColorScheme.fromSeed(seedColor: fallbackSeed, brightness: material.Brightness.dark);
          final themeData = m3e.M3EThemeData.light(seedColor: lightScheme.primary);
          final materialTheme = themeData.toThemeData().copyWith(
            colorScheme: lightScheme,
            scaffoldBackgroundColor: const material.Color(0xFFF6F7F4),
            cardTheme: material.CardThemeData(
              elevation: 0,
              color: lightScheme.surfaceContainerLow,
              shape: material.RoundedRectangleBorder(borderRadius: material.BorderRadius.circular(24)),
            ),
          );
          final darkMaterialTheme = themeData.deriveDarkTemplate().toThemeData().copyWith(
            colorScheme: darkScheme,
            cardTheme: material.CardThemeData(
              elevation: 0,
              color: darkScheme.surfaceContainerLow,
              shape: material.RoundedRectangleBorder(borderRadius: material.BorderRadius.circular(24)),
            ),
          );
          return m3e.M3EMaterialApp(
            title: '本地模型中心',
            debugShowCheckedModeBanner: false,
            data: themeData,
            autoTheming: true,
            dynamicColoring: lightDynamic != null || darkDynamic != null,
            theme: materialTheme,
            darkTheme: darkMaterialTheme,
            home: const HubShell(),
          );
        },
      );
}

enum HubPage { overview, models, keys, activity, settings }

class LocalModel {
  LocalModel({required this.name, required this.path, this.sizeLabel = '未知大小'});
  final String name;
  final String path;
  final String sizeLabel;
  bool loaded = false;
}

class HubState extends material.ChangeNotifier {
  HubState({Future<Directory> Function()? modelDirectoryProvider}) : _modelDirectoryProvider = modelDirectoryProvider ?? _defaultModelDirectory {
    gateway = ApiGateway(keys: keys, onLog: _onGatewayLog);
  }

  final Future<Directory> Function() _modelDirectoryProvider;

  static Future<Directory> _defaultModelDirectory() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'models'));

  final List<LocalModel> models = [];
  final List<GatewayKey> keys = [];
  final List<GatewayLog> logs = [];
  final List<String> engineLogs = [];
  static const MethodChannel _engineChannel = MethodChannel('local_model_hub/engine');
  static const EventChannel _engineEvents = EventChannel('local_model_hub/engine_events');
  StreamSubscription<Object?>? _engineSubscription;
  late ApiGateway gateway;
  LocalModel? selectedModel;
  bool engineRunning = false;
  bool apiRunning = false;
  bool isLoaded = false;
  String? enginePath;
  String? backendArgs;
  String? lastError;

  void _onGatewayLog(GatewayLog log) {
    logs.insert(0, log);
    if (logs.length > 500) logs.removeLast();
    unawaited(_saveLogs());
    unawaited(_saveKeys());
    notifyListeners();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedModels = prefs.getStringList('models') ?? [];
    for (final path in savedModels) {
      final file = File(path);
      if (await file.exists()) models.add(LocalModel(name: p.basename(path), path: path, sizeLabel: _formatSize(await file.length())));
    }
    enginePath = prefs.getString('llamaServerPath');
    backendArgs = prefs.getString('backendArgs') ?? '--n-gpu-layers auto';
    final storedKeys = await const FlutterSecureStorage().read(key: 'apiKeys');
    if (storedKeys != null) {
      for (final item in (jsonDecode(storedKeys) as List).cast<Map<String, Object?>>()) {
        keys.add(GatewayKey.fromJson(item));
      }
    }
    for (final key in keys) {
      key.requestTimes.removeWhere((time) => DateTime.now().difference(time) >= const Duration(minutes: 1));
    }
    selectedModel = models.isEmpty ? null : models.first;
    final savedLogs = prefs.getString('requestLogs');
    if (savedLogs != null) {
      for (final item in (jsonDecode(savedLogs) as List).cast<Map<String, Object?>>()) {
        logs.add(GatewayLog.fromJson(item));
      }
    }
    if (Platform.isAndroid) {
      _engineSubscription = _engineEvents.receiveBroadcastStream().listen(_onEngineEvent, onError: _onEngineEventError);
      engineRunning = await _engineChannel.invokeMethod<bool>('isRunning') ?? false;
      if (engineRunning) gateway.setExternalEngine(18081);
    }
    isLoaded = true;
    notifyListeners();
  }

  Future<void> addModel(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists() || !sourcePath.toLowerCase().endsWith('.gguf')) {
      throw const FormatException('请选择存在的 GGUF 文件');
    }
    final modelDirectory = await _modelDirectoryProvider();
    await modelDirectory.create(recursive: true);
    final name = p.basename(sourcePath);
    var destination = p.join(modelDirectory.path, name);
    var suffix = 1;
    while (await File(destination).exists()) {
      if (models.any((model) => model.path == destination)) return;
      destination = p.join(modelDirectory.path, '${p.basenameWithoutExtension(name)}-$suffix.gguf');
      suffix++;
    }
    final file = await source.copy(destination);
    final model = LocalModel(name: p.basename(destination), path: destination, sizeLabel: _formatSize(await file.length()));
    models.add(model);
    selectedModel ??= model;
    await _saveModels();
    notifyListeners();
  }

  Future<void> removeModel(LocalModel model) async {
    if (model.loaded) await stopEngine();
    models.remove(model);
    if (await File(model.path).exists()) await File(model.path).delete();
    selectedModel = models.isEmpty ? null : models.first;
    await _saveModels();
    notifyListeners();
  }

  void selectModel(LocalModel model) {
    selectedModel = model;
    notifyListeners();
  }

  Future<void> configureEngine(String? executable, String args) async {
    if (executable != null) enginePath = executable;
    backendArgs = args;
    final prefs = await SharedPreferences.getInstance();
    if (enginePath != null) await prefs.setString('llamaServerPath', enginePath!);
    await prefs.setString('backendArgs', args);
    notifyListeners();
  }

  Future<void> startEngine(LocalModel model) async {
    if (kIsWeb || Platform.isIOS) throw UnsupportedError('当前平台不支持本地 llama.cpp 服务');
    await stopEngine();
    try {
      final enginePort = Platform.isAndroid ? 18081 : 8081;
      if (Platform.isAndroid) {
        await _engineChannel.invokeMethod<void>('start', {
          'modelPath': model.path,
          'backendArgs': backendArgs ?? '',
          'port': enginePort,
        });
        gateway.setExternalEngine(enginePort);
      } else {
        final executable = enginePath;
        if (executable == null || executable.isEmpty) throw const FormatException('先设置 llama-server 可执行文件路径');
        await gateway.launchEngine(executable: executable, modelPath: model.path, backendArgs: backendArgs ?? '');
      }
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      try {
        for (var attempt = 0; attempt < 120; attempt++) {
          try {
            final request = await client.getUrl(Uri.parse('http://127.0.0.1:$enginePort/health'));
            final response = await request.close();
            await response.drain<void>();
            if (response.statusCode == HttpStatus.ok) {
              engineRunning = true;
              model.loaded = true;
              selectedModel = model;
              lastError = null;
              notifyListeners();
              return;
            }
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          } on TimeoutException {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
      } finally {
        client.close(force: true);
      }
      throw const HttpException('llama-server 启动超时，请检查模型文件和后端参数');
    } catch (error) {
      lastError = error.toString();
      if (Platform.isAndroid) {
        await _engineChannel.invokeMethod<void>('stop');
        gateway.setExternalEngine(18081);
      } else {
        await gateway.stopEngine();
      }
      notifyListeners();
      rethrow;
    }
  }

  void _onEngineEvent(Object? event) {
    if (event is! Map) return;
    if (event['type'] == 'log' && event['message'] is String) {
      engineLogs.insert(0, event['message'] as String);
      if (engineLogs.length > 300) engineLogs.removeLast();
    } else if (event['type'] == 'status') {
      engineRunning = true;
      final model = selectedModel;
      if (model != null) model.loaded = true;
    } else if (event['type'] == 'exit' || event['type'] == 'error') {
      engineRunning = false;
      apiRunning = false;
      if (event['type'] == 'error') lastError = event['message'] as String?;
      for (final model in models) {
        model.loaded = false;
      }
    }
    notifyListeners();
  }

  void _onEngineEventError(Object error) {
    engineLogs.insert(0, error.toString());
    notifyListeners();
  }

  Future<void> stopApi() async {
    await gateway.stop(stopEngine: false);
    apiRunning = false;
    notifyListeners();
  }

  Future<void> stopEngine() async {
    await stopApi();
    if (Platform.isAndroid) {
      await _engineChannel.invokeMethod<void>('stop');
      gateway.setExternalEngine(18081);
    } else {
      await gateway.stopEngine();
    }
    for (final model in models) {
      model.loaded = false;
    }
    engineRunning = false;
    notifyListeners();
  }

  Future<GatewayKey> addKey(String name, int rpm) async {
    final random = Random.secure();
    final secret = 'lmh_${List<int>.generate(32, (_) => random.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    final key = GatewayKey(name: name, secret: secret, rpm: rpm);
    keys.add(key);
    await _saveKeys();
    notifyListeners();
    return key;
  }

  Future<void> removeKey(GatewayKey key) async {
    keys.remove(key);
    await _saveKeys();
    notifyListeners();
  }

  Future<void> updateKey(GatewayKey key, {bool? enabled, int? rpm}) async {
    if (enabled != null) key.enabled = enabled;
    if (rpm != null) key.rpm = rpm;
    await _saveKeys();
    notifyListeners();
  }

  Future<void> _saveModels() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('models', models.map((model) => model.path).toList());
  }

  Future<void> _saveKeys() async {
    await const FlutterSecureStorage().write(key: 'apiKeys', value: jsonEncode(keys.map((key) => key.toJson()).toList()));
  }

  Future<void> _saveLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('requestLogs', jsonEncode(logs.map((log) => log.toJson()).toList()));
  }

  String _formatSize(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(bytes / (1 << 10)).toStringAsFixed(1)} KB';
  }

  Future<void> disposeAsync() async {
    await _engineSubscription?.cancel();
    await gateway.dispose();
  }

  void changed() => notifyListeners();
}

class HubScope extends widgets.InheritedNotifier<HubState> {
  const HubScope({super.key, required HubState state, required super.child}) : super(notifier: state);
  static HubState of(material.BuildContext context) => context.dependOnInheritedWidgetOfExactType<HubScope>()!.notifier!;
}

class HubShell extends material.StatefulWidget {
  const HubShell({super.key});

  @override
  material.State<HubShell> createState() => _HubShellState();
}

class _HubShellState extends material.State<HubShell> {
  HubPage page = HubPage.overview;
  final HubState state = HubState();

  @override
  void initState() {
    super.initState();
    state.load();
  }

  @override
  void dispose() {
    state.disposeAsync();
    state.dispose();
    super.dispose();
  }

  @override
  material.Widget build(material.BuildContext context) {
    final wide = widgets.MediaQuery.sizeOf(context).width >= 900;
    return HubScope(
      state: state,
      child: material.Scaffold(
        body: material.Row(
          children: [
            if (wide) _Rail(selected: page, onSelected: _select),
            material.Expanded(
              child: material.SafeArea(
                child: widgets.AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: _pageContent(),
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: wide ? null : _FloatingNavigation(selected: page, onSelected: _select),
      ),
    );
  }

  void _select(HubPage value) => setState(() => page = value);

  material.Widget _pageContent() => switch (page) {
        HubPage.overview => const OverviewPage(),
        HubPage.models => const ModelsPage(),
        HubPage.keys => const KeysPage(),
        HubPage.activity => const ActivityPage(),
        HubPage.settings => const SettingsPage(),
      };
}

class _PageSpec {
  const _PageSpec(this.page, this.label, this.icon, this.selectedIcon);
  final HubPage page;
  final String label;
  final widgets.IconData icon;
  final widgets.IconData selectedIcon;
}

const _pages = [
  _PageSpec(HubPage.overview, '概览', material.Icons.space_dashboard_outlined, material.Icons.space_dashboard),
  _PageSpec(HubPage.models, '模型', material.Icons.memory_outlined, material.Icons.memory),
  _PageSpec(HubPage.keys, 'API 密钥', material.Icons.key_outlined, material.Icons.key),
  _PageSpec(HubPage.activity, '请求日志', material.Icons.receipt_long_outlined, material.Icons.receipt_long),
  _PageSpec(HubPage.settings, '设置', material.Icons.tune_outlined, material.Icons.tune),
];

class _Rail extends material.StatelessWidget {
  const _Rail({required this.selected, required this.onSelected});
  final HubPage selected;
  final material.ValueChanged<HubPage> onSelected;

  @override
  material.Widget build(material.BuildContext context) => material.NavigationRail(
        selectedIndex: _pages.indexWhere((item) => item.page == selected),
        onDestinationSelected: (index) => onSelected(_pages[index].page),
        labelType: material.NavigationRailLabelType.all,
        destinations: [
          for (final item in _pages)
            material.NavigationRailDestination(
              icon: material.Icon(item.icon),
              selectedIcon: material.Icon(item.selectedIcon),
              label: material.Text(item.label),
            ),
        ],
      );
}

class _FloatingNavigation extends material.StatelessWidget {
  const _FloatingNavigation({required this.selected, required this.onSelected});
  final HubPage selected;
  final material.ValueChanged<HubPage> onSelected;

  @override
  material.Widget build(material.BuildContext context) {
    final scheme = material.Theme.of(context).colorScheme;
    return material.SafeArea(
      minimum: const material.EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: material.Center(
        child: material.ConstrainedBox(
          constraints: const widgets.BoxConstraints(maxWidth: 560),
          child: material.ClipRRect(
            borderRadius: material.BorderRadius.circular(32),
            child: material.BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: widgets.DecoratedBox(
                decoration: material.BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.76),
                  border: material.Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
                  borderRadius: material.BorderRadius.circular(32),
                ),
                child: m3e.M3ENavigationBar(
                  selectedIndex: _pages.indexWhere((item) => item.page == selected),
                  onDestinationSelected: (index) => onSelected(_pages[index].page),
                  destinations: [
                    for (final item in _pages)
                      m3e.M3ENavigationBarDestination(
                        icon: material.Icon(item.icon),
                        selectedIcon: material.Icon(item.selectedIcon),
                        label: item.label,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PageFrame extends material.StatelessWidget {
  const _PageFrame({required this.title, required this.subtitle, required this.children, this.action});
  final String title;
  final String subtitle;
  final List<material.Widget> children;
  final material.Widget? action;

  @override
  material.Widget build(material.BuildContext context) {
    return material.ListView(
      key: widgets.ValueKey(title),
      padding: const material.EdgeInsets.fromLTRB(24, 20, 24, 32),
      children: [
        material.Row(
          crossAxisAlignment: material.CrossAxisAlignment.start,
          children: [
            material.Expanded(
              child: material.Column(crossAxisAlignment: material.CrossAxisAlignment.start, children: [
                material.Text(title, style: material.Theme.of(context).textTheme.headlineMedium),
                const material.SizedBox(height: 6),
                material.Text(subtitle, style: material.Theme.of(context).textTheme.bodyMedium?.copyWith(color: material.Theme.of(context).colorScheme.onSurfaceVariant)),
              ]),
            ),
            if (action != null) ...[const material.SizedBox(width: 12), action!],
          ],
        ),
        const material.SizedBox(height: 24),
        ...children,
      ],
    );
  }
}

class OverviewPage extends material.StatelessWidget {
  const OverviewPage({super.key});

  @override
  material.Widget build(material.BuildContext context) {
    final state = HubScope.of(context);
    return _PageFrame(
      title: '本地模型中心',
      subtitle: '模型运行状态、API 服务与资源用量',
      action: material.FilledButton.icon(
        onPressed: () => _pickModel(context),
        icon: const material.Icon(material.Icons.add),
        label: const material.Text('导入模型'),
      ),
      children: [
        _StatusCard(model: state.selectedModel),
        const material.SizedBox(height: 16),
        const _SectionTitle('运行概况'),
        const material.SizedBox(height: 10),
        const _StatGrid(),
        const material.SizedBox(height: 22),
        const _SectionTitle('本地 API'),
        const material.SizedBox(height: 10),
        const _ApiEndpointCard(),
        const material.SizedBox(height: 22),
        const _SectionTitle('最近活动'),
        const material.SizedBox(height: 10),
        const _RecentActivityCard(),
      ],
    );
  }
}

Future<void> _pickModel(material.BuildContext context) async {
  final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['gguf']);
  final path = result?.files.single.path;
  if (path == null || !context.mounted) return;
  try {
    await HubScope.of(context).addModel(path);
  } catch (error) {
    if (context.mounted) _showMessage(context, error.toString());
  }
}

void _showMessage(material.BuildContext context, String message) {
  material.ScaffoldMessenger.of(context).showSnackBar(material.SnackBar(content: material.Text(message)));
}

class _StatusCard extends material.StatelessWidget {
  const _StatusCard({required this.model});
  final LocalModel? model;

  @override
  material.Widget build(material.BuildContext context) {
    final scheme = material.Theme.of(context).colorScheme;
    final loaded = model?.loaded ?? false;
    return material.Card(
      color: loaded ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      child: material.Padding(
        padding: const material.EdgeInsets.all(22),
        child: material.Row(children: [
          material.Icon(material.Icons.memory, size: 36, color: loaded ? scheme.onPrimaryContainer : scheme.primary),
          const material.SizedBox(width: 16),
          material.Expanded(child: material.Column(crossAxisAlignment: material.CrossAxisAlignment.start, children: [
            material.Text(loaded ? model!.name : model?.name ?? '尚未加载模型', style: material.Theme.of(context).textTheme.titleLarge),
            const material.SizedBox(height: 5),
            material.Text(loaded ? 'llama-server 正在运行 · 本机 API 已就绪' : '导入 GGUF 模型并启动内置 llama.cpp', style: material.Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ])),
          material.Icon(material.Icons.circle, size: 10, color: loaded ? scheme.primary : scheme.outline),
        ]),
      ),
    );
  }
}

class _StatGrid extends material.StatelessWidget {
  const _StatGrid();
  @override
  material.Widget build(material.BuildContext context) {
    final width = widgets.MediaQuery.sizeOf(context).width;
    final state = HubScope.of(context);
    final count = width >= 1100 ? 4 : 2;
    final requests = state.keys.fold<int>(0, (sum, key) => sum + key.requests);
    final input = state.keys.fold<int>(0, (sum, key) => sum + key.inputTokens);
    final output = state.keys.fold<int>(0, (sum, key) => sum + key.outputTokens);
    final active = state.keys.where((key) => key.enabled).length;
    return material.GridView.count(
      crossAxisCount: count,
      shrinkWrap: true,
      physics: const widgets.NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: width < 420 ? 1.1 : 1.8,
      children: [
        _MetricCard(label: '输入 tokens', value: '$input', icon: material.Icons.input),
        _MetricCard(label: '输出 tokens', value: '$output', icon: material.Icons.output),
        _MetricCard(label: '今日请求', value: '$requests', icon: material.Icons.bolt),
        _MetricCard(label: '活跃 API key', value: '$active', icon: material.Icons.key),
      ],
    );
  }
}

class _MetricCard extends material.StatelessWidget {
  const _MetricCard({required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final widgets.IconData icon;
  @override
  material.Widget build(material.BuildContext context) => material.Card(
        child: material.Padding(
          padding: const material.EdgeInsets.all(16),
          child: material.Column(crossAxisAlignment: material.CrossAxisAlignment.start, mainAxisAlignment: material.MainAxisAlignment.spaceBetween, children: [
            material.Icon(icon, color: material.Theme.of(context).colorScheme.primary),
            material.Text(value, style: material.Theme.of(context).textTheme.headlineMedium),
            material.Text(label, style: material.Theme.of(context).textTheme.labelLarge?.copyWith(color: material.Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      );
}

class _SectionTitle extends material.StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  material.Widget build(material.BuildContext context) => material.Text(text, style: material.Theme.of(context).textTheme.titleMedium);
}

class _ApiEndpointCard extends material.StatelessWidget {
  const _ApiEndpointCard();
  @override
  material.Widget build(material.BuildContext context) {
    final state = HubScope.of(context);
    final activeKeys = state.keys.where((key) => key.enabled).toList();
    final rpm = activeKeys.fold<int>(0, (min, key) => min == 0 ? key.rpm : min < key.rpm ? min : key.rpm);
    return material.Card(
      child: material.Padding(
        padding: const material.EdgeInsets.all(18),
        child: material.Column(crossAxisAlignment: material.CrossAxisAlignment.start, children: [
          material.Row(children: [
            material.Icon(material.Icons.cloud_outlined, color: material.Theme.of(context).colorScheme.primary),
            const material.SizedBox(width: 10),
            const material.Expanded(child: material.Text('OpenAI-compatible API')),
            material.Chip(avatar: material.Icon(material.Icons.circle, size: 9, color: state.apiRunning ? material.Theme.of(context).colorScheme.primary : material.Theme.of(context).colorScheme.outline), label: material.Text(state.apiRunning ? '运行中' : '已停止')),
          ]),
          const material.SizedBox(height: 14),
          const material.SelectableText('http://127.0.0.1:8080/v1'),
          const material.SizedBox(height: 12),
          material.Row(children: [
            const material.Icon(material.Icons.speed, size: 18),
            const material.SizedBox(width: 8),
            material.Text('速率上限：${rpm == 0 ? '未设置' : '$rpm RPM'}', style: material.Theme.of(context).textTheme.bodyMedium),
            const widgets.Spacer(),
            material.TextButton(onPressed: () => state.changed(), child: const material.Text('管理')),
          ]),
          material.Align(
            alignment: widgets.Alignment.centerRight,
            child: material.FilledButton.tonalIcon(
              onPressed: !state.isLoaded
                  ? null
                  : state.apiRunning
                      ? () async => state.stopApi()
                      : state.engineRunning && activeKeys.isNotEmpty
                          ? () async {
                              final messenger = material.ScaffoldMessenger.of(context);
                              try {
                                await state.gateway.start();
                                state.apiRunning = true;
                                state.changed();
                              } catch (error) {
                                messenger.showSnackBar(material.SnackBar(content: material.Text(error.toString())));
                              }
                            }
                          : null,
              icon: material.Icon(state.apiRunning ? material.Icons.stop : material.Icons.play_arrow),
              label: material.Text(state.apiRunning ? '停止服务' : '启动服务'),
            ),
          ),
          if (state.lastError != null) ...[
            const material.SizedBox(height: 8),
            material.Text(state.lastError!, style: material.TextStyle(color: material.Theme.of(context).colorScheme.error)),
          ],
        ]),
      ),
    );
  }
}

class _RecentActivityCard extends material.StatelessWidget {
  const _RecentActivityCard();
  @override
  material.Widget build(material.BuildContext context) {
    final logs = HubScope.of(context).logs.take(4).toList();
    if (logs.isEmpty) {
      return const _EmptyState(icon: material.Icons.inbox_outlined, title: '暂无请求记录', body: '启动服务并发起 API 请求后，最近活动会显示在这里。');
    }
    return material.Column(children: [for (final log in logs) _RequestLogTile(log: log)]);
  }
}

class ModelsPage extends material.StatelessWidget {
  const ModelsPage({super.key});
  @override
  material.Widget build(material.BuildContext context) {
    final state = HubScope.of(context);
    return _PageFrame(
      title: '模型',
      subtitle: '导入、管理并启动本地模型',
      action: material.FilledButton.icon(onPressed: () => _pickModel(context), icon: const material.Icon(material.Icons.add), label: const material.Text('导入')),
      children: [
        if (state.models.isEmpty)
          const _EmptyState(icon: material.Icons.folder_open, title: '模型库为空', body: '选择 GGUF 文件导入到本地模型库。模型文件保留在设备上。')
        else
          for (final model in state.models) _ModelTile(model: model),
        const material.SizedBox(height: 18),
        _BackendCard(state: state),
      ],
    );
  }
}

class _ModelTile extends material.StatelessWidget {
  const _ModelTile({required this.model});
  final LocalModel model;
  @override
  material.Widget build(material.BuildContext context) {
    final state = HubScope.of(context);
    return material.Card(
      child: material.ListTile(
        leading: material.Icon(model.loaded ? material.Icons.memory : material.Icons.sd_storage_outlined, color: material.Theme.of(context).colorScheme.primary),
        title: material.Text(model.name, maxLines: 1, overflow: widgets.TextOverflow.ellipsis),
        subtitle: material.Text('${model.sizeLabel} · ${model.loaded ? '运行中' : model.path}', maxLines: 1, overflow: widgets.TextOverflow.ellipsis),
        onTap: () => state.selectModel(model),
        trailing: material.Wrap(spacing: 4, children: [
          material.IconButton(
            tooltip: model.loaded ? '停止' : '启动',
            onPressed: () async {
              try {
                if (model.loaded) {
                  await state.stopEngine();
                } else {
                  await state.startEngine(model);
                }
              } catch (error) {
                if (context.mounted) _showMessage(context, error.toString());
              }
            },
            icon: material.Icon(model.loaded ? material.Icons.stop_circle_outlined : material.Icons.play_circle_outline),
          ),
          material.IconButton(
            tooltip: '移除',
            onPressed: () => state.removeModel(model),
            icon: const material.Icon(material.Icons.delete_outline),
          ),
        ]),
      ),
    );
  }
}

class _BackendCard extends material.StatelessWidget {
  const _BackendCard({required this.state});
  final HubState state;
  @override
  material.Widget build(material.BuildContext context) => material.Card(
        child: material.Padding(
          padding: const material.EdgeInsets.all(18),
          child: material.Column(crossAxisAlignment: material.CrossAxisAlignment.start, children: [
            material.Row(children: [
              material.Expanded(child: material.Text('推理后端', style: material.Theme.of(context).textTheme.titleMedium)),
              if (!Platform.isAndroid)
                material.TextButton.icon(onPressed: () => _configureEngine(context, state), icon: const material.Icon(material.Icons.settings_ethernet), label: const material.Text('配置')),
            ]),
            const material.SizedBox(height: 12),
            _BackendRow(label: '当前后端', value: state.engineRunning ? '内置 llama-server' : '未运行'),
            _BackendRow(label: 'GPU 参数', value: state.backendArgs?.isNotEmpty == true ? state.backendArgs! : '未配置'),
            if (!Platform.isAndroid) _BackendRow(label: '可执行文件', value: state.enginePath ?? '未设置'),
            if (state.engineLogs.isNotEmpty) ...[
              const material.Divider(height: 24),
              material.Text('引擎日志', style: material.Theme.of(context).textTheme.titleSmall),
              const material.SizedBox(height: 8),
              for (final line in state.engineLogs.take(12))
                material.Padding(
                  padding: const material.EdgeInsets.symmetric(vertical: 2),
                  child: material.SelectableText(line, maxLines: 2, style: material.Theme.of(context).textTheme.bodySmall),
                ),
            ],
          ]),
        ),
      );
}

Future<void> _configureEngine(material.BuildContext context, HubState state) async {
  final args = material.TextEditingController(text: state.backendArgs ?? '--n-gpu-layers auto');
  final saved = await material.showDialog<String>(
    context: context,
    builder: (context) => material.AlertDialog(
      title: const material.Text('配置推理引擎'),
      content: material.SizedBox(
        width: 440,
        child: material.Column(mainAxisSize: material.MainAxisSize.min, children: [
          material.Text(state.enginePath ?? '尚未选择 llama-server'),
          const material.SizedBox(height: 12),
          material.TextField(controller: args, decoration: const material.InputDecoration(labelText: '启动参数', hintText: '--n-gpu-layers auto')),
        ]),
      ),
      actions: [
        material.TextButton(onPressed: () => material.Navigator.pop(context), child: const material.Text('取消')),
        material.TextButton.icon(
          onPressed: () => material.Navigator.pop(context, '__pick__'),
          icon: const material.Icon(material.Icons.folder_open),
          label: const material.Text('选择可执行文件'),
        ),
        material.FilledButton(onPressed: () => material.Navigator.pop(context, '__save__'), child: const material.Text('保存')),
      ],
    ),
  );
  final launchArgs = args.text.trim();
  args.dispose();
  if (saved == '__pick__' && context.mounted) {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final executable = result?.files.single.path;
    if (executable != null) await state.configureEngine(executable, launchArgs);
  } else if (saved == '__save__' && state.enginePath != null) {
    await state.configureEngine(state.enginePath!, launchArgs);
  }
}

class _BackendRow extends material.StatelessWidget {
  const _BackendRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  material.Widget build(material.BuildContext context) => material.Padding(
        padding: const material.EdgeInsets.symmetric(vertical: 7),
        child: material.Row(children: [
          material.Expanded(child: material.Text(label, style: material.TextStyle(color: material.Theme.of(context).colorScheme.onSurfaceVariant))),
          material.Text(value),
        ]),
      );
}

class KeysPage extends material.StatelessWidget {
  const KeysPage({super.key});
  @override
  material.Widget build(material.BuildContext context) {
    final state = HubScope.of(context);
    return _PageFrame(
      title: 'API 密钥',
      subtitle: '为本地 API 创建独立凭证并配置访问限制',
      action: material.FilledButton.icon(onPressed: () => _createKey(context, state), icon: const material.Icon(material.Icons.add), label: const material.Text('新建密钥')),
      children: [
        if (state.keys.isEmpty)
          const _EmptyState(icon: material.Icons.key_off, title: '暂无密钥', body: '创建密钥后，客户端可使用 Bearer Token 访问本地 API。')
        else
          for (final key in state.keys) _KeyTile(apiKey: key),
        const material.SizedBox(height: 18),
        const _SecurityNote(),
      ],
    );
  }
}

class _KeyTile extends material.StatelessWidget {
  const _KeyTile({required this.apiKey});
  final GatewayKey apiKey;
  @override
  material.Widget build(material.BuildContext context) {
    final state = HubScope.of(context);
    return material.Card(
      child: material.Padding(
        padding: const material.EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: material.Column(children: [
          material.SwitchListTile(
            value: apiKey.enabled,
            onChanged: (value) => state.updateKey(apiKey, enabled: value),
            secondary: const material.Icon(material.Icons.key),
            title: material.Text(apiKey.name),
            subtitle: material.Text('RPM ${apiKey.rpm} · 请求 ${apiKey.requests} · ${apiKey.inputTokens + apiKey.outputTokens} tokens'),
          ),
          material.Row(children: [
            material.Expanded(child: material.Text('每分钟请求上限', style: material.Theme.of(context).textTheme.bodyMedium)),
            material.IconButton(onPressed: apiKey.rpm > 1 ? () => state.updateKey(apiKey, rpm: apiKey.rpm - 1) : null, icon: const material.Icon(material.Icons.remove)),
            material.Text('${apiKey.rpm}', style: material.Theme.of(context).textTheme.titleMedium),
            material.IconButton(onPressed: () => state.updateKey(apiKey, rpm: apiKey.rpm + 1), icon: const material.Icon(material.Icons.add)),
            material.IconButton(tooltip: '删除密钥', onPressed: () => state.removeKey(apiKey), icon: const material.Icon(material.Icons.delete_outline)),
          ]),
        ]),
      ),
    );
  }
}

Future<void> _createKey(material.BuildContext context, HubState state) async {
  final name = material.TextEditingController();
  final rpm = material.TextEditingController(text: '60');
  final result = await material.showDialog<(String, int)?>(
    context: context,
    builder: (context) => material.AlertDialog(
      title: const material.Text('新建 API 密钥'),
      content: material.SizedBox(
        width: 400,
        child: material.Column(mainAxisSize: material.MainAxisSize.min, children: [
          material.TextField(controller: name, autofocus: true, decoration: const material.InputDecoration(labelText: '名称')),
          const material.SizedBox(height: 12),
          material.TextField(controller: rpm, keyboardType: widgets.TextInputType.number, decoration: const material.InputDecoration(labelText: '每分钟请求上限')),
        ]),
      ),
      actions: [
        material.TextButton(onPressed: () => material.Navigator.pop(context), child: const material.Text('取消')),
        material.FilledButton(
          onPressed: () {
            final keyName = name.text.trim();
            final limit = int.tryParse(rpm.text) ?? 60;
            if (keyName.isNotEmpty && limit > 0) material.Navigator.pop(context, (keyName, limit));
          },
          child: const material.Text('创建'),
        ),
      ],
    ),
  );
  name.dispose();
  rpm.dispose();
  if (result == null || !context.mounted) return;
  final key = await state.addKey(result.$1, result.$2);
  if (!context.mounted) return;
  await material.showDialog<void>(
    context: context,
    builder: (context) => material.AlertDialog(
      icon: const material.Icon(material.Icons.key),
      title: const material.Text('密钥已创建'),
      content: material.SelectableText(key.secret),
      actions: [material.FilledButton(onPressed: () => material.Navigator.pop(context), child: const material.Text('完成'))],
    ),
  );
}

class _SecurityNote extends material.StatelessWidget {
  const _SecurityNote();
  @override
  material.Widget build(material.BuildContext context) => material.Card(
        color: material.Theme.of(context).colorScheme.secondaryContainer,
        child: const material.Padding(
          padding: material.EdgeInsets.all(18),
          child: material.Row(crossAxisAlignment: material.CrossAxisAlignment.start, children: [
            material.Icon(material.Icons.shield_outlined),
            material.SizedBox(width: 12),
            material.Expanded(child: material.Text('密钥仅在创建时显示一次。用量按密钥分别统计，可单独设置每分钟请求数上限。')),
          ]),
        ),
      );
}

class ActivityPage extends material.StatelessWidget {
  const ActivityPage({super.key});
  @override
  material.Widget build(material.BuildContext context) {
    final state = HubScope.of(context);
    final requests = state.keys.fold<int>(0, (sum, key) => sum + key.requests);
    final input = state.keys.fold<int>(0, (sum, key) => sum + key.inputTokens);
    final output = state.keys.fold<int>(0, (sum, key) => sum + key.outputTokens);
    return _PageFrame(
      title: '请求日志',
      subtitle: '查看请求状态、token 用量和延迟',
      action: material.IconButton(onPressed: () => state.changed(), tooltip: '刷新', icon: const material.Icon(material.Icons.refresh)),
      children: [
        _UsageSummary(requests: requests, input: input, output: output),
        const material.SizedBox(height: 16),
        if (state.logs.isEmpty)
          const _EmptyState(icon: material.Icons.receipt_long, title: '暂无请求', body: 'API 收到请求后，日志会显示在这里。')
        else
          for (final log in state.logs) _RequestLogTile(log: log),
      ],
    );
  }
}

class _RequestLogTile extends material.StatelessWidget {
  const _RequestLogTile({required this.log});
  final GatewayLog log;
  @override
  material.Widget build(material.BuildContext context) {
    final ok = log.status >= 200 && log.status < 400;
    return material.Card(
      child: material.ListTile(
        leading: material.Icon(ok ? material.Icons.check_circle_outline : material.Icons.error_outline, color: ok ? material.Theme.of(context).colorScheme.primary : material.Theme.of(context).colorScheme.error),
        title: material.Text('${log.path} · ${log.status}'),
        subtitle: material.Text('${log.keyName} · ${log.inputTokens} in / ${log.outputTokens} out tokens · ${log.latencyMs} ms'),
        trailing: material.Text('${log.time.hour.toString().padLeft(2, '0')}:${log.time.minute.toString().padLeft(2, '0')}:${log.time.second.toString().padLeft(2, '0')}'),
      ),
    );
  }
}

class _UsageSummary extends material.StatelessWidget {
  const _UsageSummary({required this.requests, required this.input, required this.output});
  final int requests;
  final int input;
  final int output;
  @override
  material.Widget build(material.BuildContext context) => material.Card(
        child: material.Padding(
          padding: const material.EdgeInsets.all(18),
          child: material.Column(crossAxisAlignment: material.CrossAxisAlignment.start, children: [
            material.Text('累计用量', style: material.Theme.of(context).textTheme.titleMedium),
            const material.SizedBox(height: 14),
            material.Row(children: [
              material.Expanded(child: _UsageValue(label: '请求数', value: '$requests')),
              material.Expanded(child: _UsageValue(label: '输入 tokens', value: '$input')),
              material.Expanded(child: _UsageValue(label: '输出 tokens', value: '$output')),
            ]),
          ]),
        ),
      );
}

class _UsageValue extends material.StatelessWidget {
  const _UsageValue({required this.label, required this.value});
  final String label;
  final String value;
  @override
  material.Widget build(material.BuildContext context) => material.Column(crossAxisAlignment: material.CrossAxisAlignment.start, children: [
        material.Text(value, style: material.Theme.of(context).textTheme.headlineSmall),
        const material.SizedBox(height: 4),
        material.Text(label, style: material.Theme.of(context).textTheme.labelMedium?.copyWith(color: material.Theme.of(context).colorScheme.onSurfaceVariant)),
      ]);
}

class SettingsPage extends material.StatelessWidget {
  const SettingsPage({super.key});
  @override
  material.Widget build(material.BuildContext context) {
    final state = HubScope.of(context);
    return _PageFrame(
      title: '设置',
      subtitle: '外观、服务和运行参数',
      children: [
        material.Card(child: material.Column(children: [
          const material.ListTile(leading: material.Icon(material.Icons.palette_outlined), title: material.Text('外观'), subtitle: material.Text('跟随系统 · material.Material 3 Expressive')),
          const material.Divider(height: 1, indent: 56),
          const material.ListTile(leading: material.Icon(material.Icons.language), title: material.Text('语言'), subtitle: material.Text('简体中文')),
          const material.Divider(height: 1, indent: 56),
          material.ListTile(
            leading: const material.Icon(material.Icons.terminal),
            title: const material.Text('llama-server'),
            subtitle: material.Text(Platform.isAndroid ? '内置 Android ARM64 引擎' : state.enginePath ?? '点击配置服务可执行文件'),
            trailing: const material.Icon(material.Icons.chevron_right),
            onTap: Platform.isAndroid ? null : () => _configureEngine(context, state),
          ),
          const material.Divider(height: 1, indent: 56),
          material.ListTile(
            leading: const material.Icon(material.Icons.tune),
            title: const material.Text('GPU / 启动参数'),
            subtitle: material.Text(state.backendArgs?.isNotEmpty == true ? state.backendArgs! : '未配置'),
            trailing: const material.Icon(material.Icons.chevron_right),
            onTap: () => _configureEngine(context, state),
          ),
        ])),
        const material.SizedBox(height: 16),
        const material.Card(child: material.Column(children: [
          material.ListTile(leading: material.Icon(material.Icons.info_outline), title: material.Text('关于'), subtitle: material.Text('Local Model Hub · 0.1.0')),
        ])),
      ],
    );
  }
}

class _EmptyState extends material.StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.body});
  final widgets.IconData icon;
  final String title;
  final String body;
  @override
  material.Widget build(material.BuildContext context) => material.Card(
        child: material.Padding(
          padding: const material.EdgeInsets.fromLTRB(24, 36, 24, 36),
          child: material.Column(children: [
            material.Icon(icon, size: 34, color: material.Theme.of(context).colorScheme.secondary),
            const material.SizedBox(height: 14),
            material.Text(title, style: material.Theme.of(context).textTheme.titleMedium),
            const material.SizedBox(height: 6),
            material.ConstrainedBox(
              constraints: const widgets.BoxConstraints(maxWidth: 420),
              child: material.Text(body, textAlign: widgets.TextAlign.center, style: material.Theme.of(context).textTheme.bodyMedium?.copyWith(color: material.Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
          ]),
        ),
      );
}
