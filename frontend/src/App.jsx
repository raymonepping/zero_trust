import { useState, useEffect, useRef } from 'react';

// sessionStorage token store — survives Vite HMR module resets.
// Validates expiry on every read so stale tokens are never sent.
const getAuthHeaders = () => {
  const t = sessionStorage.getItem('access_token');
  if (!t) return {};
  try {
    const { exp } = JSON.parse(atob(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
    if (exp * 1000 < Date.now()) { sessionStorage.removeItem('access_token'); return {}; }
  } catch { return {}; }
  return { 'Authorization': `Bearer ${t}` };
};

const STATUS = {
  loading: { label: 'Checking', tone: 'loading', icon: '...' },
  connected: { label: 'Connected', tone: 'connected', icon: 'OK' },
  error: { label: 'Disconnected', tone: 'error', icon: '!!' },
};

const SUGGESTIONS = [
  'What did Raymon order?',
  'What are the tech interests of all users?',
  'Which user spent the most money?',
  'Who has the highest security clearance?',
];

const ORDER_STATUSES = ['processing', 'shipped', 'delivered', 'cancelled'];

// Maps source → visual metadata
const VAULT_SOURCE_META = {
  'static-config':         { label: 'Hardcoded',         badge: 'STATIC',          cls: 'vault-badge-static' },
  'env-file':              { label: 'Env Variables',     badge: 'ENV',             cls: 'vault-badge-env' },
  'vault-kv':              { label: 'Static KV',         badge: 'KV v2',           cls: 'vault-badge-kv' },
  'vault-dynamic':         { label: 'Dynamic',           badge: 'DYNAMIC',         cls: 'vault-badge-dynamic' },
  'vault-approle':         { label: 'AppRole / KV',      badge: 'APPROLE',         cls: 'vault-badge-approle' },
  'vault-approle-dynamic': { label: 'AppRole / Dynamic', badge: 'APPROLE+DYN',     cls: 'vault-badge-approle-dynamic' },
  'vault-jwt-dynamic':     { label: 'JWT / Dynamic',     badge: 'JWT+ROTATION',    cls: 'vault-badge-jwt' },
};

// Classification level config
const CLASSIFICATIONS = [
  { key: 'public',       label: 'Public',       color: '#34d399', minLevel: 0 },
  { key: 'internal',     label: 'Internal',     color: '#f6c64f', minLevel: 1 },
  { key: 'confidential', label: 'Confidential', color: '#ff8c32', minLevel: 2 },
  { key: 'restricted',   label: 'Restricted',   color: '#f87171', minLevel: 3 },
];

export default function App() {
  const [db, setDb] = useState('loading');
  const [vault, setVault] = useState({
    status: 'loading', source: null, path: null, username: null,
    trust_level: null, allowed_classifications: [], capabilities: {},
  });
  const [question, setQuestion] = useState('');
  const [answer, setAnswer] = useState('');
  const [lastQuestion, setLastQuestion] = useState('');
  const [asking, setAsking] = useState(false);
  const [askError, setAskError] = useState('');
  const [copyState, setCopyState] = useState('idle');
  const answerRef = useRef(null);

  // Auth state
  const [token, setToken] = useState(() => sessionStorage.getItem('access_token') || '');
  const [loginUser, setLoginUser] = useState(() => sessionStorage.getItem('login_user') || '');
  const [loginForm, setLoginForm] = useState({ username: '', password: '' });
  const [loginError, setLoginError] = useState('');
  const [loggingIn, setLoggingIn] = useState(false);
  const refreshTimerRef = useRef(null);
  const storedCredsRef = useRef({ username: '', password: '' });

  // CIBA write flow
  const [cibaForm, setCibaForm] = useState({ orderId: '1', newStatus: 'shipped' });
  const [cibaSession, setCibaSession] = useState(null);
  const [cibaPending, setCibaPending] = useState(null);
  const [cibaMessage, setCibaMessage] = useState('Request write access for one order status change.');
  const [cibaError, setCibaError] = useState('');
  const [cibaBusy, setCibaBusy] = useState(false);

  const applyToken = (access_token, expires_in, username, password) => {
    sessionStorage.setItem('access_token', access_token);
    sessionStorage.setItem('login_user', username);
    setToken(access_token);
    storedCredsRef.current = { username, password };

    // Auto-refresh at 80% of TTL
    if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
    const refreshMs = Math.floor(expires_in * 0.8) * 1000;
    refreshTimerRef.current = setTimeout(async () => {
      try {
        const res = await fetch('/api/auth/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(storedCredsRef.current),
        });
        const data = await res.json();
        if (res.ok) applyToken(data.access_token, data.expires_in, username, password);
        else setToken(''); // force re-login if refresh fails
      } catch {
        setToken('');
      }
    }, refreshMs);
  };

  const login = async (e) => {
    e.preventDefault();
    setLoggingIn(true);
    setLoginError('');
    try {
      const res = await fetch('/api/auth/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(loginForm),
      });
      const data = await res.json();
      if (!res.ok) { setLoginError(data.error || 'Login failed'); return; }
      applyToken(data.access_token, data.expires_in, loginForm.username, loginForm.password);
      setLoginUser(loginForm.username);
      setLoginForm({ username: '', password: '' });
    } catch {
      setLoginError('Identity provider unreachable');
    } finally {
      setLoggingIn(false);
    }
  };

  const logout = () => {
    sessionStorage.removeItem('access_token');
    setToken('');
    setLoginUser('');
    storedCredsRef.current = { username: '', password: '' };
    if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
    sessionStorage.removeItem('login_user');
  };

  useEffect(() => {
    const check = async () => {
      try {
        const res = await fetch('/api/health', { headers: getAuthHeaders() });
        const data = await res.json();
        // Update vault connectivity from health probe (independent of credentials)
        if (data.vault && !data.vault.ok) {
          setVault((v) => ({
            ...v,
            status: 'error',
            vaultHealth: data.vault.status,
          }));
        }
        if (data.db === 'connected') {
          setDb('connected');
        } else {
          // Health probe can misreport in legacy connector modes — verify with a real query
          try {
            const fallback = await fetch('/api/users', { headers: getAuthHeaders() });
            const rows = await fallback.json();
            setDb(Array.isArray(rows) ? 'connected' : 'error');
          } catch {
            setDb('error');
          }
        }
      } catch {
        setDb('error');
      }
    };
    check();
    const interval = setInterval(check, 10000);
    return () => clearInterval(interval);
  }, []);

  useEffect(() => {
    const check = async () => {
      try {
        const res = await fetch('/api/credentials', { headers: getAuthHeaders() });
        const data = await res.json();
        if (res.ok && data.username) {
          setVault({
            status: 'ok',
            source: data.source,
            path: data.path,
            username: data.username,
            trust_level: data.trust_level ?? 0,
            allowed_classifications: data.allowed_classifications ?? ['public'],
            capabilities: data.capabilities ?? {},
          });
        } else {
          setVault({ status: 'error', source: null, path: null, username: null, trust_level: null, allowed_classifications: [], capabilities: {} });
        }
      } catch {
        setVault({ status: 'error', source: null, path: null, username: null, trust_level: null, allowed_classifications: [], capabilities: {} });
      }
    };
    check();
    const interval = setInterval(check, 15000);
    return () => clearInterval(interval);
  }, []);

  useEffect(() => {
    if (answerRef.current) {
      answerRef.current.scrollTop = answerRef.current.scrollHeight;
    }
  }, [answer]);

  const fetchCibaPending = async () => {
    const res = await fetch('/api/ciba/pending', { headers: getAuthHeaders() });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Could not load pending CIBA requests');
    if (!Array.isArray(data)) throw new Error('Pending CIBA response was not a list');
    const match = cibaSession?.action
      ? data.find((request) => request.bindingMessage === cibaSession.action)
      : data[0];
    setCibaPending(match || null);
    return match || null;
  };

  const executeCibaWrite = async (session) => {
    const res = await fetch(`/api/ciba/orders/${session.orderId}/status`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
      body: JSON.stringify({ newStatus: session.newStatus, cibaSessionId: session.sessionId }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'CIBA write failed');
    setCibaSession((current) => current ? { ...current, status: 'executed' } : current);
    setCibaMessage(data.message || `Order ${session.orderId} updated to ${session.newStatus}.`);
  };

  useEffect(() => {
    if (!token || !vault.capabilities?.ciba_write || cibaSession?.status !== 'polling') return undefined;

    const checkStatus = async () => {
      try {
        const res = await fetch(`/api/ciba/status/${cibaSession.sessionId}`, { headers: getAuthHeaders() });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || 'Could not check CIBA status');
        setCibaSession((current) => current ? { ...current, status: data.status } : current);
        if (data.status === 'approved') {
          await executeCibaWrite({ ...cibaSession, status: data.status });
        } else if (data.status === 'denied' || data.status === 'expired') {
          setCibaMessage(`CIBA request ${data.status}.`);
        }
      } catch (err) {
        setCibaError(err.message);
      }
    };

    const interval = setInterval(checkStatus, 3000);
    return () => clearInterval(interval);
  }, [token, vault.capabilities?.ciba_write, cibaSession]);

  useEffect(() => {
    if (!token || !vault.capabilities?.ciba_write || !cibaSession || cibaSession.status !== 'polling') return undefined;

    fetchCibaPending().catch(() => {});
    const interval = setInterval(() => {
      fetchCibaPending().catch(() => {});
    }, 2500);
    return () => clearInterval(interval);
  }, [token, vault.capabilities?.ciba_write, cibaSession]);

  const requestCibaWrite = async () => {
    if (cibaBusy) return;
    setCibaBusy(true);
    setCibaError('');
    setCibaPending(null);

    try {
      const orderId = Number.parseInt(cibaForm.orderId, 10);
      if (!Number.isInteger(orderId) || orderId < 1) {
        throw new Error('Use a valid order id.');
      }

      const res = await fetch('/api/ciba/initiate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
        body: JSON.stringify({ orderId, newStatus: cibaForm.newStatus }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Could not start CIBA flow');

      setCibaSession({
        sessionId: data.sessionId,
        action: data.action,
        orderId,
        newStatus: cibaForm.newStatus,
        status: 'polling',
      });
      setCibaMessage(`Write request created for order ${orderId}. Authorize it to continue.`);
    } catch (err) {
      setCibaError(err.message);
    } finally {
      setCibaBusy(false);
    }
  };

  const authorizeCibaWrite = async () => {
    if (cibaBusy || !cibaSession) return;
    setCibaBusy(true);
    setCibaError('');

    try {
      const pending = cibaPending || await fetchCibaPending();
      if (!pending) throw new Error('No matching authorization request is pending yet.');

      const res = await fetch('/api/ciba/approve', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
        body: JSON.stringify({ requestId: pending.id, decision: 'SUCCEED' }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Authorization failed');

      setCibaPending(null);
      setCibaMessage('Authorization sent. Waiting for write credential approval.');
    } catch (err) {
      setCibaError(err.message);
    } finally {
      setCibaBusy(false);
    }
  };

  const ask = async () => {
    if (!question.trim() || asking) return;
    const nextQuestion = question.trim();
    setAsking(true);
    setAskError('');
    setAnswer('');
    setCopyState('idle');
    setLastQuestion(nextQuestion);

    try {
      const res = await fetch('/api/ask', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
        body: JSON.stringify({ question: nextQuestion }),
      });

      if (!res.ok) {
        setAskError('The backend did not return a valid response. Retry after checking the API container.');
        return;
      }

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let streamed = '';

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        streamed += decoder.decode(value, { stream: true });
        setAnswer(streamed);
      }
    } catch {
      setAskError('The request failed before the answer stream completed.');
    } finally {
      setAsking(false);
    }
  };

  const handleKey = (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      ask();
    }
  };

  const copyAnswer = async () => {
    if (!answer) return;
    try {
      await navigator.clipboard.writeText(answer);
      setCopyState('copied');
      setTimeout(() => setCopyState('idle'), 1800);
    } catch {
      setCopyState('error');
      setTimeout(() => setCopyState('idle'), 2200);
    }
  };

  const clearAnswer = () => {
    setAnswer('');
    setLastQuestion('');
    setAskError('');
    setCopyState('idle');
  };

  const { label, tone, icon } = STATUS[db];
  const vaultTone = vault.status === 'ok' ? 'vault' : vault.status === 'loading' ? 'loading' : 'error';
  const baseSourceMeta = VAULT_SOURCE_META[vault.source] || { label: vault.source || 'Unknown', badge: null, cls: '' };
  const sourceMeta = vault.capabilities?.ciba_write && vault.source === 'vault-jwt-dynamic'
    ? { ...baseSourceMeta, badge: 'JWT+CIBA' }
    : baseSourceMeta;
  const vaultDownMsg = vault.vaultHealth
    ? (vault.vaultHealth === 'sealed' ? 'Sealed' : 'Unreachable')
    : 'Unreachable';
  const vaultLabel = vault.status === 'ok' ? sourceMeta.label : vault.status === 'loading' ? 'Checking' : vaultDownMsg;
  const vaultBadge = vault.status === 'ok' && sourceMeta.badge
    ? { label: sourceMeta.badge, cls: sourceMeta.cls }
    : null;
  const hasAnswer = Boolean(answer);

  const trustLevel = vault.trust_level ?? -1;
  const allowedSet = new Set(vault.allowed_classifications || []);
  const unlockedCount = CLASSIFICATIONS.filter(({ key }) => allowedSet.has(key)).length;
  const accessProgress = `${Math.round((unlockedCount / CLASSIFICATIONS.length) * 100)}%`;
  const nextLocked = CLASSIFICATIONS.find(({ key }) => !allowedSet.has(key));
  const cibaEnabled = vault.capabilities?.ciba_write === true;
  const cibaCanAuthorize = Boolean(cibaSession && cibaSession.status === 'polling' && cibaPending);
  const cibaStatus = cibaSession?.status || (cibaEnabled ? 'ready' : 'disabled');

  return (
    <div className="app">
      {/* Login bar */}
      <div className="login-bar">
        {token ? (
          <div className="login-bar-inner">
            <span className="login-user">Signed in as <strong>{loginUser}</strong></span>
            <button className="login-bar-btn" onClick={logout}>Sign out</button>
          </div>
        ) : (
          <form className="login-bar-inner" onSubmit={login}>
            <input
              className="login-input"
              type="text"
              placeholder="Username"
              value={loginForm.username}
              onChange={(e) => setLoginForm((f) => ({ ...f, username: e.target.value }))}
              disabled={loggingIn}
              autoComplete="username"
            />
            <input
              className="login-input"
              type="password"
              placeholder="Password"
              value={loginForm.password}
              onChange={(e) => setLoginForm((f) => ({ ...f, password: e.target.value }))}
              disabled={loggingIn}
              autoComplete="current-password"
            />
            <button className="login-bar-btn" type="submit" disabled={loggingIn || !loginForm.username || !loginForm.password}>
              {loggingIn ? 'Signing in…' : 'Sign in'}
            </button>
            {loginError && <span className="login-error">{loginError}</span>}
          </form>
        )}
      </div>

      <div className="layout">
        <section className="hero card">
          <div className="eyebrow">Zero Trust Workshop</div>
          <div className="hero-head">
            <div>
              <h1>Interrogate workshop data without leaving the trust boundary.</h1>
              <p className="hero-copy">
                Query users, orders, and preferences while tracking the live health of PostgreSQL and Vault.
                Data visibility changes automatically as you progress through the connector phases.
              </p>
              {token && (
                <div className="ciba-panel" aria-label="CIBA write authorization">
                  <div className="ciba-panel-head">
                    <div>
                      <div className="ciba-kicker">Delegated write</div>
                      <div className="ciba-title">Authorize an order status change</div>
                    </div>
                    <span className={`ciba-status ciba-status-${cibaStatus}`}>{cibaStatus}</span>
                  </div>
                  <div className="ciba-controls">
                    <label className="ciba-field">
                      <span>Order</span>
                      <input
                        type="number"
                        min="1"
                        value={cibaForm.orderId}
                        onChange={(e) => setCibaForm((form) => ({ ...form, orderId: e.target.value }))}
                        disabled={cibaBusy || !cibaEnabled}
                      />
                    </label>
                    <label className="ciba-field">
                      <span>Status</span>
                      <select
                        value={cibaForm.newStatus}
                        onChange={(e) => setCibaForm((form) => ({ ...form, newStatus: e.target.value }))}
                        disabled={cibaBusy || !cibaEnabled}
                      >
                        {ORDER_STATUSES.map((status) => (
                          <option key={status} value={status}>{status}</option>
                        ))}
                      </select>
                    </label>
                    <button
                      className="ciba-btn ciba-request-btn"
                      type="button"
                      onClick={requestCibaWrite}
                      disabled={cibaBusy || !cibaEnabled}
                    >
                      Request write
                    </button>
                    <button
                      className="ciba-btn ciba-authorize-btn"
                      type="button"
                      onClick={authorizeCibaWrite}
                      disabled={cibaBusy || !cibaCanAuthorize}
                    >
                      Authorize
                    </button>
                  </div>
                  <div className={cibaError ? 'ciba-message ciba-message-error' : 'ciba-message'}>
                    {cibaError || (cibaEnabled ? cibaMessage : 'Switch to the CIBA connector to enable delegated writes.')}
                  </div>
                </div>
              )}
            </div>
            <div className="status-panel" aria-label="System status">
              <div className="status-panel-title">System readiness</div>
              <div className="status-stack">
                <div className="status-row">
                  <span className="status-label">PostgreSQL</span>
                  <div className={`indicator indicator-${tone}`}>
                    <span className="indicator-icon" aria-hidden="true">{icon}</span>
                    <span className="indicator-label">{label}</span>
                  </div>
                </div>
                <div className="status-row">
                  <span className="status-label">Vault</span>
                  <div className={`indicator indicator-${vaultTone}`}>
                    <span className="indicator-icon" aria-hidden="true">{vault.status === 'ok' ? 'VT' : vault.status === 'loading' ? '...' : '!!'}</span>
                    <div className="vault-detail">
                      <div className="vault-label-row">
                        <span className="indicator-label">{vaultLabel}</span>
                        {vaultBadge && (
                          <span className={`vault-badge ${vaultBadge.cls}`}>{vaultBadge.label}</span>
                        )}
                      </div>
                      {vault.username && (
                        <span className="vault-meta">{vault.path} · {vault.username}</span>
                      )}
                    </div>
                  </div>
                </div>
              </div>

              {/* Classification access panel */}
              {vault.status !== 'loading' && (
                <div className="trust-panel">
                  <div className="trust-panel-title">
                    Data access
                    {trustLevel >= 0 && (
                      <span className="trust-level-badge">Level {trustLevel}</span>
                    )}
                  </div>
                  <div className="trust-summary">
                    <span>{unlockedCount} of {CLASSIFICATIONS.length} classifications visible</span>
                    {nextLocked && (
                      <span className="trust-next">Next: {nextLocked.label}</span>
                    )}
                  </div>
                  <div className="trust-meter" aria-hidden="true">
                    <span style={{ width: accessProgress }} />
                  </div>
                  <div className="classification-grid">
                    {CLASSIFICATIONS.map(({ key, label: clsLabel, color, minLevel }) => {
                      const active = allowedSet.has(key);
                      return (
                        <div
                          key={key}
                          className={`classification-pill ${active ? 'classification-active' : 'classification-locked'}`}
                          style={active ? { '--cls-color': color } : {}}
                          title={active ? `${clsLabel} data is visible` : `${clsLabel} data requires trust level ${minLevel}`}
                        >
                          <span className="classification-dot" />
                          <span className="classification-label">{clsLabel}</span>
                          <span className="classification-state">{active ? 'visible' : 'locked'}</span>
                        </div>
                      );
                    })}
                  </div>
                </div>
              )}
            </div>
          </div>

          <div className="qa-shell">
            <div className="qa-header">
              <div>
                <h2>Ask about your data</h2>
                <p className="section-copy">
                  Use a prompt below or write a custom question.
                  {trustLevel >= 0 && trustLevel < 3 && (
                    <span className="trust-hint"> Switch to a higher-trust connector to unlock more data.</span>
                  )}
                </p>
              </div>
              <div className="composer-tip">Enter to send. Shift+Enter for a new line.</div>
            </div>

            <div className="suggestions" aria-label="Suggested prompts">
              {SUGGESTIONS.map((s) => (
                <button
                  key={s}
                  className="chip"
                  onClick={() => setQuestion(s)}
                  disabled={asking}
                >
                  {s}
                </button>
              ))}
            </div>

            <div className="input-row">
              <label className="input-group">
                <span className="input-label">Question</span>
                <textarea
                  className="qa-input"
                  rows={3}
                  placeholder="Ask a question about users, orders, or preferences..."
                  value={question}
                  onChange={(e) => setQuestion(e.target.value)}
                  onKeyDown={handleKey}
                  disabled={asking}
                />
              </label>
              <button className="ask-btn" onClick={ask} disabled={asking || !question.trim()}>
                <span className={`spinner ${asking ? 'spinner-visible' : ''}`} aria-hidden="true" />
                <span>{asking ? 'Streaming' : 'Ask'}</span>
              </button>
            </div>

            <div className="answer-section">
              <div className="answer-header">
                <div>
                  <div className="answer-kicker">Latest response</div>
                  <div className="answer-title">{lastQuestion || 'Ready for your first prompt'}</div>
                </div>
                <div className="answer-tools">
                  <div className={`answer-state ${askError ? 'answer-state-error' : asking ? 'answer-state-streaming' : hasAnswer ? 'answer-state-ready' : 'answer-state-idle'}`}>
                    {askError ? 'Retry available' : asking ? 'Streaming now' : hasAnswer ? 'Response captured' : 'Waiting'}
                  </div>
                  {(hasAnswer || askError) && (
                    <div className="answer-actions">
                      {hasAnswer && (
                        <button className="answer-action-btn" type="button" onClick={copyAnswer}>
                          {copyState === 'copied' ? 'Copied' : copyState === 'error' ? 'Copy failed' : 'Copy'}
                        </button>
                      )}
                      <button className="answer-action-btn" type="button" onClick={clearAnswer}>
                        Clear
                      </button>
                    </div>
                  )}
                </div>
              </div>

              {!hasAnswer && !asking && !askError && (
                <div className="answer-empty">
                  <p>No answer yet. Start with a suggested prompt or ask about spending, preferences, or user activity.</p>
                </div>
              )}

              {(hasAnswer || asking) && (
                <div className="answer-box" ref={answerRef} aria-live="polite">
                  {answer || <span className="thinking">Thinking...</span>}
                  {asking && answer && <span className="cursor" />}
                </div>
              )}

              {askError && (
                <div className="answer-error" role="alert">
                  <span>{askError}</span>
                  <button className="retry-btn" onClick={ask} disabled={asking || !question.trim()}>
                    Retry
                  </button>
                </div>
              )}
            </div>
          </div>
        </section>
      </div>
    </div>
  );
}
