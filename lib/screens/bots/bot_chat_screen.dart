import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../app_state.dart';
import '../../services/digital_human/person.dart';
import '../../services/digital_human/awareness.dart';
import '../../theme.dart';
import '../../ui/tokens.dart';
import '../../widgets/motion.dart';
import 'bots_feed_screen.dart';

/// Enhanced chat with one digital human — WhatsApp-style bubbles, read receipts,
/// typing indicators, and presence-aware composer.
class BotChatScreen extends StatefulWidget {
  const BotChatScreen({super.key, required this.person});
  final DigitalPerson person;

  @override
  State<BotChatScreen> createState() => BotChatScreenState();
}

class BotChatScreenState extends State<BotChatScreen> {
  final _ctrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_Message> _messages = [];
  bool _typing = false;
  bool _sending = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();
    setState(() => _sending = true);
    _addMessage(_Message(role: 'user', text: text, time: DateTime.now()));
    widget.person.markSpoken();
    // Simulate bot thinking
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() => _typing = true);
    });
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      final response = _generateResponse(text);
      setState(() => _typing = false);
      _addMessage(_Message(role: 'bot', text: response, time: DateTime.now()));
      widget.person.memory.remember('message', response, topic: text.split(' ').take(3).join(' '));
      widget.person.awareness.note(AwarenessInsight(title: response, source: 'response'));
    });
  }

  String _generateResponse(String input) {
    final lower = input.toLowerCase();
    if (lower.contains('hello') || lower.contains('hi')) return 'Hello! I\'m ${widget.person.name}. How can I help you today?';
    if (lower.contains('how are you')) return 'I\'m doing well — been thinking about a few things while you were away. What\'s on your mind?';
    if (lower.contains('what can you')) return 'I can research topics, track changes in things you care about, summarize long reads, or just keep an eye on things while you focus on other work.';
    if (lower.contains('remember')) return 'I remember that from earlier — want me to recall more details?';
    if (lower.contains('who are you')) return 'I\'m ${widget.person.name}, a digital human here to help. Think of me as a colleague who never sleeps and always pays attention.';
    return 'Interesting — tell me more. I\'m listening.';
  }

  void _addMessage(_Message msg) {
    _messages.add(msg);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            _buildHeader(p),
            const Divider(height: 1, thickness: 0.5),
            // Messages
            Expanded(
              child: _messages.isEmpty
                  ? _EmptyChat(person: widget.person)
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.all(Space.x4),
                      itemCount: _messages.length + (_typing ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i == _messages.length) return _TypingIndicator();
                        final msg = _messages[i];
                        return _Bubble(msg: msg, isBot: msg.role == 'bot');
                      },
                    ),
            ),
            // Composer
            _Composer(ctrl: _ctrl, onSend: _send, isDisabled: _sending),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(Palette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.x4, Space.x2, Space.x4, Space.x2),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
            onPressed: () => Navigator.pop(context),
          ),
          _HeaderAvatar(person: widget.person),
          const SizedBox(width: Space.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.person.name, style: AppText.titleStyle.copyWith(color: p.text)),
                InkText(
                  _presenceLabel(widget.person.presence),
                  style: AppText.metaStyle.copyWith(color: p.muted),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: () => showModalBottomSheet(
              context: context,
              backgroundColor: Colors.transparent,
              builder: (_) => BotProfileSheet(person: widget.person),
            ),
          ),
        ],
      ),
    );
  }

  String _presenceLabel(PresenceState s) => switch (s) {
        PresenceState.offline => 'Offline',
        PresenceState.online => 'Online',
        PresenceState.thinking => 'Thinking...',
        PresenceState.working => 'Working on something',
      };
}

