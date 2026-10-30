import { useEffect, useRef, useState } from 'react';

const SUGGESTIONS = [
  'What did Raymon order?',
  'What are the tech interests of all users?',
  'Which user spent the most money?',
  'Who has the highest security clearance?',
];

export default function Ask({ vault, state }) {
  const { question, setQuestion, answer, lastQuestion, asking, error, ask, clear } = state;
  const [copied, setCopied] = useState('Copy');
  const answerRef = useRef(null);

  useEffect(() => {
    if (answerRef.current) answerRef.current.scrollTop = answerRef.current.scrollHeight;
  }, [answer]);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(answer);
      setCopied('Copied');
    } catch {
      setCopied('Copy failed');
    }
    setTimeout(() => setCopied('Copy'), 1800);
  };

  const onKey = (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      ask();
    }
  };

  return (
    <>
      <section className="vg-hero zt-hero zt-hero--compact">
        <div className="eyebrow">Optional · Needs Ollama</div>
        <h1>Ask your data a question.</h1>
        <p className="zt-hero__copy">
          The model only receives rows this identity may read, currently {(vault.allowed_classifications || []).join(', ') || 'none'}.
          Ask the same question as another user and compare the answers.
        </p>
      </section>

      <section className="vg-card">
        <div className="zt-chips" aria-label="Suggested questions">
          {SUGGESTIONS.map((s) => (
            <button key={s} type="button" className="vg-btn vg-btn--ghost" onClick={() => setQuestion(s)} disabled={asking}>{s}</button>
          ))}
        </div>
        <label className="form-field">
          <span>Question</span>
          <textarea
            rows={3}
            value={question}
            onChange={(e) => setQuestion(e.target.value)}
            onKeyDown={onKey}
            disabled={asking}
          />
          <small>Enter sends. Shift+Enter starts a new line.</small>
        </label>
        <div className="form-actions zt-ask-actions">
          <button className="primary-button" type="button" onClick={ask} disabled={asking || !question.trim()}>
            {asking ? 'Answering…' : 'Ask'}
          </button>
          {(answer || error) && <button className="secondary-button" type="button" onClick={clear}>Clear</button>}
          {answer && !asking && <button className="secondary-button" type="button" onClick={copy}>{copied}</button>}
        </div>
        {error && <p className="inline-notice error" role="alert">{error}</p>}
        {(answer || asking) && (
          <div className="zt-answer" ref={answerRef} aria-live="polite">
            <div className="zt-answer__q">{lastQuestion}</div>
            {answer || 'Thinking…'}
          </div>
        )}
      </section>
    </>
  );
}
