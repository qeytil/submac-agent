import vosk, json, glob, sys, random, array
vosk.SetLogLevel(-1)
model=vosk.Model('/tmp/vosk-model-small-en-us-0.15')
PHR=json.loads(sys.argv[1]) if len(sys.argv)>1 else ["hey sub mac","hello sub mac","hi sub mac","okay sub mac","sub mac","hey sub mack","hello sub mack","sub mack","[unk]"]
def heard(js,final,sens,keys=("sub","mac","mack")):
    o=json.loads(js); t=(o.get('text') if final else o.get('partial','')).lower()
    if 'sub mac' not in t and 'sub mack' not in t: return False
    if not final: return True
    w=[x for x in o.get('result',[]) if x['word'] in keys]
    if not w: return False
    return sum(x['conf'] for x in w)/len(w) >= 0.92-0.45*sens
def run(raw,sens,noise=int(__import__("os").environ.get("NOISE","300")),vol=float(__import__("os").environ.get("VOL","1"))):
    rec=vosk.KaldiRecognizer(model,16000,json.dumps(PHR)); rec.SetWords(True)
    pcm=array.array('h',open(raw,'rb').read())
    pcm=array.array("h",[int(s*vol) for s in pcm])
    pad=array.array('h',[0]*8000)
    sig=pad+pcm+pad+pad
    sig=array.array('h',[max(-32768,min(32767,s+random.randint(-noise,noise))) for s in sig])
    import os
    agc=os.environ.get('AGC')=='1'
    gain=1.0
    for i in range(0,len(sig),1600):
        ch=sig[i:i+1600]
        if agc:
            pk=max(abs(x) for x in ch) or 1
            target=min(8.0, 12000/pk)
            gain = gain+(target-gain)*(0.5 if target<gain else 0.1)
            ch=array.array('h',[max(-32768,min(32767,int(x*gain))) for x in ch])
        if rec.AcceptWaveform(ch.tobytes()):
            if heard(rec.Result(),True,sens): return True
        elif sens>=0.75 and heard(rec.PartialResult(),False,sens): return True
    return heard(rec.FinalResult(),True,sens)
for sens in (0.4,0.6,0.8):
    tp=fn=fp=tn=0; misses=[]; fps=[]
    for raw in sorted(glob.glob('*.raw')):
        r=run(raw,sens); t=open(raw[:-4]+'.txt').read()
        if raw.startswith('pos'):
            tp+=r; fn+=not r
            if not r: misses.append(t)
        else:
            fp+=r; tn+=not r
            if r: fps.append(t)
    print(f'sens {sens}: hit {tp}/{tp+fn}  false {fp}/{fp+tn}  miss={sorted(set(misses))} fp={sorted(set(fps))}')
