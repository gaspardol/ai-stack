const $ = (id) => document.getElementById(id);
let meetings = [];
let selected = location.hash.slice(1) || null;
let current = null; // full meeting
let tab = 'notes';
let editing = false;
let liveId = null;
const qa = new Map(); // meetingId -> [{ q, a, error }]

async function loadList() {
  const [list, status] = await Promise.all([
    AIS.host({ type: 'meeting.list' }, 20000).catch((error) => ({ meetings: [], error })),
    AIS.message({ type: 'status' }).catch(() => ({})),
  ]);
  meetings = list.meetings || [];
  liveId = status.live?.meetingId || null;
  if (list.error) $('list').innerHTML = `<p class="small warn" style="padding:8px">${AIS.escape(list.error.message)}</p>`;
  else renderList();
  if (!selected && meetings.length) select(meetings[0].id);
  else if (selected) loadDetail();
  else renderDetail();
}

function renderList() {
  const query = $('search').value.trim().toLowerCase();
  const filtered = meetings.filter((m) => !query || m.title.toLowerCase().includes(query) || (m.preview || '').toLowerCase().includes(query));
  const groups = new Map();
  const today = new Date().toDateString();
  const yesterday = new Date(Date.now() - 86400000).toDateString();
  for (const m of filtered) {
    const day = new Date(m.startedAt).toDateString();
    const label = day === today ? 'Today' : day === yesterday ? 'Yesterday'
      : new Date(m.startedAt).toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long' });
    if (!groups.has(label)) groups.set(label, []);
    groups.get(label).push(m);
  }
  let html = '';
  for (const [label, items] of groups) {
    html += `<div class="group">${AIS.escape(label)}</div>`;
    for (const m of items) {
      const minutes = m.endedAt ? Math.max(1, Math.round((new Date(m.endedAt) - new Date(m.startedAt)) / 60000)) : null;
      const badge = m.id === liveId ? '<span class="dot red"></span>' : m.status === 'processing' ? '<span class="small">…</span>' : m.status === 'failed' ? '<span class="small">⚠︎</span>' : '';
      html += `<div class="item ${m.id === selected ? 'selected' : ''}" data-id="${m.id}">
        <div class="row"><span class="t grow">${AIS.escape(m.title)}</span>${badge}</div>
        <div class="small muted">${new Date(m.startedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}${minutes ? ` · ${minutes} min` : ''}${m.app ? ` · ${AIS.escape(m.app)}` : ''}</div>
      </div>`;
    }
  }
  $('list').innerHTML = html || '<p class="small muted" style="padding:8px">No meetings yet. Notes start automatically when you join a call.</p>';
}

function select(id) {
  selected = id;
  editing = false;
  history.replaceState(null, '', `#${id}`);
  renderList();
  loadDetail();
}

async function loadDetail() {
  if (!selected) { current = null; renderDetail(); return; }
  const reply = await AIS.host({ type: 'meeting.get', meetingId: selected }, 20000).catch(() => null);
  current = reply?.meeting || null;
  renderDetail();
}

function renderDetail() {
  const detail = $('detail');
  $('askBar').hidden = !current || current.id === liveId;
  if (!current) {
    detail.innerHTML = `<div class="empty"><div><img src="icons/icon128.png" width="64" alt=""><h2>Your meeting notes live here</h2>
      <p class="muted">AI Stack takes notes automatically when a call starts in Meet, Teams or Zoom.<br>Audio is transcribed on this computer, then Claude writes the notes.</p></div></div>`;
    return;
  }
  const m = current;
  const minutes = Math.max(1, Math.round(((m.endedAt ? new Date(m.endedAt) : new Date()) - new Date(m.startedAt)) / 60000));
  const meta = [new Date(m.startedAt).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }), `${minutes} min`, m.app].filter(Boolean).join(' · ');
  let body = '';
  if (m.id === liveId) {
    body = `<p><span class="dot red"></span> Recording now. <button class="link" id="openPad">Open the live notepad</button></p>
      <div class="section-title">Live transcript</div><div id="tr"></div>`;
  } else if (tab === 'notes') {
    if (m.status === 'processing') body = '<p class="muted">Claude is writing your notes…</p>';
    else if (editing) body = `<textarea id="editor">${AIS.escape(m.notes || '')}</textarea><div class="toolbar" style="margin-top:8px"><button class="btn" id="cancel">Cancel</button><button class="btn primary" id="save">Save</button></div>`;
    else {
      body = `<div class="toolbar">
          <button class="btn" id="copy">Copy</button><button class="btn" id="edit">Edit</button>
          <button class="btn" id="regen">Regenerate</button><button class="btn" id="file">Show file</button>
          <button class="btn" id="delete">Delete</button></div>`;
      if (m.status === 'failed') body += `<p class="warn">⚠︎ ${AIS.escape(m.error || 'Notes could not be generated.')}</p>`;
      body += `<div class="md" id="md">${m.notes ? AIS.markdown(m.notes) : '<p class="muted">No notes yet.</p>'}</div>`;
      for (const item of qa.get(m.id) || []) {
        body += `<div class="qa"><b>${AIS.escape(item.q)}</b><div class="md">${item.a ? AIS.markdown(item.a) : item.error ? `<p class="warn">${AIS.escape(item.error)}</p>` : '<p class="muted">Thinking…</p>'}</div></div>`;
      }
    }
  } else if (tab === 'transcript') {
    body = '<div id="tr"></div>';
  } else {
    body = `<p class="small muted">Notes you typed during the meeting. Regenerate the notes to fold edits in.</p><textarea id="mine">${AIS.escape(m.userNotes || '')}</textarea>`;
  }
  const tabs = m.id === liveId ? '' : `<div class="tabs">${[['notes', 'Notes'], ['transcript', 'Transcript'], ['mine', 'My notes']]
    .map(([id, label]) => `<button class="tab ${tab === id ? 'active' : ''}" data-tab="${id}">${label}</button>`).join('')}</div>`;
  detail.innerHTML = `<div class="wrap"><input id="mtitle" type="text" value="${AIS.escape(m.title)}"><div class="muted small" style="margin-top:4px">${AIS.escape(meta)}</div>${tabs}${body}</div>`;
  if ($('tr')) AIS.renderTranscript($('tr'), m, { follow: m.id === liveId });
  wireDetail(m);
}

