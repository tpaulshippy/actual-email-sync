require 'sqlite3'

# Loads budget categories live from the Actual Budget database.
#
# The category list is NEVER hardcoded here. It is read from the Actual
# system of record (the budget db.sqlite that Actual syncs), so renames,
# new categories, and hidden flags in Actual are picked up automatically.
#
# Usage:
#   cats = ActualCategories.load
#   # => [{ id:, name:, group:, is_income: }, ...]
module ActualCategories
  REPO_ROOT = File.expand_path('..', __dir__)

  class << self
    # Find the Actual budget sqlite file.
    # Order: $ACTUAL_BUDGET_DB, $ACTUAL_DATA_DIR/*/db.sqlite,
    #        ./actual-data/*/db.sqlite (repo checkout).
    def budget_db_path(explicit = nil)
      candidates = []
      candidates << explicit if explicit
      candidates << ENV['ACTUAL_BUDGET_DB'] if ENV['ACTUAL_BUDGET_DB']
      if ENV['ACTUAL_DATA_DIR']
        candidates.concat(Dir.glob(File.join(ENV['ACTUAL_DATA_DIR'], '*/db.sqlite')))
        candidates.concat(Dir.glob(File.join(ENV['ACTUAL_DATA_DIR'], 'db.sqlite')))
      end
      candidates.concat(Dir.glob(File.join(REPO_ROOT, 'actual-data', '*/db.sqlite')))
      candidates.concat(Dir.glob(File.join(REPO_ROOT, 'actual-data', 'db.sqlite')))
      path = candidates.find { |p| p && File.file?(p) }
      return path if path

      raise "No Actual budget database found. Set ACTUAL_BUDGET_DB to your " \
            "Actual db.sqlite (e.g. ./actual-data/My-Finances-*/db.sqlite). " \
            "Checked: #{candidates.uniq.inspect}"
    end

    # Load visible, non-deleted categories from Actual, ordered by group/name.
    # Income categories are included (Jev decides; callers may filter).
    def load(db_path: nil)
      path = budget_db_path(db_path)
      db = SQLite3::Database.new(path, readonly: true)
      db.results_as_hash = true
      rows = db.execute(<<~SQL)
        SELECT c.id AS id, c.name AS name, c.is_income AS is_income,
               g.name AS grp
        FROM categories c
        LEFT JOIN category_groups g ON g.id = c.cat_group
        WHERE c.tombstone = 0 AND c.hidden = 0
        ORDER BY grp, c.name
      SQL
      rows.map do |r|
        {
          id: r['id'],
          name: r['name'],
          group: r['grp'],
          is_income: r['is_income'].to_i == 1
        }
      end
    ensure
      db&.close
    end

    # Spending categories only (the usual target for email transactions).
    def spending(db_path: nil)
      load(db_path: db_path).reject { |c| c[:is_income] }
    end

    # Build a Jev Choice `criteria` map from live categories.
    #
    # Keys are category names (what Jev returns as `choice`); values are
    # short group-qualified descriptions. Duplicate names across groups are
    # disambiguated as "Group > Name" keys.
    def to_criteria(categories)
      by_name = categories.group_by { |c| c[:name] }
      criteria = {}
      categories.each do |c|
        key = by_name[c[:name]].length > 1 ? "#{c[:group]} > #{c[:name]}" : c[:name]
        criteria[key] = "Actual Budget category '#{c[:name]}' in group '#{c[:group]}'"
      end
      criteria
    end

    # Map a Jev `choice` string back to the category record.
    def find_by_choice(categories, choice)
      return nil if choice.nil?
      exact = categories.find { |c| c[:name] == choice }
      return exact if exact
      # Disambiguated "Group > Name" form.
      if choice.include?(' > ')
        group, name = choice.split(' > ', 2)
        return categories.find { |c| c[:name] == name && c[:group] == group }
      end
      nil
    end
  end
end
