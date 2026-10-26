#!/usr/bin/env python3
# lottie_web_reference.py <lottie_chunk.js> <out.png> <size> <frames,comma,sep> <anim.json>...
#
# Renders Lottie frames with the official client's own lottie-web (webpack chunk
# 996382 / module 883885, e.g. https://discord.com/assets/896dfe0ebae4455a.js,
# lottie-web 5.12.2, SVG renderer as the client uses) in headless Chrome. One row
# per animation, one column per frame, transparent background. Frames are
# stepped sequentially from 0 like playback. Used for src/lottie tests
# (testdata/lottie_web_64.png) and the sticker comparisons in the report.
import json, os, subprocess, sys, tempfile
chunk, out, size, frames = sys.argv[1], sys.argv[2], int(sys.argv[3]), [int(f) for f in sys.argv[4].split(',')]
anims = [open(p).read() for p in sys.argv[5:]]
tmp = tempfile.mkdtemp()
os.symlink(os.path.abspath(chunk), os.path.join(tmp, 'lottie_chunk.js'))
html = ['<html><body style="margin:0;background:transparent"><style>div{position:absolute;width:%dpx;height:%dpx}</style>' % (size, size),
        '<script>var captured;self.webpackChunkdiscord_app={push:function(a){captured=a[1]}};</script>',
        '<script src="lottie_chunk.js"></script><script>var m={exports:{}};captured["883885"](m,m.exports);var lottie=m.exports;</script>',
        '<script>var A=[%s],F=%s,S=%d;' % (','.join(anims), json.dumps(frames), size),
        'A.forEach(function(D,r){F.forEach(function(f,c){var d=document.createElement("div");d.style.left=(c*S)+"px";d.style.top=(r*S)+"px";'
        'document.body.appendChild(d);var a=lottie.loadAnimation({container:d,renderer:"svg",loop:false,autoplay:false,animationData:JSON.parse(JSON.stringify(D))});'
        'for(var k=0;k<=f;k++)a.goToAndStop(k,true);});});</script></body></html>']
page = os.path.join(tmp, 'grid.html')
open(page, 'w').write('\n'.join(html))
chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
subprocess.run([chrome, '--headless=new', '--disable-gpu', '--force-device-scale-factor=1', '--hide-scrollbars',
                '--default-background-color=00000000', '--window-size=%d,%d' % (size * len(frames), size * len(anims)),
                '--virtual-time-budget=20000', '--allow-file-access-from-files', '--user-data-dir=' + os.path.join(tmp, 'prof'),
                '--screenshot=' + os.path.abspath(out), 'file://' + page], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
