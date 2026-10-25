import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'connector_catalog.dart';

/// Token connectors: GitHub and Notion, using a personal token the user pasted.
class ConnectorTools {
  static String githubToken = '';
  static String notionToken = '';

  static const names = {'github_api', 'notion_api'};

  static List<Map<String, dynamic>> definitions() => [
        if (githubToken.isNotEmpty)
          {
            'type': 'function',
            'function': {
              'name': 'github_api',
              'description': 'Call the GitHub REST API as the user (https://api.github.com). '
                  'Examples: GET /user/repos?per_page=20, GET /repos/{owner}/{repo}/issues, '
                  'POST /repos/{owner}/{repo}/issues with {"title":"...","body":"..."}.',
              'parameters': {
                'type': 'object',
                'properties': {
                  'method': {'type': 'string', 'description': 'GET, POST, PATCH, PUT or DELETE'},
                  'path': {'type': 'string', 'description': 'Path starting with /'},
                  'body': {'type': 'object', 'description': 'JSON body for POST/PATCH/PUT'},
                },
                'required': ['method', 'path'],
              },
            },
          },
        if (notionToken.isNotEmpty)
          {
            'type': 'function',
            'function': {
              'name': 'notion_api',
              'description': 'Call the Notion API as the user (https://api.notion.com/v1). '
                  'Examples: POST /search with {"query":"..."}, GET /pages/{id}, GET /blocks/{id}/children, '
                  'POST /pages to create a page, PATCH /blocks/{id}/children to append.',
              'parameters': {
                'type': 'object',
                'properties': {
                  'method': {'type': 'string'},
                  'path': {'type': 'string'},
                  'body': {'type': 'object'},
                },
                'required': ['method', 'path'],
              },
            },
          },
      ];

  static bool isWrite(Map<String, dynamic> a) {
    final m = (a['method'] ?? 'GET').toString().toUpperCase();
    if (m == 'GET') return false;
    // Notion search and database queries are POSTs but only read (the path alone counts, never its ?query).
    final p = ConnectorCatalog.pathOnly('${a['path'] ?? ''}'.trim());
    if (m == 'POST' && RegExp(r'^/?search/?$').hasMatch(p)) return false;
    if (m == 'POST' && RegExp(r'^/?databases/[^/]+/query/?$').hasMatch(p)) return false;
    return true;
  }

  static Future<String> execute(String name, Map<String, dynamic> a) async {
    try {
      final method = (a['method'] ?? 'GET').toString().toUpperCase();
      var path = (a['path'] ?? '/').toString();
      if (!path.startsWith('/')) path = '/$path';
      late Uri uri;
      late Map<String, String> headers;
      if (name == 'github_api') {
        if (githubToken.isEmpty) return 'Error: GitHub is not connected. Ask the user to add a token in Settings > Connectors.';
        uri = Uri.parse('https://api.github.com$path');
        headers = {
          'Authorization': 'Bearer $githubToken',
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'SubMacAgent',
        };
      } else if (name == 'notion_api') {
        if (notionToken.isEmpty) return 'Error: Notion is not connected. Ask the user to add a token in Settings > Connectors.';
        uri = Uri.parse('https://api.notion.com/v1$path');
        headers = {'Authorization': 'Bearer $notionToken', 'Notion-Version': '2022-06-28'};
      } else {
        return 'Error: unknown tool "$name"';
      }
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (a['body'] != null && method != 'GET') {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(a['body']);
      }
      final streamed = await req.send().timeout(const Duration(seconds: 40));
      final r = await http.Response.fromStream(streamed);
      var text = utf8.decode(r.bodyBytes, allowMalformed: true);
      if (text.length > 15000) text = '${text.substring(0, 15000)}\n…[truncated]';
      return 'HTTP ${r.statusCode}\n$text';
    } catch (e) {
      var t = 'Error: $e';
      for (final k in [githubToken, notionToken]) {
        if (k.length >= 6) t = t.replaceAll(k, '•••');
      }
      return t;
    }
  }
}
