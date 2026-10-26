import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/today_screen.dart';
import '../app_state.dart';
import '../models.dart';
import '../screens/connectors_screen.dart';
import '../screens/files_screen.dart';
import '../screens/projects_screen.dart';
import '../screens/settings_screen.dart';
import '../services/chat_search.dart';
import '../services/projects.dart';
import 'motion.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';
import 'logo.dart';
import 'lux_kit.dart';
import 'bot_list.dart';
import '../services/bots.dart';
import '../services/offices.dart';
import '../services/inbox.dart';
import '../screens/inbox_screen.dart';
import 'chat/entrance.dart';
import '../services/reply_text.dart' show cleanGlyphs;

class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  String _query = '';
  // CB-32: chats whose saved words match the query (id -> the matching line). Filled after a short pause in typing.
  Map<String, String> _bodyHits = const {};
  Timer? _searchTimer;
  int _searchGen = 0;

  void _onQuery(String v) {
    setState(() => _query = v);
    _searchTimer?.cancel();
    final gen = ++_searchGen;
    if (v.trim().length < ChatSearch.minChars) {
      if (_bodyHits.isNotEmpty) setState(() => _bodyHits = const {});
      return;
    }
    _searchTimer = Timer(ChatSearch.debounce, () async {
      if (!mounted) return;
      final state = context.read<AppState>();
      final store = state.repo.store;
      final botChats = state.botConvIds;
      final ids = (state.conversations.where((c) => !c.archived && !c.packedAway && !botChats.contains(c.id)).toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)))
          .map((c) => c.id);
      final hits = await ChatSearch(store.rowsForSearch).search(ids, v);
      if (!mounted || gen != _searchGen) return;
      setState(() => _bodyHits = hits);
    });
  }
  // Search only takes focus when tapped: opening the menu never brings up the keyboard.
  final FocusNode _searchFocus = FocusNode(canRequestFocus: false);

  void _onProjects() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    Projects.I.addListener(_onProjects);
  }

  @override
  void dispose() {
    Projects.I.removeListener(_onProjects);
    _searchFocus.dispose();
    _searchTimer?.cancel();
    super.dispose();
  }

  Map<String, List<Conversation>> _group(List<Conversation> list) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final groups = <String, List<Conversation>>{};
    void add(String k, Conversation c) => (groups[k] ??= []).add(c);
    for (final c in list.where((c) => c.pinned)) {
      add('Pinned', c);
    }
    for (final c in list.where((c) => !c.pinned)) {
      final d = DateTime(c.updatedAt.year, c.updatedAt.month, c.updatedAt.day);
      final diff = today.difference(d).inDays;
      if (diff <= 0) {
        add('Today', c);
      } else if (diff == 1) {
        add('Yesterday', c);
      } else if (diff <= 7) {
        add('Previous 7 days', c);
      } else if (diff <= 30) {
        add('Previous 30 days', c);
      } else {
        add('Older', c);
      }
    }
    return groups;
  }

  /// The menu rebuilds only when something it lists changes, never on every chat update: a reply streaming in used
  /// to rebuild the whole drawer many times a second, which made opening and closing it stutter.
  static int _listKey(AppState s) => Object.hashAll([
        s.currentId,
        s.loadingConversations,
        s.currentProject?.id,
        s.repo.email,
        s.botConvIds.length,
        for (final c in s.conversations) Object.hash(c.id, c.title, c.pinned, c.archived, c.packedAway, c.updatedAt),
      ]);

  @override
  Widget build(BuildContext context) {
    context.select<AppState, int>(_listKey);
    final state = context.read<AppState>();
    final p = Palette.of(context);
    final q = _query.toLowerCase();
    final inProject = Projects.I.chatProject;
    // Chats inside a project live in that project; search still finds them.
    // Each bot's chat lives under Bots, not in the chat list.
    final botChats = state.botConvIds;
    final visible = state.conversations
        .where((c) => !c.archived && !botChats.contains(c.id) && (q.isEmpty ? !inProject.containsKey(c.id) : c.title.toLowerCase().contains(q) || _bodyHits.containsKey(c.id)))
        .toList();
    final groups = _group(visible);
    final email = state.repo.email ?? '';
    return Drawer(
      width: MediaQuery.of(context).size.width * 0.84,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          // SubMac motion: the menu's rows rise and settle in turn as it opens.
          children: revealRows([
            // The wordmark-quiet top: search straight on the paper (no field box), then the few places, as words.
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x2, Space.x4, 0),
              child: LuxSearchField(
                fieldKey: const ValueKey('menu-search'),
                focusNode: _searchFocus,
                onTap: () {
                  _searchFocus.canRequestFocus = true;
                  _searchFocus.requestFocus();
                },
                onTapOutside: (_) {
                  // Back to "only on a tap", so nothing hands the keyboard back to search later.
                  _searchFocus.unfocus();
                  _searchFocus.canRequestFocus = false;
                },
                onChanged: _onQuery,
              ),
            ),
            const SizedBox(height: Space.x2),
            _NavTile(
              title: 'New chat',
              onTap: () {
                state.newChat();
                Navigator.pop(context);
              },
            ),
            // Today shows once there is a bot or a routine (PLAN.md 3.3).
            if (TodayScreen.hasFeed)
              _NavTile(
                title: 'Today',
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const TodayScreen()));
                },
              ),
            _NavTile(
              title: 'Apps',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectorsScreen()));
              },
            ),
            _NavTile(
              title: 'Files',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const FilesScreen()));
              },
            ),
            // The inbox while something is unread (it used to sit in the top bar). No app name in the menu.
            ValueListenableBuilder<int>(
              valueListenable: Inbox.I.unread,
              builder: (context, n, _) => n <= 0
                  ? const SizedBox.shrink()
                  : _NavTile(
                      title: 'Inbox',
                      count: n,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const InboxScreen()));
                      },
                    ),
            ),
            const SizedBox(height: Space.x1),
            Expanded(
              child: state.loadingConversations && state.conversations.isEmpty
                  ? const Center(child: RedDot(size: 18, animate: true))
                  : RefreshIndicator(
                      onRefresh: state.refreshConversations,
                      color: p.text,
                      backgroundColor: p.sidebar,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: Space.x2),
                        children: [
                          // Grok-style: Chief, Bots and Teams as quiet, foldable sections. Search finds them too.
                          AnimatedBuilder(
                            animation: Listenable.merge([Bots.I, Offices.I]),
                            builder: (context, _) => DrawerBots(
                              query: q,
                              selectedConv: state.currentId,
                              onOpen: () => Navigator.pop(context),
                            ),
                          ),
                          if (q.isEmpty) ...[
                            LuxSection(
                              'Projects',
                              padding: const EdgeInsetsDirectional.fromSTEB(Space.x3, Space.x5, 0, 0),
                              trailing: LuxTap(
                                key: const ValueKey('menu-new-project'),
                                onTap: () async {
                                  final pr = await createProjectFlow(context);
                                  if (pr != null && context.mounted) {
                                    Navigator.pop(context);
                                    Navigator.push(context, MaterialPageRoute(builder: (_) => ProjectScreen(projectId: pr.id)));
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x2),
                                  child: Text(tr('New'), style: AppText.metaStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ),
                            for (final (i, pr) in Projects.I.list.indexed)
                              FadeSlideIn(
                                key: ValueKey('pj${pr.id}'),
                                delay: SubMotion.staggerFor(i) ~/ 2,
                                child: _ProjectTile(project: pr, selected: state.currentProject?.id == pr.id),
                              ),
                            if (Projects.I.list.isEmpty)
                              Padding(
                                padding: const EdgeInsetsDirectional.fromSTEB(Space.x3, 0, Space.x3, Space.x1),
                                child: Text(tr('Keep chats, files and instructions together.'),
                                    style: AppText.metaStyle.copyWith(color: p.muted)),
                              ),
                          ],
                          for (final entry in groups.entries) ...[
                            LuxSection(entry.key, padding: const EdgeInsetsDirectional.fromSTEB(Space.x3, Space.x5, Space.x3, Space.x1)),
                            for (final c in entry.value)
                              _ChatTile(
                                conversation: c,
                                // The matching line shows under the title when only the words matched.
                                match: q.isEmpty || c.title.toLowerCase().contains(q) ? null : _bodyHits[c.id],
                              ),
                          ],
                          if (visible.isEmpty && !(q.isNotEmpty && DrawerBots.anyHit(q)))
                            Padding(
                              padding: const EdgeInsets.all(Space.x6),
                              child: Text(tr(q.isEmpty ? 'No chats yet' : 'No results'),
                                  textAlign: TextAlign.center, style: AppText.bodyStyle.copyWith(color: p.muted)),
                            ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: Space.x2),
            // Settings at the foot: the word and the account under it. No avatar disc.
            LuxTap(
              key: const ValueKey('menu-settings'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
              },
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x3, Space.x5, Space.x4),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(tr('Settings'), style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
                      if (email.isNotEmpty)
                        Text(email, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.faint)),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  final Project project;
  final bool selected;
  const _ProjectTile({required this.project, required this.selected});

  @override
  Widget build(BuildContext context) {
    final n = Projects.I.chatsIn(project.id).length;
    return LuxRow(
      dense: true,
      title: project.name,
      value: n > 0 ? '$n' : null,
      selected: selected,
      onTap: () {
        Navigator.pop(context);
        Navigator.push(context, MaterialPageRoute(builder: (_) => ProjectScreen(projectId: project.id)));
      },
    );
  }
}

class _NavTile extends StatelessWidget {
  final String title;
  final VoidCallback onTap;
  final int count;
  const _NavTile({required this.title, required this.onTap, this.count = 0});

  @override
  Widget build(BuildContext context) => LuxRow(
        dense: true,
        title: tr(title),
        value: count > 0 ? (count > 9 ? '9+' : '$count') : null,
        selected: count > 0,
        padding: const EdgeInsetsDirectional.symmetric(horizontal: Space.x5, vertical: Space.x2 + 2),
        onTap: onTap,
      );
}

/// One chat in the menu: its title, and a quiet second line only when it says something (backed up, or the words that
/// matched the search). The open chat is set in the full ink weight; no fill behind it.
class _ChatTile extends StatelessWidget {
  final Conversation conversation;
  final String? match;
  const _ChatTile({required this.conversation, this.match});

  @override
  Widget build(BuildContext context) {
    final selected = context.select<AppState, bool>((s) => s.currentId == conversation.id);
    final state = context.read<AppState>();
    final p = Palette.of(context);
    final second = conversation.packedAway ? tr('Backed up. Tap to open') : match;
    return LuxTap(
      selected: selected,
      onTap: () {
        state.openConversation(conversation.id);
        Navigator.pop(context);
      },
      onLongPress: () => showChatActions(context, conversation),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x2 + 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(cleanGlyphs(conversation.title),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.bodyStyle.copyWith(color: selected ? p.text : p.text.withValues(alpha: 0.82), fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
          if (second != null) ...[
            const SizedBox(height: 2),
            Text(second,
                key: match != null && !conversation.packedAway ? ValueKey('menu-search-hit-${conversation.id}') : null,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.captionStyle.copyWith(color: p.muted)),
          ],
        ]),
      ),
    );
  }
}

Future<void> showChatActions(BuildContext context, Conversation c) async {
  final state = context.read<AppState>();
  // The keyboard stays away: closing the sheet must not hand focus back to the message box.
  FocusManager.instance.primaryFocus?.unfocus();
  final choice = await showLuxChoices<String>(context, title: cleanGlyphs(c.title), choices: [
    const LuxChoice('rename', 'Rename'),
    LuxChoice('project', Projects.I.forChat(c.id) == null ? 'Add to project' : 'Move to another project'),
    LuxChoice('pin', c.pinned ? 'Unpin' : 'Pin'),
    LuxChoice('archive', c.archived ? 'Unarchive' : 'Archive'),
    const LuxChoice('delete', 'Delete', destructive: true),
  ]);
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'rename':
      final name = await luxPrompt(context, title: 'Rename chat', initial: c.title);
      if (name != null && name.trim().isNotEmpty) await state.renameConversation(c.id, name.trim());
    case 'project':
      await _pickProject(context, c.id);
    case 'pin':
      state.togglePin(c.id);
    case 'archive':
      state.setArchived(c.id, !c.archived);
    case 'delete':
      final ok = await luxConfirm(context,
          title: 'Delete chat?', message: tr('This will delete "{name}".', {'name': cleanGlyphs(c.title)}), action: 'Delete', destructive: true);
      if (ok) await state.deleteConversation(c.id);
  }
}

Future<void> _pickProject(BuildContext context, String chatId) async {
  final current = Projects.I.forChat(chatId);
  final choice = await showLuxChoices<String>(context, title: 'Project', selected: current?.id, choices: [
    for (final pr in Projects.I.list) LuxChoice(pr.id, pr.name),
    const LuxChoice('_new', 'New project'),
    if (current != null) const LuxChoice('_none', 'Remove from project'),
  ]);
  if (choice == null) return;
  if (choice == '_none') {
    await Projects.I.assign(chatId, null);
  } else if (choice == '_new') {
    if (!context.mounted) return;
    final pr = await createProjectFlow(context);
    if (pr != null) await Projects.I.assign(chatId, pr.id);
  } else {
    await Projects.I.assign(chatId, choice);
  }
}
