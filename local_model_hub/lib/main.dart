import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_3_expressive/components/navigation_bar/models/m3e_navigation_bar_destination.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_model_hub/api_gateway.dart';

void main() {
  runApp(const ModelHubApp());
}

class ModelHubApp extends StatelessWidget {
  const ModelHubApp({super.key});

  @override
  Widget build(BuildContext context) => DynamicColorBuilder(
        builder: (lightDynamic, darkDynamic) {
          const fallbackSeed = Color(0xFF426B58);
          final lightScheme = lightDynamic ?? ColorScheme.fromSeed(seedColor: fallbackSeed);
          final darkScheme = darkDynamic ?? ColorScheme.fromSeed(seedColor: fallbackSeed, brightness: Brightness.dark);
          return M3EMaterialApp(
            title: '本地模型中心',
            debugShowCheckedModeBanner: false,
            themeMode: ThemeMode.system,
            data: M3EThemeData.light(seedColor: lightScheme.primary),
            autoTheming: true,
            dynamicColoring: lightDynamic != null || darkDynamic != null,
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: lightScheme,
              scaffoldBackgroundColor: const Color(0xFFF6F7F4),
              cardTheme: CardThemeData(
                elevation: 0,
                color: lightScheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
            ),
            darkTheme: ThemeData(
              useMaterial3: true,
              colorScheme: darkScheme,
              cardTheme: CardThemeData(
                elevation: 0,
                color: darkScheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
            ),
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

class HubState extends ChangeNotifier {
  final List<LocalModel> models = [];
  final List<GatewayKey> keys = [];
  final List<GatewayLog> logs = [];
  late ApiGateway gateway;
  LocalModel? selectedModel;
  bool engineRunning = false;
  bool apiRunning = false;
  bool isLoaded = false;
  String? enginePath;
  String? backendArgs;
  String? lastError;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedModels = prefs.getStringList('models') ?? [];
    for (final path in savedModels) {
      if (File(path).existsSync()) models.add(LocalModel(name: p.basename(path), path: path));
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
    gateway = ApiGateway(keys: keys, onLog: (log) {
      logs.insert(0, log);
      if (logs.length > 500) logs.removeLast();
      unawaited(_saveLogs());
      unawaited(_saveKeys());
      notifyListeners();
    });
    final savedLogs = prefs.getString('requestLogs');
    if (savedLogs != null) {
      for (final item in (jsonDecode(savedLogs) as List).cast<Map<String, Object?>>()) {
        logs.add(GatewayLog.fromJson(item));
      }
    }
    isLoaded = true;
    notifyListeners();
  }

  Future<void> addModel(String path) async {
    if (models.any((model) => model.path == path)) return;
    final file = File(path);
    if (!await file.exists() || !path.toLowerCase().endsWith('.gguf')) {
      throw const FormatException('请选择存在的 GGUF 文件');
    }
    final model = LocalModel(name: p.basename(path), path: path, sizeLabel: _formatSize(await file.length()));
    models.add(model);
    selectedModel ??= model;
    await _saveModels();
    notifyListeners();
  }

  Future<void> removeModel(LocalModel model) async {
    if (model.loaded) await stopEngine();
    models.remove(model);
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
    if (Platform.isAndroid || Platform.isIOS || Platform.isWeb) {
      throw const UnsupportedError('当前版本的模型子进程仅支持桌面端；Android 原生引擎桥接尚未实现');
    }
    final executable = enginePath;
    if (executable == null || executable.isEmpty) throw const FormatException('先设置 llama-server 可执行文件路径');
    await stopEngine();
    try {
      await gateway.launchEngine(executable: executable, modelPath: model.path, backendArgs: backendArgs ?? '');
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
      try {
        for (var attempt = 0; attempt < 60; attempt++) {
          try {
            final request = await client.getUrl(Uri.parse('http://127.0.0.1:8081/health'));
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
      await gateway.stopEngine();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> stopApi() async {
    await gateway.stop();
    apiRunning = false;
    notifyListeners();
  }

  Future<void> stopEngine() async {
    await stopApi();
    await gateway.stopEngine();
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

  Future<void> disposeAsync() async => gateway.dispose();
  void changed() => notifyListeners();
}

class HubScope extends InheritedNotifier<HubState> {
  const HubScope({super.key, required HubState state, required super.child}) : super(notifier: state);
  static HubState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<HubScope>()!.notifier!;
}

class HubShell extends StatefulWidget {
  const HubShell({super.key});

  @override
  State<HubShell> createState() => _HubShellState();
}

class _HubShellState extends State<HubShell> {
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
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return HubScope(
      state: state,
      child: Scaffold(
        body: Row(
          children: [
            if (wide) _Rail(selected: page, onSelected: _select),
            Expanded(
              child: SafeArea(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: _pageContent(),
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: wide
            ? null
            : _FloatingNavigation(selected: page, onSelected: _select),
      ),
    );
  }

  void _select(HubPage value) => setState(() => page = value);

  Widget _pageContent() => switch (page) {
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
  final IconData icon;
  final IconData selectedIcon;
}

const _pages = [
  _PageSpec(HubPage.overview, '概览', Icons.space_dashboard_outlined, Icons.space_dashboard),
  _PageSpec(HubPage.models, '模型', Icons.memory_outlined, Icons.memory),
  _PageSpec(HubPage.keys, 'API 密钥', Icons.key_outlined, Icons.key),
  _PageSpec(HubPage.activity, '请求日志', Icons.receipt_long_outlined, Icons.receipt_long),
  _PageSpec(HubPage.settings, '设置', Icons.tune_outlined, Icons.tune),
];

class _Rail extends StatelessWidget {
  const _Rail({required this.selected, required this.onSelected});
  final HubPage selected;
  final ValueChanged<HubPage> onSelected;

  @override
  Widget build(BuildContext context) => NavigationRail(
        selectedIndex: _pages.indexWhere((item) => item.page == selected),
        onDestinationSelected: (index) => onSelected(_pages[index].page),
        labelType: NavigationRailLabelType.all,
        destinations: [
          for (final item in _pages)
            NavigationRailDestination(
              icon: Icon(item.icon),
              selectedIcon: Icon(item.selectedIcon),
              label: Text(item.label),
            ),
        ],
      );
}

class _FloatingNavigation extends StatelessWidget {
  const _FloatingNavigation({required this.selected, required this.onSelected});
  final HubPage selected;
  final ValueChanged<HubPage> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.76),
                  border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
                  borderRadius: BorderRadius.circular(32),
                ),
                child: M3ENavigationBar(
                  selectedIndex: _pages.indexWhere((item) => item.page == selected),
                  onDestinationSelected: (index) => onSelected(_pages[index].page),
                  destinations: [
                    for (final item in _pages)
                      M3ENavigationBarDestination(
                        icon: Icon(item.icon),
                        selectedIcon: Icon(item.selectedIcon),
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

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({required this.item, required this.selected, required this.onTap});
  final _PageSpec item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minWidth: 56, minHeight: 48),
          padding: EdgeInsets.symmetric(horizontal: selected ? 14 : 10),
          decoration: BoxDecoration(
            color: selected ? scheme.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(selected ? item.selectedIcon : item.icon, size: 20),
              if (selected) ...[
                const SizedBox(height: 2),
                Text(item.label, style: Theme.of(context).textTheme.labelSmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({required this.title, required this.subtitle, required this.children, this.action});
  final String title;
  final String subtitle;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: ValueKey(title),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 6),
                Text(subtitle, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ]),
            ),
            if (action != null) ...[const SizedBox(width: 12), action!],
          ],
        ),
        const SizedBox(height: 24),
        ...children,
      ],
    );
  }
}

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = HubScope.of(context);
    return _PageFrame(
      title: '本地模型中心',
      subtitle: '模型运行状态、API 服务与资源用量',
      action: FilledButton.icon(
        onPressed: () => _pickModel(context),
        icon: const Icon(Icons.add),
        label: const Text('导入模型'),
      ),
      children: [
        _StatusCard(model: state.selectedModel),
        const SizedBox(height: 16),
        const _SectionTitle('运行概况'),
        const SizedBox(height: 10),
        const _StatGrid(),
        const SizedBox(height: 22),
        const _SectionTitle('本地 API'),
        const SizedBox(height: 10),
        const _ApiEndpointCard(),
        const SizedBox(height: 22),
        const _SectionTitle('最近活动'),
        const SizedBox(height: 10),
        const _RecentActivityCard(),
      ],
    );
  }
}

Future<void> _pickModel(BuildContext context) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['gguf'],
  );
  final path = result?.files.single.path;
  if (path == null || !context.mounted) return;
  try {
    await HubScope.of(context).addModel(path);
  } catch (error) {
    if (context.mounted) _showMessage(context, error.toString());
  }
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.model});
  final LocalModel? model;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loaded = model?.loaded ?? false;
    return Card(
      color: loaded ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(children: [
          Icon(Icons.memory, size: 36, color: loaded ? scheme.onPrimaryContainer : scheme.primary),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(loaded ? model!.name : model?.name ?? '尚未加载模型', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 5),
            Text(loaded ? 'llama-server 正在运行 · 本机 API 已就绪' : '导入 GGUF 模型并配置 llama-server 后启动推理', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ])),
          Icon(Icons.circle, size: 10, color: loaded ? scheme.primary : scheme.outline),
        ]),
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid();
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final state = HubScope.of(context);
    final count = width >= 1100 ? 4 : 2;
    final requests = state.keys.fold<int>(0, (sum, key) => sum + key.requests);
    final input = state.keys.fold<int>(0, (sum, key) => sum + key.inputTokens);
    final output = state.keys.fold<int>(0, (sum, key) => sum + key.outputTokens);
    final active = state.keys.where((key) => key.enabled).length;
    return GridView.count(
      crossAxisCount: count,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: width < 420 ? 1.35 : 1.8,
      children: [
        _MetricCard(label: '输入 tokens', value: '$input', icon: Icons.input),
        _MetricCard(label: '输出 tokens', value: '$output', icon: Icons.output),
        _MetricCard(label: '今日请求', value: '$requests', icon: Icons.bolt),
        _MetricCard(label: '活跃 API key', value: '$active', icon: Icons.key),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            Text(value, style: Theme.of(context).textTheme.headlineMedium),
            Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.titleMedium);
}

class _ApiEndpointCard extends StatelessWidget {
  const _ApiEndpointCard();
  @override
  Widget build(BuildContext context) {
    final state = HubScope.of(context);
    final activeKeys = state.keys.where((key) => key.enabled).toList();
    final rpm = activeKeys.fold<int>(0, (min, key) => min == 0 ? key.rpm : min < key.rpm ? min : key.rpm);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.cloud_outlined, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            const Expanded(child: Text('OpenAI-compatible API')),
            Chip(avatar: Icon(Icons.circle, size: 9, color: state.apiRunning ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline), label: Text(state.apiRunning ? '运行中' : '已停止')),
          ]),
          const SizedBox(height: 14),
          const SelectableText('http://127.0.0.1:8080/v1'),
          const SizedBox(height: 12),
          Row(children: [
            const Icon(Icons.speed, size: 18),
            const SizedBox(width: 8),
            Text('速率上限：${rpm == 0 ? '未设置' : '$rpm RPM'}', style: Theme.of(context).textTheme.bodyMedium),
            const Spacer(),
            TextButton(onPressed: () => state.changed(), child: const Text('管理')),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: !state.isLoaded
                  ? null
                  : state.apiRunning
                      ? () async => state.stopApi()
                      : state.engineRunning && activeKeys.isNotEmpty
                      ? () async {
                          try {
                            await state.gateway.start();
                            state.apiRunning = true;
                            state.changed();
                          } catch (error) {
                            _showMessage(context, error.toString());
                          }
                        }
                      : null,
              icon: Icon(state.apiRunning ? Icons.stop : Icons.play_arrow),
              label: Text(state.apiRunning ? '停止服务' : '启动服务'),
            ),
          ),
          if (state.lastError != null) ...[
            const SizedBox(height: 8),
            Text(state.lastError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ]),
      ),
    );
  }
}

