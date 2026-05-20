require 'test_helper'

# Unit tests for `RbsRails::CallbacksGenerator` — parses a Ruby source
# string and extracts `.steep_callbacks.yml` entries from
# `before_action`/`skip_before_action` declarations.
class CallbacksGeneratorTest < Minitest::Test
  Generator = RbsRails::CallbacksGenerator

  def gen(source)
    Generator.new(source: source).entries
  end

  def test_emits_entry_for_before_action_with_only
    entries = gen(<<~RUBY)
      class PostsController < ApplicationController
        before_action :set_post, only: [:show, :edit]

        def index; end
        def show; end
        def edit; end
        def new; end
      end
    RUBY

    assert_equal 1, entries.size
    assert_equal({
      "class" => "PostsController",
      "apply_postcondition_of" => "set_post",
      "runs_before" => ["show", "edit"]
    }, entries.first)
  end

  def test_emits_entry_for_before_action_with_except
    entries = gen(<<~RUBY)
      class PostsController
        before_action :authenticate, except: [:index, :show]

        def index; end
        def show; end
        def edit; end
        def update; end
      end
    RUBY

    assert_equal 1, entries.size
    assert_equal ["edit", "update"], entries.first["runs_before"]
  end

  def test_emits_entry_for_before_action_without_modifier
    entries = gen(<<~RUBY)
      class PostsController
        before_action :set_post

        def index; end
        def show; end
        def edit; end
      end
    RUBY

    assert_equal 1, entries.size
    assert_equal ["index", "show", "edit"], entries.first["runs_before"]
  end

  def test_supports_single_symbol_as_only
    # Rails accepts `only: :show` (single symbol) without the array.
    entries = gen(<<~RUBY)
      class PostsController
        before_action :set_post, only: :show

        def show; end
        def edit; end
      end
    RUBY

    assert_equal ["show"], entries.first["runs_before"]
  end

  def test_supports_percent_symbol_array
    # `%i[show edit]` should parse to symbols.
    entries = gen(<<~RUBY)
      class PostsController
        before_action :set_post, only: %i[show edit]

        def show; end
        def edit; end
        def index; end
      end
    RUBY

    assert_equal ["show", "edit"], entries.first["runs_before"]
  end

  def test_subtracts_skip_before_action
    entries = gen(<<~RUBY)
      class PostsController
        before_action :authenticate
        skip_before_action :authenticate, only: [:index]

        def index; end
        def show; end
      end
    RUBY

    assert_equal 1, entries.size
    assert_equal ["show"], entries.first["runs_before"]
  end

  def test_multiple_before_actions
    entries = gen(<<~RUBY)
      class PostsController
        before_action :set_post, only: [:show]
        before_action :authenticate

        def index; end
        def show; end
      end
    RUBY

    assert_equal 2, entries.size
    assert_equal({"class" => "PostsController", "apply_postcondition_of" => "set_post", "runs_before" => ["show"]}, entries[0])
    assert_equal({"class" => "PostsController", "apply_postcondition_of" => "authenticate", "runs_before" => ["index", "show"]}, entries[1])
  end

  def test_skips_block_form
    entries = gen(<<~RUBY)
      class PostsController
        before_action do
          @x = 1
        end

        def show; end
      end
    RUBY

    assert_empty entries
  end

  def test_skips_proc_form
    entries = gen(<<~RUBY)
      class PostsController
        before_action ->(c) { c.foo }

        def show; end
      end
    RUBY

    assert_empty entries
  end

  def test_skips_if_conditional
    entries = gen(<<~RUBY)
      class PostsController
        before_action :authenticate, if: :requires_auth?

        def show; end
      end
    RUBY

    assert_empty entries
  end

  def test_skips_unless_conditional
    entries = gen(<<~RUBY)
      class PostsController
        before_action :authenticate, unless: :skip_auth?

        def show; end
      end
    RUBY

    assert_empty entries
  end

  def test_skips_callback_object_argument
    entries = gen(<<~RUBY)
      class PostsController
        before_action Authenticator.new

        def show; end
      end
    RUBY

    assert_empty entries
  end

  def test_ignores_only_with_unknown_method
    # `only: [:nonexistent]` against a controller with no such action —
    # runs_before resolves to [], entry is dropped.
    entries = gen(<<~RUBY)
      class PostsController
        before_action :set_post, only: [:nonexistent]

        def show; end
      end
    RUBY

    assert_empty entries
  end

  def test_ignores_private_methods
    # Methods after `private` are not actions; they're handlers. Don't
    # include them in runs_before.
    entries = gen(<<~RUBY)
      class PostsController
        before_action :set_post

        def show; end

        private

        def set_post
          @post = Post.find(params[:id])
        end
      end
    RUBY

    assert_equal ["show"], entries.first["runs_before"]
  end

  def test_supports_namespaced_class
    entries = gen(<<~RUBY)
      module Admin
        class UsersController < ApplicationController
          before_action :authorize, only: [:show]

          def show; end
        end
      end
    RUBY

    assert_equal 1, entries.size
    assert_equal "Admin::UsersController", entries.first["class"]
  end

  def test_compound_constant_class_name
    # `class Admin::UsersController` (compound path) in flat form.
    entries = gen(<<~RUBY)
      class Admin::UsersController
        before_action :authorize, only: [:show]

        def show; end
      end
    RUBY

    assert_equal 1, entries.size
    assert_equal "Admin::UsersController", entries.first["class"]
  end

  def test_no_actions_no_entry
    entries = gen(<<~RUBY)
      class PostsController
        before_action :set_post
      end
    RUBY

    assert_empty entries
  end

  def test_skip_before_action_block_form_ignored
    # `skip_before_action { ... }` doesn't make sense semantically but
    # the generator should not crash. Just ignore.
    entries = gen(<<~RUBY)
      class PostsController
        before_action :authenticate
        skip_before_action do
          # weird usage; doesn't actually skip anything in Rails
        end

        def show; end
      end
    RUBY

    assert_equal 1, entries.size
    assert_equal ["show"], entries.first["runs_before"]
  end

  def test_multiple_classes_in_one_file
    entries = gen(<<~RUBY)
      class AController
        before_action :a_handler
        def a_action; end
      end

      class BController
        before_action :b_handler
        def b_action; end
      end
    RUBY

    assert_equal 2, entries.size
    assert_equal "AController", entries[0]["class"]
    assert_equal "BController", entries[1]["class"]
  end

  def test_skip_before_action_for_different_handler_does_not_subtract
    # `skip_before_action :other` shouldn't touch `set_post`'s coverage.
    entries = gen(<<~RUBY)
      class PostsController
        before_action :set_post
        skip_before_action :other_handler, only: [:show]

        def show; end
        def edit; end
      end
    RUBY

    assert_equal 1, entries.size
    assert_equal ["show", "edit"], entries.first["runs_before"]
  end
end
