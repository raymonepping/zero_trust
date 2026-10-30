const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
test('Agent connector consumes file replacement without Vault access', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zt-agent-'));
  const filename = path.join(dir, 'creds.json');
  process.env.VAULT_AGENT_CREDS_FILE = filename;
  const originalFetch = global.fetch;
  global.fetch = () => { throw new Error('Agent connector called the network'); };
  const connector = require('../../data/connector.lab-agent-dynamic.js');
  const write = id => fs.writeFileSync(filename, JSON.stringify({username:'db-user',password:'test-only',lease_id:id,lease_duration:120}));
  try {
    write('lease-1');
    assert.equal((await connector.startAutoRenewal()).leaseId, 'lease-1');
    const event = new Promise((resolve, reject) => {
      const deadline=setTimeout(() => reject(new Error('No file replacement event')), 3500);
      connector.onRotation((_role, creds) => {clearTimeout(deadline); resolve(creds);});
    });
    write('lease-2');
    assert.equal((await event).leaseId, 'lease-2');
    fs.writeFileSync(filename,'{}');
    await assert.rejects(connector.getCredentials(), /Incomplete/);
  } finally {
    connector.stopAutoRenewal();global.fetch=originalFetch;fs.rmSync(dir,{recursive:true,force:true});
  }
});