class _RecentActivityCard extends StatelessWidget {
  const _RecentActivityCard();
  @override
  Widget build(BuildContext context) {
    final logs = HubScope.of(context).logs.take(4).toList();
    if (logs.isEmpty) {
      return const _EmptyState(icon: Icons.inbox_outlined, title: '暂无请求记录', body: '启动服务并发起 API 请求后，最近活动会显示在这里。');
    }
    return Column(children: [for (final log in logs) _RequestLogTile(log: log)]);
  }
}

class ModelsPage extends StatelessWidget {
  const ModelsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final state = HubScope.of(context);
    return _PageFrame(
      title: '模型',
      subtitle: '导入、管理并启动本地模型',
      action: FilledButton.icon(onPressed: () => _pickModel(context), icon: const Icon(Icons.add), label: const Text('导入')),
      children: [
        if (state.models.isEmpty)
          const _EmptyState(icon: Icons.folder_open, title: '模型库为空', body: '选择 GGUF 文件导入到本地模型库。模型文件保留在设备上。')
        else
          for (final model in state.models) _ModelTile(model: model),
        const SizedBox(height: 18),
        _BackendCard(state: state),
      ],
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({required this.model});
  final LocalModel model;
  @override
  Widget build(BuildContext context) {
    final state = HubScope.of(context);
    return Card(
      child: ListTile(
        leading: Icon(model.loaded ? Icons.memory : Icons.sd_storage_outlined, color: Theme.of(context).colorScheme.primary),
        title: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${model.sizeLabel} · ${model.loaded ? '运行中' : model.path}', maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => state.selectModel(model),
        trailing: Wrap(spacing: 4, children: [
          IconButton(
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
            icon: Icon(model.loaded ? Icons.stop_circle_outlined : Icons.play_circle_outline),
          ),
          IconButton(
            tooltip: '移除',
            onPressed: () => state.removeModel(model),
            icon: const Icon(Icons.delete_outline),
          ),
        ]),
      ),
    );
  }
}

class _BackendCard extends StatelessWidget {
  const _BackendCard({required this.state});
  final HubState state;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('推理后端', style: Theme.of(context).textTheme.titleMedium)),
              TextButton.icon(onPressed: () => _configureEngine(context, state), icon: const Icon(Icons.settings_ethernet), label: const Text('配置')),
            ]),
            const SizedBox(height: 12),
            _BackendRow(label: '当前后端', value: state.engineRunning ? 'llama-server' : '未运行'),
            _BackendRow(label: 'GPU 参数', value: state.backendArgs?.isNotEmpty == true ? state.backendArgs! : '未配置'),
            _BackendRow(label: '可执行文件', value: state.enginePath ?? '未设置'),
          ]),
        ),
      );
}

