module Embulk
  module Output
    require 'jdbc/sqlite3'
    require 'java'

    Jdbc::SQLite3.load_driver

    class Sqlite3OutputPlugin < OutputPlugin
      Plugin.register_output("sqlite3", self)

      def self.transaction(config, schema, count, &control)
        columns = schema.map {|c| "`#{c.name}`" }
        column_types = schema.map {|c| "#{to_sqlite_column_type(c.type.to_s)}" }

        task = {
          'database' => config.param('database', :string),
          'table' => config.param('table', :string),
          'columns' => columns,
          'column_types' => column_types,
        }

        connect(task) do |sqlite|
          execute_sql(sqlite, %[create table if not exists #{task['table']}(#{to_sqlite_schema(schema)})])
        end

        commit_reports = yield(task)
        next_config_diff = {}
        return next_config_diff
      end

      def self.to_sqlite_schema(schema)
        schema.map {|column| "`#{column.name}` #{to_sqlite_column_type(column.type.to_s)}" }.join(',')
      end

      def self.to_sqlite_column_type(type)
        case type
        when 'long' then
          'integer'
        when 'string' then
          'text'
        when 'timestamp' then
          'text'
        when 'double' then
          'real'
        else
          type
        end
      end

      def self.connect(task)
        url = "jdbc:sqlite:#{task['database']}"
        sqlite = org.sqlite.JDBC.new.connect(url, java.util.Properties.new)
        if block_given?
          begin
            yield sqlite
          ensure
            sqlite.close
          end
        end
        sqlite
      end

      def self.execute_sql(sqlite, sql, *args)
        stmt = sqlite.createStatement
        begin
          stmt.execute(sql)
        ensure
          stmt.close
        end
      end

      def init
        @sqlite = self.class.connect(task)
        @records = 0
      end

      def close
        @sqlite.close
      end

      def add(page)
        prep = @sqlite.prepareStatement(%[insert into #{@task['table']}(#{@task['columns'].join(',')}) values (#{@task['columns'].map{|c| '?' }.join(',')})])
        begin
          page.each do |record|

            @task['column_types'].each_with_index do |type, index|
              if record[index].nil?
                javaType = case type
                           # Had lots of trouble referencing the java types directly, so hackily trying it
                           # just using the integer values themselves directly
                           when 'integer' then
                             4
                             # java.sql.Types.INTEGER
                           when 'string' then
                             12
                             # java.sql.Types.VARCHAR
                           when 'timestamp' then
                             93
                             # java.sql.Types.TIMESTAMP
                           when 'double' then
                             8
                             # java.sql.Types.DOUBLE
                           else
                             12
                             # java.sql.Types.VARCHAR
                           end

                prep.setNull(index+1, javaType)
              else
                case type
                when 'integer' then
                  prep.setInt(index+1, record[index])
                when 'string' then
                  prep.setString(index+1, record[index])
                when 'timestamp' then
                  prep.setString(index+1, record[index].to_s)
                when 'double' then
                  prep.setString(index+1, record[index].to_f)
                else
                  prep.setString(index+1, record[index].to_s)
                end
              end
            end

            prep.execute
            @records += 1
          end
        ensure
          prep.close
        end
      end

      def finish
      end

      def abort
      end

      def commit
        commit_report = {
          "records" => @records
        }
        return commit_report
      end
    end

  end
end
