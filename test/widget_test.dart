import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lab1_chat_ui/main.dart';

void main() {
  testWidgets('앱이 뜨고 가짜 대화가 보인다', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatLabApp());

    expect(find.text('AI Chat — 실습 1'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    expect(find.text('오늘 뭐 배워?'), findsOneWidget);

    // TODO 3 — 입력창과 전송 버튼이 있다
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('보내면 내 말풍선 → 점 3개 → AI 답', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatLabApp());

    await tester.enterText(find.byType(TextField), '안녕');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    // 내 메시지가 즉시 보이고, 응답 대기 중 표시가 나온다
    expect(find.text('안녕'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300)); // 전환 200ms
    expect(find.bySemanticsLabel('AI가 답하는 중'), findsOneWidget);

    // 응답 도착
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('에 대한 답입니다'), findsOneWidget);
    expect(find.bySemanticsLabel('AI가 답하는 중'), findsNothing);
  });

  testWidgets('500 오류 → 오류 말풍선 + 다시 시도', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatLabApp());

    await tester.enterText(find.byType(TextField), '500 오류 내 줘');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('⚠️ 응답을 받지 못했습니다'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);

    // 오류 뒤에도 입력이 된다
    await tester.enterText(find.byType(TextField), '다른 질문');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('다른 질문”에 대한 답입니다'), findsOneWidget);
    expect(find.text('다시 시도'), findsNothing);
  });

  testWidgets('다시 시도는 마지막 메시지를 다시 보낸다', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatLabApp());

    await tester.enterText(find.byType(TextField), '401');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('🔑 키/권한을 확인해 주세요'), findsOneWidget);

    await tester.tap(find.text('다시 시도'));
    await tester.pump();
    // 재시도 중에는 오류 대신 점 3개
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.bySemanticsLabel('AI가 답하는 중'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    // 같은 메시지라 같은 오류가 다시 나오고, 내 말풍선은 하나뿐이다
    expect(find.text('🔑 키/권한을 확인해 주세요'), findsOneWidget);
    expect(find.text('401'), findsOneWidget);
  });

  testWidgets('429는 1s → 2s 백오프 후 오류', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatLabApp());

    await tester.enterText(find.byType(TextField), '429');
    await tester.tap(find.byIcon(Icons.send));

    // 1.2s 호출 + 1s 대기 + 1.2s + 2s 대기 + 1.2s ≈ 6.6s
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('⏳ 잠시 후 다시 시도해 주세요'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('⏳ 잠시 후 다시 시도해 주세요'), findsOneWidget);
  });

  testWidgets('timeout → 시간 초과 문구', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatLabApp());

    await tester.enterText(find.byType(TextField), 'timeout');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('⌛ 응답 시간이 초과되었습니다'), findsOneWidget);
  });
}
