namespace :statesman do
  desc "Set most_recent to false for old transitions and to true for the "\
       "latest one. Safe to re-run"
  task :backfill_most_recent, [:parent_model_name] => :environment do |_, args|
    parent_model_name = args.parent_model_name
    abort("Parent model name must be specified") unless parent_model_name

    parent_class = parent_model_name.constantize
    transition_class = parent_class.transition_class
    parent_fk = "#{parent_model_name.demodulize.underscore}_id"
    updated_at = if ActiveRecord::Base.default_timezone == :utc
                   Time.now.utc
                 else
                   Time.now
                 end

    total_models = parent_class.count
    done_models = 0
    batch_size = 500

    parent_class.find_in_batches(batch_size: batch_size) do |models|
      ActiveRecord::Base.transaction(requires_new: true) do
        if Statesman::Adapters::ActiveRecord.database_supports_partial_indexes?
          # Set all transitions' most_recent to FALSE
          transition_class.where(parent_fk => models.map(&:id)).
            update_all(most_recent: false, updated_at: updated_at)
        else
          transition_class.where(parent_fk => models.map(&:id)).
            update_all(most_recent: nil, updated_at: updated_at)
        end

        # Set current transition's most_recent to TRUE
        initial_t = transition_class.arel_table
        subsequent_t = initial_t.alias

        later_row_for_same_parent = initial_t[parent_fk].
          eq(subsequent_t[parent_fk]).
          and(initial_t[:sort_key].
                                    lt(subsequent_t[:sort_key]))

        no_later_row = subsequent_t[:id].eq(nil)
        in_current_parent_batch = initial_t[parent_fk].in(models.map(&:id))

        latest_ids_query = initial_t.join(subsequent_t, Arel::Nodes::OuterJoin).
          on(later_row_for_same_parent).
          where(no_later_row.and(in_current_parent_batch)).
          project(initial_t[:id]).to_sql

        latest_ids = transition_class.find_by_sql(latest_ids_query).
          to_a.collect(&:id)

        transition_class.where(id: latest_ids).
          update_all(most_recent: true, updated_at: updated_at)
      end

      done_models += batch_size
      puts "Updated #{transition_class.name.pluralize} for "\
           "#{[done_models, total_models].min}/#{total_models} "\
           "#{parent_model_name.pluralize}"
    end
  end
end
