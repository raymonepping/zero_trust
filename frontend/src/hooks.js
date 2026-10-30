import { useEffect, useRef, useState } from 'react';
import { getAuthHeaders } from './lib.js';

export function useNow(intervalMs = 1000) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}

export function useAuth() {
  const [token, setToken] = useState(() => sessionStorage.getItem('access_token') || '');
  const [loginUser, setLoginUser] = useState(() => sessionStorage.getItem('login_user') || '');
  const [loginError, setLoginError] = useState('');
  const [loggingIn, setLoggingIn] = useState(false);
  const refreshTimerRef = useRef(null);
  const storedCredsRef = useRef({ username: '', password: '' });

  const applyToken = (accessToken, expiresIn, username, password) => {
    sessionStorage.setItem('access_token', accessToken);
    sessionStorage.setItem('login_user', username);
    setToken(accessToken);
    storedCredsRef.current = { username, password };

    // Auto-refresh at 80% of TTL
    if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
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
    }, Math.floor(expiresIn * 0.8) * 1000);
  };

  const login = async ({ username, password }) => {
    setLoggingIn(true);
    setLoginError('');
    try {
      const res = await fetch('/api/auth/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password }),
      });
      const data = await res.json();
      if (!res.ok) { setLoginError(data.error || 'Login failed'); return false; }
      applyToken(data.access_token, data.expires_in, username, password);
      setLoginUser(username);
      return true;
    } catch {
      setLoginError('Identity provider unreachable');
      return false;
    } finally {
      setLoggingIn(false);
    }
  };

  const logout = () => {
    sessionStorage.removeItem('access_token');
    sessionStorage.removeItem('login_user');
    setToken('');
    setLoginUser('');
    storedCredsRef.current = { username: '', password: '' };
    if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
  };

  return { token, loginUser, loginError, loggingIn, login, logout };
}

export function useHealth() {
  const [db, setDb] = useState('loading');
  const [vaultHealth, setVaultHealth] = useState(null);

  useEffect(() => {
    const check = async () => {
      try {
        const res = await fetch('/api/health', { headers: getAuthHeaders() });
        const data = await res.json();
        setVaultHealth(data.vault || null);
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

  return { db, vaultHealth };
}

export function useCredentials(token) {
  const [vault, setVault] = useState({ status: 'loading' });

  useEffect(() => {
    let stale = false;
    const check = async () => {
      try {
        const res = await fetch('/api/credentials', { headers: getAuthHeaders() });
        const data = await res.json();
        if (stale) return;
        setVault(res.ok && data.username ? { status: 'ok', ...data } : { status: 'error' });
      } catch {
        if (!stale) setVault({ status: 'error' });
      }
    };
    check();
    const interval = setInterval(check, 15000);
    return () => {
      stale = true;
      clearInterval(interval);
    };
  }, [token]);

  return vault;
}

export function useCiba(token, cibaEnabled, onWritten) {
  const [form, setForm] = useState({ orderId: '', newStatus: 'shipped' });
  const [session, setSession] = useState(null);
  const [pending, setPending] = useState(null);
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const fetchPending = async () => {
    const res = await fetch('/api/ciba/pending', { headers: getAuthHeaders() });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Could not load pending approvals');
    if (!Array.isArray(data)) throw new Error('Pending approvals response was not a list');
    const match = session?.action
      ? data.find((request) => request.bindingMessage === session.action)
      : data[0];
    setPending(match || null);
    return match || null;
  };

  const executeWrite = async (current) => {
    const res = await fetch(`/api/ciba/orders/${current.orderId}/status`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
      body: JSON.stringify({ newStatus: current.newStatus, cibaSessionId: current.sessionId }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'The approved write failed');
    setSession((s) => (s ? { ...s, status: 'executed' } : s));
    setMessage(data.message || `Order ${current.orderId} updated to ${current.newStatus}.`);
    onWritten?.();
  };

  useEffect(() => {
    if (!token || !cibaEnabled || session?.status !== 'polling') return undefined;
    const checkStatus = async () => {
      try {
        const res = await fetch(`/api/ciba/status/${session.sessionId}`, { headers: getAuthHeaders() });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || 'Could not check the approval status');
        setSession((s) => (s ? { ...s, status: data.status } : s));
        if (data.status === 'approved') {
          await executeWrite({ ...session, status: data.status });
        } else if (data.status === 'denied' || data.status === 'expired') {
          setMessage(`The request was ${data.status}.`);
        }
      } catch (err) {
        setError(err.message);
      }
    };
    const interval = setInterval(checkStatus, 3000);
    return () => clearInterval(interval);
  }, [token, cibaEnabled, session]);

  useEffect(() => {
    if (!token || !cibaEnabled || session?.status !== 'polling') return undefined;
    fetchPending().catch(() => {});
    const interval = setInterval(() => fetchPending().catch(() => {}), 2500);
    return () => clearInterval(interval);
  }, [token, cibaEnabled, session]);

  const request = async () => {
    if (busy) return;
    setBusy(true);
    setError('');
    setPending(null);
    try {
      const orderId = Number.parseInt(form.orderId, 10);
      if (!Number.isInteger(orderId) || orderId < 1) throw new Error('Pick an order first.');
      const res = await fetch('/api/ciba/initiate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
        body: JSON.stringify({ orderId, newStatus: form.newStatus }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Could not start the approval');
      setSession({ sessionId: data.sessionId, action: data.action, orderId, newStatus: form.newStatus, status: 'polling' });
      setMessage(`Waiting for approval to set order ${orderId} to ${form.newStatus}.`);
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  };

  const authorize = async () => {
    if (busy || !session) return;
    setBusy(true);
    setError('');
    try {
      const match = pending || (await fetchPending());
      if (!match) throw new Error('No matching approval is pending yet.');
      const res = await fetch('/api/ciba/approve', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
        body: JSON.stringify({ requestId: match.id, decision: 'SUCCEED' }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Authorization failed');
      setPending(null);
      setMessage('Approved. Waiting for the write credential.');
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  };

  return { form, setForm, session, pending, message, error, busy, request, authorize };
}

export function useAsk() {
  const [question, setQuestion] = useState('');
  const [answer, setAnswer] = useState('');
  const [lastQuestion, setLastQuestion] = useState('');
  const [asking, setAsking] = useState(false);
  const [error, setError] = useState('');

  const ask = async () => {
    if (!question.trim() || asking) return;
    setAsking(true);
    setError('');
    setAnswer('');
    setLastQuestion(question.trim());
    try {
      const res = await fetch('/api/ask', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
        body: JSON.stringify({ question: question.trim() }),
      });
      if (!res.ok) {
        setError('The backend could not answer. Ask needs the optional Ollama service, which the numbered labs do not start.');
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
      setError('The request failed before the answer finished.');
    } finally {
      setAsking(false);
    }
  };

  const clear = () => {
    setAnswer('');
    setLastQuestion('');
    setError('');
  };

  return { question, setQuestion, answer, lastQuestion, asking, error, ask, clear };
}
