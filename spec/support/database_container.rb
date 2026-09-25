# frozen_string_literal: true

require "testcontainers/mysql"
require "testcontainers/postgres"

# Starts a throwaway database in Docker so the suite can run against PostgreSQL or
# MySQL locally without a pre-provisioned server.
module DatabaseContainer
  DEFAULT_IMAGES = {
    "postgres" => "postgres:17",
    "mysql" => "mysql:8.4",
  }.freeze

  def self.start(db, image: nil)
    image ||= DEFAULT_IMAGES.fetch(db) do
      raise ArgumentError, "Unsupported DB '#{db}', expected one of: " \
                           "#{DEFAULT_IMAGES.keys.join(', ')}"
    end

    container = build(db, image)
    container.start
    at_exit { container.remove(force: true) }

    database_url(container)
  end

  def self.build(db, image)
    case db
    when "postgres" then Testcontainers::PostgresContainer.new(image)
    when "mysql" then Testcontainers::MysqlContainer.new(image)
    end
  end

  def self.database_url(container)
    if container.is_a?(Testcontainers::MysqlContainer)
      container.database_url(protocol: "mysql2")
    else
      container.database_url
    end
  end
end
