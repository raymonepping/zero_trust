import { useState, useEffect, useRef } from 'react';

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
    trust_level: null, allowed_classifications: [],
  });
  const [question, setQuestion] = useState('');
  const [answer, setAnswer] = useState('');
  const [lastQuestion, setLastQuestion] = useState('');
  const [asking, setAsking] = useState(false);
  const [askError, setAskError] = useState('');
  const answerRef = useRef(null);

  useEffect(() => {
    const check = async () => {
      try {
        const res = await fetch('/api/health');
        const data = await res.json();
        setDb(data.db === 'connected' ? 'connected' : 'error');
        // Update vault connectivity from health probe (independent of credentials)
        if (data.vault && !data.vault.ok) {
          setVault((v) => ({
            ...v,
            status: 'error',
            vaultHealth: data.vault.status,
          }));
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
        const res = await fetch('/api/credentials');
        const data = await res.json();
        if (res.ok && data.username) {
          setVault({
            status: 'ok',
            source: data.source,
            path: data.path,
            username: data.username,
            trust_level: data.trust_level ?? 0,
            allowed_classifications: data.allowed_classifications ?? ['public'],
          });
        } else {
          setVault({ status: 'error', source: null, path: null, username: null, trust_level: null, allowed_classifications: [] });
        }
      } catch {
        setVault({ status: 'error', source: null, path: null, username: null, trust_level: null, allowed_classifications: [] });
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

  const ask = async () => {
    if (!question.trim() || asking) return;
    const nextQuestion = question.trim();
    setAsking(true);
    setAskError('');
    setLastQuestion(nextQuestion);

    try {
      const res = await fetch('/api/ask', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
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

  const { label, tone, icon } = STATUS[db];
  const vaultTone = vault.status === 'ok' ? 'vault' : vault.status === 'loading' ? 'loading' : 'error';
  const sourceMeta = VAULT_SOURCE_META[vault.source] || { label: vault.source || 'Unknown', badge: null, cls: '' };
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

  return (
    <div className="app">
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
                <div className={`answer-state ${askError ? 'answer-state-error' : asking ? 'answer-state-streaming' : hasAnswer ? 'answer-state-ready' : 'answer-state-idle'}`}>
                  {askError ? 'Retry available' : asking ? 'Streaming now' : hasAnswer ? 'Response captured' : 'Waiting'}
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
