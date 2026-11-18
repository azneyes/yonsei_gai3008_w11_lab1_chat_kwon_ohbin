import 'dart:async';

import 'package:flutter/material.dart';

void main() => runApp(const ChatLabApp());

class ChatLabApp extends StatelessWidget {
  const ChatLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Chat — 실습 1',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FE4)),
        useMaterial3: true,
      ),
      home: const ChatPage(),
    );
  }
}

/// 대화 한 줄. 서버 없이 화면만 만들기 위한 최소 모델.
class ChatMessage {
  const ChatMessage({required this.text, required this.isUser});

  final String text;
  final bool isUser;
}

// ─────────────────────────────────────────────────────────────────────
// 실습 4 — 오류와 재시도
//
// 프록시(w12/ai) 없이도 오류 화면을 확인할 수 있도록 가짜 AI 클라이언트를 쓴다.
// 메시지에 아래 단어가 들어 있으면 해당 오류를 일부러 낸다.
//   '401'  → 키/권한 오류
//   '429'  → 요청 과다 (1초 → 2초 지수 백오프 후에도 실패)
//   '500'  → 서버 오류
//   '타임아웃' 또는 'timeout' → 시간 초과
// 그 외에는 약 1.2초 뒤 정상 응답한다.
// 실제 프록시를 붙일 때는 FakeAiClient 대신 HTTP로 /api/chat을 부르는
// 클라이언트를 만들고, 상태 코드를 AiException으로 던지면 된다.
// ─────────────────────────────────────────────────────────────────────

/// HTTP 상태 코드를 담은 AI 호출 오류.
class AiException implements Exception {
  const AiException(this.status);

  final int status;

  @override
  String toString() => 'AiException($status)';
}

abstract class AiClient {
  Future<String> chat(String text);
}

class FakeAiClient implements AiClient {
  const FakeAiClient({this.delay = const Duration(milliseconds: 1200)});

  final Duration delay;

  @override
  Future<String> chat(String text) async {
    await Future<void>.delayed(delay);
    final lower = text.toLowerCase();
    if (lower.contains('401')) throw const AiException(401);
    if (lower.contains('429')) throw const AiException(429);
    if (lower.contains('500')) throw const AiException(500);
    if (lower.contains('timeout') || text.contains('타임아웃')) {
      throw TimeoutException('응답 시간 초과');
    }
    return '“$text”에 대한 답입니다. (가짜 AI 응답)';
  }
}

