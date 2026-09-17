# Actual Email Sync

A free, open-source alternative to Actual Budget's bank sync options. This project automates transaction entry by parsing email alerts from your banks and feeding them into Actual Budget.

## Overview

Actual Budget offers bank sync integrations, but some (SimpleFIN) require paid subscriptions. This project provides a free alternative by:

1. **Fetching emails** from your email provider (Gmail via gog CLI, or directly via IMAP)
2. **Parsing transactions** using configurable regex-based parsers
3. **LLM-assisted parser creation** to easily set up new bank alerts
4. **Syncing to Actual** by writing transactions to Actual's SQLite database

### Current Status

- ✅ MVP working: Fidelity account alerts parsed via gog CLI → SQLite staging db → Actual Budget
- 🚧 In development: React + Node.js web UI for parser configuration
- 📋 Planned: Multi-bank support, IMAP email fetching, interactive LLM parser wizard

## Architecture

### System Components

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│  Email Source   │───▶│   Parser Engine  │───▶│  Staging DB     │
│  (gog/IMAP)     │    │  (Ruby/Node.js)  │    │  (spending.db)  │
└─────────────────┘    └──────────────────┘    └────────┬────────┘
                                                      │
                                                      ▼
                      ┌──────────────────┐    ┌─────────────────┐
                      │   Actual Budget  │◀───│  Sync Service   │
                      │   (SQLite)       │    │                 │
                      └──────────────────┘    └─────────────────┘
```

### Data Flow

1. **Email Fetch**: Bank alert emails are retrieved via gog CLI or IMAP
2. **Staging**: Emails are stored in `spending.db` staging database
3. **Parsing**: Parser engine matches emails against configured parsers and extracts transaction data
4. **Deduplication**: Transactions are checked for duplicates before insertion
5. **Sync**: Transactions are written to Actual Budget's database

### Database Schema

#### `spending.db` - Staging Database

```sql
-- Email parsers configuration
CREATE TABLE email_parsers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  from_pattern TEXT,
  subject_pattern TEXT,
  merchant_pattern TEXT,
  amount_pattern TEXT,
  card_pattern TEXT,
  account_pattern TEXT,
  date_pattern TEXT,
  transaction_type TEXT DEFAULT 'posted',
  account TEXT,
  is_spending INTEGER DEFAULT 1,
  matches_auth_on_card INTEGER DEFAULT 0,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

-- Parsed transactions staging table
CREATE TABLE transactions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  transaction_date TEXT,
  merchant TEXT,
  amount REAL,
  card_last_four TEXT,
  source TEXT,
  email_subject TEXT,
  email_file TEXT,
  transaction_type TEXT DEFAULT 'posted',
  account TEXT,
  matched_auth_id INTEGER,
  matched_posted_id INTEGER,
  actual_posted INTEGER DEFAULT 0,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

-- Transaction flags for tracking issues
CREATE TABLE transaction_flags (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  transaction_id INTEGER,
  type TEXT NOT NULL,
  status TEXT DEFAULT 'open',
  description TEXT,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP,
  resolved_at TEXT,
  FOREIGN KEY(transaction_id) REFERENCES transactions(id)
);
```

### Technology Stack

- **Frontend**: React (following Actual's UI patterns)
- **Backend**: Node.js + Express
- **Database**: SQLite (staging) + Actual's SQLite (target)
- **Email**: gog CLI (Gmail) or IMAP
- **LLM Integration**: OpenRouter API, OpenCode Zen (bring your own key)

## Features

### Parser Configuration UI

The web interface allows users to:

- **View all configured parsers** in a list
- **Create new parsers** with field-by-field configuration
- **Test parsers** against real email samples with split-view (raw email vs parsed result)
- **Map parsers to Actual Budget accounts**

### Parser Testing Interface

```
┌─────────────────────────────┬─────────────────────────────┐
│      Raw Email Content      │     Parsed Result          │
├─────────────────────────────┼─────────────────────────────┤
│ From: alert@fidelity.com    │ Date: 2024-01-15           │
│ Subject: Transaction Alert  │ Merchant: AMAZON.COM*WA    │
│                             │ Amount: -47.99              │
│ Dear Card Member,           │ Account: Fidelity Visa     │
│ Your card was used for      │ Type: posted                │
│ $47.99 at AMAZON.COM*WA     │                            │
│ ...                         │ [Match: ✓] [Confidence: 95%]│
└─────────────────────────────┴─────────────────────────────┘
```

### LLM Parser Wizard

An interactive wizard helps users create new parsers:

1. **Sample Input**: User pastes a bank alert email
2. **LLM Analysis**: LLM suggests regex patterns for each field
3. **Review**: User reviews and adjusts the suggested patterns
4. **Test**: User tests against more samples
5. **Save**: Parser is saved to the database

### Supported LLM Providers

| Provider | Status | Notes |
|----------|--------|-------|
| OpenRouter | ✅ Supported | Bring your own API key |
| OpenCode Zen | ✅ Supported | Bring your own API key |

Users can add custom LLM endpoints via configuration.

## Setup

### Prerequisites

- Node.js 18+
- Ruby 3.0+ (for existing parsing scripts)
- Actual Budget running (desktop or server)
- Gmail account + [gog CLI](https://github.com/steipete/gogcli) (for email fetching)

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/actual-email-sync.git
cd actual-email-sync

# Install Node dependencies
npm install

# Initialize the staging database
ruby init_db.rb
```

