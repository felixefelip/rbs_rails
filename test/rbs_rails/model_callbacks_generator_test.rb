require 'test_helper'

# Unit tests for `RbsRails::ModelCallbacksGenerator` — parses a model source
# string and extracts after-validation lifecycle callback handler methods,
# keyed by class name, for the `applies_self` entries of
# `.steep_callbacks.yml`.
class ModelCallbacksGeneratorTest < Minitest::Test
  Generator = RbsRails::ModelCallbacksGenerator

  def by_class(source, host: nil)
    Generator.new(source: source, host: host).callbacks_by_class
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
        after_create_commit :i
        after_update_commit :j
        after_save_commit :k
      end
    RUBY

    assert_equal [:a, :b, :c, :d, :e, :f, :g, :h, :i, :j, :k], result["Foo"].sort
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

  # --- callbacks declared in a concern's `included do` ----------------------
  #
  # The dominant Rails shape: the macro runs on the HOST, the handler is
  # type-checked in the CONCERN, so the entry has to be keyed by the concern.

  def test_collects_callbacks_from_a_concern_included_block
    result = by_class(<<~RUBY, host: "User")
      module User::Accessor
        extend ActiveSupport::Concern

        included do
          has_many :accesses
          after_create_commit :grant_access_to_boards, unless: :system?
        end

        private
          def grant_access_to_boards
            account.boards
          end
      end
    RUBY

    assert_equal({ "User::Accessor" => [:grant_access_to_boards] }, result)
  end

  def test_follows_the_self_call_closure_across_the_concern_body
    result = by_class(<<~RUBY, host: "User")
      module Searchable
        extend ActiveSupport::Concern

        included do
          after_create_commit :create_in_search_index
        end

        def create_in_search_index
          search_record_class.create!(search_record_attributes)
        end

        def search_record_attributes
          { account_id: account.id }
        end

        def search_record_class
          Search::Record
        end
      end
    RUBY

    assert_equal [:create_in_search_index, :search_record_attributes, :search_record_class],
                 result["Searchable"].sort
  end

  # A def written inside `included do` is `class_eval`d on the includer, so it
  # is checked in the HOST's scope, not the concern's.
  def test_keys_a_def_inside_included_do_by_the_host
    result = by_class(<<~RUBY, host: "User")
      module User::Accessor
        extend ActiveSupport::Concern

        included do
          after_create_commit :grant_access

          def grant_access
            account.boards
          end
        end
      end
    RUBY

    assert_equal({ "User" => [:grant_access] }, result)
  end

  # Without a host there is no sound key for such a def — better absent than
  # attributed to the concern, where nothing of that name is checked.
  def test_skips_an_included_do_def_when_no_host_is_given
    result = by_class(<<~RUBY)
      module User::Accessor
        extend ActiveSupport::Concern

        included do
          after_create_commit :grant_access

          def grant_access; end
        end
      end
    RUBY

    assert_equal({}, result)
  end

  # A handler with no def in the file (an association writer such as the
  # `create_settings` of `has_one :settings`) still lands under the scope: the
  # entry is inert, since nothing is checked under that name.
  def test_keeps_a_handler_with_no_visible_def
    result = by_class(<<~RUBY, host: "User")
      module User::Configurable
        extend ActiveSupport::Concern

        included do
          has_one :settings
          after_create :create_settings, unless: :system?
        end
      end
    RUBY

    assert_equal({ "User::Configurable" => [:create_settings] }, result)
  end

  def test_ignores_a_concern_with_no_lifecycle_callback
    result = by_class(<<~RUBY, host: "User")
      module User::Named
        extend ActiveSupport::Concern

        included do
          has_many :things
        end

        def display_name
          name
        end
      end
    RUBY

    assert_equal({}, result)
  end

  def test_keys_a_nested_class_in_a_concern_file_by_its_own_name
    result = by_class(<<~RUBY, host: "User")
      module User::Configurable
        extend ActiveSupport::Concern

        included do
          after_create :create_settings
        end

        class Settings < ApplicationRecord
          after_save :flush

          def flush; end
        end
      end
    RUBY

    assert_equal({ "User::Configurable" => [:create_settings],
                   "User::Configurable::Settings" => [:flush] }, result)
  end
  # `callbacks_across` — one closure over a model's whole corpus (its own file
  # plus each concern in its ancestry), which is what lets a callback declared
  # in the model reach a handler defined in a concern.

  def across(sources, host:)
    Generator.callbacks_across(sources, host: host)
  end

  CARD = <<~RUBY
    class Card < ApplicationRecord
      after_update :handle_board_change, if: :saved_change_to_board_id?

      private
        def handle_board_change
          track_board_change_event
          clean_inaccessible_data_later
        end

        def track_board_change_event; end
    end
  RUBY

  CARD_ACCESSIBLE = <<~RUBY
    module Card::Accessible
      extend ActiveSupport::Concern

      def clean_inaccessible_data; end

      private
        def clean_inaccessible_data_later
          Card::CleanInaccessibleDataJob.perform_later(self)
        end
    end
  RUBY

  def test_closure_reaches_a_handler_defined_in_a_concern
    result = across([["Card", CARD, "card.rb"],
                     ["Card::Accessible", CARD_ACCESSIBLE, "card/accessible.rb"]],
                    host: "Card")

    assert_equal({ "Card" => [:handle_board_change, :track_board_change_event],
                   "Card::Accessible" => [:clean_inaccessible_data_later] }, result)
  end

  # Only what the callback reaches: a public method of the concern nothing in
  # the closure calls keeps its declared `self`.
  def test_closure_leaves_unreached_concern_methods_alone
    result = across([["Card", CARD, "card.rb"],
                     ["Card::Accessible", CARD_ACCESSIBLE, "card/accessible.rb"]],
                    host: "Card")

    refute_includes result.fetch("Card::Accessible"), :clean_inaccessible_data
  end

  # The reverse direction: a callback declared in a concern's `included do`
  # reaching a helper defined on the model itself.
  def test_closure_reaches_the_model_from_a_concern_declared_callback
    concern = <<~RUBY
      module Card::Stallable
        extend ActiveSupport::Concern

        included do
          after_update_commit :detect_activity_spikes_later
        end

        private
          def detect_activity_spikes_later
            note_spike
          end
      end
    RUBY
    model = <<~RUBY
      class Card < ApplicationRecord
        private
          def note_spike; end
      end
    RUBY

    result = across([["Card", model, "card.rb"],
                     ["Card::Stallable", concern, "card/stallable.rb"]],
                    host: "Card")

    assert_equal({ "Card::Stallable" => [:detect_activity_spikes_later],
                   "Card" => [:note_spike] }, result)
  end

  # Another class sharing a concern's file answers to its own generator, so it
  # must not feed this model's closure.
  def test_reads_only_the_model_and_the_scope_the_file_was_opened_for
    concern = <<~RUBY
      module Card::Accessible
        extend ActiveSupport::Concern

        private
          def clean_inaccessible_data_later; end
      end

      class Unrelated < ApplicationRecord
        after_save :handle_board_change

        def handle_board_change; end
      end
    RUBY

    result = across([["Card", CARD, "card.rb"],
                     ["Card::Accessible", concern, "card/accessible.rb"]],
                    host: "Card")

    refute_includes result.keys, "Unrelated"
    assert_equal [:clean_inaccessible_data_later], result.fetch("Card::Accessible")
  end

  # First definition wins across files, which is Ruby's own resolution given
  # the sources in method-resolution order (the model, then its ancestors).
  def test_the_model_own_def_wins_over_a_concern_of_the_same_name
    concern = <<~RUBY
      module Card::Accessible
        extend ActiveSupport::Concern

        private
          def track_board_change_event; end
      end
    RUBY

    result = across([["Card", CARD, "card.rb"],
                     ["Card::Accessible", concern, "card/accessible.rb"]],
                    host: "Card")

    assert_equal [:handle_board_change, :track_board_change_event], result.fetch("Card")
    refute result.key?("Card::Accessible")
  end

  # A handler with no def anywhere still lands under the scope that DECLARED
  # it, as it does when a single file is read.
  def test_a_handler_with_no_def_is_filed_under_its_declaring_scope
    model = <<~RUBY
      class Card < ApplicationRecord
        after_create :create_settings
      end
    RUBY

    result = across([["Card", model, "card.rb"]], host: "Card")

    assert_equal({ "Card" => [:create_settings] }, result)
  end
end
