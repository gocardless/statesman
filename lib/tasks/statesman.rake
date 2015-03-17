namespace :statesman do
  desc "Set most_recent to false for old transitions and to true for the "\
       "latest one. Safe to re-run"
  task :backfill_most_recent, [:parent_model_name] => :environment do |_, args|
    parent_model_name = args.parent_model_name
    abort("Parent model name must be specified") unless parent_model_name

    parent_class = parent_model_name.constantize
    transition_class = parent_class.transition_class
    parent_fk = "#{parent_model_name.demodulize.underscore}_id"

    total_models = parent_class.count
    done_models = 0
    batch_size = 500

    parent_class.find_in_batches(batch_size: batch_size) do |models|
      ActiveRecord::Base.transaction do
        # Set all transitions' most_recent to FALSE
        transition_class.where(parent_fk => models.map(&:id)).
          update_all(most_recent: false)

        # Set current transition's most_recent to TRUE
        ActiveRecord::Base.connection.execute %{
          UPDATE #{transition_class.table_name}
          SET most_recent = true
          FROM
          (
            SELECT initial_t.id, subsequent_t.created_at
            FROM #{transition_class.table_name} initial_t
            LEFT JOIN #{transition_class.table_name} subsequent_t ON
            (
                initial_t.#{parent_fk} = subsequent_t.#{parent_fk}
                AND initial_t.sort_key < subsequent_t.sort_key
            )
            WHERE initial_t.#{parent_fk}
              IN (#{models.map { |p| "'#{p.id}'" }.join(',')})
            AND subsequent_t.id IS NULL
          ) x
          WHERE #{transition_class.table_name}.id = x.id
        }
      end

      done_models += batch_size
      puts "Updated #{transition_class.name.pluralize} for "\
           "#{[done_models, total_models].min}/#{total_models} "\
           "#{parent_model_name.pluralize}"
    end
  end
end
