// Text-selection probe: select from the middle of one message to the middle
// of a later one, then report Selection.toString() and what Discord's copy
// handler puts on the clipboard. The copy event is synthetic with our own
// DataTransfer, so the system clipboard is never touched. If Discord sets no
// data, the browser default (≈ selection.toString()) would be copied.
(() => {
  const msgs = [...document.querySelectorAll('[id^="message-content-"]')].filter((e) => (e.innerText || '').length >= 4);
  if (msgs.length < 3) return JSON.stringify({ error: 'need >= 3 messages', count: msgs.length });
  const a = msgs[msgs.length - 3], b = msgs[msgs.length - 1];
  const textNode = (el) => { const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT); let n; while ((n = w.nextNode())) if (n.data.trim().length >= 2) return n; return null; };
  const na = textNode(a), nb = textNode(b);
  const range = document.createRange();
  range.setStart(na, Math.floor(na.data.length / 2));
  range.setEnd(nb, Math.floor(nb.data.length / 2));
  const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range);
  const dt = new DataTransfer();
  const ev = new ClipboardEvent('copy', { clipboardData: dt, bubbles: true, cancelable: true });
  const prevented = !(na.parentElement.dispatchEvent(ev));
  const div = document.createElement('div'); div.appendChild(range.cloneContents());
  const out = {
    from: a.id, to: b.id,
    from_text: a.innerText, to_text: b.innerText,
    selection_toString: sel.toString(),
    copy_handler_prevented_default: prevented,
    clipboard_types: [...dt.types],
    clipboard_text_plain: dt.getData('text/plain'),
    clipboard_text_html: dt.getData('text/html').slice(0, 8000),
    range_html: div.innerHTML.slice(0, 8000),
  };
  sel.removeAllRanges();
  return JSON.stringify(out);
})()
