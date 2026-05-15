require 'test_helper'
require 'active_model'

# Lightweight fixture classes for unit-style coverage of
# `RbsRails::ActiveRecord::Generator#conditional_presence_markers`.
# They don't need a database — the private method only reads
# `validators`, `reflect_on_association`, and `columns`.
class CondPresenceFixtureModel
  class << self
    attr_accessor :test_validators, :test_associations, :test_columns

    def validators
      test_validators || []
    end

    def reflect_on_association(name)
      (test_associations || {})[name]
    end

    def columns
      test_columns || []
    end
  end
end

class CondPresenceFixtureTarget
end

class ConditionalPresenceMarkersTest < Minitest::Test
  Association = Struct.new(:macro, :klass, :polymorphic_flag, :options) do
    def polymorphic?
      polymorphic_flag
    end
  end

  Column = Struct.new(:name, :null, :type)

  def teardown
    CondPresenceFixtureModel.test_validators = nil
    CondPresenceFixtureModel.test_associations = nil
    CondPresenceFixtureModel.test_columns = nil
  end

  def presence_validator(attrs, if_: nil, unless_: nil)
    opts = { attributes: Array(attrs) }
    opts[:if] = if_ if if_
    opts[:unless] = unless_ if unless_
    ::ActiveModel::Validations::PresenceValidator.new(opts)
  end

  def markers
    RbsRails::ActiveRecord::Generator
      .new(CondPresenceFixtureModel)
      .send(:conditional_presence_markers)
  end

  def test_if_symbol_with_optional_belongs_to_emits_validated_as_marker
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:target, if_: :paid?)
    ]
    CondPresenceFixtureModel.test_associations = {
      target: Association.new(:belongs_to, CondPresenceFixtureTarget, false, { optional: true })
    }

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::ValidatedAsPaid
        def target: () -> ::CondPresenceFixtureTarget
      end
    RBS
    assert_equal expected, markers
  end

  def test_unless_symbol_with_nullable_column_emits_validated_unless_marker
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:price, unless_: :free?)
    ]
    CondPresenceFixtureModel.test_columns = [
      Column.new('price', true, :integer)
    ]

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::ValidatedUnlessFree
        def price: () -> ::Integer
      end
    RBS
    assert_equal expected, markers
  end

  def test_multiple_attrs_same_predicate_are_grouped_in_one_marker
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:a, if_: :pred?),
      presence_validator(:b, if_: :pred?)
    ]
    CondPresenceFixtureModel.test_columns = [
      Column.new('a', true, :string),
      Column.new('b', true, :integer)
    ]

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::ValidatedAsPred
        def a: () -> ::String
        def b: () -> ::Integer
      end
    RBS
    assert_equal expected, markers
  end

  def test_distinct_predicates_emit_separate_markers
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:a, if_: :first?),
      presence_validator(:b, unless_: :second?)
    ]
    CondPresenceFixtureModel.test_columns = [
      Column.new('a', true, :string),
      Column.new('b', true, :integer)
    ]

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::ValidatedAsFirst
        def a: () -> ::String
      end

      class ::CondPresenceFixtureModel::ValidatedUnlessSecond
        def b: () -> ::Integer
      end
    RBS
    assert_equal expected, markers
  end

  def test_attrs_on_same_predicate_via_one_validator_call
    # `validates :a, :b, presence: true, if: :pred?` produces one validator
    # whose `attributes` is `[:a, :b]`.
    CondPresenceFixtureModel.test_validators = [
      presence_validator([:a, :b], if_: :pred?)
    ]
    CondPresenceFixtureModel.test_columns = [
      Column.new('a', true, :string),
      Column.new('b', true, :integer)
    ]

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::ValidatedAsPred
        def a: () -> ::String
        def b: () -> ::Integer
      end
    RBS
    assert_equal expected, markers
  end

  def test_proc_condition_is_ignored
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:a, if_: -> { true })
    ]
    CondPresenceFixtureModel.test_columns = [Column.new('a', true, :string)]

    assert_equal '', markers
  end

  def test_string_condition_is_ignored
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:a, if_: "self.foo?")
    ]
    CondPresenceFixtureModel.test_columns = [Column.new('a', true, :string)]

    assert_equal '', markers
  end

  def test_unconditional_presence_validator_is_ignored
    CondPresenceFixtureModel.test_validators = [presence_validator(:a)]
    CondPresenceFixtureModel.test_columns = [Column.new('a', true, :string)]

    assert_equal '', markers
  end

  def test_polymorphic_belongs_to_is_dropped_from_marker
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:target, if_: :foo?)
    ]
    CondPresenceFixtureModel.test_associations = {
      target: Association.new(:belongs_to, nil, true, { optional: true })
    }

    # Polymorphic → no concrete narrow type → no attr in marker → marker dropped.
    assert_equal '', markers
  end

  def test_non_optional_belongs_to_is_dropped_from_marker
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:target, if_: :foo?)
    ]
    CondPresenceFixtureModel.test_associations = {
      target: Association.new(:belongs_to, CondPresenceFixtureTarget, false, {})
    }

    # `belongs_to` without `optional: true` → already non-nil → nothing to narrow.
    assert_equal '', markers
  end

  def test_non_nullable_column_is_dropped_from_marker
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:a, if_: :foo?)
    ]
    CondPresenceFixtureModel.test_columns = [Column.new('a', false, :string)]

    assert_equal '', markers
  end

  def test_unknown_attribute_is_dropped_from_marker
    # Validates an attribute that's neither a column nor an association.
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:virtual, if_: :foo?)
    ]

    assert_equal '', markers
  end

  def test_marker_only_emitted_when_some_attr_is_narrowable
    # Two attrs in the same condition; only one is narrowable.
    CondPresenceFixtureModel.test_validators = [
      presence_validator([:narrow_me, :already_nonnull], if_: :pred?)
    ]
    CondPresenceFixtureModel.test_columns = [
      Column.new('narrow_me', true, :string),
      Column.new('already_nonnull', false, :string)
    ]

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::ValidatedAsPred
        def narrow_me: () -> ::String
      end
    RBS
    assert_equal expected, markers
  end

  def test_no_validators_emits_empty_string
    assert_equal '', markers
  end

  def test_predicate_name_camelization
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:a, if_: :requires_full_payment?)
    ]
    CondPresenceFixtureModel.test_columns = [Column.new('a', true, :string)]

    assert_match(/ValidatedAsRequiresFullPayment\b/, markers)
  end

  def test_predicate_without_trailing_question_mark
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:a, if_: :active)
    ]
    CondPresenceFixtureModel.test_columns = [Column.new('a', true, :string)]

    assert_match(/ValidatedAsActive\b/, markers)
  end

  def test_unless_with_belongs_to
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:target, unless_: :no_transport?)
    ]
    CondPresenceFixtureModel.test_associations = {
      target: Association.new(:belongs_to, CondPresenceFixtureTarget, false, { optional: true })
    }

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::ValidatedUnlessNoTransport
        def target: () -> ::CondPresenceFixtureTarget
      end
    RBS
    assert_equal expected, markers
  end
end
