// AI Stack writing assistant: red (errors) / blue (phrasing) underlines in text fields,
// hover cards, a badge with all suggestions, and Ctrl+Alt+A to accept everything.
(() => {
  'use strict';
  if (window.__aistackWriting) return;
  window.__aistackWriting = true;
  // Google Docs draws text on a canvas: nothing to underline there.
  if (location.hostname === 'docs.google.com' && /^\/(document|presentation|spreadsheets)\//.test(location.pathname)) return;

  const DEBOUNCE_MS = 900;
  const MAX_LENGTH = 30000;
  const COLORS = { error: '#e5484d', style: '#2b6ff2' };
  const site = location.hostname;
  const settings = { writingEnabled: true, styleSuggestions: true, disabledSites: [] };

  const extensionAlive = () => {
    try { return Boolean(chrome.runtime?.id); } catch { return false; }
  };

  function send(message) {
    return new Promise((resolve, reject) => {
      if (!extensionAlive()) { reject(new Error('AI Stack was updated — reload this page.')); return; }
      try {
        chrome.runtime.sendMessage(message, (reply) => {
          const error = chrome.runtime.lastError;
          if (error) reject(new Error(error.message));
          else if (!reply?.ok) reject(new Error(reply?.error || 'AI Stack error'));
          else resolve(reply);
        });
      } catch (error) {
        reject(error);
      }
    });
  }

  const enabled = () => settings.writingEnabled && !(settings.disabledSites || []).includes(site);

  try {
    chrome.storage.local.get(Object.keys(settings)).then((stored) => {
      Object.assign(settings, stored);
      if (!enabled()) deactivate();
    });
    chrome.storage.onChanged.addListener((changes) => {
      for (const [key, { newValue }] of Object.entries(changes)) if (key in settings) settings[key] = newValue;
      if (!enabled()) deactivate();
      else { recompute(issues); scheduleLayout(); }
    });
  } catch { return; }

  // ---------------------------------------------------------------------------
  // Engine: paragraphs, cache, Claude request, span location (same logic as the Mac app)

  const cache = new Map();
  const inFlight = new Set();
  const failedAt = new Map();
  const ignored = new Set();

  function paragraphs(text) {
    const result = [];
    let start = 0;
    for (let i = 0; i <= text.length; i++) {
      const c = i === text.length ? '\n' : text[i];
      if (c === '\n' || c === '\r' || c === ' ' || c === ' ') {
        if (i > start) result.push({ text: text.slice(start, i), start });
        start = i + 1;
      }
    }
    return result;
  }

  function isCheckable(paragraph) {
    const t = paragraph.trim();
    if (t.length < 3 || !/\p{L}/u.test(t)) return false;
    if (!t.includes(' ') && (/^https?:/i.test(t) || t.includes('@') || t.includes('/'))) return false;
    return true;
  }

  function hashString(s) {
    let h = 0;
    for (let i = 0; i < s.length; i++) h = (Math.imul(31, h) + s.charCodeAt(i)) | 0;
    return h;
  }

  function paragraphsToCheck(text, caret) {
    const now = Date.now();
    const seen = new Set();
    const candidates = paragraphs(text).filter((p) => {
      if (seen.has(p.text)) return false;
      seen.add(p.text);
      if (cache.has(p.text) || inFlight.has(p.text) || !isCheckable(p.text)) return false;
      const failed = failedAt.get(p.text);
      return !(failed && now - failed < 45000);
    });
    const distance = (p) => {
      const end = p.start + p.text.length;
      if (caret >= p.start && caret <= end) return 0;
      return caret < p.start ? p.start - caret : caret - end;
    };
    candidates.sort((a, b) => distance(a) - distance(b));
    const batch = [];
    let total = 0;
    for (const p of candidates) {
      if (batch.length && (total + p.text.length > 5000 || batch.length >= 16)) break;
      batch.push(p.text);
      total += p.text.length;
    }
    batch.forEach((p) => inFlight.add(p));
    return batch;
  }

  function storeResults(results) {
    for (const [paragraph, items] of results) {
      cache.delete(paragraph);
      cache.set(paragraph, items);
      inFlight.delete(paragraph);
      failedAt.delete(paragraph);
    }
    while (cache.size > 800) cache.delete(cache.keys().next().value);
  }

  function markFailed(batch) {
    const now = Date.now();
    batch.forEach((p) => { inFlight.delete(p); failedAt.set(p, now); });
  }

  function parseIssues(raw) {
    let body = (raw || '').trim();
    const a = body.indexOf('{');
    const b = body.lastIndexOf('}');
    if (a >= 0 && b > a) body = body.slice(a, b + 1);
    const parsed = JSON.parse(body);
    return (parsed.issues || []).map((entry) => ({
      p: Number(entry.p),
      kind: entry.type === 'style' ? 'style' : 'error',
      text: String(entry.text ?? ''),
      before: String(entry.before ?? ''),
      fix: String(entry.fix ?? ''),
      why: String(entry.why ?? ''),
    })).filter((i) => Number.isFinite(i.p) && i.text && i.fix !== i.text && i.fix.length < 800);
  }

  function locate(needle, before, paragraph, taken) {
    const find = (haystack, target) => {
      const found = [];
      let from = 0;
      while (from <= haystack.length) {
        const index = haystack.indexOf(target, from);
        if (index < 0) break;
        found.push(index);
        from = index + Math.max(target.length, 1);
      }
      return found;
    };
    let starts = find(paragraph, needle);
    if (!starts.length) starts = find(paragraph.toLowerCase(), needle.toLowerCase());
    const free = starts.filter((s) => !taken.some((t) => s < t.start + t.len && t.start < s + needle.length));
    if (!free.length) return null;
    const anchor = before.trim();
    let chosen = free[0];
    if (anchor) {
      const match = free.find((s) => paragraph.slice(0, s).trimEnd().endsWith(anchor));
      if (match !== undefined) chosen = match;
    }
    return { start: chosen, len: needle.length, actual: paragraph.slice(chosen, chosen + needle.length) };
  }

  async function checkBatch(batch) {
    const reply = await send({ type: 'grammar', paragraphs: batch, app: `${site} (Chrome)` });
    const items = parseIssues(reply.text);
    const results = new Map(batch.map((p) => [p, []]));
    const taken = new Map();
    for (const item of items) {
      if (item.p < 1 || item.p > batch.length) continue;
      const paragraph = batch[item.p - 1];
      const spans = taken.get(paragraph) || [];
      const loc = locate(item.text, item.before, paragraph, spans);
      if (!loc || loc.actual === item.fix) continue;
      spans.push(loc);
      taken.set(paragraph, spans);
      results.get(paragraph).push({ kind: item.kind, start: loc.start, len: loc.len, text: loc.actual, fix: item.fix, why: item.why });
    }
    return results;
  }

  function recordApplied(issue) {
    const items = cache.get(issue.paragraph);
    if (!items) return;
    const updated = issue.paragraph.slice(0, issue.local) + issue.fix + issue.paragraph.slice(issue.local + issue.text.length);
    const delta = issue.fix.length - issue.text.length;
    const remaining = [];
    for (const item of items) {
      if (item.start === issue.local && item.fix === issue.fix) continue;
      if (item.start < issue.local + issue.text.length && issue.local < item.start + item.len) continue;
      remaining.push(item.start >= issue.local + issue.text.length ? { ...item, start: item.start + delta } : item);
    }
    storeResults(new Map([[updated, remaining]]));
  }

  const ignoreKey = (issue) => `${issue.paragraph}\u0001${issue.text}\u0001${issue.fix}`;

  // ---------------------------------------------------------------------------
  // Fields: <textarea>/<input> and contenteditable editors (Gmail, Slack, Notion…)

  function editableRoot(el) {
    if (!el || !el.isContentEditable) return null;
    let root = el;
    while (root.parentElement && root.parentElement.isContentEditable) root = root.parentElement;
    return root;
  }

  function usable(el) {
    if (el.readOnly || el.disabled) return false;
    if (el.getAttribute('aria-readonly') === 'true') return false;
    // Note: spellcheck="false" is NOT a reason to skip — Gmail sets it on its message body because it
    // runs its own checker. Sites opt out of writing assistants with the Grammarly attributes instead.
    if (el.closest('[data-gramm="false"], [data-gramm_editor="false"], [data-enable-grammarly="false"], [data-aistack-ignore]')) return false;
    if (el.closest('.monaco-editor, .cm-editor, .CodeMirror, .ace_editor, .ql-code-block, pre, code')) return false;
    if (el instanceof HTMLInputElement && el.closest('[role="combobox"], [role="search"]')) return false;
    return true;
  }

  function fieldFor(target) {
    if (!(target instanceof Element)) return null;
    if (target instanceof HTMLTextAreaElement) return usable(target) ? new TextControl(target) : null;
    if (target instanceof HTMLInputElement) {
      const type = (target.getAttribute('type') || 'text').toLowerCase();
      return type === 'text' && usable(target) && target.autocomplete !== 'off' ? new TextControl(target) : null;
    }
    const root = editableRoot(target);
    return root && usable(root) ? new RichText(root) : null;
  }

  const MIRROR_PROPS = [
    'direction', 'boxSizing', 'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth', 'borderStyle',
    'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft', 'fontStyle', 'fontVariant', 'fontWeight', 'fontStretch',
    'fontSize', 'fontSizeAdjust', 'lineHeight', 'fontFamily', 'fontFeatureSettings', 'fontKerning', 'textAlign',
    'textTransform', 'textIndent', 'letterSpacing', 'wordSpacing', 'tabSize', 'wordBreak',
  ];

  class TextControl {
    constructor(el) { this.el = el; this.kind = 'control'; }
    getText() { return this.el.value.replace(/ /g, ' '); }
    caret() { return this.el.selectionStart ?? this.el.value.length; }
    frame() { return this.el.getBoundingClientRect(); }

    rects(ranges) {
      const el = this.el;
      const style = getComputedStyle(el);
      const box = el.getBoundingClientRect();
      const mirror = ui.mirror;
      mirror.textContent = '';
      const s = mirror.style;
      s.cssText = '';
      for (const prop of MIRROR_PROPS) s[prop] = style[prop];
      const isInput = el.tagName === 'INPUT';
      Object.assign(s, {
        position: 'fixed', visibility: 'hidden', pointerEvents: 'none', overflow: 'hidden', borderColor: 'transparent',
        left: `${box.left}px`, top: `${box.top}px`, width: `${box.width}px`, boxSizing: 'border-box',
        whiteSpace: isInput ? 'pre' : 'pre-wrap', overflowWrap: isInput ? 'normal' : 'break-word',
      });
      const borderX = (parseFloat(style.borderLeftWidth) || 0) + (parseFloat(style.borderRightWidth) || 0);
      const scrollbar = el.offsetWidth - el.clientWidth - borderX;
      if (scrollbar > 0) s.paddingRight = `${(parseFloat(style.paddingRight) || 0) + scrollbar}px`;

      const text = el.value;
      const spans = [];
      let position = 0;
      for (const range of [...ranges].sort((a, b) => a.start - b.start)) {
        if (range.start < position) continue;
        mirror.append(text.slice(position, range.start));
        const span = document.createElement('span');
        span.textContent = text.slice(range.start, range.end);
        mirror.append(span);
        spans.push([range.key, span]);
        position = range.end;
      }
      mirror.append(text.slice(position) + '​');

      let dy = -el.scrollTop;
      const dx = -el.scrollLeft;
      if (isInput && spans.length) {
        // Inputs centre their single line vertically.
        const lineHeight = spans[0][1].getBoundingClientRect().height;
        const inner = box.height - (parseFloat(style.borderTopWidth) || 0) - (parseFloat(style.borderBottomWidth) || 0)
          - (parseFloat(style.paddingTop) || 0) - (parseFloat(style.paddingBottom) || 0);
        dy += Math.max(0, (inner - lineHeight) / 2);
      }
      const out = new Map();
      for (const [key, span] of spans) {
        out.set(key, mergeLines([...span.getClientRects()]).map((r) => shift(r, dx, dy)));
      }
      mirror.textContent = '';
      return out;
    }

    async replace(start, end, fix) {
      const el = this.el;
      const before = el.value;
      const expected = before.slice(0, start) + fix + before.slice(end);
      el.focus({ preventScroll: true });
      el.setSelectionRange(start, end);
      try {
        if (fix) document.execCommand('insertText', false, fix);
        else document.execCommand('delete');
      } catch { /* fall through */ }
      if (el.value !== expected) {
        el.setRangeText(fix, start, end, 'end');
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
      return el.value === expected;
    }
  }

  const BLOCK_TAGS = new Set(['DIV', 'P', 'LI', 'UL', 'OL', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'BLOCKQUOTE', 'PRE', 'TR', 'TABLE', 'SECTION', 'ARTICLE', 'HEADER', 'FOOTER', 'FIGURE']);
  // Quoted replies and signatures (Gmail, Outlook web) are not the user's new text.
  const SKIP_SELECTOR = '.gmail_quote, .gmail_signature, .gmail_extra, [data-smartmail="gmail_signature"], blockquote[type="cite"], #divRplyFwdMsg, #Signature, [contenteditable="false"], script, style';

  class RichText {
    constructor(root) { this.el = root; this.kind = 'rich'; this.model = { text: '', nodes: [] }; }

    getText() {
      const nodes = [];
      let text = '';
      const root = this.el;
      const walk = (node) => {
        if (node.nodeType === Node.TEXT_NODE) {
          const value = node.nodeValue;
          if (value) {
            nodes.push({ node, start: text.length });
            text += value.replace(/ /g, ' ');
          }
          return;
        }
        if (node.nodeType !== Node.ELEMENT_NODE) return;
        if (node !== root && node.matches(SKIP_SELECTOR)) {
          if (text && !text.endsWith('\n')) text += '\n';
          return;
        }
        if (node.tagName === 'BR') { text += '\n'; return; }
        const block = node !== root && BLOCK_TAGS.has(node.tagName);
        if (block && text && !text.endsWith('\n')) text += '\n';
        for (const child of node.childNodes) walk(child);
        if (block && text && !text.endsWith('\n')) text += '\n';
      };
      walk(root);
      this.model = { text, nodes };
      return text;
    }

    frame() { return this.el.getBoundingClientRect(); }

    caret() {
      const selection = getSelection();
      if (!selection?.rangeCount) return this.model.text.length;
      const node = selection.focusNode;
      const entry = this.model.nodes.find((n) => n.node === node);
      if (entry) return entry.start + selection.focusOffset;
      return this.model.text.length;
    }

    point(offset, isEnd) {
      const nodes = this.model.nodes;
      if (!nodes.length) return null;
      let lo = 0;
      let hi = nodes.length - 1;
      let index = -1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (nodes[mid].start <= offset) { index = mid; lo = mid + 1; } else hi = mid - 1;
      }
      if (index < 0) return { node: nodes[0].node, offset: 0 };
      const entry = nodes[index];
      const length = entry.node.nodeValue.length;
      if (offset <= entry.start + length) {
        if (isEnd && offset === entry.start && index > 0) {
          const prev = nodes[index - 1];
          if (prev.start + prev.node.nodeValue.length === offset) return { node: prev.node, offset: prev.node.nodeValue.length };
        }
        return { node: entry.node, offset: offset - entry.start };
      }
      if (isEnd) return { node: entry.node, offset: length };
      const next = nodes[index + 1];
      return next ? { node: next.node, offset: 0 } : { node: entry.node, offset: length };
    }

    range(start, end) {
      const a = this.point(start, false);
      const b = this.point(end, true);
      if (!a || !b || !a.node.isConnected || !b.node.isConnected) return null;
      const range = document.createRange();
      try {
        range.setStart(a.node, Math.min(a.offset, a.node.nodeValue.length));
        range.setEnd(b.node, Math.min(b.offset, b.node.nodeValue.length));
      } catch { return null; }
      return range;
    }

    rects(ranges) {
      const out = new Map();
      for (const r of ranges) {
        const range = this.range(r.start, r.end);
        if (range) out.set(r.key, mergeLines([...range.getClientRects()]));
      }
      return out;
    }

    async replace(start, end, fix) {
      const range = this.range(start, end);
      if (!range) return false;
      const before = this.getText();
      const expected = before.slice(0, start) + fix + before.slice(end);
      this.el.focus({ preventScroll: true });
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      try {
        if (fix) document.execCommand('insertText', false, fix);
        else document.execCommand('delete');
      } catch { return false; }
      await new Promise((r) => requestAnimationFrame(() => r()));
      return this.getText() === expected;
    }
  }

  function mergeLines(list) {
    const out = [];
    for (const r of list) {
      if (r.width < 1 || r.height < 1) continue;
      const last = out[out.length - 1];
      if (last && Math.abs((last.top + last.bottom) / 2 - (r.top + r.bottom) / 2) < Math.min(last.height, r.height) * 0.5) {
        last.left = Math.min(last.left, r.left);
        last.right = Math.max(last.right, r.right);
        last.top = Math.min(last.top, r.top);
        last.bottom = Math.max(last.bottom, r.bottom);
      } else {
        out.push({ left: r.left, right: r.right, top: r.top, bottom: r.bottom });
      }
    }
    return out;
  }

  const shift = (r, dx, dy) => ({ left: r.left + dx, right: r.right + dx, top: r.top + dy, bottom: r.bottom + dy });

  function intersect(a, b) {
    const r = { left: Math.max(a.left, b.left), right: Math.min(a.right, b.right), top: Math.max(a.top, b.top), bottom: Math.min(a.bottom, b.bottom) };
    return r.right > r.left && r.bottom > r.top ? r : null;
  }

  function clipRect(el) {
    let clip = el.getBoundingClientRect();
    clip = { left: clip.left, right: clip.right, top: clip.top, bottom: clip.bottom };
    for (let node = el.parentElement; node && node !== document.documentElement; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (/(auto|scroll|hidden|clip)/.test(style.overflowY + style.overflowX)) {
        const r = node.getBoundingClientRect();
        clip = intersect(clip, r) || { left: 0, right: 0, top: 0, bottom: 0 };
      }
    }
    return intersect(clip, { left: 0, top: 0, right: innerWidth, bottom: innerHeight });
  }

  // ---------------------------------------------------------------------------
  // UI (closed shadow root so page styles can't interfere)

  const ui = (() => {
    const host = document.createElement('aistack-ui');
    host.style.cssText = 'all: initial; position: fixed; left: 0; top: 0; width: 0; height: 0; z-index: 2147483647; pointer-events: none;';
    const root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `
      <style>
        :host { all: initial; }
        * { box-sizing: border-box; font-family: -apple-system, "Segoe UI", system-ui, sans-serif; }
        .line { position: fixed; height: 2px; border-radius: 1px; pointer-events: none; opacity: .85; }
        .hl { position: fixed; border-radius: 3px; pointer-events: none; }
        .panel { position: fixed; pointer-events: auto; background: #fff; color: #1d1d1f; border-radius: 12px;
          box-shadow: 0 8px 30px rgba(0,0,0,.18), 0 0 0 1px rgba(0,0,0,.06); font-size: 13px; line-height: 1.35; }
        .card { width: 320px; padding: 12px; }
        .head { display: flex; align-items: center; gap: 6px; margin-bottom: 8px; }
        .dot { width: 8px; height: 8px; border-radius: 50%; flex: none; }
        .label { font-size: 10px; font-weight: 700; letter-spacing: .04em; color: #6e6e73; text-transform: uppercase; }
        .why { margin-left: auto; font-size: 11px; color: #6e6e73; text-align: right; max-width: 65%; white-space: normal; }
        .old { color: #6e6e73; text-decoration: line-through; margin-bottom: 4px; overflow-wrap: anywhere; }
        .fix { display: block; width: 100%; text-align: left; border: 0; border-radius: 8px; padding: 7px 10px; color: #fff;
          font-weight: 600; font-size: 13px; cursor: pointer; overflow-wrap: anywhere; }
        .fix:hover { filter: brightness(1.08); }
        .foot { display: flex; gap: 14px; margin-top: 10px; font-size: 11px; color: #6e6e73; align-items: center; }
        .link { background: none; border: 0; padding: 0; color: #6e6e73; cursor: pointer; font-size: 11px; }
        .link:hover { color: #1d1d1f; text-decoration: underline; }
        .hint { margin-left: auto; color: #aeaeb2; white-space: nowrap; }
        .badge { width: 24px; height: 24px; border-radius: 50%; border: 0; color: #fff; font-size: 11px; font-weight: 700;
          display: grid; place-items: center; cursor: pointer; pointer-events: auto; position: fixed;
          box-shadow: 0 1px 4px rgba(0,0,0,.25); }
        .spin { width: 10px; height: 10px; border: 2px solid rgba(255,255,255,.5); border-top-color: #fff; border-radius: 50%; animation: s .8s linear infinite; }
        @keyframes s { to { transform: rotate(360deg); } }
        .list { width: 340px; max-height: 420px; display: flex; flex-direction: column; }
        .list .top { display: flex; gap: 8px; align-items: center; padding: 12px; border-bottom: 1px solid #ececec; }
        .list .title { font-weight: 600; flex: 1; }
        .btn { border: 0; border-radius: 7px; padding: 5px 10px; font-size: 12px; cursor: pointer; background: #f0f0f2; color: #1d1d1f; }
        .btn.primary { color: #fff; }
        .rows { overflow-y: auto; }
        .row { display: flex; gap: 8px; padding: 9px 12px; border-bottom: 1px solid #f2f2f2; align-items: flex-start; }
        .row .body { flex: 1; min-width: 0; font-size: 12px; }
        .row .new { font-weight: 600; overflow-wrap: anywhere; }
        .row .sub { font-size: 11px; color: #6e6e73; }
        .row .dot { margin-top: 5px; }
        .status { padding: 6px 12px; font-size: 11px; color: #6e6e73; }
        @media (prefers-color-scheme: dark) {
          .panel { background: #2c2c2e; color: #f5f5f7; box-shadow: 0 8px 30px rgba(0,0,0,.5), 0 0 0 1px rgba(255,255,255,.08); }
          .btn { background: #3a3a3c; color: #f5f5f7; }
          .list .top, .row { border-color: #3a3a3c; }
          .link:hover { color: #f5f5f7; }
        }
      </style>
      <div class="layer"></div><div class="mirror"></div>`;
    const layer = root.querySelector('.layer');
    const mirror = root.querySelector('.mirror');
    return {
      host, root, layer, mirror,
      attach() { if (!host.isConnected) document.documentElement.appendChild(host); },
    };
  })();

  // ---------------------------------------------------------------------------
  // State

  let field = null;
  let text = '';
  let issues = [];
  let rects = new Map();
  let clip = null;
  let lastChange = 0;
  let checking = false;
  let lastError = null;
  let applying = false;
  let layoutQueued = false;
  let card = null; // { issue, el, pinned }
  let listEl = null;
  let badgeEl = null;
  let hoverTimer = null;
  let hideTimer = null;
  let lastPrewarm = 0;

  function activate(next) {
    if (field && field.el === next.el) return;
    deactivate();
    field = next;
    text = field.getText();
    lastChange = Date.now();
    recompute([]);
    if (Date.now() - lastPrewarm > 30000) {
      lastPrewarm = Date.now();
      send({ type: 'prewarm' }).catch(() => {});
    }
  }

  function deactivate() {
    field = null;
    text = '';
    issues = [];
    rects = new Map();
    hideCard();
    hideList();
    ui.layer.textContent = '';
    if (badgeEl) { badgeEl.remove(); badgeEl = null; }
  }

  function makeIssue(paragraph, offset, item) {
    return {
      id: `${hashString(paragraph)}|${item.start}|${item.len}|${hashString(item.fix)}`,
      kind: item.kind, start: offset + item.start, end: offset + item.start + item.len,
      text: item.text, fix: item.fix, why: item.why, paragraph, local: item.start,
    };
  }

  /// Keeps underlines the edit didn't touch, shifted to their new position.
  function shiftIssues(list, oldText, newText) {
    if (!list.length) return [];
    let prefix = 0;
    while (prefix < oldText.length && prefix < newText.length && oldText[prefix] === newText[prefix]) prefix++;
    let suffix = 0;
    while (suffix < oldText.length - prefix && suffix < newText.length - prefix
      && oldText[oldText.length - 1 - suffix] === newText[newText.length - 1 - suffix]) suffix++;
    const editEnd = oldText.length - suffix;
    const delta = newText.length - oldText.length;
    return list.flatMap((issue) => {
      if (issue.end < prefix) return [issue];
      if (issue.start > editEnd) return [{ ...issue, start: issue.start + delta, end: issue.end + delta }];
      return [];
    });
  }

  function recompute(provisional) {
    const result = [];
    for (const p of paragraphs(text)) {
      const cached = cache.get(p.text);
      if (cached) {
        for (const item of cached) {
          const issue = makeIssue(p.text, p.start, item);
          if (ignored.has(ignoreKey(issue))) continue;
          if (issue.kind === 'style' && !settings.styleSuggestions) continue;
          result.push(issue);
        }
      } else {
        result.push(...provisional.filter((i) => i.start >= p.start && i.end <= p.start + p.text.length));
      }
    }
    issues = result.filter((i) => text.slice(i.start, i.end) === i.text);
    scheduleLayout();
    if (listEl) renderList();
  }

  function syncText() {
    if (!field) return;
    if (!field.el.isConnected) { deactivate(); return; }
    const current = field.getText();
    if (current === text) return;
    const previous = text;
    text = current;
    lastChange = Date.now();
    if (card) hideCard();
    recompute(shiftIssues(issues, previous, current));
  }

  function maybeCheck() {
    if (!field || checking || applying || !enabled() || text.length > MAX_LENGTH) return;
    if (Date.now() - lastChange < DEBOUNCE_MS) return;
    const batch = paragraphsToCheck(text, field.caret());
    if (!batch.length) return;
    checking = true;
    renderBadge();
    checkBatch(batch)
      .then((results) => { storeResults(results); lastError = null; })
      .catch((error) => { markFailed(batch); lastError = error.message; })
      .finally(() => { checking = false; recompute(issues); renderBadge(); });
  }

  // ---------------------------------------------------------------------------
  // Layout & drawing

  function scheduleLayout() {
    if (layoutQueued) return;
    layoutQueued = true;
    requestAnimationFrame(() => { layoutQueued = false; layout(); });
  }

  function layout() {
    if (!field) return;
    ui.attach();
    clip = clipRect(field.el);
    rects = new Map();
    if (issues.length && clip) {
      const measured = field.rects(issues.map((i) => ({ key: i.id, start: i.start, end: i.end })));
      for (const issue of issues) {
        const visible = (measured.get(issue.id) || []).map((r) => intersect(r, clip)).filter((r) => r && r.bottom - r.top > 4);
        if (visible.length) rects.set(issue.id, visible);
      }
    }
    draw();
    renderBadge();
  }

  function draw() {
    const layer = ui.layer;
    layer.textContent = '';
    const highlighted = card?.issue.id;
    for (const issue of issues) {
      for (const r of rects.get(issue.id) || []) {
        if (issue.id === highlighted) {
          const hl = document.createElement('div');
          hl.className = 'hl';
          Object.assign(hl.style, { left: `${r.left - 1}px`, top: `${r.top}px`, width: `${r.right - r.left + 2}px`, height: `${r.bottom - r.top}px`, background: `${COLORS[issue.kind]}22` });
          layer.append(hl);
        }
        const line = document.createElement('div');
        line.className = 'line';
        Object.assign(line.style, { left: `${r.left}px`, top: `${r.bottom - 1}px`, width: `${r.right - r.left}px`, background: COLORS[issue.kind] });
        layer.append(line);
      }
    }
  }

  function issueAt(x, y) {
    for (const issue of issues) {
      for (const r of rects.get(issue.id) || []) {
        if (x >= r.left - 1 && x <= r.right + 1 && y >= r.top - 2 && y <= r.bottom + 3) return { issue, rect: r };
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Card

  function el(tag, className, textContent) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (textContent != null) node.textContent = textContent;
    return node;
  }

  function keepFocus(node) {
    // Clicking our UI must not blur the field we're editing.
    node.addEventListener('mousedown', (e) => { e.preventDefault(); e.stopPropagation(); });
  }

  function showCard(issue, rect, pinned) {
    if (card?.issue.id === issue.id) { card.pinned ||= pinned; return; }
    hideCard();
    const node = el('div', 'panel card');
    keepFocus(node);
    const head = el('div', 'head');
    const dot = el('span', 'dot');
    dot.style.background = COLORS[issue.kind];
    head.append(dot, el('span', 'label', issue.kind === 'error' ? 'Correctness' : 'Clarity'), el('span', 'why', issue.why));
    node.append(head);
    if (issue.kind === 'error' || issue.text.length < 40) node.append(el('div', 'old', issue.text));
    const fix = el('button', 'fix', issue.fix || 'Remove');
    fix.style.background = COLORS[issue.kind];
    fix.addEventListener('click', () => accept(issue));
    node.append(fix);
    const foot = el('div', 'foot');
    const ignore = el('button', 'link', 'Ignore');
    ignore.addEventListener('click', () => { ignored.add(ignoreKey(issue)); hideCard(); recompute(issues); });
    const off = el('button', 'link', 'Turn off on this site');
    off.title = site;
    off.addEventListener('click', () => {
      const list = [...new Set([...(settings.disabledSites || []), site])];
      chrome.storage.local.set({ disabledSites: list });
      deactivate();
    });
    foot.append(ignore, off, el('span', 'hint', 'Ctrl+Alt+A: accept all'));
    node.append(foot);
    node.addEventListener('mouseenter', () => { clearTimeout(hideTimer); hideTimer = null; });
    node.addEventListener('mouseleave', () => {
      if (!card?.pinned) hideTimer = setTimeout(() => { hideTimer = null; hideCard(); }, 400);
    });
    ui.root.append(node);
    const width = 320;
    const height = node.offsetHeight;
    let left = Math.min(Math.max(8, rect.left - 12), innerWidth - width - 8);
    let top = rect.bottom + 6;
    if (top + height > innerHeight - 8) top = Math.max(8, rect.top - height - 6);
    Object.assign(node.style, { left: `${left}px`, top: `${top}px` });
    card = { issue, el: node, pinned };
    draw();
  }

  function hideCard() {
    clearTimeout(hoverTimer);
    clearTimeout(hideTimer);
    hideTimer = null;
    if (!card) return;
    card.el.remove();
    card = null;
    draw();
  }

  // ---------------------------------------------------------------------------
  // Badge + list

  function renderBadge() {
    const show = field && enabled() && clip && (clip.bottom - clip.top) >= 30 && (clip.right - clip.left) >= 120
      && paragraphs(text).some((p) => isCheckable(p.text));
    if (!show) {
      if (badgeEl) { badgeEl.remove(); badgeEl = null; }
      return;
    }
    if (!badgeEl) {
      badgeEl = el('button', 'badge');
      keepFocus(badgeEl);
      badgeEl.addEventListener('click', () => (listEl ? hideList() : showList()));
      ui.root.append(badgeEl);
    }
    const errors = issues.filter((i) => i.kind === 'error').length;
    badgeEl.textContent = '';
    if (checking) {
      badgeEl.style.background = '#8e8e93';
      badgeEl.append(el('span', 'spin'));
      badgeEl.title = 'Checking with Claude…';
    } else if (lastError && !issues.length) {
      badgeEl.style.background = '#ff9f0a';
      badgeEl.textContent = '!';
      badgeEl.title = lastError;
    } else if (!issues.length) {
      badgeEl.style.background = '#30a46c';
      badgeEl.textContent = '✓';
      badgeEl.title = 'Looks good';
    } else {
      badgeEl.style.background = errors ? COLORS.error : COLORS.style;
      badgeEl.textContent = String(Math.min(issues.length, 99));
      badgeEl.title = `${issues.length} suggestion(s) — click to review, Ctrl+Alt+A to accept all`;
    }
    Object.assign(badgeEl.style, { left: `${clip.right - 30}px`, top: `${clip.bottom - 30}px` });
  }

  function showList() {
    hideCard();
    listEl = el('div', 'panel list');
    keepFocus(listEl);
    ui.root.append(listEl);
    renderList();
  }

  function hideList() {
    if (listEl) listEl.remove();
    listEl = null;
  }

  function renderList() {
    if (!listEl) return;
    listEl.textContent = '';
    const top = el('div', 'top');
    top.append(el('span', 'title', issues.length ? `${issues.length} suggestion${issues.length === 1 ? '' : 's'}` : 'No suggestions'));
    const hasErrors = issues.some((i) => i.kind === 'error');
    if (hasErrors && issues.some((i) => i.kind === 'style')) {
      const errorsOnly = el('button', 'btn', 'Errors only');
      errorsOnly.addEventListener('click', () => acceptAll(true));
      top.append(errorsOnly);
    }
    if (issues.length) {
      const all = el('button', 'btn primary', 'Accept all');
      all.style.background = hasErrors ? COLORS.error : COLORS.style;
      all.title = 'Ctrl+Alt+A';
      all.addEventListener('click', () => acceptAll(false));
      top.append(all);
    }
    const close = el('button', 'link', '✕');
    close.addEventListener('click', hideList);
    top.append(close);
    listEl.append(top);
    if (checking) listEl.append(el('div', 'status', 'Checking with Claude…'));
    else if (lastError) listEl.append(el('div', 'status', lastError));
    const rows = el('div', 'rows');
    for (const issue of issues) {
      const row = el('div', 'row');
      const dot = el('span', 'dot');
      dot.style.background = COLORS[issue.kind];
      const body = el('div', 'body');
      body.append(el('div', 'old', issue.text), el('div', 'new', issue.fix || '(remove)'));
      if (issue.why) body.append(el('div', 'sub', issue.why));
      const accept1 = el('button', 'btn', 'Accept');
      accept1.addEventListener('click', () => accept(issue));
      row.append(dot, body, accept1);
      rows.append(row);
    }
    listEl.append(rows);
    if (badgeEl) {
      const b = badgeEl.getBoundingClientRect();
      const width = 340;
      const height = listEl.offsetHeight;
      let left = Math.min(Math.max(8, b.right - width), innerWidth - width - 8);
      let topPos = b.top - height - 8;
      if (topPos < 8) topPos = Math.min(innerHeight - height - 8, b.bottom + 8);
      Object.assign(listEl.style, { left: `${left}px`, top: `${topPos}px` });
    }
  }

  // ---------------------------------------------------------------------------
  // Actions

  async function apply(issue) {
    if (!field) return false;
    syncText();
    if (text.slice(issue.start, issue.end) !== issue.text) return false;
    recordApplied(issue);
    const ok = await field.replace(issue.start, issue.end, issue.fix);
    syncText();
    return ok;
  }

  async function accept(issue) {
    hideCard();
    if (applying) return;
    applying = true;
    try { await apply(issue); } finally { applying = false; }
    recompute(issues);
  }

  async function acceptAll(errorsOnly) {
    if (!field || applying) return;
    const targets = issues.filter((i) => !errorsOnly || i.kind === 'error').sort((a, b) => b.start - a.start);
    if (!targets.length) return;
    hideCard();
    hideList();
    applying = true;
    try {
      // Later spans first, so earlier offsets stay valid while the text changes.
      for (const issue of targets) {
        if (!(await apply(issue))) break;
      }
    } finally {
      applying = false;
    }
    recompute(issues);
  }

  // ---------------------------------------------------------------------------
  // Events

  document.addEventListener('focusin', (e) => {
    if (!enabled()) return;
    const target = e.composedPath()[0];
    if (target === ui.host) return;
    const next = fieldFor(target);
    if (next) activate(next);
  }, true);

  document.addEventListener('focusout', () => {
    setTimeout(() => {
      if (!field) return;
      const active = document.activeElement;
      if (active === ui.host) return;
      if (active && (active === field.el || field.el.contains(active))) return;
      deactivate();
    }, 200);
  }, true);

  document.addEventListener('input', (e) => {
    if (field && (e.target === field.el || field.el.contains(e.target))) syncText();
  }, true);

  addEventListener('scroll', scheduleLayout, { capture: true, passive: true });
  addEventListener('resize', scheduleLayout, { passive: true });

  addEventListener('mousemove', (e) => {
    if (!field || !issues.length) return;
    if (e.composedPath()[0] === ui.host || e.target === ui.host) return;
    const hit = issueAt(e.clientX, e.clientY);
    if (hit) {
      clearTimeout(hideTimer);
      hideTimer = null;
      if (card?.issue.id === hit.issue.id) return;
      clearTimeout(hoverTimer);
      hoverTimer = setTimeout(() => showCard(hit.issue, hit.rect, false), 220);
    } else {
      clearTimeout(hoverTimer);
      if (card && !card.pinned && !hideTimer) hideTimer = setTimeout(() => { hideTimer = null; hideCard(); }, 400);
    }
  }, { capture: true, passive: true });

  addEventListener('mousedown', (e) => {
    if (e.target === ui.host) return;
    const hit = field && issueAt(e.clientX, e.clientY);
    if (hit) {
      setTimeout(() => showCard(hit.issue, hit.rect, true), 0);
      return;
    }
    hideCard();
    hideList();
  }, true);

  addEventListener('keydown', (e) => {
    if (!field) return;
    if (e.ctrlKey && e.altKey && !e.metaKey && !e.shiftKey && e.code === 'KeyA') {
      e.preventDefault();
      e.stopImmediatePropagation();
      acceptAll(false);
    } else if (e.key === 'Escape' && (card || listEl)) {
      hideCard();
      hideList();
    }
  }, true);

  // Pages that edit text without input events (signatures, templates…) and moving layouts.
  setInterval(() => {
    if (!extensionAlive()) { deactivate(); return; }
    if (!field && enabled()) {
      const candidate = fieldFor(document.activeElement);
      if (candidate) activate(candidate);
    }
    if (!field) return;
    syncText();
    maybeCheck();
    scheduleLayout();
  }, 350);
})();
