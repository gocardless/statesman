# frozen_string_literal: true

module Statesman
  module Adapters
    # Include on an ActiveRecord model configured with
    # Statesman::Adapters::TypeSafeActiveRecordQueries#configure_state_machine (only
    # transition_class: is required) to cache the current state on a column on the
    # model. Including this module does nothing on its own - the model must also call
    # `configure_cached_current_state` to wire up the write, which also exposes the
    # configured column name via `cached_state_column_name`, for generic tooling that
    # needs to introspect or repair the cached column (e.g. a cache-repair rake task).
    #
    # The write itself happens inside Statesman::Adapters::ActiveRecord#create_transition
    # (see `maintain_cached_current_state` there), not via a callback registered by this
    # module - that single code path is shared by every Machine subclass and every
    # storage adapter instance for a model, so this works even when a model is driven by
    # several different machine classes (e.g. chosen dynamically per scheme), and it
    # fires reliably under Statesman's mysql_gaplock_protection config, where the DB-level
    # most_recent flip happens via a raw SQL UPDATE that bypasses ActiveRecord callbacks
    # entirely.
    #
    # Caveat: because the write only happens as part of `transition_to!` (via the
    # adapter), a transition row created directly on transition_class - bypassing the
    # machine entirely, e.g. `parent.transitions.create!(...)` - does not update the
    # cache. Only real transitions performed through the machine do.
    #
    # The initial-state seed on create only applies when the column is nil - if it's
    # already been explicitly set (e.g. a test factory building a record straight into a
    # given state, without a real transition history), that value is left alone.
    module ConfigureCachedCurrentState
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def configure_cached_current_state(column: :cached_current_state, touch_updated_at: false)
          unless respond_to?(:transition_class) && transition_class
            raise ArgumentError,
                  "transition_class: must be configured via configure_state_machine " \
                  "before calling configure_cached_current_state"
          end

          initial = initial_state

          define_singleton_method(:cached_state_column_name) { column }
          define_singleton_method(:cached_current_state_touch_updated_at?) { touch_updated_at }

          before_create do
            next unless respond_to?(:"#{column}=")
            next unless send(column).nil?

            send(:"#{column}=", initial.to_s)
          end
        end
      end
    end
  end
end
