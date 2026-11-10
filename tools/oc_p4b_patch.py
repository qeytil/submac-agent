import sys, pathlib

def patch(path, old, new):
    p = pathlib.Path(path); s = p.read_text(); n = s.count(old)
    if n != 1:
        print("::error file=%s::pattern found %d times" % (path, n)); sys.exit(1)
    p.write_text(s.replace(old, new)); print("patched", path)

T = "test/bot_model_test.dart"
patch(T, "      expect(botModelLabel('submac'), 'SubMac');",
        "      expect(botModelLabel('submac'), BotModelWords.defaultLabel);")
patch(T, "      expect(find.byKey(const ValueKey('model-submac')), findsOneWidget);",
        "      expect(find.byKey(const ValueKey('model-submac')), findsNothing);")