Future<void> _configureEngine(BuildContext context, HubState state) async {
  final args = TextEditingController(text: state.backendArgs ?? '--n-gpu-layers auto');
  final saved = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('配置推理引擎'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(state.enginePath ?? '尚未选择 llama-server'),
          const SizedBox(height: 12),
          TextField(controller: args, decoration: const InputDecoration(labelText: '启动参数', hintText: '--n-gpu-layers auto')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton.icon(
          onPressed: () => Navigator.pop(context, '__pick__'),
          icon: const Icon(Icons.folder_open),
          label: const Text('选择可执行文件'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context, '__save__'), child: const Text('保存')),
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

class _BackendRow extends StatelessWidget {
  const _BackendRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Text(value),
        ]),
      );
}

class KeysPage extends StatelessWidget {
  const KeysPage({super.key});
  @override
  Widget build(BuildContext context) {
    final state = HubScope.of(context);
    return _PageFrame(
      title: 'API 密钥',
      subtitle: '为本地 API 创建独立凭证并配置访问限制',
      action: FilledButton.icon(onPressed: () => _createKey(context, state), icon: const Icon(Icons.add), label: const Text('新建密钥')),
      children: [
        if (state.keys.isEmpty)
          const _EmptyState(icon: Icons.key_off, title: '暂无密钥', body: '创建密钥后，客户端可使用 Bearer Token 访问本地 API。')
        else
          for (final key in state.keys) _KeyTile(apiKey: key),
        const SizedBox(height: 18),
        const _SecurityNote(),
      ],
    );
  }
}

