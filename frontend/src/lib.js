// Bearer token from sessionStorage. Expiry is checked on every read so a stale
// token is never sent.
export const getAuthHeaders = () => {
  const t = sessionStorage.getItem('access_token');
  if (!t) return {};
  try {
    const { exp } = JSON.parse(atob(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
    if (exp * 1000 < Date.now()) { sessionStorage.removeItem('access_token'); return {}; }
  } catch { return {}; }
  return { Authorization: `Bearer ${t}` };
};

// The credential ladder. The backend reports a source, and one source can cover
// several labs, so each rung names its lab range instead of a single lab.
export const LADDER = [
  { source: 'static-config', label: 'Hardcoded', labs: 'Lab 01',
    copy: 'The database password sits in the source code. Anyone who can read the repository can log in.' },
  { source: 'env-file', label: 'Environment', labs: 'Lab 02',
    copy: 'The password moved out of the code and into the environment. It still never changes.' },
  { source: 'vault-kv', label: 'Vault KV', labs: 'Lab 03',
    copy: 'Vault holds the password and the app fetches it at startup. The password itself is still static.' },
  { source: 'vault-approle', label: 'AppRole', labs: 'Lab 04',
    copy: 'The app logs in with its own machine identity, scoped to one policy. The password is still static.' },
  { source: 'vault-approle-dynamic', label: 'Dynamic', labs: 'Labs 05–06',
    copy: 'Vault creates a database user for this app on demand. It expires by itself and gets replaced before it does.' },
  { source: 'vault-agent-dynamic', label: 'Vault Agent', labs: 'Lab 07',
    copy: 'Vault Agent renders the credential to a file. The app reads the file and never talks to Vault.' },
  { source: 'vault-jwt-dynamic', label: 'Identity', labs: 'Labs 08–10',
    copy: 'The backend trades an identity-provider JWT for a Vault token, then gets a database user matched to the caller.' },
];

export const CLASSIFICATIONS = [
  { key: 'public', label: 'Public', minLevel: 0 },
  { key: 'internal', label: 'Internal', minLevel: 1 },
  { key: 'confidential', label: 'Confidential', minLevel: 2 },
  { key: 'restricted', label: 'Restricted', minLevel: 3 },
];

export const ORDER_STATUSES = ['processing', 'shipped', 'delivered', 'cancelled'];

export function formatRemaining(ms) {
  if (ms <= 0) return 'expired';
  const total = Math.ceil(ms / 1000);
  const minutes = Math.floor(total / 60);
  return minutes ? `${minutes}m ${String(total % 60).padStart(2, '0')}s` : `${total}s`;
}
