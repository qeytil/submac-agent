#!/usr/bin/env python3
"""Chat bug hunt (2026-10-25): drives the RELEASE build-62 APK over adb only (uiautomator dump + input), the way a
person taps it. Prints ADB: lines; screenshots go to out/shots/rel_*.png. Best effort: every step logs and goes on.
Usage: chatbug_adb.py <email> <password>"""
import re, subprocess, sys, time, xml.etree.ElementTree as ET

PKG = 'com.submac.agent'
EMAIL, PW = sys.argv[1], sys.argv[2]


def sh(*a, timeout=60):
    try:
        return subprocess.run(['adb', *a], capture_output=True, text=True, timeout=timeout).stdout
    except Exception as e:
        return f'ERR {e}'


def log(s):
    print('ADB: ' + s, flush=True)


def shot(name):
    with open(f'out/shots/rel_{name}.png', 'wb') as f:
        f.write(subprocess.run(['adb', 'exec-out', 'screencap', '-p'], capture_output=True).stdout)
    texts = [t for t in (n.get('text') or n.get('content-desc') for n in nodes()) if t]
    log(f'SEE {name}: ' + ' ¦ '.join(texts)[:2500].replace('\n', ' '))


def nodes():
    sh('shell', 'uiautomator', 'dump', '/sdcard/ui.xml', timeout=40)
    x = sh('shell', 'cat', '/sdcard/ui.xml')
    try:
        return list(ET.fromstring(x[x.index('<?xml'):] if '<?xml' in x else x).iter('node'))
    except Exception:
        return []


def bounds(n):
    m = re.findall(r'\d+', n.get('bounds', ''))
    return [int(v) for v in m] if len(m) == 4 else None


def label(n):
    # Flutter puts most labels in content-desc, not text.
    return ((n.get('text') or '') + ' ' + (n.get('content-desc') or '')).strip()


def find(text=None, desc=None, cls=None, ns=None):
    ns = ns if ns is not None else nodes()
    want = (text or desc or '').lower()
    hits = []
    for n in ns:
        if want and want not in label(n).lower():
            continue
        if cls and cls not in (n.get('class') or ''):
            continue
        if bounds(n):
            hits.append(n)
    if not hits:
        return None
    # Prefer an exact label ("Continue" over "Continue with Google"), then the shortest one.
    exact = [n for n in hits if label(n).lower().split('\n')[0].strip() == want]
    return (exact or sorted(hits, key=lambda n: len(label(n))))[0]


def tap_node(n):
    b = bounds(n)
    sh('shell', 'input', 'tap', str((b[0] + b[2]) // 2), str((b[1] + b[3]) // 2))
    time.sleep(1.5)


def tap(text=None, desc=None):
    n = find(text=text, desc=desc)
    if n is None:
        log(f'miss tap {text or desc}')
        return False
    tap_node(n)
    return True


def type_text(s):
    # adb input text: spaces as %s, no non-ASCII.
    esc = s.replace('\\', '').replace(' ', '%s').replace("'", '').replace('"', '').replace('&', 'and').replace('(', '').replace(')', '').replace('?', '').replace(';', ',')
    sh('shell', 'input', 'text', esc)
    time.sleep(1)


def composer():
    ns = nodes()
    eds = [n for n in ns if 'EditText' in (n.get('class') or '')]
    if not eds:
        pill = find(text='Ask SubMac', ns=ns) or find(desc='Ask SubMac', ns=ns)
        if pill is not None:
            tap_node(pill)
            ns = nodes()
            eds = [n for n in ns if 'EditText' in (n.get('class') or '')]
    return (eds[-1] if eds else None), ns


def send(text, wait=0):
    ed, ns = composer()
    if ed is None:
        log('no composer')
        return False
    tap_node(ed)
    type_text(text)
    ed, ns = composer()
    b = bounds(ed)
    cy = (b[1] + b[3]) // 2
    # The round Send button sits right of the field on the same row.
    cands = [n for n in ns if n.get('clickable') == 'true' and bounds(n) and bounds(n)[0] >= b[2] - 10 and bounds(n)[1] <= cy <= bounds(n)[3]]
    if cands:
        tap_node(sorted(cands, key=lambda n: bounds(n)[0])[0])
    else:
        sh('shell', 'input', 'tap', str(b[2] + 40), str(cy))
    log(f'sent: {text[:60]}')
    time.sleep(wait)
    return True


def new_chat():
    n = find(desc='New chat') or find(text='New chat')
    if n is not None:
        tap_node(n)


def main():
    sh('shell', 'monkey', '-p', PKG, '-c', 'android.intent.category.LAUNCHER', '1')
    time.sleep(25)
    shot('00_first')
    if tap(text='Log in'):
        ns = nodes()
        eds = [n for n in ns if 'EditText' in (n.get('class') or '')]
        if len(eds) >= 2:
            tap_node(eds[0]); type_text(EMAIL)
            tap_node(eds[1]); type_text(PW)
            sh('shell', 'input', 'keyevent', '4')  # hide keyboard
            time.sleep(1)
            tap(text='Continue')
            time.sleep(12)
    shot('01_after_login')
    if find(text='Agree and continue'):  # 18+ / Terms gate, if the account has no consent yet
        tap(text='I am 18 or older')
        tap(text='Agree and continue')
        time.sleep(8)
        shot('01b_after_consent')
    for i in range(3):  # first-run sheets
        if find(text='Ask SubMac') or find(desc='Ask SubMac'):
            break
        for t in ('Not now', 'Skip', 'Close', 'Got it', 'Continue', 'Done'):
            if tap(text=t):
                break
        time.sleep(2)
    shot('02_home')

    # Send + stream, then Stop mid-stream (CB-2).
    send('Write a very long and detailed 2000 word guide to opening a small shop in Mogadishu, with many sections.', wait=12)
    shot('10_streaming')
    if tap(desc='Stop'):
        time.sleep(4)
    shot('11_after_stop')

    # Steer while the final answer streams (CB-1).
    new_chat(); time.sleep(3)
    send('Write a detailed 1500 word essay on the history of Somali poetry.', wait=9)
    shot('20_essay_streaming')
    send('Stop the essay. Instead reply with only the single word BANANA.', wait=2)
    shot('21_steer_sent')
    time.sleep(90)
    shot('22_after_steer')

    # Somali reply that opens with an Arabic greeting (CB-9), table + code + choices.
    new_chat(); time.sleep(3)
    send('Reply in Somali only. Start your reply with the greeting Assalamu alaikum written in Arabic letters, then explain in 3 sentences what Zaad is.', wait=45)
    shot('30_somali_rtl')
    new_chat(); time.sleep(3)
    send('Compare EVC Plus, Zaad and Sahal in a table, show a short Python code block converting USD to SOS, then ask me which one I use with choices.', wait=70)
    shot('31_table_code_choices')
    sh('shell', 'input', 'swipe', '540', '700', '540', '1900', '400'); time.sleep(2)
    shot('32_table_code_choices_top')

    # Kill mid-task and come back (resume after a kill).
    new_chat(); time.sleep(3)
    send('Search the web for three news headlines about Somalia today and summarise each one in two sentences.', wait=10)
    shot('40_task_running')
    sh('shell', 'am', 'force-stop', PKG)
    log('force-stopped')
    time.sleep(5)
    sh('shell', 'monkey', '-p', PKG, '-c', 'android.intent.category.LAUNCHER', '1')
    time.sleep(30)
    shot('41_reopened')
    time.sleep(90)
    shot('42_reopened_later')
    log('done')


if __name__ == '__main__':
    main()
