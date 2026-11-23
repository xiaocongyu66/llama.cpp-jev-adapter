import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:material_ui/material_ui.dart' as material;
import 'package:flutter_test/flutter_test.dart';
import 'package:local_model_hub/api_gateway.dart';
import 'package:local_model_hub/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences mockPreferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mockPreferences = await SharedPreferences.getInstance();
  });

  testWidgets('renders the page before loading saved preferences', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = Completer<SharedPreferences>();
    final state = HubState(preferencesProvider: () => preferences.future);
    await tester.pumpWidget(ModelHubApp(home: HubShell(state: state)));
    await tester.pump();

    expect(find.byType(OverviewPage), findsOneWidget);
    expect(tester.getRect(find.byType(OverviewPage)).height, greaterThan(0));
    expect(find.byType(material.LinearProgressIndicator), findsOneWidget);
    for (final label in ['概览', '模型', 'API 密钥', '请求日志', '设置']) {
      expect(find.text(label), findsAtLeastNWidgets(1));
    }

    preferences.complete(mockPreferences);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('renders overview and mobile page navigation', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = HubState();
    await tester.pumpWidget(ModelHubApp(home: HubShell(state: state)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(OverviewPage), findsOneWidget);

    await tester.tap(find.text('模型').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ModelsPage), findsOneWidget);
    expect(find.text('模型'), findsAtLeastNWidgets(1));

    await tester.tap(find.text('请求日志').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ActivityPage), findsOneWidget);

    await tester.pumpWidget(const material.SizedBox.shrink());
  });

  test('copies and registers an imported GGUF model', () async {
    final directory = await Directory.systemTemp.createTemp('model-import-test-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.gguf');
    await source.writeAsBytes([1, 2, 3, 4]);
    final state = HubState(modelDirectoryProvider: () async => Directory('${directory.path}/models'));

    await state.addModel(source.path);

    expect(state.models, hasLength(1));
    expect(state.models.single.name, 'source.gguf');
    expect(await File(state.models.single.path).readAsBytes(), [1, 2, 3, 4]);
    expect(mockPreferences.getStringList('models'), [state.models.single.path]);
  });

  test('writes picker bytes into the model library', () async {
    final directory = await Directory.systemTemp.createTemp('model-bytes-import-test-');
    addTearDown(() => directory.delete(recursive: true));
    final state = HubState(modelDirectoryProvider: () async => Directory('${directory.path}/models'));

    await state.addModelBytes('picked.gguf', [4, 3, 2, 1]);

    expect(state.models, hasLength(1));
    expect(await File(state.models.single.path).readAsBytes(), [4, 3, 2, 1]);
    expect(mockPreferences.getStringList('models'), [state.models.single.path]);
  });

  test('persists key configuration without losing usage totals', () {
    final key = GatewayKey(name: 'test', secret: 'secret', rpm: 17)
      ..requests = 3
      ..inputTokens = 40
      ..outputTokens = 12;
    final restored = GatewayKey.fromJson(key.toJson());
    expect(restored.name, 'test');
    expect(restored.rpm, 17);
    expect(restored.requests, 3);
    expect(restored.inputTokens, 40);
    expect(restored.outputTokens, 12);
  });

  test('persists request log fields', () {
    final log = GatewayLog(
      time: DateTime.utc(2026, 1, 2),
      keyName: 'desktop',
      path: '/v1/chat/completions',
      status: 200,
      inputTokens: 20,
      outputTokens: 8,
      latencyMs: 312,
    );
    final restored = GatewayLog.fromJson(log.toJson());
    expect(restored.path, '/v1/chat/completions');
    expect(restored.status, 200);
    expect(restored.inputTokens, 20);
    expect(restored.outputTokens, 8);
    expect(restored.latencyMs, 312);
  });
}
