import { useState, useEffect, useRef } from 'react';

const STATUS = {
  loading: { label: 'Checking...', color: '#f59e0b' },
  connected: { label: 'Connected', color: '#22c55e' },
  error: { label: 'Disconnected', color: '#ef4444' },
};

const SUGGESTIONS = [
  'What did Raymon order?',
  'What are the likings of Cojan?',
  'Compare the tech interests of Raymon and Cojan.',
  'Which user spent the most money?',
];

export default function App() {
  const [db, setDb] = useState('loading');
  const [question, setQuestion] = useState('');
  const [answer, setAnswer] = useState('');
  const [asking, setAsking] = useState(false);
  const answerRef = useRef(null);

  useEffect(() => {
    const check = async () => {
      try {
        const res = await fetch('/api/health');
        const data = await res.json();
        setDb(res.ok && data.db === 'connected' ? 'connected' : 'error');
      } catch {
        setDb('error');
      }
    };
    check();
    const interval = setInterval(check, 10000);
    return () => clearInterval(interval);
  }, []);

  useEffect(() => {
    if (answerRef.current) {
      answerRef.current.scrollTop = answerRef.current.scrollHeight;
    }
  }, [answer]);

  const ask = async () => {
    if (!question.trim() || asking) return;
    setAsking(true);
    setAnswer('');

    try {
      const res = await fetch('/api/ask', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ question }),
      });

      if (!res.ok) {
        setAnswer('Error: could not reach the backend.');
        return;
      }

      const reader = res.body.getReader();
      const decoder = new TextDecoder();

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        setAnswer((prev) => prev + decoder.decode(value, { stream: true }));
      }
    } catch {
      setAnswer('Error: request failed.');
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

  const { label, color } = STATUS[db];

  return (
    <div className="app">
      <div className="layout">

        {/* Status card */}
        <div className="card">
          <h1>Zero Trust Workshop</h1>
          <div className="status-row">
            <span className="status-label">PostgreSQL</span>
            <div className="indicator" style={{ '--color': color }}>
              <span className="dot" />
              <span className="indicator-label">{label}</span>
            </div>
          </div>
        </div>

        {/* Q&A card */}
        <div className="card qa-card">
          <h2>Ask about your data</h2>

          <div className="suggestions">
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
            <textarea
              className="qa-input"
              rows={2}
              placeholder="Ask a question about users, orders, or preferences…"
              value={question}
              onChange={(e) => setQuestion(e.target.value)}
              onKeyDown={handleKey}
              disabled={asking}
            />
            <button className="ask-btn" onClick={ask} disabled={asking || !question.trim()}>
              {asking ? <span className="spinner" /> : 'Ask'}
            </button>
          </div>

          {(answer || asking) && (
            <div className="answer-box" ref={answerRef}>
              {answer || <span className="thinking">Thinking…</span>}
              {asking && answer && <span className="cursor" />}
            </div>
          )}
        </div>

      </div>
    </div>
  );
}
