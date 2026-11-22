import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_model_hub/api_gateway.dart';
import 'package:local_model_hub/main.dart';

void main() {
  testWidgets('persists imported models in app storage', (tester) async {
    final directory = await Directory.systemTemp.createTemp('model-hub-test');
    addTearDown(() => directory.delete(recursive: true));
    SharedPreferences.setMockInitialValues({});
    final source = File('${directory.path}/sample.gguf');
    await source.writeAsBytes([1, 2, 3]);
    final state = HubState(modelDirectoryProvider: () async => Directory('${directory.path}/models'));
    await state.addModel(source.path);
    expect(state.models, hasLength(1));
    expect(state.models.single.path, isNot(source.path));
    expect(await File(state.models.single.path).readAsBytes(), [1, 2, 3]);
  });

  testWidgets('renders overview and mobile page navigation', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ModelHubApp());
    await tester.pumpAndSettle();
    expect(find.byType(OverviewPage), findsOneWidget);

    await tester.tap(find.text('模型').last);
    await tester.pumpAndSettle();
    expect(find.byType(ModelsPage), findsOneWidget);
    expect(find.text('模型库为空'), findsOneWidget);

    await tester.tap(find.text('请求日志').last);
    await tester.pumpAndSettle();
    expect(find.byType(ActivityPage), findsOneWidget);
    expect(find.text('暂无请求'), findsOneWidget);
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
