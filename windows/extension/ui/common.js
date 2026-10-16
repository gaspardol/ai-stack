// Shared helpers for the extension pages (popup, side panel, notes).
window.AIS = (() => {
  async function message(payload) {
    const reply = await chrome.runtime.sendMessage(payload);
    if (!reply?.ok) throw new Error(reply?.error || 'AI Stack error');
    return reply;
  }

  const host = (request, timeoutMs) => message({ type: 'host', request, timeoutMs });

  function escape(text) {
    return String(text ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  function inline(text) {
    let html = escape(text);
    html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
    html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    html = html.replace(/(^|[^*])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>');
    html = html.replace(/(^|\s)_([^_]+)_(?=\s|$|[.,;:!?])/g, '$1<em>$2</em>');
    html = html.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
    return html;
  }

  /// Small Markdown renderer: headings, (nested) bullets, checklists, numbered lists, quotes, rules.
  function markdown(source) {
    const out = [];
    const lines = String(source || '').split('\n');
    lines.forEach((raw, index) => {
      const indent = Math.floor((raw.match(/^[ \t]*/)[0].replace(/\t/g, '  ').length) / 2);
      const line = raw.trim();
      const pad = `style="margin-left:${indent * 18}px"`;
      let m;
      if (!line) { out.push('<div class="md-gap"></div>'); return; }
      if ((m = line.match(/^(#{1,6})\s+(.*)$/))) { const level = Math.min(m[1].length + 1, 4); out.push(`<h${level}>${inline(m[2])}</h${level}>`); return; }
      if (/^(-{3,}|\*{3,}|_{3,})$/.test(line)) { out.push('<hr>'); return; }
      if ((m = line.match(/^[-*+]\s+\[([ xX])\]\s+(.*)$/))) {
        const done = m[1] !== ' ';
        out.push(`<label class="md-check ${done ? 'done' : ''}" ${pad}><input type="checkbox" data-line="${index}" ${done ? 'checked' : ''}><span>${inline(m[2])}</span></label>`);
        return;
      }
      if ((m = line.match(/^[-*+]\s+(.*)$/))) { out.push(`<div class="md-li" ${pad}><span class="md-bullet">${indent ? '◦' : '•'}</span><span>${inline(m[1])}</span></div>`); return; }
      if ((m = line.match(/^(\d+)[.)]\s+(.*)$/))) { out.push(`<div class="md-li" ${pad}><span class="md-num">${m[1]}.</span><span>${inline(m[2])}</span></div>`); return; }
      if ((m = line.match(/^>\s?(.*)$/))) { out.push(`<blockquote>${inline(m[1])}</blockquote>`); return; }
      out.push(`<p>${inline(line)}</p>`);
    });
    return out.join('');
  }

  function toggleCheckbox(source, lineIndex) {
    const lines = source.split('\n');
    if (lines[lineIndex] == null) return source;
    lines[lineIndex] = /\[ \]/.test(lines[lineIndex])
      ? lines[lineIndex].replace('[ ]', '[x]')
      : lines[lineIndex].replace(/\[[xX]\]/, '[ ]');
    return lines.join('\n');
  }

  function clock(ms) {
    const total = Math.max(0, Math.floor(ms / 1000));
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const two = (n) => String(n).padStart(2, '0');
    return h ? `${h}:${two(m)}:${two(s)}` : `${two(m)}:${two(s)}`;
  }

  /// Consecutive segments of one speaker merged into blocks.
  function blocks(segments) {
    const sorted = [...(segments || [])].sort((a, b) => new Date(a.start) - new Date(b.start));
    const result = [];
    for (const s of sorted) {
      const last = result[result.length - 1];
      if (last && last.speaker === s.speaker && new Date(s.start) - last.end < 6000) {
        last.text += ` ${s.text}`;
        last.end = Math.max(last.end, +new Date(s.end));
      } else {
        result.push({ speaker: s.speaker, start: +new Date(s.start), end: +new Date(s.end), text: s.text });
      }
    }
    return result;
  }

  function renderTranscript(container, meeting, { follow = false } = {}) {
    const items = blocks(meeting.segments);
    const started = +new Date(meeting.startedAt);
    if (!items.length) {
      container.innerHTML = `<p class="muted">${follow ? 'Listening… the transcript appears here a few seconds after people speak.' : 'No transcript.'}</p>`;
      return;
    }
    container.innerHTML = items.map((b) => `
      <div class="tr-row">
        <span class="tr-who ${b.speaker}">${b.speaker === 'me' ? 'Me' : 'Them'}</span>
        <span class="tr-time">${clock(b.start - started)}</span>
        <span class="tr-text">${escape(b.text)}</span>
      </div>`).join('');
    if (follow) container.scrollTop = container.scrollHeight;
  }

  const LANGUAGES = [
    ['auto', 'Auto-detect'], ['en', 'English'], ['fr', 'Français'], ['es', 'Español'], ['de', 'Deutsch'],
    ['it', 'Italiano'], ['nl', 'Nederlands'], ['pt', 'Português'],
  ];

  return { message, host, escape, markdown, toggleCheckbox, clock, renderTranscript, LANGUAGES };
})();