class _HeaderAvatar extends StatelessWidget {
  const _HeaderAvatar({required this.person});
  final DigitalPerson person;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = PresenceStateColors.colorOf(person.presence);
    return GestureDetector(
      onTap: () => showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (_) => BotProfileSheet(person: person),
      ),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color.withValues(alpha: 0.3), color]),
        ),
        child: Center(
          child: Text(
            person.name.isNotEmpty ? person.name[0].toUpperCase() : '?',
            style: Brand.display(size: 20, color: p.bg),
          ),
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.person});
  final DigitalPerson person;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    PresenceStateColors.colorOf(person.presence).withValues(alpha: 0.2),
                    PresenceStateColors.colorOf(person.presence),
                  ],
                ),
              ),
              child: Center(
                child: Text(
                  person.name.isNotEmpty ? person.name[0].toUpperCase() : '?',
                  style: Brand.display(size: 36, color: p.bg),
                ),
              ),
            ),
            const SizedBox(height: Space.x4),
            Text('Welcome, ${person.name}', style: Brand.display(size: 24, color: p.text)),
            const SizedBox(height: Space.x2),
            InkText('Start a conversation. I\'ll remember everything we discuss.',
                style: AppText.leadStyle.copyWith(color: p.muted), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.msg, required this.isBot});
  final _Message msg;
  final bool isBot;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final isUser = !isBot;
    return Align(
      alignment: isUser ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        child: Material(
          color: Colors.transparent,
          child: Container(
            margin: EdgeInsets.only(
              bottom: Space.x2,
              left: isUser ? Space.x12 : Space.x2,
              right: isUser ? Space.x2 : Space.x12,
            ),
            padding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x2),
            decoration: BoxDecoration(
              color: isUser ? p.text : p.bubble,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(Radii.row),
                topRight: const Radius.circular(Radii.row),
                bottomLeft: Radius.circular(isUser ? Radii.row : Space.x1),
                bottomRight: Radius.circular(isUser ? Space.x1 : Radii.row),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(msg.text, style: AppText.bodyStyle.copyWith(color: isUser ? p.bg : p.text)),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatTime(msg.time),
                      style: AppText.captionStyle.copyWith(color: isUser ? p.faint : p.muted),
                    ),
                    if (isUser) ...[
                      const SizedBox(width: Space.x1),
                      Icon(Icons.done_all_rounded, size: 14, color: p.muted),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _TypingIndicator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: Space.x2, bottom: Space.x2),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x2),
            decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(Radii.row)),
            child: const _ThreeDots(),
          ),
        ],
      ),
    );
  }
}

class _ThreeDots extends StatefulWidget {
  const _ThreeDots();
  @override
  State<_ThreeDots> createState() => _ThreeDotsState();
}

class _ThreeDotsState extends State<_ThreeDots> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late List<Animation<double>> _dots;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _dots = List.generate(3, (i) => Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Interval(i * 0.25, 1.0, curve: Curves.easeInOut)),
    ));
    _ctrl.repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(
      children: List.generate(3, (i) => AnimatedBuilder(
            animation: _dots[i],
            builder: (_, __) => Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: p.muted.withValues(alpha: _dots[i].value),
                shape: BoxShape.circle,
              ),
            ),
          )),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.ctrl, required this.onSend, this.isDisabled = false});
  final TextEditingController ctrl;
  final VoidCallback onSend;
  final bool isDisabled;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2),
      decoration: BoxDecoration(
        color: p.composer,
        border: Border(top: BorderSide(color: p.hairline, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: ctrl,
              enabled: !isDisabled,
              decoration: InputDecoration(
                hintText: 'Message...',
                filled: true,
                fillColor: p.bubble,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.row),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x3),
                suffixIcon: isDisabled
                    ? const SizedBox.shrink()
                    : IconButton(
                        icon: const Icon(Icons.send_rounded, size: 20),
                        onPressed: onSend,
                        color: p.text,
                      ),
              ),
              style: AppText.bodyStyle.copyWith(color: p.text),
              maxLines: 4,
              minLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message {
  const _Message({required this.role, required this.text, required this.time});
  final String role; // 'user' | 'bot'
  final String text;
  final DateTime time;
}
