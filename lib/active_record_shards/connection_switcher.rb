module ActiveRecordShards
  module ConnectionSwitcher
    def self.extended(klass)
      klass.singleton_class.alias_method_chain :columns, :default_shard
      klass.singleton_class.alias_method_chain :table_exists?, :default_shard
    end

    def default_shard=(new_default_shard)
      ActiveRecordShards::ShardSelection.default_shard = new_default_shard
      switch_connection(:shard => new_default_shard)
    end

    def on_shard(shard, &block)
      old_options = current_shard_selection.options
      switch_connection(:shard => shard) if supports_sharding?
      yield
    ensure
      switch_connection(old_options)
    end

    def on_first_shard(&block)
      shard_name = shard_names.first
      on_shard(shard_name) { yield }
    end

    def on_all_shards(&block)
      old_options = current_shard_selection.options
      if supports_sharding?
        shard_names.each do |shard|
          switch_connection(:shard => shard)
          yield(shard)
        end
      else
        yield
      end
    ensure
      switch_connection(old_options)
    end

    def on_slave_if(condition, &block)
      condition ? on_slave(&block) : yield
    end

    def on_slave_unless(condition, &block)
      on_slave_if(!condition, &block)
    end

    def on_master_if(condition, &block)
      condition ? on_master(&block) : yield
    end

    def on_master_unless(condition, &block)
      on_master_if(!condition, &block)
    end

    def on_master_or_slave(which, &block)
      if block_given?
        on_cx_switch_block(which, &block)
      else
        MasterSlaveProxy.new(self, which)
      end
   end

    # Executes queries using the slave database. Fails over to master if no slave is found.
    # if you want to execute a block of code on the slave you can go:
    #   Account.on_slave do
    #     Account.first
    #   end
    # the first account will be found on the slave DB
    #
    # For one-liners you can simply do
    #   Account.on_slave.first
    def on_slave(&block)
      on_master_or_slave(:slave, &block)
    end

    def on_master(&block)
      on_master_or_slave(:master, &block)
    end

    # just to ease the transition from replica to active_record_shards
    alias_method :with_slave, :on_slave
    alias_method :with_slave_if, :on_slave_if
    alias_method :with_slave_unless, :on_slave_unless

    def on_cx_switch_block(which, &block)
      old_options = current_shard_selection.options
      switch_to_slave = (which == :slave && (@disallow_slave.nil? || @disallow_slave == 0))
      switch_connection(:slave => switch_to_slave)

      @disallow_slave = (@disallow_slave || 0) + 1 if which == :master

      # setting read-only scope on ActiveRecord::Base never made any sense, anyway
      if self == ActiveRecord::Base
        yield
      else
        with_scope({:find => {:readonly => on_slave?}}, :merge, &block)
      end
    ensure
      @disallow_slave -= 1 if which == :master
      switch_connection(old_options)
    end

    # Name of the connection pool. Used by ConnectionHandler to retrieve the current connection pool.
    def connection_pool_name # :nodoc:
      name = @connection_pool_name_override || current_shard_selection.shard_name(self)

      if configurations[name].nil? && on_slave?
        current_shard_selection.shard_name(self, false)
      else
        name
      end
    end

    def establish_connection_override(connection_name)
      @connection_pool_name_override = connection_name
      establish_connection(connection_name)
    end

    def supports_sharding?
      shard_names.any?
    end

    def on_slave?
      current_shard_selection.on_slave?
    end

    def current_shard_selection
      Thread.current[:shard_selection] ||= ShardSelection.new
    end

    def current_shard_id
      current_shard_selection.shard
    end

    def shard_names
      configurations[shard_env]['shard_names'] || []
    end

    private

    def switch_connection(options)
      if options.any?
        if options.has_key?(:slave)
          current_shard_selection.on_slave = options[:slave]
        end

        if options.has_key?(:shard)
          current_shard_selection.shard = options[:shard]
        end

        establish_shard_connection unless connected_to_shard?
      end
    end

    def shard_env
      ActiveRecordShards.rails_env
    end

    def establish_shard_connection
      name = connection_pool_name
      spec = configurations[name]

      raise ActiveRecord::AdapterNotSpecified.new("No database defined by #{name} in database.yml") if spec.nil?

      connection_handler.establish_connection(connection_pool_name, ActiveRecord::Base::ConnectionSpecification.new(spec, "#{spec['adapter']}_connection"))
    end

    def connected_to_shard?
      connection_handler.connection_pools.has_key?(connection_pool_name)
    end

    def columns_with_default_shard
      begin
        columns_without_default_shard
      rescue
        if is_sharded? && (shard_name = shard_names.first)
          on_shard(shard_name) { columns_without_default_shard }
        else
          raise
        end
      end
    end

    def table_exists_with_default_shard?
      result = table_exists_without_default_shard?

      if !result && is_sharded? && (shard_name = shard_names.first)
        result = on_shard(shard_name) { table_exists_without_default_shard? }
      end

      result
    end

    class MasterSlaveProxy
      def initialize(target, which)
        @target = target
        @which = which
      end

      def method_missing(method, *args, &block)
        @target.on_master_or_slave(@which) { @target.send(method, *args, &block) }
      end
    end
  end
end
