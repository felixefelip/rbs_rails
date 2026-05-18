require "optparse"
require "yaml"
require "rbs_rails/cli/configuration"

module RbsRails
  # @rbs &block: (CLI::Configuration) -> void
  def self.configure(&block) #: void
    CLI::Configuration.configure(&block)
  end

  class CLI
    attr_reader :config_file #: String?

    # @rbs argv: Array[String]
    def run(argv) #: Integer
      parser = create_option_parser

      begin
        args = parser.parse(argv)
        subcommand = args.shift || "help"

        case subcommand
        when "help"
          $stdout.puts parser.help
          0
        when "version"
          $stdout.puts "rbs_rails #{RbsRails::VERSION}"
          0
        when "all"
          load_application
          load_config
          generate_models
          generate_path_helpers
          generate_postconditions_sidecar
          0
        when "models"
          load_application
          load_config
          generate_models
          generate_postconditions_sidecar
          0
        when "path_helpers"
          load_application
          load_config
          generate_path_helpers
          0
        else
          $stdout.puts "Unknown command: #{subcommand}"
          $stdout.puts parser.help
          1
        end
      rescue OptionParser::InvalidOption => e
        $stderr.puts "Error: #{e.message}"
        $stdout.puts parser.help
        1
      end
    rescue StandardError => e
      $stderr.puts "Error: #{e.message}"
      1
    end

    private

    def config #: Configuration
      Configuration.instance
    end

    def load_config #: void
      if config_file
        load config_file
      else
        if File.exist?(".rbs_rails.rb")
          load ".rbs_rails.rb"
        elsif Rails.root.join("config/rbs_rails.rb").exist?
          load Rails.root.join("config/rbs_rails.rb").to_s
        end
      end
    end

    def load_application #: void
      require_relative "#{Dir.getwd}/config/application"

      install_hooks

      Rails.application.initialize!
    rescue LoadError => e
      raise "Failed to load Rails application: #{e.message}"
    end

    def install_hooks #: void
      # Load inspectors.  This is necessary to load earlier than Rails application.
      require 'rbs_rails/active_record/enum'
      require 'rbs_rails/active_record/scope'
    end

    def generate_models #: void
      check_db_migrations!
      Rails.application.eager_load!

      @postcondition_entries = [] #: Array[Hash[String, untyped]]

      ::ActiveRecord::Base.descendants.each do |klass|
        generate_single_model(klass)
      rescue => e
        puts "Error generating RBS for #{klass.name} model"
        raise e
      end
    end

    # Raise an error if database is not migrated to the latest version
    def check_db_migrations! #: void
      return unless config.check_db_migrations

      if ::ActiveRecord::Migration.respond_to? :check_all_pending!
        # Rails 7.1 or later
        ::ActiveRecord::Migration.check_all_pending!  # steep:ignore NoMethod
      else
        ::ActiveRecord::Migration.check_pending!
      end
    end

    # @rbs klass: singleton(ActiveRecord::Base)
    def generate_single_model(klass) #: bool
      return false if config.ignored_model?(klass)
      return false unless RbsRails::ActiveRecord.generatable?(klass)

      original_path, _line = Object.const_source_location(klass.name) rescue nil

      rbs_relative_path = if original_path && Pathname.new(original_path).fnmatch?("#{Rails.root}/**")
                            Pathname.new(original_path)
                                    .relative_path_from(Rails.root)
                                    .sub_ext('.rbs')
                          else
                            "app/models/#{klass.name.underscore}.rbs"
                          end

      path = config.signature_root_dir / rbs_relative_path
      path.dirname.mkpath

      generator = RbsRails::ActiveRecord::Generator.new(klass)
      Util::FileWriter.new(path).write generator.generate

      collect_postcondition_entries(generator)

      true
    end

    # @rbs generator: RbsRails::ActiveRecord::Generator
    private def collect_postcondition_entries(generator) #: void
      return unless @postcondition_entries

      @postcondition_entries.concat(generator.postcondition_entries)
    end

    # Writes the aggregated `.steep_postconditions.yml` sidecar consumed by
    # Steep (felixefelip/steep, conditional postconditions). No-op if no
    # model produced any entry, so untouched projects don't get a stray file.
    #
    # Entries from different generators are merged by (class, method): the
    # target's own `self:` refinement (emitted by the target generator) and
    # any number of `via_receiver` refinements (emitted by host generators
    # via `has_one :x, through: :y`, issue #2) collapse into one entry per
    # predicate, with `via_receiver` arrays concatenated in a stable order.
    def generate_postconditions_sidecar #: void
      entries = @postcondition_entries
      return if entries.nil? || entries.empty?

      merged = merge_postcondition_entries(entries)
      sorted = merged.sort_by { |e| [e["class"], e["method"]] }

      path = config.signature_root_dir.join(".steep_postconditions.yml")
      path.dirname.mkpath
      Util::FileWriter.new(path).write(YAML.dump("postconditions" => sorted))
    end

    # Collapses entries with the same (class, method): combines per-branch
    # bodies (`when_true`/`when_false`) so `self:` from the target meets
    # `via_receiver:` from each host. First-wins on `self` if two generators
    # somehow emit it (target should be the only source).
    # @rbs entries: Array[Hash[String, untyped]]
    private def merge_postcondition_entries(entries) #: Array[Hash[String, untyped]]
      merged = {} #: Hash[[String, String], Hash[String, untyped]]

      entries.each do |entry|
        key = [entry["class"], entry["method"]]
        slot = merged[key] ||= { "class" => entry["class"], "method" => entry["method"] }

        %w[when_true when_false].each do |branch|
          body = entry[branch]
          next unless body

          slot_branch = slot[branch] ||= {}

          if body["self"]
            slot_branch["self"] ||= body["self"]
          end

          if (vias = body["via_receiver"])
            slot_branch["via_receiver"] ||= []
            slot_branch["via_receiver"].concat(vias)
          end
        end
      end

      merged.each_value do |entry|
        %w[when_true when_false].each do |branch|
          vias = entry[branch]&.dig("via_receiver")
          vias.sort_by! { |v| [v["through"].to_s, v["as"].to_s] }.uniq! if vias
        end
      end

      merged.values
    end

    def generate_path_helpers #: void
      path = config.signature_root_dir.join 'path_helpers.rbs'
      path.dirname.mkpath

      sig = RbsRails::PathHelpers.generate
      Util::FileWriter.new(path).write sig
    end

    def create_option_parser #: OptionParser
      OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Usage: rbs_rails [command] [options]

          Commands:
                  help           Show this help message
                  version        Show version
                  all            Generate all RBS files
                  models         Generate RBS files for models
                  path_helpers   Generate RBS for Rails path helpers

          Options:
        BANNER

        opts.on("--signature-root-dir=DIR", "Specify the root directory for RBS signatures") do |dir|
          config.signature_root_dir = Pathname.new(dir)
        end

        opts.on("--config=FILE", "Load configuration from FILE") do |file|
          @config_file = file
        end
      end
    end
  end
end
