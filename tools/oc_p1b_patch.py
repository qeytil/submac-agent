import sys, pathlib

def patch(path, old, new):
    p = pathlib.Path(path); s = p.read_text(); n = s.count(old)
    if n != 1:
        print("::error file=%s::pattern found %d times" % (path, n)); sys.exit(1)
    p.write_text(s.replace(old, new)); print("patched", path)

T = "test/oc_lanes_test.dart"
patch(T, "      expect(OcLane.modelFor('submac|submac-think'), 'submac-think');",
        "      expect(OcLane.modelFor('submac|submac-think'), 'submac');")
patch(T, "      expect(OcLane.modelFor('submac-fast'), 'submac-fast');",
        "      expect(OcLane.modelFor('submac-fast'), 'submac');")
patch(T, "      expect(OcLane.pick(background: true, botModel: 'submac|submac-smart')['modelID'], 'submac-smart');",
        "      expect(OcLane.pick(background: true, botModel: 'submac|submac-smart')['modelID'], 'submac');")
patch(T, """      expect(OcLane.pick(background: false, botModel: 'submac|submac-smart'),
          {'providerID': 'submac', 'modelID': 'submac-smart'}, reason: 'the owner in a bot\\'s chat: the bot\\'s model, owner\\'s lane');""",
        """      expect(OcLane.pick(background: false, botModel: 'submac|submac-smart'),
          {'providerID': 'submac', 'modelID': 'submac'}, reason: 'the owner in a bot\\'s chat: owner\\'s lane');""")
