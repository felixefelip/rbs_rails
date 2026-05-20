require 'test_helper'
require 'rbs_rails/cli'
require 'tmpdir'

# Integration-style tests for `CLI#generate_callbacks_sidecar`. They
# write controller files to a tmpdir, drive the generator via the CLI
# method directly, and assert on the emitted YAML structure.
class CallbacksSidecarTest < Minitest::Test
  def with_tmp_project
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p("app/controllers")
        yield Pathname(dir)
      end
    end
  end

  def configure_sidecar_dir(dir)
    RbsRails::CLI::Configuration.instance.signature_root_dir = dir.join("sig/rbs_rails")
  end

  def run_generator
    RbsRails::CLI.new.send(:generate_callbacks_sidecar)
  end

  def sidecar_path
    RbsRails::CLI::Configuration.instance.signature_root_dir.join(".steep_callbacks.yml")
  end

  def teardown
    RbsRails::CLI::Configuration.instance.signature_root_dir = nil
  rescue StandardError
    # The setter raises on `nil`; clear via instance variable as a
    # fallback so one test doesn't leak state into the next.
    RbsRails::CLI::Configuration.instance.instance_variable_set(:@signature_root_dir, nil)
  end

  def test_emits_sidecar_for_controller_with_before_action
    with_tmp_project do |dir|
      configure_sidecar_dir(dir)

      File.write("app/controllers/posts_controller.rb", <<~RUBY)
        class PostsController < ApplicationController
          before_action :set_post, only: [:show, :edit, :update, :destroy]

          def index; end
          def show; end
          def edit; end
          def update; end
          def destroy; end
        end
      RUBY

      run_generator

      assert sidecar_path.file?, "expected sidecar to be written"
      payload = YAML.safe_load(sidecar_path.read)
      assert_equal 1, payload["version"]
      assert_equal 1, payload["callbacks"].size
      entry = payload["callbacks"].first
      assert_equal "PostsController", entry["class"]
      assert_equal "set_post", entry["apply_postcondition_of"]
      assert_equal ["show", "edit", "update", "destroy"], entry["runs_before"]
    end
  end

  def test_writes_nothing_when_no_controllers
    with_tmp_project do |dir|
      configure_sidecar_dir(dir)

      run_generator

      refute sidecar_path.exist?, "sidecar must not be created when there are no entries"
    end
  end

  def test_writes_nothing_when_controllers_have_no_before_action
    with_tmp_project do |dir|
      configure_sidecar_dir(dir)

      File.write("app/controllers/posts_controller.rb", <<~RUBY)
        class PostsController < ApplicationController
          def index; end
          def show; end
        end
      RUBY

      run_generator

      refute sidecar_path.exist?, "sidecar must not be created when there are no entries"
    end
  end

  def test_aggregates_entries_across_multiple_controllers
    with_tmp_project do |dir|
      configure_sidecar_dir(dir)

      File.write("app/controllers/posts_controller.rb", <<~RUBY)
        class PostsController
          before_action :set_post, only: [:show]
          def show; end
        end
      RUBY

      File.write("app/controllers/users_controller.rb", <<~RUBY)
        class UsersController
          before_action :set_user
          def show; end
          def edit; end
        end
      RUBY

      run_generator

      payload = YAML.safe_load(sidecar_path.read)
      classes = payload["callbacks"].map { |e| e["class"] }
      assert_includes classes, "PostsController"
      assert_includes classes, "UsersController"
    end
  end

  def test_handles_namespaced_controllers_under_subdirectories
    with_tmp_project do |dir|
      configure_sidecar_dir(dir)

      FileUtils.mkdir_p("app/controllers/admin")
      File.write("app/controllers/admin/users_controller.rb", <<~RUBY)
        module Admin
          class UsersController < ApplicationController
            before_action :authorize, only: [:show]
            def show; end
          end
        end
      RUBY

      run_generator

      payload = YAML.safe_load(sidecar_path.read)
      assert_equal 1, payload["callbacks"].size
      assert_equal "Admin::UsersController", payload["callbacks"].first["class"]
    end
  end

  def test_sorts_entries_for_stable_output
    with_tmp_project do |dir|
      configure_sidecar_dir(dir)

      File.write("app/controllers/zeta_controller.rb", <<~RUBY)
        class ZetaController
          before_action :zeta_handler
          def index; end
        end
      RUBY

      File.write("app/controllers/alpha_controller.rb", <<~RUBY)
        class AlphaController
          before_action :alpha_handler
          def index; end
        end
      RUBY

      run_generator

      payload = YAML.safe_load(sidecar_path.read)
      classes = payload["callbacks"].map { |e| e["class"] }
      assert_equal ["AlphaController", "ZetaController"], classes
    end
  end
end
