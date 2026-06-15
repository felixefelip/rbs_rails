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

  def test_collects_all_post_validation_lifecycle_callbacks
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        after_validation :a
        before_save :b
        before_create :c
        before_update :d
        after_save :e
        after_create :f
        after_update :g
        after_commit :h
      end
    RUBY

    assert_equal [:a, :b, :c, :d, :e, :f, :g, :h], result["Foo"].sort
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

  # An `if:`/`unless:` condition only gates whether the callback runs, never
  # moving it before validation — so a handler that runs is still
  # post-validation and IS collected (felixefelip/rbs_rails: e.g. Card's
  # `after_update :handle_board_change, if: :saved_change_to_board_id?`).
  def test_collects_conditional_if
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        after_save :a, if: :ready?
      end
    RUBY

    assert_equal [:a], result["Foo"]
  end

  def test_collects_conditional_unless
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        after_save :a, unless: :skip?
      end
    RUBY

    assert_equal [:a], result["Foo"]
  end

  # A Proc/lambda CONDITION is fine — only a Proc/lambda HANDLER can't be
  # translated. The Symbol handler is still collected.
  def test_collects_conditional_with_proc_condition
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        after_update :a, if: -> { ready? }
      end
    RUBY

    assert_equal [:a], result["Foo"]
  end

  # The conditional handler still gets its transitive self-call closure
  # narrowed, mirroring Card#handle_board_change -> track_board_change_event.
  def test_collects_conditional_handler_with_self_call_closure
    result = by_class(<<~RUBY)
      class Card < ApplicationRecord
        after_update :handle_board_change, if: :saved_change_to_board_id?

        def handle_board_change
          track_board_change_event
        end

        def track_board_change_event
          board.name
        end
      end
    RUBY

    assert_equal [:handle_board_change, :track_board_change_event], result["Card"].sort
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

  def test_collects_before_save_family_but_ignores_before_validation_and_destroy
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        before_validation :normalize
        before_save :prepare
        after_destroy :cleanup
      end
    RUBY

    # before_save runs post-validation → collected; before_validation runs
    # pre-validation and after_destroy doesn't establish the invariant → ignored.
    assert_equal [:prepare], result["Foo"]
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

  def test_includes_transitively_called_helper_methods
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        before_save :calcular

        def calcular
          status = if done?
            :a
          else
            :b
          end
        end

        def done?
          qtde >= total
        end

        def qtde
          caderneta.qtde_por_vacina(vacina)
        end

        def total
          vacina.count
        end
      end
    RUBY

    # calcular -> done? -> qtde, total. caderneta/vacina/qtde_por_vacina/count
    # are not methods of Foo, so they are not followed.
    assert_equal [:calcular, :done?, :qtde, :total], result["Foo"].sort
  end

  def test_follows_calls_through_safe_navigation_and_handles_cycles
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        after_save :a

        def a
          b&.to_s
          recurse
        end

        def b
          recurse
        end

        def recurse
          a
        end
      end
    RUBY

    # `b&.to_s` follows the receiver-less `b`; the a/recurse cycle terminates.
    assert_equal [:a, :b, :recurse], result["Foo"].sort
  end

  def test_follows_self_calls_but_not_other_receivers
    result = by_class(<<~RUBY)
      class Foo < ApplicationRecord
        before_save :calcular

        def calcular
          self.explicit   # explicit self → followed
          implicit         # receiver-less → followed
          vacina.count     # other receiver → not followed
          Foo.helper       # class method → not followed
        end

        def explicit; end

        def implicit; end

        def self.helper; end
      end
    RUBY

    # Both self.explicit and implicit are followed; vacina.* and Foo.* are not.
    assert_equal [:calcular, :explicit, :implicit], result["Foo"].sort
  end
end
