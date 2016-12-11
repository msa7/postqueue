module Postqueue
  MAX_ATTEMPTS = 5

  class Base
    # Processes many entries
    #
    # process batch_size: 100
    def process(entity_type: nil, op: nil, batch_size: 100, &block)
      status, result = item_class.transaction do
        process_inside_transaction(entity_type: entity_type, op: op, batch_size: batch_size, &block)
      end

      raise result if status == :err
      result
    end

    def process_one(entity_type: nil, op: nil, &block)
      process(entity_type: entity_type, op: op, batch_size: 1, &block)
    end

    private

    def calculate_batch_size(op:, entity_type:, max_batch_size:)
      recommended_batch_size = batch_size(op: op, entity_type: entity_type) || 1
      return 1 if recommended_batch_size < 2
      return recommended_batch_size unless max_batch_size
      [ recommended_batch_size, max_batch_size ].min
    end

    # The actual processing. Returns [ :ok, number-of-items ] or  [ :err, exception ]
    def process_inside_transaction(entity_type:, op:, batch_size:, &_block)
      batch = select_and_lock_batch(entity_type: entity_type, op: op, batch_size: batch_size)

      first_match = batch.first
      return [ :ok, nil ] unless first_match
      op = batch.first.op
      entity_type = batch.first.entity_type

      entity_ids = batch.map(&:entity_id)
      batch_ids = batch.map(&:id)

      queue_times = item_class.find_by_sql <<-SQL
        SELECT extract('epoch' from AVG(now() - created_at)) AS avg,
               extract('epoch' from MAX(now() - created_at)) AS max
        FROM #{item_class.table_name} WHERE entity_id IN (#{entity_ids.join(',')})
      SQL
      queue_time = queue_times.first

      # run callback.
      result = [ op, entity_type, entity_ids ]

      processing_time = Benchmark.realtime do
        result = yield(*result) if block_given?
      end

      # Depending on the result either reprocess or delete all items
      if result == false
        postpone batch_ids
      else
        on_processing(op, entity_type, entity_ids, processing_time, queue_time)
        item_class.where(id: batch_ids).delete_all
      end

      [ :ok, result ]
    rescue => e
      on_exception(e, op, entity_type, entity_ids)
      postpone batch_ids
      [ :err, e ]
    end

    def postpone(ids)
      item_class.connection.exec_query <<-SQL
        UPDATE #{item_class.table_name}
          SET failed_attempts = failed_attempts+1,
              next_run_at = next_run_at + power(failed_attempts + 1, 1.5) * interval '10 second'
          WHERE id IN (#{ids.join(',')})
      SQL
    end
  end
end
