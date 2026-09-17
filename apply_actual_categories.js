require('dotenv').config();
const api = require('@actual-app/api');
const fs = require('fs');

const serverURL = process.env.ACTUAL_SERVER_URL || 'http://localhost:5006';
const password = process.env.ACTUAL_SERVER_PASSWORD;
const syncId = process.env.ACTUAL_SERVER_SYNC_ID;

// Applies a backfill_actual_categories.rb JSON mapping via the Actual API.
// Direct SQL edits to db.sqlite would not sync to the server, so every
// category assignment goes through updateTransaction.
//
// Usage:
//   node apply_actual_categories.js [results.json] [--dry-run]
const resultsPath = process.argv.find((a) => a.endsWith('.json')) || './actual_jev_results.json';
const dryRun = process.argv.includes('--dry-run');

async function main() {
  const results = JSON.parse(fs.readFileSync(resultsPath, 'utf8'));
  const toApply = results.filter((r) => r.category_id);
  console.log(`Applying ${toApply.length} Jev categorization(s) from ${resultsPath}${dryRun ? ' (dry run)' : ''}...`);

  await api.init({
    dataDir: './actual-data',
    serverURL,
    password,
    verbose: false,
  });

  await api.downloadBudget(syncId);

  const cats = await api.getCategories();
  const catIds = new Set(cats.map((c) => c.id));
  console.log(`Actual API reports ${cats.length} categories`);

  let ok = 0;
  let skipped = 0;
  let failed = 0;
  for (const r of toApply) {
    if (!catIds.has(r.category_id)) {
      console.log(`SKIP ${r.merchant}: category ${r.category_name} (${r.category_id}) not in API list`);
      skipped += 1;
      continue;
    }
    if (dryRun) {
      console.log(`WOULD APPLY ${r.merchant} ${r.amount} -> ${r.category_name} (${r.confidence.toFixed(2)})`);
      ok += 1;
      continue;
    }
    try {
      await api.updateTransaction(r.id, { category: r.category_id });
      console.log(`OK ${r.merchant} ${r.amount} -> ${r.category_name} (${r.confidence.toFixed(2)})`);
      ok += 1;
    } catch (e) {
      console.error(`FAIL ${r.merchant}: ${e.message}`);
      failed += 1;
    }
  }

  console.log(`Done: ${ok} updated, ${skipped} skipped, ${failed} failed`);
  await api.shutdown();
}

main().catch((e) => { console.error(e); process.exit(1); });
