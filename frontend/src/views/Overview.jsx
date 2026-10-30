import { useNow } from '../hooks.js';
import { CLASSIFICATIONS, formatRemaining, LADDER } from '../lib.js';

const DB_STATE = { loading: 'Checking', connected: 'Connected', error: 'Disconnected' };

function DataAccess({ vault }) {
  const allowed = new Set(vault.allowed_classifications || []);
  const byTrust = new Set(vault.trust_classifications || []);
  const nextLocked = CLASSIFICATIONS.find(({ key }) => !allowed.has(key));
  const roleLimited = Boolean(nextLocked && byTrust.has(nextLocked.key));
  const count = CLASSIFICATIONS.filter(({ key }) => allowed.has(key)).length;

  return (
    <section className="vg-card">
      <div className="zt-card-head">
        <h2>Data access</h2>
        <span className="vg-pill vg-pill--local">Trust level {vault.trust_level ?? '–'}</span>
      </div>
      <p className="zt-lede">
        {count} of {CLASSIFICATIONS.length} classifications visible.{' '}
        {roleLimited && `The role ${vault.vaultRole} sets the limit here.`}
        {nextLocked && !roleLimited && `A stronger credential source unlocks ${nextLocked.label.toLowerCase()} data.`}
      </p>
      <ul className="zt-access">
        {CLASSIFICATIONS.map(({ key, label, minLevel }) => {
          const open = allowed.has(key);
          const reason = open
            ? 'Visible'
            : byTrust.has(key)
              ? `Needs a higher role than ${vault.vaultRole}`
              : `Needs trust level ${minLevel}`;
          return (
            <li key={key} className={open ? `zt-access__row zt-access__row--${key}` : 'zt-access__row zt-access__row--locked'}>
              <span className="zt-access__dot" aria-hidden="true" />
              <span className="zt-access__label">{label}</span>
              <span className="zt-access__state">{reason}</span>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

function Credential({ vault, lease, remaining }) {
  const rows = [
    ['Source', vault.source],
    ['Vault path', vault.path || 'Not read from Vault'],
    ['Database user', vault.username],
    ['Vault role', vault.vaultRole || 'Not reported'],
    ['Lease', lease?.leaseId || vault.leaseId || 'None. This password does not expire'],
    ['Time left', remaining],
    ['Reissued', vault.rotations != null ? `${vault.rotations} ${vault.rotations === 1 ? 'time' : 'times'} since the backend started` : 'Not reported'],
  ];
  return (
    <section className="vg-card">
      <div className="zt-card-head">
        <h2>Active credential</h2>
        <span className="vg-label-muted">Password never shown</span>
      </div>
      <dl className="zt-details">
        {rows.map(([label, value]) => (
          <div key={label}>
            <dt>{label}</dt>
            <dd className={['Source', 'Vault path', 'Database user', 'Vault role', 'Lease'].includes(label) ? 'vg-mono' : ''}>{value}</dd>
          </div>
        ))}
      </dl>
    </section>
  );
}

export default function Overview({ vault, health, auth }) {
  const now = useNow();
  const index = LADDER.findIndex((r) => r.source === vault.source);
  const rung = LADDER[index];
  const lease = vault.leases?.[vault.vaultRole] || Object.values(vault.leases || {})[0];
  const expiresAt = lease?.expiresAt ? Date.parse(lease.expiresAt) : null;
  const remaining = expiresAt ? formatRemaining(expiresAt - now) : 'No expiry';
  const vaultOk = health.vaultHealth ? health.vaultHealth.ok !== false : null;
  const vaultText = vault.status === 'loading'
    ? 'Checking'
    : vaultOk === false
      ? (health.vaultHealth.status === 'sealed' ? 'Sealed' : 'Unreachable')
      : vault.source?.startsWith('vault-') ? 'In use' : 'Not in use';
  const allowedCount = (vault.allowed_classifications || []).length;

  return (
    <>
      <section className="vg-hero zt-hero">
        <div className="eyebrow">Where the database password comes from</div>
        <h1>
          {vault.status === 'loading' && 'Checking the credential source…'}
          {vault.status === 'error' && 'The backend reports no credential.'}
          {vault.status === 'ok' && (rung ? rung.label : vault.source)}
        </h1>
        <p className="zt-hero__copy">
          {vault.status === 'error' && 'Check that the backend is running and its connector can reach its source.'}
          {vault.status === 'ok' && (rung ? rung.copy : 'This connector is outside the numbered labs.')}
        </p>
        <ol className="zt-ladder" aria-label="Credential ladder">
          {LADDER.map((r, i) => (
            <li key={r.source} className={i === index ? 'is-current' : i < index ? 'is-passed' : ''} aria-current={i === index ? 'step' : undefined}>
              <span className="zt-ladder__label">{r.label}</span>
              <span className="zt-ladder__labs">{r.labs}</span>
            </li>
          ))}
        </ol>
        <div className="zt-tiles">
          <div className="vg-tile">
            <span className="vg-tile__label">PostgreSQL</span>
            <span className="vg-tile__value zt-tile-text">{DB_STATE[health.db]}</span>
          </div>
          <div className="vg-tile">
            <span className="vg-tile__label">Vault</span>
            <span className="vg-tile__value zt-tile-text">{vaultText}</span>
          </div>
          <div className="vg-tile">
            <span className="vg-tile__label">Credential expires in</span>
            <span className="vg-tile__value zt-tile-text">{remaining}</span>
          </div>
          <div className="vg-tile">
            <span className="vg-tile__label">Visible classifications</span>
            <span className="vg-tile__value zt-tile-text">{allowedCount} of {CLASSIFICATIONS.length}</span>
          </div>
        </div>
      </section>

      {vault.status === 'ok' && (
        <div className="zt-grid">
          <DataAccess vault={vault} />
          <Credential vault={vault} lease={lease} remaining={remaining} />
        </div>
      )}
      {!auth.token && vault.status === 'ok' && (
        <p className="inline-notice zt-notice">Browsing anonymously. Sign in as a workshop user from <code className="vg-mono">ldap/bootstrap.ldif</code> to see how access changes per identity.</p>
      )}
    </>
  );
}
