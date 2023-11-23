# frozen_string_literal: true

# `expected_dbs` should be a Hash of the form:
# {
#   primary: [:writing, :reading],
#   replica: [:reading],
# }
RSpec::Matchers.define :exactly_query_databases do |expected_dbs|
  match do |block|
    @expected_dbs = expected_dbs.transform_values(&:to_set).with_indifferent_access
    @actual_dbs = Hash.new { |h, k| h[k] = Set.new }.with_indifferent_access

    ActiveSupport::Notifications.
      subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      pool = payload.fetch(:connection).pool

      next if pool.is_a?(ActiveRecord::ConnectionAdapters::NullPool)

      name = pool.db_config.name
      role = pool.role

      @actual_dbs[name] << role
    end

    block.call

    @actual_dbs == @expected_dbs
  end

  failure_message do |_block|
    "expected to query exactly #{@expected_dbs}, but queried #{@actual_dbs}"
  end

  supports_block_expectations
end
