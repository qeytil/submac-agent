import math, json, cairosvg
def blob(points, r=0.5):
    # closed smooth path through points (Catmull-Rom -> bezier)
    n=len(points); d=''
    for i in range(n):
        p0=points[(i-1)%n];p1=points[i];p2=points[(i+1)%n];p3=points[(i+2)%n]
        c1=(p1[0]+(p2[0]-p0[0])*r/3,p1[1]+(p2[1]-p0[1])*r/3)
        c2=(p2[0]-(p3[0]-p1[0])*r/3,p2[1]-(p3[1]-p1[1])*r/3)
        if i==0: d+=f'M{p1[0]:.1f} {p1[1]:.1f}'
        d+=f'C{c1[0]:.1f} {c1[1]:.1f} {c2[0]:.1f} {c2[1]:.1f} {p2[0]:.1f} {p2[1]:.1f}'
    return d+'Z'
def polar(n,fr,cx=50,cy=52,rot=-90):
    return [(cx+fr(i)*math.cos(math.radians(rot+360*i/n)), cy+fr(i)*math.sin(math.radians(rot+360*i/n))) for i in range(n)]
S={}
# pebble: soft irregular stone
S['pebble']=blob(polar(7,lambda i:[41,39,42,40,41,38,40][i],cy=51,rot=-80),0.5)
# arch: round top, flat soft bottom
S['arch']='M18 86V48C18 28 32 12 50 12S82 28 82 48V86C82 89 80 90 77 90H23C20 90 18 89 18 86Z'
# squircle
S['squircle']='M50 12C80 12 88 20 88 50S80 88 50 88 12 80 12 50 20 12 50 12Z'
# sparkle: soft 4-point star
S['spark']=blob(polar(8,lambda i:44 if i%2==0 else 24,cy=50),0.9)
# bean
S['bean']='M30 16C46 10 58 22 70 18C86 13 94 32 90 52C86 76 68 90 46 88C24 86 10 70 10 50C10 32 16 21 30 16Z'
# bloom: 8 scallops
S['bloom']=blob(polar(16,lambda i:43 if i%2==0 else 36,cy=50),1.0)
# dome: wide half moon on a flat base
S['dome']='M10 78C10 46 28 24 50 24S90 46 90 78C90 82 88 84 84 84H16C12 84 10 82 10 78Z'
# kite: rotated soft square
S['kite']=blob([(50,8),(92,50),(50,92),(8,50)],0.55)
# ghost: round top, wavy hem
S['ghost']='M18 50C18 28 32 12 50 12S82 28 82 50V84C82 90 76 92 72 87C68 82 64 82 60 87C56 92 50 92 46 87C42 82 38 82 34 87C30 92 18 92 18 84Z'
# capsule: tall pill
S['capsule']='M50 8C64 8 72 18 72 32V68C72 82 64 92 50 92S28 82 28 68V32C28 18 36 8 50 8Z'
# clover: 4 lobes
S['cushion']=blob(polar(8,lambda i:44 if i%2==0 else 27,cy=50,rot=-45),1.1)
# leaf
S['leaf']='M14 86C14 46 40 14 86 14C86 54 60 86 14 86Z'
# eye anchors (center y) and spacing per shape
EY={'pebble':(50,46,13),'arch':(50,46,12),'squircle':(50,47,13),'spark':(50,50,9),'bean':(50,48,13),'bloom':(50,48,12),'dome':(50,58,13),'kite':(50,48,11),'ghost':(50,46,12),'capsule':(50,42,9),'cushion':(50,50,11),'leaf':(54,50,10)}
C={'ink':'#1B1A18','red':'#C2361B','ember':'#E0713F','saffron':'#E8AE2E','sage':'#7FA67A','moss':'#3F6B4F','sea':'#3D8FA3','indigo':'#4B5BB0','plum':'#8B5C93','rose':'#E58C9B','sand':'#CDB592','stone':'#8E8A83'}
PAPER='#FBF8F2'
def eyes(kind,x,y,g,col):
    l,r=x-g,x+g
    if kind=='dots':
        return f'<rect x="{l-2.6}" y="{y-5}" width="5.2" height="10" rx="2.6" fill="{col}"/><rect x="{r-2.6}" y="{y-5}" width="5.2" height="10" rx="2.6" fill="{col}"/>'
    if kind=='wink':
        return f'<rect x="{l-2.6}" y="{y-5}" width="5.2" height="10" rx="2.6" fill="{col}"/><path d="M{r-4.5} {y+1}Q{r} {y-4} {r+4.5} {y+1}" stroke="{col}" stroke-width="3.6" fill="none" stroke-linecap="round"/>'
    if kind=='happy':
        return ''.join(f'<path d="M{e-4.5} {y+2}Q{e} {y-5} {e+4.5} {y+2}" stroke="{col}" stroke-width="3.6" fill="none" stroke-linecap="round"/>' for e in (l,r))
    if kind=='sleepy':
        return ''.join(f'<path d="M{e-4.5} {y}H{e+4.5}" stroke="{col}" stroke-width="3.6" stroke-linecap="round"/>' for e in (l,r))
    if kind=='round':
        return ''.join(f'<circle cx="{e}" cy="{y}" r="5.4" fill="{col}"/><circle cx="{e+1.6}" cy="{y-1.6}" r="1.6" fill="{PAPER if col!=PAPER else "#1B1A18"}"/>' for e in (l,r))
    if kind=='spark':  # one Telesia red spark for an eye: signature
        return f'<rect x="{l-2.6}" y="{y-5}" width="5.2" height="10" rx="2.6" fill="{col}"/><path d="M{r} {y-6}L{r+1.6} {y-1.6}L{r+6} {y}L{r+1.6} {y+1.6}L{r} {y+6}L{r-1.6} {y+1.6}L{r-6} {y}L{r-1.6} {y-1.6}Z" fill="{col}"/>'
