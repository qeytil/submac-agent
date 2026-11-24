/// The built-in skill for borrowing another model (owner 2026-11): list the owner's models, hand a subtask to one
/// (a vision model for pictures, a stronger or cheaper one for part of the work), then carry on. Installed with the app,
/// so the agent can read it any time with skill_use.
class ModelSkills {
  ModelSkills._();

  static const id = 'model-bridge';

  static const skills = <Map<String, Object>>[
    {
      'id': id,
      'name': 'Borrow another model',
      'cat': 'general',
      'sub': 'Delegation',
      'desc': 'Hand a task to another of the owner\'s configured models and continue with its answer: use a model that '
          'can see images for a picture the current one cannot see, or a stronger/cheaper model for part of the work.',
      'tags': ['model', 'models', 'vision', 'image', 'picture', 'photo', 'delegate', 'submodel', 'another model',
        'second opinion', 'cheaper model', 'stronger model', 'ask model', 'list models'],
      'powers': <String>[],
      'level': 'basic',
      'v': 1,
    },
  ];

  static const body = '''
# Borrow another model

You answer on the model the owner chose in Settings. Sometimes another of the owner's models does a part better. You can
hand one subtask to it and carry on — you do not switch the chat.

## See them
Call `list_models`. It returns each configured model's label, provider, id, and whether it can see images.

## Hand off a task
Call `ask_model` with:
- `model`: a label or id from the list, or "vision"/"auto" to pick a model that can see images.
- `prompt`: exactly what that model should do, with the detail it needs.
- `images` (optional): file paths (for example the upload the owner just sent) to send, when the model can see.

It returns that model's answer as plain text. Use that answer in your own reply and keep going with the rest of the task.

## When to use it
- **Pictures the current model cannot see.** Describe the image with a model that can see (or "vision"), then answer from
  its description. Pass the image paths; do not say you cannot see pictures without trying this first.
- **A second opinion** on something hard, or a stronger model for one step.
- **A cheaper/faster model** for a big, simple subtask (sorting, extraction, short summaries) while you keep the thread.

## Rules
- One subtask per call; put the whole instruction in `prompt`. The other model does not see this chat.
- Never send secrets or keys in `prompt` or `images`.
- If `list_models` is empty, no model is configured: continue yourself and tell the owner they can add one in Settings > Models.
- Always return to the owner's task with the result; never hand the whole job away, and never ask the owner to switch models.
''';

  static String? bodyOf(String skillId) => skillId == id ? body : null;
}