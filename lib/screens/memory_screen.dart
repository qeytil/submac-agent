import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/memory_store.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import '../widgets/lux_kit.dart';
import '../widgets/surface.dart';
import '../ui/i18n.dart';

/// What SubMac remembers about the user: view, edit, delete.
class MemoryScreen extends StatelessWidget {
  const MemoryScreen({super.key});

  Future<String?> _edit(BuildContext context, {String initial = '', required String title}) =>
      luxPrompt(context, title: title, initial: initial, hint: 'e.g. Lives in Mogadishu and prefers short answers', maxLines: 4, maxLength: 300);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = Palette.of(context);
    final facts = state.memory.facts;
    return Scaffold(
      appBar: AppBar(
        title: Text('Memory', style: Brand.serif(size: 28, color: p.text)),
        actions: [
          TextButton(
            onPressed: () async {
              final t = await _edit(context, title: 'Add a memory');
              if (t != null && t.trim().isNotEmpty) await state.addMemory(t);
            },
            child: const Text('Add'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 32),
        children: [
          SurfaceGroup(children: [
            LuxSwitchRow(
              title: tr('Remember things'),
              sub: tr('SubMac keeps short notes about you to help next time'),
              value: state.memoryEnabled,
              onChanged: state.setMemoryEnabled,
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            facts.isEmpty
                ? 'Nothing saved yet. Say "remember that…" in any chat, or tap Add.'
                : 'Tap to edit.',
            style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4),
          ),
          const SizedBox(height: 12),
          for (final f in facts) _FactTile(fact: f, onEdit: () async {
            final t = await _edit(context, initial: f.fact, title: 'Edit memory');
            if (t != null && t.trim().isNotEmpty) await state.updateMemory(f, t);
          }),
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 16),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: LuxWordButton('Forget everything', destructive: true, onPressed: () async {
                final ok = await luxConfirm(context,
                    title: 'Forget everything?', message: 'SubMac will forget all saved notes about you.', action: 'Forget all', destructive: true);
                if (ok) await state.clearMemories();
              }),
            ),
          ],
        ],
      ),
    );
  }
}

class _FactTile extends StatelessWidget {
  final MemoryFact fact;
  final VoidCallback onEdit;
  const _FactTile({required this.fact, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    // The shared sky surface: no border, rows apart by space.
    return SurfaceRow(
      margin: const EdgeInsets.only(bottom: Space.x2),
      child: LuxRow(
        title: fact.fact,
        maxLines: 6,
        onTap: onEdit,
        trailing: LuxWordButton('Delete', onPressed: () => state.removeMemory(fact)),
      ),
    );
  }
}
