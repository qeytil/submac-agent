# Run: python3 tools/intro_sound.py, measure intro_raw.wav integrated loudness (ffmpeg -af ebur128), then
#      ffmpeg -i intro_raw.wav -af "volume=<-17.5 - measured>dB" -ac 1 -c:a aac -b:a 64k assets/intro/intro_sound.m4a
#      (linear gain only; plain loudnorm overshoots on this sparse a file). Pluck times: ticks.py mirrors IntroMotion.ticks().
# Synthesizes the Telesia intro sound (original, no samples): one soft rounded glass/marimba pluck per letter of the
# wordmark, on the haptic ticks (IntroMotion.ticks(): 0.302 0.520 0.677 0.823 0.980 1.198 s), rising through
# A-major pentatonic (A4 B4 C#5 E5 F#5 A5), then the warm two-note bloom when the logo resolves (1.75 s) and the dot
# lands (2.30 s). No noise and no pitch sweeps anywhere in the dry signal.
import numpy as np, wave
SR=44100; T=3.3; n=int(SR*T); t=np.arange(n)/SR
rng=np.random.default_rng(7)
rng.standard_normal(n)  # keeps the reverb IR below identical to v1 (v1 drew its whoosh noise here first)
def onepole_lp(x,fc):
    a=np.exp(-2*np.pi*fc/SR); y=np.empty_like(x); s=0.0
    for i in range(len(x)): s=(1-a)*x[i]+a*s; y[i]=s
    return y
def smooth(x0,x1,x):  # smoothstep
    u=np.clip((x-x0)/(x1-x0),0,1); return u*u*(3-2*u)
# 1) letter plucks: sine + a little 2nd harmonic, ~3 ms rounded attack, short exponential decay (~150 ms audible),
#    one per haptic tick, velocity rising gently across the six letters; peak about -12 dB under the chime.
TICKS=[0.3018,0.5202,0.6770,0.8230,0.9798,1.1982]   # IntroMotion.ticks() * total (3.0 s), IntroMotion.ticks() in lib/ui/intro_motion.dart
PITCH=[440.00,493.88,554.37,659.26,739.99,880.00]   # A4 B4 C#5 E5 F#5 A5
def pluck(f0,at,vel):
    x=np.zeros(n); i=int(round(at*SR)); tt=t[i:]-at
    att=np.where(tt<0.003,0.5-0.5*np.cos(np.pi*np.clip(tt/0.003,0,1)),1.0)
    env=att*np.exp(-tt/0.032)           # -40 dB at ~150 ms
    env2=att*np.exp(-tt/0.020)          # the harmonic fades first, so it rounds off like a struck bar
    x[i:]=(np.sin(2*np.pi*f0*tt)*env+0.14*np.sin(2*np.pi*2*f0*tt)*env2)*vel; return x
# 2) warm bloom notes (unchanged from v1): sine + soft 2nd/3rd harmonic + slight detune, 18 ms attack, exp decay
def note(f0,at,dec,amp):
    x=np.zeros(n); i=int(at*SR); tt=t[i:]-at
    env=(1-np.exp(-tt/0.018))*np.exp(-tt/dec)
    s=(np.sin(2*np.pi*f0*tt)+0.35*np.sin(2*np.pi*f0*1.003*tt+0.4)+0.18*np.sin(2*np.pi*2*f0*tt)+0.05*np.sin(2*np.pi*3*f0*tt))
    x[i:]=s*env*amp; return x
chime=note(440.0,1.75,0.85,0.30)+note(659.26,2.30,1.0,0.30)
# low bloom pad under the landing (A3 + E4), slow swell (unchanged from v1)
pad=np.zeros(n); i=int(1.70*SR); tt=t[i:]-1.70
penv=smooth(0,0.35,tt)*np.exp(-np.clip(tt-0.35,0,None)/0.9)
pad[i:]=(np.sin(2*np.pi*220*tt)+0.5*np.sin(2*np.pi*329.63*tt))*penv*0.12
chime_peak=np.abs(chime).max()
PLUCK_DB=-12.0
plucks=sum(pluck(f,a,v) for f,a,v in zip(PITCH,TICKS,np.linspace(0.72,1.0,6)))
plucks*=chime_peak*10**(PLUCK_DB/20)/np.abs(plucks).max()
dry=plucks+chime+pad
dry=onepole_lp(dry,6500)  # no harsh highs
# 3) short reverb (unchanged from v1): exponentially decaying filtered noise IR (0.7 s)
L=int(0.7*SR); ir=rng.standard_normal(L)*np.exp(-np.arange(L)/SR/0.18); ir=onepole_lp(ir,3500); ir/=np.sqrt((ir**2).sum())
wet=np.convolve(dry,ir)[:n]
mix=dry*0.85+wet*0.35
# fades
mix*=smooth(0,0.04,t)*(1-smooth(T-0.45,T,t))
mix/=np.abs(mix).max(); mix*=0.5
pcm=(mix*32767).astype(np.int16)
with wave.open('intro_raw.wav','wb') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(SR); f.writeframes(pcm.tobytes())
print('ok',len(pcm)/SR)
