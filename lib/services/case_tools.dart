import 'case_engine.dart';
import 'case_jobs.dart';
import 'cases.dart';

/// The `case_job` tool (docs/investigation.md §20, §23): the detective's own job queue. Heavy or multi-step work is
/// recorded here so it survives restarts and the section can report one line of status per job.
class CaseTools {
  CaseTools._();

  static const names = {'case_job'};

  static final List<Map<String, dynamic>> definitions = [
    {
      'type': 'function',
      'function': {
        'name': 'case_job',
        'description': 'Track a long or heavy job of this case in its own queue, so it survives restarts: add a job, '
            'update its status (running, done, failed, paused) and its output, or list them. Use it for big scans, long '
            'code builds, batch image/video work. Heavy jobs go to the cloud chain (see docs §23); small ones stay on the phone.',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {'type': 'string', 'enum': ['add', 'update', 'list']},
            'title': {'type': 'string', 'description': 'What the job is, in a few words (add).'},
            'tool': {'type': 'string', 'description': 'The tool it runs, if any (add).'},
            'input': {'type': 'string', 'description': 'The input or instruction (add).'},
            'heavy': {'type': 'boolean', 'description': 'True routes the job to the cloud chain (add).'},
            'id': {'type': 'string', 'description': 'The job id (update).'},
            'status': {'type': 'string', 'enum': ['queued', 'running', 'done', 'failed', 'paused'], 'description': 'New status (update).'},
            'output': {'type': 'string', 'description': 'Where the result is, or a one-line outcome (update).'},
          },
          'required': ['action'],
        },
      },
    },
  ];

  static Future<String> execute(String name, Map<String, dynamic> a, String? convId) async {
    final c = Cases.I.byConv(convId);
    if (c == null) return 'Error: case_job only works inside a case chat.';
    await CaseJobs.I.init();
    final action = '${a['action'] ?? 'list'}';
    if (action == 'list') {
      final jobs = CaseJobs.I.of(c.id);
      if (jobs.isEmpty) return 'No jobs in this case yet.';
      return jobs.map((j) => '- ${j.id}: ${j.title} — ${j.status} on ${CaseEngine.word(j.lane)}${j.output.isEmpty ? '' : ' (${j.output})'}').join('\n');
    }
    if (action == 'add') {
      final title = '${a['title'] ?? ''}'.trim();
      if (title.isEmpty) return 'Error: give the job a title.';
      final lane = CaseEngine.route(heavy: a['heavy'] == true);
      final j = await CaseJobs.I.add(c.id, title: title, tool: '${a['tool'] ?? ''}', input: '${a['input'] ?? ''}', lane: lane);
      return 'Job ${j.id} queued on ${CaseEngine.word(lane)}: $title. Update it (action update) when it starts, finishes or fails.';
    }
    if (action == 'update') {
      final id = '${a['id'] ?? ''}'.trim();
      if (id.isEmpty) return 'Error: give the job id.';
      await CaseJobs.I.update(c.id, id,
          status: a['status'] == null ? null : '${a['status']}', output: a['output'] == null ? null : '${a['output']}');
      return 'Job $id updated.';
    }
    return 'Error: unknown action $action.';
  }
}