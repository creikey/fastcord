(() => {
  const out = [];
  const seen = new Set();
  const want = /^(guilds|sidebar|panels|container|base|content|page|chat|title|bar|upperContainer|privateChannels|scroller|nav|wrapper|listItem|header|tabBar|item|avatar|nameTag|panelTitleContainer|searchBar|channel|layout|interactive|link|name|children|toolbar|peopleColumn|nowPlayingColumn|tutorial)_/;
  const walk = (el, depth) => {
    if (depth > 14) return;
    for (const c of el.children) {
      const cls = [...c.classList].find(k => want.test(k));
      const r = c.getBoundingClientRect();
      if (cls && r.width > 0 && !seen.has(cls + depth)) {
        seen.add(cls + depth);
        const cs = getComputedStyle(c);
        out.push([depth, cls, Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height), cs.backgroundColor, cs.borderRadius, cs.fontSize, cs.fontWeight, cs.lineHeight, cs.color, cs.padding, cs.fontFamily.slice(0,40)]);
      }
      walk(c, depth + 1);
    }
  };
  walk(document.querySelector('#app-mount'), 0);
  return out.map(x => x.join(' | ')).join('\n');
})()
