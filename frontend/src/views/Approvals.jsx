import { useEffect, useState } from 'react';
import { ClassPill } from '../components.jsx';
import { getAuthHeaders, ORDER_STATUSES } from '../lib.js';

const STEPS = [
  { key: 'request', label: 'Request', text: 'Ask to change one order.' },
  { key: 'approve', label: 'Approve', text: 'A person confirms that exact change.' },
  { key: 'write', label: 'Write', text: 'A short-lived write credential applies it.' },
];

const stepIndex = (session) => {
  if (!session) return 0;
  if (session.status === 'polling') return 1;
  if (session.status === 'approved') return 2;
  if (session.status === 'executed') return 3;
  return 1;
};

export default function Approvals({ vault, auth, ciba, cibaEnabled, writes }) {
  const [orders, setOrders] = useState([]);
  const signedIn = Boolean(auth.token);
  const { form, setForm, session } = ciba;
  const active = stepIndex(session);
  const stopped = session?.status === 'denied' || session?.status === 'expired';

  useEffect(() => {
    if (!signedIn || !cibaEnabled) return undefined;
    let stale = false;
    (async () => {
      try {
        const res = await fetch('/api/orders', { headers: getAuthHeaders() });
        const rows = await res.json();
        if (!stale && res.ok && Array.isArray(rows)) setOrders(rows);
      } catch {
        if (!stale) setOrders([]);
      }
    })();
    return () => { stale = true; };
  }, [signedIn, cibaEnabled, vault.vaultRole, writes]);

  const selected = orders.find((o) => String(o.id) === form.orderId);

  return (
    <>
      <section className="vg-hero zt-hero zt-hero--compact">
        <div className="eyebrow">Lab 10 · Delegated write</div>
        <h1>Writes wait for a person.</h1>
        <p className="zt-hero__copy">
          Reading is routine. Changing an order takes an explicit approval, and the approval covers that one change.
          The application enforces this gate; Vault issues the narrow write credential.
        </p>
      </section>

      <section className="vg-card">
        <ol className="zt-steps" aria-label="Approval progress">
          {STEPS.map((s, i) => (
            <li key={s.key} className={stopped && i === 1 ? 'is-stopped' : i < active ? 'is-done' : i === active ? 'is-current' : ''} aria-current={i === active ? 'step' : undefined}>
              <span className="zt-steps__label">{s.label}</span>
              <span className="zt-steps__text">{s.text}</span>
            </li>
          ))}
        </ol>

        {!signedIn && <p className="inline-notice">Sign in to request a change.</p>}
        {signedIn && !cibaEnabled && <p className="inline-notice">This opens in lab 10. The running connector has no approval flow yet.</p>}
        {signedIn && cibaEnabled && (
          <div className="zt-approval">
            <label className="form-field zt-approval__order">
              <span>Order</span>
              <select
                value={form.orderId}
                onChange={(e) => setForm((f) => ({ ...f, orderId: e.target.value }))}
                disabled={ciba.busy}
              >
                <option value="">Pick an order</option>
                {orders.map((o) => (
                  <option key={o.id} value={o.id}>#{o.id} {o.item} ({o.status})</option>
                ))}
              </select>
            </label>
            <label className="form-field">
              <span>New status</span>
              <select
                value={form.newStatus}
                onChange={(e) => setForm((f) => ({ ...f, newStatus: e.target.value }))}
                disabled={ciba.busy}
              >
                {ORDER_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
              </select>
            </label>
            <div className="form-actions">
              <button className="primary-button" type="button" onClick={ciba.request} disabled={ciba.busy || !form.orderId}>
                Request change
              </button>
              <button className="secondary-button" type="button" onClick={ciba.authorize} disabled={ciba.busy || session?.status !== 'polling' || !ciba.pending}>
                Approve
              </button>
            </div>
            {selected && <div className="zt-approval__class">Classification <ClassPill value={selected.classification} /></div>}
          </div>
        )}
        {ciba.error && <p className="inline-notice error" role="alert">{ciba.error}</p>}
        {!ciba.error && ciba.message && <p className="inline-notice" role="status">{ciba.message}</p>}
      </section>
    </>
  );
}
