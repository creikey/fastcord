# Serves a live commits-per-minute graph of this repo's main (its upstream, fetched every minute) on localhost.
#   python3 -I tools/commits_live.py [port]      opens http://127.0.0.1:8765 (or the given port) in the browser
import http.server, json, os, subprocess, sys, threading, time, webbrowser

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV = dict(os.environ, GIT_TERMINAL_PROMPT='0')

def git(*args):
    r = subprocess.run(['git', '-C', REPO, *args], capture_output=True, text=True, encoding='utf-8', errors='replace',
                       env=ENV, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    return r.stdout.strip() if r.returncode == 0 else ''

REF = git('rev-parse', '--abbrev-ref', 'main@{upstream}') or 'main'
cache = {'head': None, 'body': b'[]'}

def fetch_loop():
    if REF == 'main':
        return
    remote, branch = REF.split('/', 1)
    while True:
        git('fetch', '--quiet', remote, branch)
        time.sleep(60)

def data():
    head = git('rev-parse', REF)
    if head != cache['head']:
        rows = [l.split('\t', 1) for l in git('log', REF, '--no-merges', '--format=%at\t%s').splitlines()]
        cache['body'] = json.dumps(sorted([int(r[0]), r[1] if len(r) > 1 else ''] for r in rows if r[0])).encode()
        cache['head'] = head
    return cache['body']

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/data':
            body, kind = data(), 'application/json'
        elif self.path == '/':
            body, kind = PAGE.replace('{REF}', REF).encode(), 'text/html; charset=utf-8'
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', kind)
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

PAGE = r'''<!doctype html>
<html><head><meta charset="utf-8"><title>fastcord: commits per minute (live)</title>
<style>
body{font:14px system-ui,sans-serif;margin:32px;background:#fafafa;color:#222}
h1{font-size:20px;margin:0 0 4px}.sub{color:#777;margin-bottom:16px}
.card{background:#fff;border:1px solid #e3e3e3;border-radius:8px;padding:16px;margin-bottom:20px}
.stats{display:flex;gap:32px;margin-bottom:16px;flex-wrap:wrap}.stats b{display:block;font-size:22px}
.stats span{color:#777;font-size:12px}
label{color:#555}select{font:inherit}
svg{display:block;width:100%}
.tip{position:fixed;pointer-events:none;background:#222;color:#fff;padding:6px 8px;border-radius:4px;font-size:12px;max-width:420px;display:none;white-space:pre-wrap}
#live{color:#3ba55d}#live.bad{color:#d83c3e}
</style></head><body>
<h1>fastcord: commits per minute</h1>
<div class="sub">Non-merge commits on <code>{REF}</code>, by author time, shown in your local time zone. <span id="live"></span></div>
<div class="stats" id="stats"></div>
<div class="card">
<label>Smoothing window <select id="win">
<option value="1">1 min (raw)</option><option value="10">10 min</option><option value="30">30 min</option>
<option value="60" selected>60 min</option><option value="180">3 h</option></select></label>
<svg id="rate" height="320"></svg>
</div>
<div class="card"><b>Commits by hour of day</b><svg id="hours" height="200"></svg></div>
<div class="tip" id="tip"></div>
<script>
let D=[],t0,t1,N,per,msgs;
const NS='http://www.w3.org/2000/svg';
const el=(t,a,p)=>{const e=document.createElementNS(NS,t);for(const k in a)e.setAttribute(k,a[k]);p&&p.appendChild(e);return e};
const tip=document.getElementById('tip'),live=document.getElementById('live');
const fmt=d=>d.toLocaleString([],{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});

function build(){
 t0=Math.floor(D[0][0]/60);t1=Math.max(Math.floor(D[D.length-1][0]/60),Math.floor(Date.now()/60e3));N=t1-t0+1;
 per=new Float64Array(N);msgs=Array.from({length:N},()=>[]);
 for(const [t,s] of D){const i=Math.floor(t/60)-t0;per[i]++;msgs[i].push(s)}
 let peak=0,peakI=0;for(let i=0;i<N;i++)if(per[i]>peak){peak=per[i];peakI=i}
 let busy=0;for(let i=0;i<N;i++)if(per[i])busy++;
 const ago=Math.max(0,Math.round(Date.now()/60e3-D[D.length-1][0]/60));
 document.getElementById('stats').innerHTML=[
  [D.length,'commits'],[(N/60).toFixed(1)+' h','span (to now)'],[(D.length/N).toFixed(2),'avg commits/min (whole span)'],
  [(D.length/busy).toFixed(2),'commits per active minute'],[peak,'max in one minute ('+fmt(new Date((t0+peakI)*60e3))+')'],
  [ago<60?ago+' min':(ago/60).toFixed(1)+' h','since last commit']
 ].map(([v,l])=>`<div><b>${v}</b><span>${l}</span></div>`).join('');
}
function drawRate(){
 const svg=document.getElementById('rate');svg.innerHTML='';
 const W=svg.clientWidth,H=320,L=48,R=12,T=12,B=36,w=W-L-R,h=H-T-B;
 const win=+document.getElementById('win').value;
 const pre=new Float64Array(N+1);for(let i=0;i<N;i++)pre[i+1]=pre[i]+per[i];
 const sm=new Float64Array(N);
 for(let i=0;i<N;i++){const a=Math.max(0,i-Math.floor(win/2)),b=Math.min(N,a+win);sm[i]=(pre[b]-pre[a])/(b-a)}
 let ymax=0;for(const v of sm)ymax=Math.max(ymax,v);ymax=ymax*1.1||1;
 const X=i=>L+i/Math.max(1,N-1)*w,Y=v=>T+h-v/ymax*h;
 for(let k=0;k<=4;k++){const v=ymax*k/4;el('line',{x1:L,x2:L+w,y1:Y(v),y2:Y(v),stroke:'#eee'},svg);
  el('text',{x:L-6,y:Y(v)+4,'text-anchor':'end',fill:'#888','font-size':11},svg).textContent=v.toFixed(v<1?2:1)}
 for(let m=Math.ceil(t0/60)*60;m<=t1;m+=60){const d=new Date(m*60e3),i=m-t0;
  if(d.getHours()%6)continue;
  el('line',{x1:X(i),x2:X(i),y1:T,y2:T+h,stroke:d.getHours()?'#f0f0f0':'#ccc'},svg);
  el('text',{x:X(i),y:H-18,'text-anchor':'middle',fill:'#888','font-size':11},svg).textContent=d.getHours()?d.getHours()+':00':d.toLocaleDateString([],{month:'short',day:'numeric'})}
 if(win>1)for(let i=0;i<N;i++)if(per[i])el('line',{x1:X(i),x2:X(i),y1:T+h,y2:T+h-6,stroke:'#bbb'},svg);
 let p=`M${X(0)},${Y(0)}`;for(let i=0;i<N;i++)p+=`L${X(i).toFixed(1)},${Y(sm[i]).toFixed(1)}`;p+=`L${X(N-1)},${Y(0)}Z`;
 el('path',{d:p,fill:'rgba(88,101,242,.18)',stroke:'#5865f2','stroke-width':1.5},svg);
 el('text',{x:L,y:H-2,fill:'#888','font-size':11},svg).textContent='commits / minute'+(win>1?` (centered ${win}-min average; ticks = minutes with a commit)`:'');
 const cur=el('line',{y1:T,y2:T+h,stroke:'#999','stroke-dasharray':'3 3',visibility:'hidden'},svg);
 svg.onmousemove=e=>{const r=svg.getBoundingClientRect(),i=Math.round((e.clientX-r.left-L)/w*(N-1));
  if(i<0||i>=N){tip.style.display='none';cur.setAttribute('visibility','hidden');return}
  cur.setAttribute('x1',X(i));cur.setAttribute('x2',X(i));cur.setAttribute('visibility','visible');
  const near=[];for(let j=Math.max(0,i-2);j<=Math.min(N-1,i+2);j++)near.push(...msgs[j]);
  tip.textContent=`${fmt(new Date((t0+i)*60e3))}\n${sm[i].toFixed(2)} commits/min`+(near.length?'\n\n'+near.slice(0,6).join('\n')+(near.length>6?`\n+${near.length-6} more`:''):'');
  tip.style.display='block';tip.style.left=Math.min(e.clientX+14,innerWidth-440)+'px';tip.style.top=(e.clientY+14)+'px'};
 svg.onmouseleave=()=>{tip.style.display='none';cur.setAttribute('visibility','hidden')};
}
function drawHours(){
 const svg=document.getElementById('hours');svg.innerHTML='';
 const W=svg.clientWidth,H=200,L=48,R=12,T=14,B=24,w=W-L-R,h=H-T-B;
 const c=new Array(24).fill(0);for(const [t] of D)c[new Date(t*1e3).getHours()]++;
 const m=Math.max(...c),bw=w/24;
 c.forEach((v,i)=>{const bh=v/m*h;el('rect',{x:L+i*bw+2,y:T+h-bh,width:bw-4,height:bh,fill:'#5865f2',rx:2},svg);
  if(v)el('text',{x:L+i*bw+bw/2,y:T+h-bh-3,'text-anchor':'middle','font-size':10,fill:'#666'},svg).textContent=v;
  el('text',{x:L+i*bw+bw/2,y:H-6,'text-anchor':'middle','font-size':11,fill:'#888'},svg).textContent=i});
}
function redraw(){if(D.length){build();drawRate();drawHours()}}
async function poll(){
 try{D=await (await fetch('/data',{cache:'no-store'})).json();redraw();
  live.className='';live.textContent='Live, updated '+new Date().toLocaleTimeString()+'.';
 }catch(e){live.className='bad';live.textContent='Server unreachable, retrying.'}
}
document.getElementById('win').onchange=drawRate;
addEventListener('resize',redraw);
poll();setInterval(poll,15000);
</script></body></html>
'''

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    try:
        server = http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler)
    except OSError:
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    url = 'http://127.0.0.1:%d' % server.server_address[1]
    threading.Thread(target=fetch_loop, daemon=True).start()
    print('Graphing %s at %s (Ctrl+C to stop).' % (REF, url))
    webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
