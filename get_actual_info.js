const api = require('@actual-app/api');

const serverURL = process.env.ACTUAL_SERVER_URL || 'http://localhost:5006';
const password = process.env.ACTUAL_SERVER_PASSWORD;
const syncId = process.env.ACTUAL_SERVER_SYNC_ID;

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
    const transactions = await api.getTransactions(a.id);
    const balance = transactions.reduce((sum, t) => sum + t.amount, 0);
    console.log(`${a.name}: ${api.utils.integerToAmount(balance)}`);
  }

  const month = await api.getBudgetMonth('2026-03');
  console.log('\n=== Budget Summary (March 2026) ===');
  console.log(`To Budget: ${api.utils.integerToAmount(month.toBudget)}`);
  console.log(`Total Income: ${api.utils.integerToAmount(month.totalIncome)}`);
  console.log(`Total Spent: ${api.utils.integerToAmount(month.totalSpent)}`);
  
  console.log('\n=== Categories ===');
  for (const group of month.categoryGroups || []) {
    if (!group.is_income) {
      for (const cat of group.categories || []) {
        console.log(`${cat.name}: ${api.utils.integerToAmount(cat.budgeted)} budgeted, ${api.utils.integerToAmount(cat.spent)} spent`);
      }
    }
  }

  await api.shutdown();
}

main().catch(console.error);