function wireDetail(m) {
  $('detail').querySelectorAll('[data-tab]').forEach((b) => b.addEventListener('click', () => { tab = b.dataset.tab; editing = false; renderDetail(); }));
  let titleTimer;
  $('mtitle').addEventListener('input', (e) => {
    clearTimeout(titleTimer);
    titleTimer = setTimeout(async () => {
      const title = e.target.value.trim();
      if (!title) return;
      await AIS.host({ type: 'meeting.update', meetingId: m.id, title }).catch(() => {});
      const entry = meetings.find((x) => x.id === m.id);
      if (entry) { entry.title = title; renderList(); }
    }, 700);
  });
  $('openPad')?.addEventListener('click', () => AIS.message({ type: 'openNotepad' }));
  $('copy')?.addEventListener('click', () => navigator.clipboard.writeText(`# ${m.title}\n\n${m.notes || ''}`));
  $('edit')?.addEventListener('click', () => { editing = true; renderDetail(); });
  $('cancel')?.addEventListener('click', () => { editing = false; renderDetail(); });
  $('save')?.addEventListener('click', async () => {
    const notes = $('editor').value;
    await AIS.host({ type: 'meeting.update', meetingId: m.id, notes });
    current.notes = notes;
    editing = false;
    renderDetail();
  });
  $('regen')?.addEventListener('click', async () => {
    const { notesModel } = await chrome.storage.local.get('notesModel');
    await AIS.host({ type: 'meeting.regenerate', meetingId: m.id, model: notesModel || 'opus' });
    current.status = 'processing';
    renderDetail();
  });
  $('file')?.addEventListener('click', () => AIS.host({ type: 'open', what: 'file', meetingId: m.id }));
  $('delete')?.addEventListener('click', async () => {
    if (!confirm(`Delete “${m.title}”? The Markdown file in your notes folder is kept.`)) return;
    await AIS.host({ type: 'meeting.delete', meetingId: m.id });
    selected = null;
    current = null;
    loadList();
  });
  $('md')?.addEventListener('change', async (e) => {
    const line = e.target.dataset?.line;
    if (line == null) return;
    current.notes = AIS.toggleCheckbox(current.notes, Number(line));
    await AIS.host({ type: 'meeting.update', meetingId: m.id, notes: current.notes }).catch(() => {});
    renderDetail();
  });
  let mineTimer;
  $('mine')?.addEventListener('input', (e) => {
    clearTimeout(mineTimer);
    mineTimer = setTimeout(() => {
      current.userNotes = e.target.value;
      AIS.host({ type: 'meeting.update', meetingId: m.id, userNotes: e.target.value }).catch(() => {});
    }, 700);
  });
}

async function ask() {
  const question = $('question').value.trim();
  if (!question || !current) return;
  $('question').value = '';
  tab = 'notes';
  const id = current.id;
  const items = qa.get(id) || [];
  const item = { q: question };
  items.push(item);
  qa.set(id, items);
  renderDetail();
  try {
    item.a = (await AIS.host({ type: 'meeting.ask', meetingId: id, question }, 300000)).answer;
  } catch (error) {
    item.error = error.message;
  }
  if (current?.id === id) renderDetail();
}

$('askBtn').addEventListener('click', ask);
$('question').addEventListener('keydown', (e) => { if (e.key === 'Enter') ask(); });
$('search').addEventListener('input', renderList);
$('list').addEventListener('click', (e) => {
  const item = e.target.closest('.item');
  if (item) select(item.dataset.id);
});
$('folder').addEventListener('click', () => AIS.host({ type: 'open', what: 'folder' }));
$('startNow').addEventListener('click', async () => {
  try {
    const reply = await AIS.message({ type: 'start' });
    await loadList();
    if (reply.live?.meetingId) select(reply.live.meetingId);
  } catch (error) {
    alert(error.message);
  }
});

window.addEventListener('hashchange', () => {
  const id = location.hash.slice(1);
  if (id && id !== selected) select(id);
});

chrome.runtime.onMessage.addListener((message) => {
  if (message.type === 'meeting-changed') {
    loadList();
  } else if (message.type === 'segment' && current && message.meetingId === current.id) {
    current.segments.push(message.segment);
    if ($('tr')) AIS.renderTranscript($('tr'), current, { follow: true });
  } else if (message.type === 'status-changed') {
    loadList();
  }
});

loadList();
