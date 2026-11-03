import 'package:flutter/material.dart';

import '../services/billing/billing_copy.dart';
import '../services/mcp_oauth.dart';

/// Asks for the key of an app connected with a key (no sign-in page), e.g. Composio. Returns the key, or null.
Future<String?> askAppKey(BuildContext context, McpPreset pr) async {
  final c = TextEditingController();
  final key = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Connect ${pr.name}'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (pr.keyHelp.isNotEmpty) Text(pr.keyHelp),
        const SizedBox(height: 12),
        TextField(
          controller: c,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: '${pr.name} key', hintText: pr.keyHint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        const SizedBox(height: 8),
        const Text('It stays encrypted on this phone. Disconnect any time in Apps.'),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Not now'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Connect')),
      ],
    ),
  );
  c.dispose();
  return key == null || key.isEmpty ? null : key;
}
