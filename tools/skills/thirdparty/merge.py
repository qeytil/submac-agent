"""Merge index_add.json into the live library index and write index.json (bumps v, sets count).
usage: python3 merge.py [path-to-live-index.json]   (default: downloads the public index)"""
import json, sys, urllib.request
BASE = 'https://moeemacbvsueekuvfjbo.supabase.co/storage/v1/object/public/skills'
if len(sys.argv) > 1:
    live = json.load(open(sys.argv[1]))
else:
    live = json.load(urllib.request.urlopen(f'{BASE}/index.json'))
add = json.load(open('index_add.json'))
ids = {s['id'] for s in add}
skills = [s for s in live['skills'] if s['id'] not in ids] + add
out = dict(live)
out['skills'] = skills
out['v'] = int(live.get('v', 1)) + 1
out['count'] = len(skills)
json.dump(out, open('index.json', 'w'), ensure_ascii=False, separators=(',', ':'))
print('v', out['v'], 'count', out['count'], 'added', len(ids - {s['id'] for s in live['skills']}), 'updated', len(ids & {s['id'] for s in live['skills']}))
