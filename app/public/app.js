'use strict';

/**
 * ContainerOps Dashboard - frontend logic (vanilla JavaScript).
 * Calls: GET /api/info, GET /healthz, GET /readyz, GET /api/instances
 */
(function () {
  const REQUEST_TIMEOUT_MS = 5000;

  const $ = (id) => document.getElementById(id);

  const els = {
    grid: $('metrics-grid'),
    refreshBtn: $('refresh-btn'),
    errorBanner: $('error-banner'),
    overall: $('overall-health'),
    overallText: $('overall-health-text'),
    hostname: $('m-hostname'),
    containerId: $('m-container-id'),
    node: $('m-node'),
    platform: $('m-platform'),
    uptime: $('m-uptime'),
    started: $('m-started'),
    timestamp: $('m-timestamp'),
    requests: $('m-requests'),
    probes: $('m-probes'),
    health: $('m-health'),
    ready: $('m-ready'),
    lastUpdated: $('last-updated'),
    sampleBtn: $('sample-btn'),
    sampleCount: $('sample-count'),
    sampleResults: $('sample-results'),
  };

  /** fetch() with a timeout; resolves to { ok, status, data } and never throws on HTTP errors. */
  async function getJson(url) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    try {
      const res = await fetch(url, {
        cache: 'no-store',
        headers: { Accept: 'application/json' },
        signal: controller.signal,
      });
      let data = null;
      try {
        data = await res.json();
      } catch {
        data = null;
      }
      return { ok: res.ok, status: res.status, data };
    } catch (err) {
      const reason = err && err.name === 'AbortError' ? 'request timed out' : 'network error';
      return { ok: false, status: 0, data: null, error: reason };
    } finally {
      clearTimeout(timer);
    }
  }

  function formatUptime(totalSeconds) {
    const s = Math.max(0, Math.floor(Number(totalSeconds) || 0));
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    const parts = [];
    if (d) parts.push(`${d}d`);
    if (d || h) parts.push(`${h}h`);
    if (d || h || m) parts.push(`${m}m`);
    parts.push(`${sec}s`);
    return parts.join(' ');
  }

  function setText(el, value) {
    el.textContent = value === null || value === undefined || value === '' ? '—' : String(value);
    el.removeAttribute('data-loading');
  }

  function setStatus(el, label, level) {
    setText(el, label);
    el.classList.remove('status-ok', 'status-warn', 'status-bad');
    el.classList.add(`status-${level}`);
  }

  function setOverall(level, text) {
    els.overall.classList.remove('health-unknown', 'health-ok', 'health-warn', 'health-bad');
    els.overall.classList.add(`health-${level}`);
    els.overallText.textContent = text;
  }

  function showError(message) {
    if (!message) {
      els.errorBanner.hidden = true;
      els.errorBanner.textContent = '';
      return;
    }
    els.errorBanner.textContent = message;
    els.errorBanner.hidden = false;
  }

  function setBusy(button, busy) {
    button.disabled = busy;
    button.setAttribute('aria-busy', String(busy));
  }

  async function refresh() {
    setBusy(els.refreshBtn, true);
    els.grid.setAttribute('aria-busy', 'true');

    const [info, health, ready] = await Promise.all([
      getJson('/api/info'),
      getJson('/healthz'),
      getJson('/readyz'),
    ]);

    const problems = [];

    if (info.ok && info.data) {
      const d = info.data;
      setText(els.hostname, d.hostname);
      setText(els.containerId, d.containerId || 'n/a (custom hostname)');
      setText(els.node, d.nodeVersion);
      setText(els.uptime, formatUptime(d.uptimeSeconds));
      els.started.textContent = d.startedAt ? `Started ${new Date(d.startedAt).toLocaleString()}` : '';
      setText(els.timestamp, d.timestamp);
      setText(els.requests, Number(d.requestCount).toLocaleString());
      els.probes.textContent = `+ ${Number(d.probeCount).toLocaleString()} health/readiness probes`;
    } else {
      problems.push(`/api/info failed (${info.error || `HTTP ${info.status}`})`);
      [els.hostname, els.containerId, els.node, els.uptime, els.timestamp, els.requests].forEach((el) =>
        setText(el, 'unavailable'),
      );
    }

    // /api/instances supplies platform details for the Node.js card.
    const inst = await getJson('/api/instances');
    if (inst.ok && inst.data && inst.data.instance) {
      els.platform.textContent = `${inst.data.instance.platform} · uid ${inst.data.instance.uid}`;
    }

    if (health.ok && health.data && health.data.status === 'healthy') {
      setStatus(els.health, 'Healthy', 'ok');
    } else {
      setStatus(els.health, health.status ? `Unhealthy (${health.status})` : 'Unreachable', 'bad');
      problems.push(`/healthz failed (${health.error || `HTTP ${health.status}`})`);
    }

    if (ready.ok) {
      setStatus(els.ready, 'Ready', 'ok');
    } else if (ready.status === 503) {
      setStatus(els.ready, 'Not ready (503)', 'warn');
    } else {
      setStatus(els.ready, 'Unreachable', 'bad');
      problems.push(`/readyz failed (${ready.error || `HTTP ${ready.status}`})`);
    }

    // Note: the three calls above may be answered by different replicas.
    if (problems.length === 0 && ready.ok) {
      setOverall('ok', 'All systems operational');
    } else if (info.ok || health.ok) {
      setOverall('warn', 'Degraded');
    } else {
      setOverall('bad', 'Service unavailable');
    }

    showError(problems.length ? `Some API calls failed: ${problems.join('; ')}.` : '');
    els.lastUpdated.textContent = `Last updated ${new Date().toLocaleTimeString()} · each request may be served by a different replica.`;
    els.grid.setAttribute('aria-busy', 'false');
    setBusy(els.refreshBtn, false);
  }

  function renderSamples(counts, total, failures) {
    els.sampleResults.replaceChildren();
    const entries = Object.entries(counts).sort((a, b) => b[1] - a[1]);

    const summary = document.createElement('p');
    summary.className = 'muted';
    summary.textContent =
      `${entries.length} distinct replica(s) answered ${total - failures} of ${total} requests` +
      (failures ? ` (${failures} failed).` : '.');
    els.sampleResults.appendChild(summary);

    for (const [host, count] of entries) {
      const row = document.createElement('div');
      row.className = 'sample-row';

      const name = document.createElement('span');
      name.className = 'mono';
      name.textContent = host;

      const bar = document.createElement('div');
      bar.className = 'bar';
      const fill = document.createElement('span');
      fill.style.width = `${Math.round((count / total) * 100)}%`;
      bar.appendChild(fill);

      const num = document.createElement('span');
      num.textContent = String(count);

      row.append(name, bar, num);
      els.sampleResults.appendChild(row);
    }
  }

  async function sample() {
    const total = Number.parseInt(els.sampleCount.value, 10) || 15;
    setBusy(els.sampleBtn, true);
    const counts = {};
    let failures = 0;

    // Sequential requests make round-robin distribution easy to observe.
    for (let i = 0; i < total; i += 1) {
      const res = await getJson('/api/instances');
      if (res.ok && res.data && res.data.instance) {
        const host = res.data.instance.hostname;
        counts[host] = (counts[host] || 0) + 1;
      } else {
        failures += 1;
      }
    }

    renderSamples(counts, total, failures);
    setBusy(els.sampleBtn, false);
  }

  els.refreshBtn.addEventListener('click', refresh);
  els.sampleBtn.addEventListener('click', sample);
  refresh();
})();