class _KeyTile extends StatelessWidget {
  const _KeyTile({required this.apiKey});
  final GatewayKey apiKey;
  @override
  Widget build(BuildContext context) {
    final state = HubScope.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(children: [
          SwitchListTile(
            value: apiKey.enabled,
            onChanged: (value) => state.updateKey(apiKey, enabled: value),
            secondary: const Icon(Icons.key),
            title: Text(apiKey.name),
            subtitle: Text('RPM ${apiKey.rpm} · 请求 ${apiKey.requests} · ${apiKey.inputTokens + apiKey.outputTokens} tokens'),
          ),
          Row(children: [
            Expanded(child: Text('每分钟请求上限', style: Theme.of(context).textTheme.bodyMedium)),
            IconButton(onPressed: apiKey.rpm > 1 ? () => state.updateKey(apiKey, rpm: apiKey.rpm - 1) : null, icon: const Icon(Icons.remove)),
            Text('${apiKey.rpm}', style: Theme.of(context).textTheme.titleMedium),
            IconButton(onPressed: () => state.updateKey(apiKey, rpm: apiKey.rpm + 1), icon: const Icon(Icons.add)),
            IconButton(tooltip: '删除密钥', onPressed: () => state.removeKey(apiKey), icon: const Icon(Icons.delete_outline)),
          ]),
        ]),
      ),
    );
  }
}

