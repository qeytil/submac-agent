import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/cases.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import '../widgets/ask_bar.dart';
import '../widgets/chat/activity.dart';
import '../widgets/chat/edge_fade.dart';
import '../widgets/composer.dart';
import '../widgets/message_view.dart' show selectedReply;
import 'case_file_screen.dart';
import 'home_screen.dart' show ChatList, FloatIcon, chatTopInset;

/// The Case Room: the normal chat, bound to one case, plus a Case File affordance and the Mode / Abilities pills
/// under the composer (docs/investigation.md §7). No fork of the chat pipeline: it reuses ChatList, the greeting
/// shape and the Composer, and only adds the case's own furniture.
class CaseScreen extends StatefulWidget {
  const CaseScreen({super.key, required this.caseId});
  final String caseId;

  @override
  State<CaseScreen> createState() => _CaseScreenState();
}

class _CaseScreenState extends State<CaseScreen> {
  late final AppState _state = context.read<AppState>();

  /// The chat that was open before the room, so leaving puts the main chat back where it was.
  String? _from;
  bool _opened = false;

  @override
  void initState() {
    super.initState();
    _from = _state.currentId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _state.openCase(widget.caseId);
      if (mounted) setState(() => _opened = true);
    });
  }

  /// The phone's Back (or the bar's back): leave the room and put the main chat back.
  Future<void> _restore() async {
    final from = _from;
    if (from == null) return;
    // Only if we are still in a case chat (nothing else took over meanwhile).
    if (Cases.I.byConv(_state.currentId) == null) return;
    if (from == _state.currentId) return;
    if (!_state.conversations.any((c) => c.id == from)) return;
    await _state.openConversation(from);
  }

  Future<void> _caseFile(Case c) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => CaseFileScreen(caseId: c.id)));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = Cases.I.byId(widget.caseId) ?? Cases.I.byConv(state.currentId);
    if (c == null) {
      return const Scaffold(body: SizedBox.shrink());
    }
    final loading = !_opened || state.loadingMessages;
    final empty = state.messages.isEmpty;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_restore());
      },
      child: Scaffold(
        body: GestureDetector(
          onTap: () {
            FocusScope.of(context).unfocus();
            selectedReply.value = null;
          },
          child: BackdropGroup(
            child: Stack(children: [
              FloatingChatFrame(
                body: Padding(
                  padding: EdgeInsets.only(bottom: loading || empty ? ChatFooterInset.of(context) : 0),
                  child: AnimatedSwitcher(
                    duration: SubMotion.of(context, SubMotion.base),
                    switchInCurve: SubMotion.settle,
                    switchOutCurve: SubMotion.leave,
                    layoutBuilder: SubMotion.fillLayout,
                    child: loading
                        ? Padding(
                            key: const ValueKey('l'),
                            padding: EdgeInsets.only(top: chatTopInset(context)),
                            child: const Center(child: StatusWord('Opening')),
                          )
                        : empty
                            ? Padding(
                                key: const ValueKey('e'),
                                padding: EdgeInsets.only(top: chatTopInset(context)),
                                child: CaseGreeting(item: c),
                              )
                            : const ChatList(key: ValueKey('m')),
                  ),
                ),
                footer: const Column(mainAxisSize: MainAxisSize.min, children: [
                  AskBar(),
                  TaskBar(),
                  Composer(perChatDrafts: true),
                ]),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _CaseBar(
                  title: c.title,
                  onBack: () => Navigator.maybePop(context),
                  onFile: () => _caseFile(c),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The room's top row, the same floating shape as the chat's: back on the start side, the case title in a light
/// pill, and the Case File button on the end side. No bar, no band: the chat shows through between the pieces.
class _CaseBar extends StatelessWidget {
  const _CaseBar({required this.title, required this.onBack, required this.onFile});
  final String title;
  final VoidCallback onBack;
  final VoidCallback onFile;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Lux.gutter - Space.x3, Space.x2, Lux.gutter - Space.x3, Space.x2),
        child: SizedBox(
          height: Lux.tap,
          child: Row(children: [
            FloatIcon(key: const ValueKey('case-back'), icon: 'back', tooltip: tr('Back to cases'), onTap: onBack),
            const SizedBox(width: Space.x2),
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FrostedSurface(
                  wash: 0.24,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(Space.x3, Space.x1, Space.x3, Space.x1),
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600, height: 1.2)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: Space.x2),
            FloatIcon(key: const ValueKey('case-file'), icon: 'folder', tooltip: tr('Case file'), onTap: onFile),
          ]),
        ),
      ),
    );
  }
}

/// The empty case room: the case seal (its number in a thin ring), the title, and one line. Quiet, text-first.
class CaseGreeting extends StatelessWidget {
  const CaseGreeting({super.key, required this.item});
  final Case item;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: Lux.gutter + Space.x4),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: p.border)),
                alignment: Alignment.center,
                child: Text(item.number.toString().padLeft(3, '0'), style: Brand.serif(size: 26, color: p.text, height: 1)),
              ),
              const SizedBox(height: Space.x4),
              Text(item.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Brand.serif(size: AppText.displayLarge, color: p.text, height: 1.2)),
              const SizedBox(height: Space.x2),
              Text('${item.numberLabel} · ${item.statusWord}', textAlign: TextAlign.center, style: AppText.captionStyle.copyWith(color: p.muted)),
              const SizedBox(height: Space.x3),
              Text(tr('What do we know so far?'), textAlign: TextAlign.center, style: AppText.bodyStyle.copyWith(color: p.muted)),
              const SizedBox(height: Lux.turnGap * 2),
            ],
          ),
        ),
      ),
    );
  }
}
