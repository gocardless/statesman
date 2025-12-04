.PHONY: spec spec-sqlite spec-postgres spec-mysql help

# Default target
help:
	@echo "Available targets:"
	@echo "  make spec          - Run specs with all databases (default)"
	@echo "  make spec-sqlite   - Run specs with SQLite"
	@echo "  make spec-postgres - Run specs with PostgreSQL"
	@echo "  make spec-mysql    - Run specs with MySQL"

# Run specs with all databases (default)
spec: spec-sqlite spec-postgres spec-mysql

# Run specs with SQLite
spec-sqlite:
	bundle exec rspec

# Run specs with PostgreSQL
# Uses POSTGRES_URL, then DATABASE_URL, then defaults to local PostgreSQL
spec-postgres:
	@DATABASE_URL=$${POSTGRES_URL:-$${DATABASE_URL:-postgres://postgres:statesman@localhost/statesman_test}} bundle exec rspec

# Run specs with MySQL
# Uses MYSQL_URL, then DATABASE_URL, then defaults to local MySQL
spec-mysql:
	@DATABASE_URL=$${MYSQL_URL:-$${DATABASE_URL:-mysql2://foobar:password@127.0.0.1/statesman_test}} bundle exec rspec
