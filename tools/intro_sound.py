# Run: python3 tools/intro_sound.py && ffmpeg -i intro_raw.wav -af "loudnorm=I=-18:TP=-3:LRA=20:linear=true" -ac 1 -c:a aac -b:a 64k assets/intro/intro_sound.m4a
# Synthesizes the SubMac intro sound (original, no samples): airy whoosh/shimmer under the wordmark draw,
# then a warm two-note bloom when the logo resolves (1.75 s) and the dot lands (2.25 s).
import numpy as np, wave
SR=44100; T=3.3; n=int(SR*T); t=np.arange(n)/SR
rng=np.random.default_rng(7)
def onepole_lp(x,fc):
    a=np.exp(-2*np.pi*fc/SR); y=np.empty_like(x); s=0.0
    for i in range(len(x)): s=(1-a)*x[i]+a*s; y[i]=s
    return y
def lp_var(x,fc):  # time-varying one-pole low-pass
    a=np.exp(-2*np.pi*fc/SR); y=np.empty_like(x); s=0.0
    for i in range(len(x)): s=(1-a[i])*x[i]+a[i]*s; y[i]=s
    return y
def smooth(x0,x1,x):  # smoothstep
    u=np.clip((x-x0)/(x1-x0),0,1); return u*u*(3-2*u)
# 1) whoosh: pink-ish noise, band moving up then settling, soft swell 0 -> 1.55 s
w=rng.standard_normal(n)
w=onepole_lp(onepole_lp(w,2600),3200)
fc=450+1500*smooth(0.0,1.3,t)*(1-0.5*smooth(1.3,1.9,t))
lo=lp_var(w,fc); hi=lp_var(w,fc*0.35)
band=lo-hi
env_w=smooth(0.0,1.05,t)*(1-smooth(1.15,1.85,t))
whoosh=band*env_w*0.55
# shimmer: soft high partials with slow tremolo, rising in with the draw (kept under 3.6 kHz)
sh=np.zeros(n)
for f,a,ph in [(1760,0.05,0.0),(2217,0.035,1.3),(2637,0.025,2.1),(3322,0.012,0.7)]:
    trem=0.6+0.4*np.sin(2*np.pi*(5.5+f/1000)*t+ph)
    sh+=a*np.sin(2*np.pi*f*t+ph)*trem
sh*=smooth(0.25,1.2,t)*(1-smooth(1.25,1.9,t))
# 2) warm bloom notes: sine + soft 2nd/3rd harmonic + slight detune, 18 ms attack, exp decay
def note(f0,at,dec,amp):
    x=np.zeros(n); i=int(at*SR); tt=t[i:]-at
    env=(1-np.exp(-tt/0.018))*np.exp(-tt/dec)
    s=(np.sin(2*np.pi*f0*tt)+0.35*np.sin(2*np.pi*f0*1.003*tt+0.4)+0.18*np.sin(2*np.pi*2*f0*tt)+0.05*np.sin(2*np.pi*3*f0*tt))
    x[i:]=s*env*amp; return x
chime=note(440.0,1.75,0.85,0.30)+note(659.26,2.30,1.0,0.30)
# low bloom pad under the landing (A3 + E4), slow swell
pad=np.zeros(n); i=int(1.70*SR); tt=t[i:]-1.70
penv=smooth(0,0.35,tt)*np.exp(-np.clip(tt-0.35,0,None)/0.9)
pad[i:]=(np.sin(2*np.pi*220*tt)+0.5*np.sin(2*np.pi*329.63*tt))*penv*0.12
dry=whoosh+sh+chime+pad
dry=onepole_lp(dry,6500)  # no harsh highs
# 3) short reverb: exponentially decaying filtered noise IR (0.7 s), 22 % wet
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
