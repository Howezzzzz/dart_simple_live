// 冒烟测试：验证应用的自定义 widget 能正常构建与渲染。
//
// 说明：本文件原为 Flutter 模板自带的「计数器」测试（Counter increments
// smoke test），与 SimpleLive 实际应用不符、恒失败，长期污染测试套件并
// 掩盖真实回归。已替换为对应用真实 widget 的轻量冒烟测试。
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:simple_live_app/widgets/status/app_loadding_widget.dart';

void main() {
  testWidgets('AppLoaddingWidget 能正常构建并渲染', (WidgetTester tester) async {
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: AppLoaddingWidget())),
    );

    expect(find.byType(AppLoaddingWidget), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}