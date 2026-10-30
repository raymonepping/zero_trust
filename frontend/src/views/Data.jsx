import { useEffect, useState } from 'react';
import { ClassPill } from '../components.jsx';
import { getAuthHeaders, CLASSIFICATIONS } from '../lib.js';

const person = (r) => `${r.first_name} ${r.last_name}`;

const TABLES = [
  { id: 'users', label: 'Users', columns: [['Name', person], ['Email', (r) => r.email], ['City', (r) => r.city], ['Country', (r) => r.country], ['Joined', (r) => r.joined?.slice(0, 10)]] },
  { id: 'orders', label: 'Orders', columns: [['#', (r) => r.id], ['Customer', person], ['Item', (r) => r.item], ['Status', (r) => r.status], ['Price', (r) => r.price]] },
  { id: 'preferences', label: 'Preferences', columns: [['Name', person], ['Category', (r) => r.category], ['Value', (r) => r.value]] },
  { id: 'training', label: 'Training', columns: [['Name', person], ['Course', (r) => r.course], ['Provider', (r) => r.provider], ['Score', (r) => r.score]] },
  { id: 'tickets', label: 'Tickets', columns: [['Name', person], ['Title', (r) => r.title], ['System', (r) => r.system], ['Priority', (r) => r.priority], ['Status', (r) => r.status]] },
  { id: 'projects', label: 'Projects', columns: [['Name', person], ['Project', (r) => r.project_name], ['Role', (r) => r.role], ['Status', (r) => r.status]] },
];

export default function DataView({ vault, auth, writes }) {
  const [tab, setTab] = useState('orders');
  const [state, setState] = useState({ status: 'loading', rows: [] });
  const table = TABLES.find((t) => t.id === tab);
  const hasClass = tab !== 'users';

  useEffect(() => {
    let stale = false;
    setState({ status: 'loading', rows: [] });
    (async () => {
      try {
        const res = await fetch(`/api/${tab}`, { headers: getAuthHeaders() });
        const rows = await res.json();
        if (stale) return;
        setState(res.ok && Array.isArray(rows)
          ? { status: 'ok', rows }
          : { status: 'error', message: rows.error || `The backend answered ${res.status}.`, rows: [] });
      } catch {
        if (!stale) setState({ status: 'error', message: 'The backend is unreachable.', rows: [] });
      }
    })();
    return () => { stale = true; };
  }, [tab, auth.token, vault.source, vault.vaultRole, writes]);

  const counts = CLASSIFICATIONS
    .map((c) => ({ ...c, n: state.rows.filter((r) => r.classification === c.key).length }))
    .filter((c) => c.n);

  return (
    <>
      <section className="vg-hero zt-hero zt-hero--compact">
        <div className="eyebrow">What this identity can read</div>
        <h1>{auth.token ? auth.loginUser : 'Anonymous'}</h1>
        <p className="zt-hero__copy">
          Rows come straight from the running backend through <span className="vg-mono">{vault.username || 'no credential'}</span>.
          Sign in as someone else, or finish another lab, and this list changes.
        </p>
      </section>

      <section className="vg-card">
        <div className="vg-tabs" role="tablist" aria-label="Tables">
          {TABLES.map((t) => (
            <button
              key={t.id}
              type="button"
              role="tab"
              aria-selected={t.id === tab}
              className={`vg-tab${t.id === tab ? ' vg-tab--active' : ''}`}
              onClick={() => setTab(t.id)}
            >
              {t.label}
            </button>
          ))}
        </div>

        {state.status === 'ok' && hasClass && state.rows.length > 0 && (
          <div className="zt-counts" aria-label="Visible rows by classification">
            <span>{state.rows.length} rows</span>
            {counts.map((c) => (
              <span key={c.key} className={`zt-class zt-class--${c.key}`}>{c.label} {c.n}</span>
            ))}
          </div>
        )}

        {state.status === 'loading' && <div className="state-loading">Loading {table.label.toLowerCase()}…</div>}
        {state.status === 'error' && <div className="inline-notice error" role="alert">{state.message}</div>}
        {state.status === 'ok' && state.rows.length === 0 && (
          <div className="state-empty">
            <h3>No {table.label.toLowerCase()} for this identity</h3>
            <p>Its database role has no rows here, or no access to the table at all.</p>
          </div>
        )}
        {state.status === 'ok' && state.rows.length > 0 && (
          <div className="vg-table-wrap" tabIndex={0} role="region" aria-label={`${table.label} table`}>
            <table className="vg-table">
              <thead>
                <tr>
                  {table.columns.map(([heading]) => <th key={heading} scope="col">{heading}</th>)}
                  {hasClass && <th scope="col">Classification</th>}
                </tr>
              </thead>
              <tbody>
                {state.rows.map((row, i) => (
                  <tr key={row.id ?? i}>
                    {table.columns.map(([heading, get]) => <td key={heading}>{get(row) ?? '–'}</td>)}
                    {hasClass && <td><ClassPill value={row.classification} /></td>}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}