/// 오류 → 화면에 보여 줄 문구. 401/429/500/timeout을 한 상태(_error)로 모은다.
String errorMessageFor(Object error) {
  if (error is AiException) {
    return switch (error.status) {
      401 => '🔑 키/권한을 확인해 주세요',
      429 => '⏳ 잠시 후 다시 시도해 주세요',
      500 => '⚠️ 응답을 받지 못했습니다',
      _ => '📡 네트워크를 확인해 주세요',
    };
  }
  if (error is TimeoutException) return '⌛ 응답 시간이 초과되었습니다';
  return '📡 네트워크를 확인해 주세요';
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, this.ai = const FakeAiClient()});

  final AiClient ai;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  /// 실습용 가짜 대화 — 전송으로 추가해야 하므로 const가 아닌 수정 가능한 리스트.
  final List<ChatMessage> _messages = [
    const ChatMessage(text: '오늘 뭐 배워?', isUser: true),
    const ChatMessage(text: 'AI 챗봇에 움직이는 응답을 붙입니다.', isUser: false),
    const ChatMessage(text: '타이핑 점은 왜 필요해요?', isUser: true),
    const ChatMessage(
        text: '응답이 1초를 넘으면 앱이 멈춘 것처럼 보이기 때문입니다.', isUser: false),
  ];

  // TODO 3 — 입력창 컨트롤러
  final TextEditingController _controller = TextEditingController();

  // 실습 4 — 상태: idle · sending/typing · done · error
  bool _sending = false; // 전송 중 — 입력 잠금 (연타 방지)
  bool _typing = false; // 응답 대기 — 점 3개
  String? _error; // 오류 문구 — null이면 오류 없음
  String? _lastPrompt; // 재시도할 마지막 메시지

  static const _timeout = Duration(seconds: 30);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // TODO 3 — 전송
  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _messages.add(ChatMessage(text: text, isUser: true));
    });
    _controller.clear();
    _ask(text);
  }

  // 실습 4 — 재시도: 마지막 메시지를 다시 보낸다 (내 말풍선은 다시 추가하지 않는다)
  void _retry() {
    final prompt = _lastPrompt;
    if (prompt == null || _sending) return;
    _ask(prompt);
  }

  // 실습 4 — AI 호출: sending/typing → done 또는 error
  Future<void> _ask(String text) async {
    setState(() {
      _lastPrompt = text;
      _error = null;
      _sending = true;
      _typing = true;
    });
    try {
      final answer = await _chatWithBackoff(text);
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(text: answer, isUser: false));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errorMessageFor(e));
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _typing = false;
        });
      }
    }
  }

  // 실습 4 — 429면 지수 백오프 1s → 2s 후 다시 시도, 그래도 실패하면 오류로 넘긴다.
  // 모든 호출은 30초가 지나면 timeout 오류가 된다.
  Future<String> _chatWithBackoff(String text) async {
    const backoffs = [Duration(seconds: 1), Duration(seconds: 2)];
    for (var attempt = 0;; attempt++) {
      try {
        return await widget.ai.chat(text).timeout(_timeout);
      } on AiException catch (e) {
        if (e.status != 429 || attempt >= backoffs.length) rethrow;
        await Future<void>.delayed(backoffs[attempt]);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 접근성 — Reduce Motion이면 전환 애니메이션을 끄고 결과만 즉시 보여 준다.
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    return Scaffold(
      // TODO 5 — 키보드가 올라오면 body가 줄어들어 입력창이 키보드 위에 남는다
      resizeToAvoidBottomInset: true,
      appBar: AppBar(title: const Text('AI Chat — 실습 1')),
      // TODO 5 — SafeArea로 노치·홈 인디케이터를 피한다
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              // TODO 4 — 빈 상태: Stack으로 ListView 위에 문구를 겹친다
              child: Stack(
                children: [
                  ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    // TODO 5 — 목록을 끌어내리면 키보드가 내려간다
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[_messages.length - 1 - index];
                      return _Bubble(message: message);
                    },
                  ),
                  if (_messages.isEmpty)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 48,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '무엇이든 물어보세요',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

            // 실습 4 — 상태 영역: 타이핑 점 ↔ 오류 말풍선 ↔ 없음을 AnimatedSwitcher로 전환
            AnimatedSwitcher(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(
                  sizeFactor: animation,
                  child: child,
                ),
              ),
              child: _error != null
                  ? _ErrorBubble(
                      key: const ValueKey('error'),
                      message: _error!,
                      onRetry: _sending ? null : _retry,
                    )
                  : _typing
                      ? _TypingBubble(
                          key: const ValueKey('typing'),
                          animate: !reduceMotion,
                        )
                      : const SizedBox.shrink(key: ValueKey('idle')),
            ),

            // TODO 3 — 입력창 (TextField + 전송 버튼)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        // 피드포워드 — 지금 보낼 수 있는지 안내문으로 알린다
                        hintText: _sending ? 'AI가 답하는 중…' : '메시지를 입력하세요',
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: const Icon(Icons.send),
                    tooltip: '보내기',
                    // 실습 4 — 전송 중에는 버튼을 잠근다 (연타해도 한 번만 전송)
                    onPressed: _sending ? null : _send,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// TODO 2 — 말풍선 2종 (사용자 오른쪽 / AI 왼쪽)
class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isUser = message.isUser;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: isUser
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 14),
          ),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            color: isUser
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// 실습 4 — 오류 말풍선 + 다시 시도 버튼 (SnackBar가 아니라 화면에 남는다)
class _ErrorBubble extends StatelessWidget {
  const _ErrorBubble({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                message,
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('다시 시도'),
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.onErrorContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 실습 3·4 — 응답 대기 중 AI 쪽에 점 3개 (점마다 200ms씩 순서대로)
class _TypingBubble extends StatefulWidget {
  const _TypingBubble({super.key, required this.animate});

  final bool animate;

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600), // 점 3개 × 200ms
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _TypingBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.animate) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        label: 'AI가 답하는 중',
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              // Reduce Motion이면 점 3개를 모두 진하게 고정해서 보여 준다.
              final t =
                  widget.animate ? (_controller.value * 3).floor() % 3 : 2;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Opacity(
                        opacity: i <= t ? 1 : 0.25,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: colorScheme.onSurfaceVariant,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
