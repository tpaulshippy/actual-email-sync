require('dotenv').config();
const api = require('@actual-app/api');
const sqlite3 = require('better-sqlite3');

const serverURL = process.env.ACTUAL_SERVER_URL || 'http://localhost:5006';
const password = process.env.ACTUAL_SERVER_PASSWORD;
const syncId = process.env.ACTUAL_SERVER_SYNC_ID;
const DB_PATH = process.env.SPENDING_DB_PATH || './spending.db';

async function main() {
  await api.init({
    dataDir: './actual-data',
    serverURL,
    password,
    verbose: false,
  });

  await api.downloadBudget(syncId);

  const accounts = await api.getAccounts();
  console.log('=== Accounts ===');
  for (const a of accounts) {
    console.log(`${a.name}: ${a.id}`);
  }

  const db = sqlite3(DB_PATH);
  const withdrawals = db.prepare(`
    SELECT * FROM transactions 
    WHERE transaction_type = 'withdrawal' AND actual_posted = 0
  `).all();

  const actualDbPath = './actual-data/My-Finances-f3ca349/db.sqlite';
  const actualDb = sqlite3(actualDbPath);

  console.log(`\nFound ${withdrawals.length} unposted withdrawal(s)`);

  for (const tx of withdrawals) {
    const actualAccountId = tx.account;
    if (!actualAccountId) {
      console.log(`Skipping ${tx.merchant} - no account set`);
      continue;
    }

    const amountCents = Math.round(tx.amount * 100);
    const dateStr = tx.transaction_date.replace(/-/g, '');

    const existing = actualDb.prepare(`
      SELECT id FROM transactions 
      WHERE date = ? AND amount = ? AND (description = ? OR imported_description = ?)
    `).get(dateStr, amountCents, tx.merchant, tx.merchant);

    if (existing) {
      console.log(`Skipping duplicate: ${tx.merchant} $${tx.amount} on ${tx.transaction_date}`);
      db.prepare(`UPDATE transactions SET actual_posted = 1 WHERE id = ?`).run(tx.id);
      continue;
    }

    try {
      const result = await api.addTransactions(actualAccountId, [{
        date: String(tx.transaction_date),
        amount: amountCents,
        payee_name: '' + tx.merchant,
        notes: `Source: ${tx.source} (${tx.email_subject})`,
      }]);

      db.prepare(`UPDATE transactions SET actual_posted = 1 WHERE id = ?`).run(tx.id);
      console.log(`Posted: ${tx.date} - ${tx.merchant} $${tx.amount} (Actual ID: ${result[0]})`);
    } catch (err) {
      console.error(`Failed to post ${tx.merchant}:`, err.message);
    }
  }

  db.close();
  actualDb.close();
  await api.shutdown();
}

main().catch(console.error);
