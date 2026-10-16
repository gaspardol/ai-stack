// Relays microphone state from meeting-hook.js to the extension, and shows a small
// "taking notes" pill on the call page.
(() => {
  if (window.__aistackBridge) return;
  window.__aistackBridge = true;

  let active = false;
  const alive = () => { try { return Boolean(chrome.runtime?.id); } catch { return false; } };

  const send = () => {
    if (!alive()) return;
    chrome.runtime.sendMessage({ type: 'mic', active, url: location.href, title: document.title }, (reply) => {
      void chrome.runtime.lastError;
      if (reply?.ok && window === top) showPill(Boolean(reply.recording));
    });
  };

  window.addEventListener('message', (event) => {
    if (event.source !== window || event.data?.__aistack !== 'mic') return;
    const changed = event.data.active !== active;
    active = event.data.active;
    if (changed || active) send();
  });

  if (window !== top) return;

  let pill = null;
  function showPill(on) {
    if (!on) { pill?.remove(); pill = null; return; }
    if (pill?.isConnected) return;
    pill = document.createElement('aistack-pill');
    pill.style.cssText = 'all: initial; position: fixed; left: 16px; bottom: 16px; z-index: 2147483647;';
    const root = pill.attachShadow({ mode: 'closed' });
    root.innerHTML = `
      <style>
        .pill { display: flex; align-items: center; gap: 8px; background: rgba(28,28,30,.92); color: #fff; padding: 7px 12px;
          border-radius: 999px; font: 12px -apple-system, "Segoe UI", system-ui, sans-serif; box-shadow: 0 4px 16px rgba(0,0,0,.3); }
        .dot { width: 8px; height: 8px; border-radius: 50%; background: #e5484d; animation: p 1.6s ease-in-out infinite; }
        @keyframes p { 50% { opacity: .35; } }
        button { all: unset; cursor: pointer; color: #9ecbff; }
        button:hover { text-decoration: underline; }
      </style>
      <div class="pill"><span class="dot"></span><span>AI Stack is taking notes</span>
        <button class="open">Open notepad</button><button class="stop">Stop</button></div>`;
    root.querySelector('.open').addEventListener('click', () => chrome.runtime.sendMessage({ type: 'openNotepad' }, () => void chrome.runtime.lastError));
    root.querySelector('.stop').addEventListener('click', () => chrome.runtime.sendMessage({ type: 'stop' }, () => void chrome.runtime.lastError));
    document.documentElement.appendChild(pill);
  }

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type === 'recording') showPill(message.on);
  });
})();