Future<void> _createKey(BuildContext context, HubState state) async {
  final name = TextEditingController();
  final rpm = TextEditingController(text: '60');
  final result = await showDialog<(String, int)?>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('新建 API 密钥'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: '名称')),
          const SizedBox(height: 12),
          TextField(controller: rpm, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '每分钟请求上限')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final keyName = name.text.trim();
            final limit = int.tryParse(rpm.text) ?? 60;
            if (keyName.isNotEmpty && limit > 0) Navigator.pop(context, (keyName, limit));
          },
          child: const Text('创建'),
        ),
      ],
    ),
  );
  name.dispose();
  rpm.dispose();
  if (result == null || !context.mounted) return;
  final key = await state.addKey(result.$1, result.$2);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.key),
      title: const Text('密钥已创建'),
      content: SelectableText(key.secret),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('完成'))],
    ),
  );
}

class _SecurityNote extends StatelessWidget {
  const _SecurityNote();
  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: const Padding(
          padding: EdgeInsets.all(18),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.shield_outlined),
            SizedBox(width: 12),
            Expanded(child: Text('密钥仅在创建时显示一次。用量按密钥分别统计，可单独设置每分钟请求数上限。')),
          ]),
        ),
      );
}

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});
  @override
  Widget build(BuildContext context) {
    final state = HubScope.of(context);
    final requests = state.keys.fold<int>(0, (sum, key) => sum + key.requests);
    final input = state.keys.fold<int>(0, (sum, key) => sum + key.inputTokens);
    final output = state.keys.fold<int>(0, (sum, key) => sum + key.outputTokens);
    return _PageFrame(
      title: '请求日志',
      subtitle: '查看请求状态、token 用量和延迟',
      action: IconButton(onPressed: () => state.changed(), tooltip: '刷新', icon: const Icon(Icons.refresh)),
      children: [
        _UsageSummary(requests: requests, input: input, output: output),
        const SizedBox(height: 16),
        if (state.logs.isEmpty)
          const _EmptyState(icon: Icons.receipt_long, title: '暂无请求', body: 'API 收到请求后，日志会显示在这里。')
        else
          for (final log in state.logs) _RequestLogTile(log: log),
      ],
    );
  }
}

class _RequestLogTile extends StatelessWidget {
  const _RequestLogTile({required this.log});
  final GatewayLog log;
  @override
  Widget build(BuildContext context) {
    final ok = log.status >= 200 && log.status < 400;
    return Card(
      child: ListTile(
        leading: Icon(ok ? Icons.check_circle_outline : Icons.error_outline, color: ok ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error),
        title: Text('${log.path} · ${log.status}'),
        subtitle: Text('${log.keyName} · ${log.inputTokens} in / ${log.outputTokens} out tokens · ${log.latencyMs} ms'),
        trailing: Text('${log.time.hour.toString().padLeft(2, '0')}:${log.time.minute.toString().padLeft(2, '0')}:${log.time.second.toString().padLeft(2, '0')}'),
      ),
    );
  }
}

class _UsageSummary extends StatelessWidget {
  const _UsageSummary({required this.requests, required this.input, required this.output});
  final int requests;
  final int input;
  final int output;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('累计用量', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _UsageValue(label: '请求数', value: '$requests')),
              Expanded(child: _UsageValue(label: '输入 tokens', value: '$input')),
              Expanded(child: _UsageValue(label: '输出 tokens', value: '$output')),
            ]),
          ]),
        ),
      );
}

class _UsageValue extends StatelessWidget {
  const _UsageValue({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]);
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final state = HubScope.of(context);
    return _PageFrame(
      title: '设置',
      subtitle: '外观、服务和运行参数',
      children: [
        Card(child: Column(children: [
          const ListTile(leading: Icon(Icons.palette_outlined), title: Text('外观'), subtitle: Text('跟随系统 · Material 3 Expressive')),
          const Divider(height: 1, indent: 56),
          const ListTile(leading: Icon(Icons.language), title: Text('语言'), subtitle: Text('简体中文')),
          const Divider(height: 1, indent: 56),
          ListTile(
            leading: const Icon(Icons.terminal),
            title: const Text('llama-server'),
            subtitle: Text(state.enginePath ?? '点击配置服务可执行文件'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _configureEngine(context, state),
          ),
          const Divider(height: 1, indent: 56),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('GPU / 启动参数'),
            subtitle: Text(state.backendArgs?.isNotEmpty == true ? state.backendArgs! : '未配置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _configureEngine(context, state),
          ),
        ])),
        const SizedBox(height: 16),
        Card(child: Column(children: const [
          ListTile(leading: Icon(Icons.info_outline), title: Text('关于'), subtitle: Text('Local Model Hub · 0.1.0')),
        ])),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 36, 24, 36),
          child: Column(children: [
            Icon(icon, size: 34, color: Theme.of(context).colorScheme.secondary),
            const SizedBox(height: 14),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(body, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
          ]),
        ),
      );
}