EYES=['dots','wink','happy','sleepy','round','spark']
def svg(shape,color,eye,size=100):
    x,y,g=EY[shape]; fill=C[color]
    ec='#1B1A18' if color in ('saffron','sand','rose') else PAPER
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="{size}" height="{size}"><path d="{S[shape]}" fill="{fill}"/><g transform="translate({x} {y}) scale(1.25) translate({-x} {-y})">{eyes(eye,x,y,g*0.82,ec)}</g></svg>'
json.dump({'shapes':S,'eyes_at':EY,'colors':C},open('data.json','w'),indent=1)
# contact sheet: 12 shapes in 12 colors, eyes cycling
cell=120; cols=6
items=[(s,list(C)[i%12],EYES[i%6]) for i,s in enumerate(S)]
rows=(len(items)+cols-1)//cols
body=''.join(f'<g transform="translate({(i%cols)*cell+10},{(i//cols)*cell+10})">{svg(*it)[svg(*it).find(">")+1:-6]}</g>' for i,it in enumerate(items))
sheet=f'<svg xmlns="http://www.w3.org/2000/svg" width="{cols*cell}" height="{rows*cell}"><rect width="100%" height="100%" fill="#F7F4EE"/>{body}</svg>'
cairosvg.svg2png(bytestring=sheet.encode(),write_to='sheet.png',output_width=cols*cell*2)

# ---- Dart data for lib/widgets/sub_avatar_data.dart (run from the repo root: python3 tools/avatars/gen.py)
import os
ORDER=['pebble','arch','squircle','spark','bean','bloom','dome','kite','ghost','capsule','cushion','leaf']
out=["// GENERATED by tools/avatars/gen.py (Telesia avatar set). Edit the generator, not this file.","part of 'sub_avatar.dart';","","const _shapes = <String, String>{"]
out+=[f"  '{k}': '{S[k]}'," for k in ORDER]
out.append("};\n\n/// Eye anchor (x, y) and half-gap per shape.\nconst _eyesAt = <String, (double, double, double)>{")
out+=[f"  '{k}': ({float(EY[k][0])}, {float(EY[k][1])}, {float(EY[k][2])})," for k in ORDER]
out.append("};\n\nconst _colors = <String, int>{")
out+=[f"  '{k}': 0xFF{v[1:]}," for k,v in C.items()]
out.append("};")
dst='lib/widgets/sub_avatar_data.dart'
if os.path.isdir('lib/widgets'): open(dst,'w').write('\n'.join(out)+'\n')
