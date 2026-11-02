import 'package:agent/screens/opencode_lab_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real event stream from opencode 1.19.5 (one prompt, "say hi", answered "Hello from SubMac.").
const _events = [
    r'''{"id":"evt_19bb855a4001y0a3oFdEA314kz","type":"message.updated","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","info":{"id":"msg_19bb85586001b0pARTer8zp3qI","role":"user","sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","time":{"created":1793613911430},"agent":"build","model":{"providerID":"submac","modelID":"submac"}}}}''',
    r'''{"id":"evt_19bb855b5001nz0YY541Cmf1ZR","type":"message.part.updated","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","part":{"type":"text","text":"say hi","messageID":"msg_19bb85586001b0pARTer8zp3qI","sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","id":"prt_19bb855a00011xGw3gTTsghYRn"},"time":1793613911477}}''',
    r'''{"id":"evt_19bb85b2b0014M848XOmHZb572","type":"message.updated","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","info":{"id":"msg_19bb85b27001hNNeYY4EQsMf75","parentID":"msg_19bb85586001b0pARTer8zp3qI","role":"assistant","mode":"build","agent":"build","path":{"cwd":"/workspace/work/oc/h2/w","root":"/"},"cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"modelID":"submac","providerID":"submac","time":{"created":1793613912872},"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims"}}}''',
    r'''{"id":"evt_19bb85cbd001ocw3KnlefpkMNG","type":"message.updated","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","info":{"role":"user","time":{"created":1793613911430},"agent":"build","model":{"providerID":"submac","modelID":"submac"},"id":"msg_19bb85586001b0pARTer8zp3qI","sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","summary":{"diffs":[]}}}}''',
    r'''{"id":"evt_19bb863720011hGmCvlYMKUtNK","type":"message.part.updated","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","part":{"id":"prt_19bb863720018KtvQS2V4h22Cm","messageID":"msg_19bb85b27001hNNeYY4EQsMf75","sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","type":"step-start"},"time":1793613914994}}''',
    r'''{"id":"evt_19bb86392001VDDldyZavY0lSB","type":"message.part.updated","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","part":{"id":"prt_19bb86392001WDmgYh8XMGR6pC","messageID":"msg_19bb85b27001hNNeYY4EQsMf75","sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","type":"text","text":"","time":{"start":1793613915026}},"time":1793613915026}}''',
    r'''{"id":"evt_19bb863b9001yrUnajze2EPAxW","type":"message.part.delta","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","messageID":"msg_19bb85b27001hNNeYY4EQsMf75","partID":"prt_19bb86392001WDmgYh8XMGR6pC","field":"text","delta":"Hello "}}''',
    r'''{"id":"evt_19bb863bc001nUxRq42TDIAb1t","type":"message.part.delta","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","messageID":"msg_19bb85b27001hNNeYY4EQsMf75","partID":"prt_19bb86392001WDmgYh8XMGR6pC","field":"text","delta":"from "}}''',
    r'''{"id":"evt_19bb863c00010fOL6geZY8dEZo","type":"message.part.delta","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","messageID":"msg_19bb85b27001hNNeYY4EQsMf75","partID":"prt_19bb86392001WDmgYh8XMGR6pC","field":"text","delta":"SubMac."}}''',
    r'''{"id":"evt_19bb863c2001WCH23PMGKiz0RI","type":"message.part.updated","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","part":{"id":"prt_19bb86392001WDmgYh8XMGR6pC","messageID":"msg_19bb85b27001hNNeYY4EQsMf75","sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","type":"text","text":"Hello from SubMac.","time":{"start":1793613915026,"end":1793613915074}},"time":1793613915074}}''',
    r'''{"id":"evt_19bb863f6001lgpsVLG40lDNvE","type":"message.part.updated","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","part":{"id":"prt_19bb863f50011LCMPU6EnZHZaQ","reason":"stop","messageID":"msg_19bb85b27001hNNeYY4EQsMf75","sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","type":"step-finish","tokens":{"total":8,"input":5,"output":3,"reasoning":0,"cache":{"write":0,"read":0}},"cost":0},"time":1793613915126}}''',
    r'''{"id":"evt_19bb8641b001y3SnW2oWAdRLlA","type":"message.updated","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","info":{"id":"msg_19bb85b27001hNNeYY4EQsMf75","parentID":"msg_19bb85586001b0pARTer8zp3qI","role":"assistant","mode":"build","agent":"build","path":{"cwd":"/workspace/work/oc/h2/w","root":"/"},"cost":0,"tokens":{"total":8,"input":5,"output":3,"reasoning":0,"cache":{"write":0,"read":0}},"modelID":"submac","providerID":"submac","time":{"created":1793613912872,"completed":1793613915195},"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","finish":"stop"}}}''',
    r'''{"id":"evt_19bb8643b0017Pa5HDkQfjEXfo","type":"message.updated","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","info":{"id":"msg_19bb85b27001hNNeYY4EQsMf75","parentID":"msg_19bb85586001b0pARTer8zp3qI","role":"assistant","mode":"build","agent":"build","path":{"cwd":"/workspace/work/oc/h2/w","root":"/"},"cost":0,"tokens":{"total":8,"input":5,"output":3,"reasoning":0,"cache":{"write":0,"read":0}},"modelID":"submac","providerID":"submac","time":{"created":1793613912872,"completed":1793613915195},"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","finish":"stop"}}}''',
    r'''{"id":"evt_19bb86474002TvGDwAK2TPhK5c","type":"session.idle","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims"}}''',
    r'''{"id":"evt_19bb864ad0014hK0tzmxCVisXp","type":"message.updated","properties":{"sessionID":"ses_e6447aee9ffeHh10mr5CF47ims","info":{"role":"user","time":{"created":1793613911430},"agent":"build","model":{"providerID":"submac","modelID":"submac"},"summary":{"diffs":[]},"id":"msg_19bb85586001b0pARTer8zp3qI","sessionID":"ses_e6447aee9ffeHh10mr5CF47ims"}}}'''
];

void main() {
  test('the reply is the assistant text, streamed, without the user prompt', () {
    final r = OpenCodeReply('ses_e6447aee9ffeHh10mr5CF47ims');
    final seen = <String>[];
    for (final e in _events) {
      if (r.apply(e)) seen.add(r.text);
    }
    expect(r.text, 'Hello from SubMac.');
    expect(r.done, isTrue);
    expect(seen, contains('Hello '), reason: 'deltas stream before the final text');
    expect(seen.any((t) => t.contains('say hi')), isFalse);
  });

  test('another session and junk are ignored', () {
    final r = OpenCodeReply('ses_other');
    for (final e in _events) {
      r.apply(e);
    }
    r.apply('not json');
    expect(r.text, '');
    expect(r.done, isFalse);
  });
}
