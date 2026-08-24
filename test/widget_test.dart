import 'package:flutter_test/flutter_test.dart';

import 'package:platform_p/main.dart';

void main() {
  testWidgets('PJSIP console renders', (WidgetTester tester) async {
    await tester.pumpWidget(const PlatformPApp());

    expect(find.text('PJSIP NATIVE'), findsOneWidget);
    expect(find.text('桌面原生引擎控制台'), findsOneWidget);
    expect(find.text('SIP 账号管理'), findsOneWidget);
    expect(find.text('语音通话'), findsOneWidget);
  });
}
