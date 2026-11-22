import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_model_hub/api_gateway.dart';
import 'package:local_model_hub/main.dart';

void main() {
  testWidgets('renders overview and mobile page navigation', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = HubState()..isLoaded = true;
    await tester.pumpWidget(ModelHubApp(home: HubShell(state: state)));
    await tester.pumpAndSettle();
    expect(find.byType(OverviewPage), findsOneWidget);

    await tester.tap(find.text('模型').last);
    await tester.pumpAndSettle();
    expect(find.byType(ModelsPage), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);

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