### Configuration

1. **Actual Budget**: Set path to your Actual budget file in `.env`:
   ```
   ACTUAL_BUDGET_PATH=~/path/to/your-budget.db
   ```

2. **LLM API Keys** (optional, for parser wizard):
   ```
   OPENROUTER_API_KEY=sk-or-...
   OPENCODE_API_KEY=...
   ```

### Running

```bash
# Start the web UI
npm run dev

# Or run the parsing engine standalone
ruby parse_and_insert_transactions.rb emails/fidelity-alert.json
```

## Usage

### Adding a New Bank

1. Fetch sample emails from your bank using gog:
   ```bash
   gog query "subject:transaction alert from:fidelity.com" --limit 5
   ```

2. Save email samples to the `emails/` directory

3. Open the web UI and click "Add Parser"

4. Use the LLM wizard or manually configure patterns

5. Test with your saved samples

6. Save and enable the parser

### Running Sync

```bash
# Manual sync
ruby sync_to_actual.rb

# Or use the web UI to trigger sync
```

## Roadmap

### Phase 1: Web UI (In Progress)
- [ ] Basic parser CRUD
- [ ] Split-view parser testing interface
- [ ] Parser-to-Actual-account mapping
- [ ] Transaction list with sync status

### Phase 2: LLM Integration (Planned)
- [ ] Interactive parser wizard
- [ ] OpenRouter API integration
- [ ] OpenCode Zen integration
- [ ] Custom LLM endpoint support

### Phase 3: Email Sources (Planned)
- [ ] IMAP email fetching (Gmail, Outlook, etc.)
- [ ] Multiple email account support
- [ ] Email polling/scheduling

### Phase 4: Advanced Features (Backlog)
- [x] Transaction categorization via Jev (System One model, TypeSafe)
- [ ] Duplicate detection across multiple parsers
- [ ] Parser templates library
- [ ] Multi-currency support

### Categorizing with Jev (TypeSafe System One)

Staged email transactions are classified into your **live Actual Budget
categories** using [Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev),
via [ruby_llm-typesafe](https://github.com/kieranklaassen/ruby_llm-typesafe).
Jev does not generate text: it answers a single `Choice` question whose
options are built at runtime from `ActualCategories.spending`, so it cannot
hallucinate a category that is not in your Actual system.

```bash
bundle install
export TYPESAFE_API_KEY=...   # from https://console.typesafe.ai
bundle exec ruby categorize_transactions.rb --dry-run --limit 5
bundle exec ruby categorize_transactions.rb --min-confidence 0.6
node post_to_actual.js        # posts with category set when present
```

`categorize_transactions.rb` adds `category_id / category_name /
category_confidence / categorized_at / category_probabilities` columns to
`spending.db` and `post_to_actual.js` forwards `category_id` to
`api.addTransactions`. Run `ruby test_jev_categorizer.rb` for the
Jev categorizer tests.

### CI, tests, and linting

GitHub Actions (`.github/workflows/ci.yml`) runs three jobs on every push
and pull request: Minitest suites, RuboCop, and ESLint.

```bash
bundle install
bundle exec ruby test_parsers.rb
bundle exec ruby test_jev_categorizer.rb
bundle exec rubocop
npm ci && npm run lint
```

Notes:

- `actual-data/` is gitignored, so CI has no live Actual budget. Tests that
  need the real DB skip gracefully; `TestActualCategoriesFixture` builds a
  miniature Actual-shaped DB in a tmpdir so the same load path is always
  covered.
- If bundler tries to write to the system gem dir, run installs with
  `GEM_HOME=~/.gem/ruby/3.2.0 bundle install`.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Workflow

1. Fork the repo
2. Create a feature branch
3. Make your changes
4. Test with actual budget data
5. Submit PR

## License

MIT

## Acknowledgments

- [Actual Budget](https://actualbudget.org) - The excellent budgeting software this project integrates with
- [gog CLI](https://github.com/steipete/gogcli) - Gmail CLI that makes email retrieval simple
