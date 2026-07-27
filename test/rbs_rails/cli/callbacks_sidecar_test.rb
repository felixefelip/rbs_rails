require 'test_helper'
require 'rbs_rails/cli'
require 'tmpdir'

# Integration-style tests for `CLI#generate_callbacks_sidecar`. They drive the
# generator via the CLI method directly and assert on the emitted YAML.
#
# The sidecar carries MODEL after-validation callbacks only. Controller
# `before_action` entries were dropped once rbs_infer's controller-runtime
# pseudo-code proved the same ivar facts by modelling the effective chain —
# see the removal commit for the measurements.
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

  def test_emits_model_callbacks
    with_tmp_project do |dir|
      configure_sidecar_dir(dir)

      cli = RbsRails::CLI.new
      cli.instance_variable_set(:@callback_entries, [
        {
          "class" => "Dose",
          "applies_self" => "Dose & Dose::Validated",
          "runs_before" => ["atualizar_calendario"]
        }
      ])
      cli.send(:generate_callbacks_sidecar)

      assert sidecar_path.file?, "expected sidecar with model entries"
      payload = YAML.safe_load(sidecar_path.read)
      assert_equal 1, payload["callbacks"].size
      assert_equal "Dose & Dose::Validated", payload["callbacks"].first["applies_self"]
    end
  end

  # Regression guard for the removal: a controller declaring `before_action` no
  # longer contributes anything, so a project with only controllers gets no file
  # at all. rbs_infer's controller-runtime pseudo-code covers this now.
  def test_ignores_controller_before_action
    with_tmp_project do |dir|
      configure_sidecar_dir(dir)
      File.write("app/controllers/posts_controller.rb", <<~RUBY)
        class PostsController < ApplicationController
          before_action :set_post, only: [:show, :edit]
        end
      RUBY

      run_generator

      refute sidecar_path.exist?, "controller before_action must not produce a sidecar"
    end
  end

  def test_writes_nothing_when_no_model_contributes
    with_tmp_project do |dir|
      configure_sidecar_dir(dir)

      run_generator

      refute sidecar_path.exist?, "expected no sidecar when nothing contributes an entry"
    end
  end

  def test_sorts_entries_for_stable_output
    with_tmp_project do |dir|
      configure_sidecar_dir(dir)

      cli = RbsRails::CLI.new
      cli.instance_variable_set(:@callback_entries, [
        { "class" => "Zeta", "applies_self" => "Zeta & Zeta::Validated", "runs_before" => ["z"] },
        { "class" => "Alpha", "applies_self" => "Alpha & Alpha::Validated", "runs_before" => ["a"] }
      ])
      cli.send(:generate_callbacks_sidecar)

      payload = YAML.safe_load(sidecar_path.read)
      assert_equal %w[Alpha Zeta], payload["callbacks"].map { |e| e["class"] }
    end
  end
end
