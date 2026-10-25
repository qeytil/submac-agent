import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/memory_store.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import '../widgets/surface.dart';
import '../ui/i18n.dart';

/// What SubMac remembers about the user: view, edit, delete.
class MemoryScreen extends StatelessWidget {
  const MemoryScreen({super.key});

  Future<String?> _edit(BuildContext context, {String initial = '', required String title}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          maxLength: 300,
          decoration: const InputDecoration(hintText: 'e.g. Lives in Mogadishu and prefers short answers'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(d, ctrl.text), child: Text(tr('Save'))),
        ],
      ),
    );
  }

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
            SwitchListTile(
              title: const Text('Remember things'),
              subtitle: const Text('SubMac keeps short notes about you to help next time'),
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
            OutlinedButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('Forget everything?'),
                    content: const Text('SubMac will forget all saved notes about you.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Cancel'))),
                      TextButton(
                          onPressed: () => Navigator.pop(d, true),
                          child: Text('Forget all', style: TextStyle(color: p.accent))),
                    ],
                  ),
                );
                if (ok == true) await state.clearMemories();
              },
              child: const Text('Forget everything'),
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
    final p = Palette.of(context);
    final state = context.read<AppState>();
    // The shared sky surface: no border, rows apart by space.
    return SurfaceRow(
      margin: const EdgeInsets.only(bottom: Space.x2),
      child: ListTile(
        title: Text(fact.fact, style: const TextStyle(fontSize: AppText.body, height: 1.4)),
        onTap: onEdit,
        trailing: TextButton(
          onPressed: () => state.removeMemory(fact),
          child: Text(tr('Delete'), style: TextStyle(color: p.muted, fontSize: AppText.meta)),
        ),
      ),
    );
  }
}
