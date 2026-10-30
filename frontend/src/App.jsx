import { useEffect, useState } from 'react';
import { Footer, Icon } from './components.jsx';
import { useAsk, useAuth, useCiba, useCredentials, useHealth } from './hooks.js';
import Approvals from './views/Approvals.jsx';
import Ask from './views/Ask.jsx';
import DataView from './views/Data.jsx';
import Overview from './views/Overview.jsx';

const VIEWS = [
  { id: 'overview', label: 'Overview', icon: 'overview' },
  { id: 'data', label: 'Data', icon: 'data' },
  { id: 'approvals', label: 'Approvals', icon: 'approvals' },
  { id: 'ask', label: 'Ask', icon: 'ask' },
];

const currentHash = () => {
  const id = window.location.hash.slice(1);
  return VIEWS.some((v) => v.id === id) ? id : 'overview';
};

function SignIn({ auth }) {
  const [form, setForm] = useState({ username: '', password: '' });

  if (auth.token) {
    return (
      <div className="zt-signin">
        <span className="zt-signin__user">Signed in as <strong>{auth.loginUser}</strong></span>
        <button className="secondary-button" type="button" onClick={auth.logout}>Sign out</button>
      </div>
    );
  }

  const submit = async (e) => {
    e.preventDefault();
    if (await auth.login(form)) setForm({ username: '', password: '' });
  };

  return (
    <form className="zt-signin" onSubmit={submit}>
      {auth.loginError && <span className="zt-signin__error" role="alert">{auth.loginError}</span>}
      <input
        aria-label="Username"
        placeholder="Username"
        autoComplete="username"
        value={form.username}
        onChange={(e) => setForm((f) => ({ ...f, username: e.target.value }))}
        disabled={auth.loggingIn}
      />
      <input
        aria-label="Password"
        type="password"
        placeholder="Password"
        autoComplete="current-password"
        value={form.password}
        onChange={(e) => setForm((f) => ({ ...f, password: e.target.value }))}
        disabled={auth.loggingIn}
      />
      <button className="primary-button" type="submit" disabled={auth.loggingIn || !form.username || !form.password}>
        {auth.loggingIn ? 'Signing in…' : 'Sign in'}
      </button>
    </form>
  );
}

export default function App() {
  const [view, setView] = useState(currentHash);
  const [writes, setWrites] = useState(0);
  const auth = useAuth();
  const health = useHealth();
  const vault = useCredentials(auth.token);
  const cibaEnabled = vault.capabilities?.ciba_write === true;
  const ciba = useCiba(auth.token, cibaEnabled, () => setWrites((n) => n + 1));
  const askState = useAsk();

  useEffect(() => {
    const onHash = () => setView(currentHash());
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  const title = VIEWS.find((v) => v.id === view).label;

  return (
    <div className="vg-shell">
      <a className="skip-link" href="#main">Skip to content</a>
      <aside className="vg-sidebar" aria-label="Primary">
        <div className="sidebar-brand">
          <span className="brand-icon"><Icon name="shield" /></span>
          <span className="brand-name">Zero Trust</span>
        </div>
        <nav className="sidebar-nav">
          {VIEWS.map((v) => (
            <a key={v.id} href={`#${v.id}`} className={`nav-item${view === v.id ? ' active' : ''}`} aria-current={view === v.id ? 'page' : undefined}>
              <span className="nav-icon"><Icon name={v.icon} /></span>
              <span className="nav-label">{v.label}</span>
            </a>
          ))}
        </nav>
      </aside>

      <div className="vg-main zt-main">
        <header className="vg-topbar zt-topbar">
          <div className="zt-topbar__title">{title}</div>
          <SignIn auth={auth} />
        </header>
        <main id="main" className="zt-content">
          {view === 'overview' && <Overview vault={vault} health={health} auth={auth} />}
          {view === 'data' && <DataView vault={vault} auth={auth} writes={writes} />}
          {view === 'approvals' && <Approvals vault={vault} auth={auth} ciba={ciba} cibaEnabled={cibaEnabled} writes={writes} />}
          {view === 'ask' && <Ask vault={vault} state={askState} />}
        </main>
        <Footer />
      </div>
    </div>
  );
}
