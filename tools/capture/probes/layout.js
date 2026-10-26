// Layout dump of key UI elements: rects, resolved colors, typography.
// Colors are resolved through a canvas so color-mix()/oklab() become rgba.
(() => {
  const cv = document.createElement('canvas'); cv.width = cv.height = 1;
  const cx = cv.getContext('2d', { willReadFrequently: true });
  const rgba = (c) => {
    if (!c || c === 'rgba(0, 0, 0, 0)' || c === 'transparent') return c;
    cx.clearRect(0, 0, 1, 1); cx.fillStyle = '#000'; cx.fillStyle = c; cx.fillRect(0, 0, 1, 1);
    const d = cx.getImageData(0, 0, 1, 1).data; return `rgba(${d[0]},${d[1]},${d[2]},${(d[3] / 255).toFixed(3)})`;
  };
  const groups = {
    guild_rail: '[data-list-item-id^="guildsnav___"]',
    channel_rows: '[data-list-item-id^="channels___"]',
    dm_rows: '[data-list-item-id^="private-channels-"]',
    tabs: '[role="tab"]',
    people_rows: 'main [class*="peopleListItem"]',
    message_items: 'li[id^="chat-messages-"]',
    message_headers: '[id^="message-username-"]',
    message_timestamps: 'li[id^="chat-messages-"] time',
    message_content: '[id^="message-content-"]',
    message_avatars: 'li[id^="chat-messages-"] img[class*="avatar"]',
    message_toolbar: '[aria-label="Message Actions"]',
    reactions: '[class*="reactionInner"]',
    composer: 'div[role="textbox"][aria-label^="Message "]',
    composer_form: 'form [class*="channelTextArea"]',
    reply_bar: '[class*="replyBar"], [class*="replying"]',
    member_rows: '[data-list-item-id^="members-"], [class*="member__"]',
    user_panel: 'section[aria-label="User status and settings"]',
    dialogs: '[role="dialog"], [role="alertdialog"]',
    menus: '[role="menu"]',
    menu_items: '[role="menuitem"]',
    emoji_picker: '[id^="emoji-picker"], [class*="emojiPicker"]',
    gif_picker: '[class*="gifPicker"], [id*="gif-picker"]',
    radios: '[role="radio"]',
    quick_switcher: '[class*="quickswitcher"], [aria-label="Quick switcher"]',
    headings: 'h1, h2, h3',
  };
  const out = { url: location.href, viewport: [innerWidth, innerHeight, devicePixelRatio], theme: document.documentElement.className, groups: {} };
  for (const [name, sel] of Object.entries(groups)) {
    const els = [...document.querySelectorAll(sel)].slice(0, 40);
    out.groups[name] = els.map((e) => {
      const r = e.getBoundingClientRect(); const cs = getComputedStyle(e);
      return {
        rect: [r.x, r.y, r.width, r.height].map((v) => Math.round(v * 10) / 10),
        text: (e.innerText || '').slice(0, 80), aria: e.getAttribute('aria-label'), cls: (e.className || '').toString().slice(0, 80),
        bg: rgba(cs.backgroundColor), color: rgba(cs.color), border: cs.border, radius: cs.borderRadius, padding: cs.padding,
        font: [cs.fontFamily.slice(0, 60), cs.fontSize, cs.fontWeight, cs.lineHeight, cs.letterSpacing], opacity: cs.opacity,
      };
    });
  }
  return JSON.stringify(out);
})()
