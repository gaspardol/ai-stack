const $ = (id) => document.getElementById(id);
let meeting = null; // live meeting (full)
let saveTimer = null;
let titleTimer = null;

async function load() {
  let state;
  try {
    state = await AIS.message({ type: 'status' });
  } catch {
    return;
  }
  if (state.live) {
    const reply = await AIS.host({ type: 'meeting.get', meetingId: state.live.meetingId }, 15000).catch(() => null);
    meeting = reply?.meeting || null;
  } else {
    meeting = null;
  }
  render();
}

function render() {
  $('liveView').hidden = !meeting;
  $('idleView').hidden = Boolean(meeting);
  if (meeting) {
    if (document.activeElement !== $('title')) $('title').value = meeting.title;
    if (document.activeElement !== $('notes')) $('notes').value = meeting.userNotes || '';
    AIS.renderTranscript($('transcript'), meeting, { follow: true });
  } else {
    loadRecent();
  }
}

async function loadRecent() {
  const reply = await AIS.host({ type: 'meeting.list' }, 15000).catch(() => null);
  const list = (reply?.meetings || []).slice(0, 6);
  $('recent').innerHTML = list.length
    ? list.map((m) => `<a href="#" data-id="${m.id}">${AIS.escape(m.title)}<div class="small muted">${new Date(m.startedAt).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' })}${m.status === 'processing' ? ' · writing notes…' : ''}</div></a>`).join('')
    : '<p class="small muted">None yet.</p>';
}

$('recent').addEventListener('click', (e) => {
  const link = e.target.closest('a[data-id]');
  if (!link) return;
  e.preventDefault();
  AIS.message({ type: 'openNotes', meetingId: link.dataset.id });
});

$('notes').addEventListener('input', () => {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    if (meeting) AIS.host({ type: 'meeting.update', meetingId: meeting.id, userNotes: $('notes').value }).catch(() => {});
  }, 800);
});

$('title').addEventListener('input', () => {
  clearTimeout(titleTimer);
  titleTimer = setTimeout(() => {
    if (meeting && $('title').value.trim()) AIS.host({ type: 'meeting.update', meetingId: meeting.id, title: $('title').value.trim() }).catch(() => {});
  }, 800);
});

$('stop').addEventListener('click', async () => {
  if (meeting) await AIS.host({ type: 'meeting.update', meetingId: meeting.id, userNotes: $('notes').value }).catch(() => {});
  await AIS.message({ type: 'stop' }).catch(() => {});
  $('ready').textContent = 'Claude is writing your notes…';
  load();
});

$('start').addEventListener('click', async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  await AIS.message({ type: 'start', tabId: tab?.id }).catch((error) => { $('ready').textContent = error.message; });
  load();
});

$('library').addEventListener('click', () => AIS.message({ type: 'openNotes' }));

chrome.runtime.onMessage.addListener((message) => {
  if (message.type === 'segment' && meeting && message.meetingId === meeting.id) {
    meeting.segments.push(message.segment);
    AIS.renderTranscript($('transcript'), meeting, { follow: true });
  } else if (message.type === 'status-changed') {
    load();
  } else if (message.type === 'meeting-changed' && !meeting) {
    const m = message.meeting;
    if (m.status === 'ready') {
      $('ready').innerHTML = `Notes ready: <button class="link" data-open="${m.id}">${AIS.escape(m.title)}</button>`;
    }
    loadRecent();
  }
});

$('ready').addEventListener('click', (e) => {
  const id = e.target.dataset?.open;
  if (id) AIS.message({ type: 'openNotes', meetingId: id });
});

setInterval(() => {
  if (meeting) $('timer').textContent = AIS.clock(Date.now() - new Date(meeting.startedAt));
}, 1000);

load();
