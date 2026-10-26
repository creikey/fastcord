(async () => {
  const names = new Set();
  for (const sh of document.styleSheets) { let rules; try { rules = sh.cssRules } catch(e) { continue }
    const walk = rs => { for (const r of rs) { if (r.style) for (const p of r.style) if (p.startsWith('--')) names.add(p); if (r.cssRules) walk(r.cssRules) } };
    walk(rules) }
  const keep = n => !/gradient|-hsl$|-rgb$|premium|nitro|quest|shop|collectible|lottery|halloween|xmas|badge|spine|clips|activity|deco|guild-boost|creator|mobile|redesign-button-overlay|plum|neutral-|primary-[0-9]|brand-[0-9]|red-[0-9]|green-[0-9]|yellow-[0-9]|blue-[0-9]|orange-[0-9]|teal-[0-9]|white-[0-9]|black-[0-9]|^--__/.test(n);
  const c = document.createElement('canvas'); c.width = c.height = 1; const g = c.getContext('2d', {willReadFrequently: true});
  const probe = document.createElement('div'); document.body.appendChild(probe);
  const resolve = (theme) => {
    const html = document.documentElement; const old = html.className;
    html.className = old.replace(/theme-\w+/g, '').replace(/\s+/g,' ') + ' ' + theme;
    const out = {};
    for (const n of names) { if (!keep(n)) continue;
      probe.style.backgroundColor = ''; probe.style.backgroundColor = `var(${n})`;
      const cs = getComputedStyle(probe).backgroundColor;
      if (!cs || cs === 'rgba(0, 0, 0, 0)' ) continue;
      g.clearRect(0,0,1,1); g.fillStyle = '#000'; g.fillStyle = cs; g.fillRect(0,0,1,1);
      const d = g.getImageData(0,0,1,1).data;
      out[n] = [d[0], d[1], d[2], +(d[3]/255).toFixed(3)];
    }
    html.className = old; return out;
  };
  const r = {light: resolve('theme-light'), ash: resolve('theme-dark'), dark: resolve('theme-dark theme-darker'), onyx: resolve('theme-dark theme-midnight')};
  probe.remove(); return r;
})()
