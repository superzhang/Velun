import math, wave, struct, random, argparse
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--work-dir',required=True);args=parser.parse_args()
out=Path(args.work_dir);out.mkdir(parents=True,exist_ok=True)
rate=4000
rng=random.Random(1997)
# A varying musical phrase, not a steady sinusoid. Exact sample-aligned time shifts.
melody=[]
notes=[220,330,440,294,392,523,262,349]
for i in range(35*rate):
 t=i/rate;n=int(t*4);f=notes[(n*7+n//9)%len(notes)]
 v=(math.sin(2*math.pi*f*t)*.35+math.sin(2*math.pi*f*1.5*t)*.13+math.sin(2*math.pi*93*t)*.11)*(0.5+0.5*math.sin(math.pi*(t*4%1)))
 melody.append(v)
for name,lead in [('A',6.016),('B',12.032),('C',9.024)]:
 prefix=[rng.uniform(-.2,.2) for _ in range(round(lead*rate))]
 samples=prefix+melody+[rng.uniform(-.2,.2) for _ in range(10*rate)]
 with wave.open(str(out/(name+'.wav')),'wb') as w:
  w.setnchannels(1);w.setsampwidth(2);w.setframerate(rate);w.writeframes(b''.join(struct.pack('<h',round(x*30000)) for x in samples))
