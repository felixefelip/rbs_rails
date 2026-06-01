require 'test_helper'

# Unit tests for `RbsRails::ModelCallbacksGenerator` — parses a model source
# string and extracts after-validation lifecycle callback handler methods,
# keyed by class name, for the `applies_self` entries of
# `.steep_callbacks.yml`.
class ModelCallbacksGeneratorTest < Minitest::Test
  Generator = RbsRails::ModelCallbacksGenerator

  def by_class(source)
    Generator.new(source: source).callbacks_by_class
  end

  def test_collects_after_save_symbol_handler
    result = by_class(<<~RUBY)
      class Dose < ApplicationRecord
        after_save :atualizar_calendario

        def atualizar_calendario; end
      end
    RUBY

    assert_equal({ "Dose" => [:atualizar_calendario] }, result)
  end

  def test_collects_all_after_validation_lifecycle_callbacks
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        after_validation :a
        after_create :b
        after_update :c
        after_commit :d
        after_save :e
      end
    RUBY

    assert_equal [:a, :b, :c, :d, :e], result["Foo"].sort
  end

  def test_collects_multiple_symbol_handlers_in_one_call
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        after_save :a, :b
      end
    RUBY

    assert_equal [:a, :b], result["Foo"]
  end

  def test_accepts_on_option
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        after_commit :notify, on: :create
      end
    RUBY

    assert_equal [:notify], result["Foo"]
  end

  def test_skips_conditional_if
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        after_save :a, if: :ready?
      end
    RUBY

    assert_empty result
  end

  def test_skips_conditional_unless
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        after_save :a, unless: :skip?
      end
    RUBY

    assert_empty result
  end

  def test_skips_block_handler
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        after_save { do_something }
      end
    RUBY

    assert_empty result
  end

  def test_skips_proc_handler
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        after_save ->(record) { record.touch }
      end
    RUBY

    assert_empty result
  end

  def test_ignores_before_validation_and_destroy_callbacks
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        before_validation :normalize
        before_save :prepare
        after_destroy :cleanup
      end
    RUBY

    assert_empty result
  end

  def test_handles_namespaced_and_nested_classes
    result = by_class(<<~RUBY)
      class Admin::Account < ApplicationRecord
        after_save :sync
      end

      module Billing
        class Invoice < ApplicationRecord
          after_create :issue
        end
      end
    RUBY

    assert_equal [:sync], result["Admin::Account"]
    assert_equal [:issue], result["Billing::Invoice"]
  end

  def test_empty_when_no_callbacks
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        def bar; end
      end
    RUBY

    assert_empty result
  end
end
