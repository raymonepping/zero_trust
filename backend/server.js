const express = require('express');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 3000;
const OLLAMA_ADDR = process.env.OLLAMA_ADDR || 'http://ollama:11434';

app.use(express.json());

const pool = new Pool({ connectionString: process.env.DATABASE_URL });

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------
app.get('/', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ok', message: 'database is connected' });
  } catch (err) {
    res.status(500).json({ status: 'error', message: err.message });
  }
});

app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ok', db: 'connected' });
  } catch (err) {
    res.status(500).json({ status: 'error', db: err.message });
  }
});

// ---------------------------------------------------------------------------
// Data APIs
// ---------------------------------------------------------------------------
app.get('/users', async (req, res) => {
  try {
    const { rows } = await pool.query(
      'SELECT id, first_name, last_name, email, city, country, joined FROM users ORDER BY id'
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/orders', async (req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT o.id, u.first_name, u.last_name, o.item, o.category, o.quantity, o.price, o.ordered_at
      FROM orders o
      JOIN users u ON u.id = o.user_id
      ORDER BY o.ordered_at DESC
    `);
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/preferences', async (req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT p.id, u.first_name, u.last_name, p.category, p.value
      FROM preferences p
      JOIN users u ON u.id = p.user_id
      ORDER BY u.id, p.category
    `);
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Ask — queries DB for context, streams Ollama response to client
// ---------------------------------------------------------------------------
app.post('/ask', async (req, res) => {
  const { question } = req.body;
  if (!question) return res.status(400).json({ error: 'question is required' });

  try {
    // Build full context from DB
    const [users, orders, prefs] = await Promise.all([
      pool.query('SELECT first_name, last_name, email, city, country, joined FROM users ORDER BY id'),
      pool.query(`
        SELECT u.first_name, o.item, o.category, o.quantity, o.price, o.ordered_at
        FROM orders o JOIN users u ON u.id = o.user_id ORDER BY u.id, o.ordered_at
      `),
      pool.query(`
        SELECT u.first_name, p.category, p.value
        FROM preferences p JOIN users u ON u.id = p.user_id ORDER BY u.id, p.category
      `),
    ]);

    const fmt = (rows) => rows.map((r) => JSON.stringify(r)).join('\n');

    const context = `
USERS:
${fmt(users.rows)}

ORDERS:
${fmt(orders.rows)}

PREFERENCES:
${fmt(prefs.rows)}
`.trim();

    const prompt = `You are a helpful assistant with access to a user database.
Use only the data provided below to answer the question. Be concise and friendly.

--- DATA ---
${context}
--- END DATA ---

Question: ${question}
Answer:`;

    // Stream Ollama response directly to the client
    res.setHeader('Content-Type', 'text/plain; charset=utf-8');
    res.setHeader('Transfer-Encoding', 'chunked');
    res.setHeader('X-Accel-Buffering', 'no');

    const ollamaRes = await fetch(`${OLLAMA_ADDR}/api/generate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: 'llama3.2', prompt, stream: true }),
    });

    if (!ollamaRes.ok) {
      const err = await ollamaRes.text();
      return res.status(502).end(`Ollama error: ${err}`);
    }

    const reader = ollamaRes.body.getReader();
    const decoder = new TextDecoder();

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const lines = decoder.decode(value, { stream: true }).split('\n').filter(Boolean);
      for (const line of lines) {
        try {
          const json = JSON.parse(line);
          if (json.response) res.write(json.response);
          if (json.done) { res.end(); return; }
        } catch { /* partial chunk, skip */ }
      }
    }

    res.end();
  } catch (err) {
    if (!res.headersSent) res.status(500).json({ error: err.message });
    else res.end();
  }
});

app.listen(PORT, () => {
  console.log(`Backend listening on port ${PORT}`);
  console.log(`Ollama: ${OLLAMA_ADDR}`);
});
