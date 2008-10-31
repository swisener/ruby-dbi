# figure out what tests to run
require 'yaml'
require 'rubygems'
begin
    gem 'minitest'
rescue LoadError => e
end
require 'minitest/unit'

if File.basename(Dir.pwd) == "test"
    $:.unshift('../lib')
else
    $:.unshift('lib')
end

# miniunit is awesomely full of fail
class Class
    def name=(name)
        @name = name.to_s if name
    end

    alias :name_orig :name

    def name
        return @name if @name
        return name_orig
    end
end

module MiniTest::Assertions
    def assert_nothing_raised
        begin
            yield 
            assert(true, "Nothing raised")
        rescue Exception => e
            flunk "#{mu_pp(e)} raised when nothing was expected"
        end
    end
end

module DBDConfig
    @testbase = { }
    @current_dbtype = nil

    def self.get_config
        config = nil

        begin
            config = YAML.load_file(File.join(ENV["HOME"], ".ruby-dbi.test-config.yaml"))
        rescue Exception => e
            config = { }
            config["dbtypes"] = [ ]
        end

        return config
    end

    def self.inject_sql(dbh, dbtype, file)
        # splits by --- in the file, strips newlines and the semicolons.
        # this way we can still manually import the file, but use it with our
        # drivers for client-independent injection.
        File.open(file).read.split(/\n*---\n*/, -1).collect { |x| x.gsub!(/\n/, ''); x.sub(/;\z/, '') }.each do |stmt|
            tmp = STDERR.dup
            STDERR.reopen('sql.log', 'a')
            begin
                dbh.commit rescue nil
                dbh["AutoCommit"] = true rescue nil
                dbh.do(stmt)
                dbh.commit unless dbtype == 'sqlite3'
            rescue Exception => e
                tmp.puts "Error injecting '#{stmt}' for db #{dbtype}"
                tmp.puts "Error: #{e.message}"
            end
            STDERR.reopen(tmp)
        end
    end

    def self.current_dbtype
        @current_dbtype
    end

    def self.current_dbtype=(setting)
        @current_dbtype = setting
    end

    def self.testbase(klass_name)
        return @testbase[klass_name]
    end

    def self.set_testbase(klass_name, klass)
        klass.name = klass_name
        @testbase[klass_name] = klass
    end

    def self.suite
        @suite ||= []
    end
end

if __FILE__ == $0
    Dir.chdir("..") if File.basename(Dir.pwd) == "test"
    $LOAD_PATH.unshift(File.join(Dir.pwd, "lib"))
    Dir.chdir("test") rescue nil

    begin
        require 'dbi'
    rescue LoadError => e
        begin
            require 'rubygems'
            gem 'dbi'
            require 'dbi'
        rescue LoadError => e
            abort "DBI must already be installed or must come with this package for tests to work."
        end
    end

    Deprecate.set_action(proc { })

    config = DBDConfig.get_config

    config["dbtypes"] = ENV["DBTYPES"].split(/\s+/) if ENV["DBTYPES"]

    if config and config["dbtypes"]
        config["dbtypes"].each do |dbtype|
            unless config[dbtype]
                warn "#{dbtype} is selected for testing but not configured; see test/DBD_TESTS"
                next
            end

            # base.rb is special, see DBD_TESTS
            require "dbd/#{dbtype}/base.rb"
            Dir["dbd/#{dbtype}/test*.rb"].each { |file| load file }
            # run the general tests
            DBDConfig.current_dbtype = dbtype.to_sym
            Dir["dbd/general/test*.rb"].each { |file| load file; @class.name = file }
            mt = MiniTest::Unit.new
            start = Time.now
            mt.run_test_suites

            puts
            if mt.report.length > 0

                puts "-" * 50
                puts "DATABASE: #{dbtype}"
                puts "-" * 50

                puts mt.report

                puts "-" * 50
                puts "DATABASE: #{dbtype}"
                puts "-" * 50
            end

            puts "Finished in #{(Time.now - start).to_f} seconds."
            puts

            format = "%d tests, %d assertions, %d failures, %d errors, %d skips"
            puts format % [mt.test_count, mt.assertion_count, mt.failures, mt.errors, mt.skips]

            MiniTest::Unit::TestCase.reset
        end
    else
        warn "Please see test/DBD_TESTS for information on configuring DBD tests."
    end
end
