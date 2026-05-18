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

    NamedAssociation = Struct.new(:name, :macro, :klass, :polymorphic_flag, :options) do
      def polymorphic?
        polymorphic_flag
      end
    end

    def reflect_on_all_associations(macro)
      (test_associations || {}).filter_map do |name, a|
        next unless a.macro == macro
        NamedAssociation.new(name, a.macro, a.klass, a.polymorphic_flag, a.options)
      end
    end

    def columns
      test_columns || []
    end
  end
end

class CondPresenceFixtureTarget
end

# Fixtures for the through-derived marker tests (issue
# felixefelip/rbs_rails#2). Top-level so `Util.module_name` produces the
# bare `ThroughFixtureHost` / `ThroughFixtureTarget` names — nesting them
# inside the test class would produce dotted RBS names.
ThroughReflection = Struct.new(
  :macro, :name, :klass, :options, :through_reflection, :source_reflection
) do
  def polymorphic?; false; end
end

SimpleReflection = Struct.new(:macro, :name, :klass, :polymorphic_flag, :options) do
  def polymorphic?; polymorphic_flag; end
end

class ThroughFixtureTarget
  class << self
    attr_accessor :test_validators, :test_columns, :test_associations

    def validators; test_validators || []; end
    def columns; test_columns || []; end

    def reflect_on_association(name)
      (test_associations || {})[name]
    end

    def reflect_on_all_associations(macro = nil)
      assocs = (test_associations || {}).values
      macro ? assocs.select { |a| a.macro == macro } : assocs
    end
  end
end

class ThroughFixtureHost
  class << self
    attr_accessor :test_associations

    def validators; []; end
    def columns; []; end

    def reflect_on_association(name)
      (test_associations || {})[name]
    end

    def reflect_on_all_associations(macro = nil)
      assocs = (test_associations || {}).values
      macro ? assocs.select { |a| a.macro == macro } : assocs
    end
  end
end

class ThroughFixtureFinalKlass; end

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

  def test_non_optional_belongs_to_is_still_narrowed
    # Under the always-nilable-in-the-model semantics, a non-optional
    # belongs_to has the model getter typed as nilable, so the marker still
    # narrows it back to the non-nilable association class.
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:target, if_: :foo?)
    ]
    CondPresenceFixtureModel.test_associations = {
      target: Association.new(:belongs_to, CondPresenceFixtureTarget, false, {})
    }

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::ValidatedAsFoo
        def target: () -> ::CondPresenceFixtureTarget
      end
    RBS
    assert_equal expected, markers
  end

  def test_non_nullable_column_is_still_narrowed
    # Same as above: even when the column carries `null: false`, the model
    # getter is now nilable and the marker narrows back to the SQL type.
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:a, if_: :foo?)
    ]
    CondPresenceFixtureModel.test_columns = [Column.new('a', false, :string)]

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::ValidatedAsFoo
        def a: () -> ::String
      end
    RBS
    assert_equal expected, markers
  end

  def test_unknown_attribute_is_dropped_from_marker
    # Validates an attribute that's neither a column nor an association.
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:virtual, if_: :foo?)
    ]

    assert_equal '', markers
  end

  def test_marker_only_emitted_when_some_attr_is_narrowable
    # Two attrs in the same condition; only one is narrowable. The
    # non-narrowable cases that remain after the lifecycle change are
    # polymorphic belongs_to and unknown attrs.
    CondPresenceFixtureModel.test_validators = [
      presence_validator([:name, :poly], if_: :pred?)
    ]
    CondPresenceFixtureModel.test_columns = [
      Column.new('name', true, :string)
    ]
    CondPresenceFixtureModel.test_associations = {
      poly: Association.new(:belongs_to, nil, true, { optional: true })
    }

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::ValidatedAsPred
        def name: () -> ::String
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

  # -------------------------------------------------------------------
  # Layer A — Validated marker emission for unconditional presence validations
  # -------------------------------------------------------------------

  def validated_marker
    RbsRails::ActiveRecord::Generator
      .new(CondPresenceFixtureModel)
      .send(:validated_marker)
  end

  def test_validated_marker_emitted_for_unconditional_presence_on_nullable_column
    CondPresenceFixtureModel.test_validators = [presence_validator(:name)]
    CondPresenceFixtureModel.test_columns = [Column.new('name', true, :string)]

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::Validated
        def name: () -> ::String
      end
    RBS
    assert_equal expected, validated_marker
  end

  def test_validated_marker_emitted_for_unconditional_presence_on_optional_belongs_to
    CondPresenceFixtureModel.test_validators = [presence_validator(:target)]
    CondPresenceFixtureModel.test_associations = {
      target: Association.new(:belongs_to, CondPresenceFixtureTarget, false, { optional: true })
    }

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::Validated
        def target: () -> ::CondPresenceFixtureTarget
      end
    RBS
    assert_equal expected, validated_marker
  end

  def test_validated_marker_groups_attrs_across_multiple_unconditional_validators
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:name),
      presence_validator([:email, :token]),
    ]
    CondPresenceFixtureModel.test_columns = [
      Column.new('name', true, :string),
      Column.new('email', true, :string),
      Column.new('token', true, :string),
    ]

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::Validated
        def name: () -> ::String
        def email: () -> ::String
        def token: () -> ::String
      end
    RBS
    assert_equal expected, validated_marker
  end

  def test_validated_marker_skipped_when_only_conditional_presence
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:a, if_: :foo?)
    ]
    CondPresenceFixtureModel.test_columns = [Column.new('a', true, :string)]

    assert_equal '', validated_marker
  end

  def test_validated_marker_skipped_when_only_polymorphic_validator
    # Only narrow_type_for nil-returning cases (polymorphic belongs_to,
    # unknown attr) survive as "non-narrowable" — they keep the marker empty
    # iff no other narrowable attr (column or non-polymorphic association) or
    # id/timestamps exist.
    CondPresenceFixtureModel.test_validators = [presence_validator(:target)]
    CondPresenceFixtureModel.test_associations = {
      target: Association.new(:belongs_to, nil, true, { optional: true })
    }

    assert_equal '', validated_marker
  end

  def test_validated_marker_skipped_when_no_presence_validators
    assert_equal '', validated_marker
  end

  def test_validated_marker_drops_non_narrowable_attrs_but_keeps_emitter_when_at_least_one_works
    CondPresenceFixtureModel.test_validators = [
      presence_validator([:name, :poly])
    ]
    CondPresenceFixtureModel.test_columns = [
      Column.new('name', true, :string),
    ]
    CondPresenceFixtureModel.test_associations = {
      poly: Association.new(:belongs_to, nil, true, { optional: true })
    }

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::Validated
        def name: () -> ::String
      end
    RBS
    assert_equal expected, validated_marker
  end

  def test_validated_marker_includes_id_when_id_column_exists
    CondPresenceFixtureModel.test_columns = [Column.new('id', false, :integer)]

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::Validated
        def id: () -> ::Integer
      end
    RBS
    assert_equal expected, validated_marker
  end

  def test_validated_marker_includes_timestamps_when_columns_exist
    CondPresenceFixtureModel.test_columns = [
      Column.new('id', false, :integer),
      Column.new('created_at', false, :datetime),
      Column.new('updated_at', false, :datetime),
    ]

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::Validated
        def id: () -> ::Integer
        def created_at: () -> ::ActiveSupport::TimeWithZone
        def updated_at: () -> ::ActiveSupport::TimeWithZone
      end
    RBS
    assert_equal expected, validated_marker
  end

  def test_validated_marker_id_and_timestamps_combine_with_presence_attrs
    CondPresenceFixtureModel.test_validators = [presence_validator(:name)]
    CondPresenceFixtureModel.test_columns = [
      Column.new('id', false, :integer),
      Column.new('name', true, :string),
      Column.new('created_at', false, :datetime),
      Column.new('updated_at', false, :datetime),
    ]

    expected = <<~RBS.chomp
      class ::CondPresenceFixtureModel::Validated
        def id: () -> ::Integer
        def name: () -> ::String
        def created_at: () -> ::ActiveSupport::TimeWithZone
        def updated_at: () -> ::ActiveSupport::TimeWithZone
      end
    RBS
    assert_equal expected, validated_marker
  end

  # -------------------------------------------------------------------
  # postcondition_entries — public API for the YAML sidecar
  # -------------------------------------------------------------------

  VALIDATED_METHODS = %w[valid? save save! update update!]

  def postcondition_entries
    RbsRails::ActiveRecord::Generator
      .new(CondPresenceFixtureModel)
      .postcondition_entries
  end

  def test_postcondition_entries_layer_a_emits_one_per_validated_method
    CondPresenceFixtureModel.test_validators = [presence_validator(:name)]
    CondPresenceFixtureModel.test_columns = [Column.new('name', true, :string)]

    expected = VALIDATED_METHODS.map do |m|
      {
        "class" => "CondPresenceFixtureModel",
        "method" => m,
        "when_true" => { "self" => "CondPresenceFixtureModel & CondPresenceFixtureModel::Validated" },
      }
    end
    assert_equal expected, postcondition_entries
  end

  def test_postcondition_entries_layer_b_if_predicate_uses_when_true
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:a, if_: :paid?)
    ]
    CondPresenceFixtureModel.test_columns = [Column.new('a', true, :string)]

    assert_equal(
      [{
        "class" => "CondPresenceFixtureModel",
        "method" => "paid?",
        "when_true" => { "self" => "CondPresenceFixtureModel & CondPresenceFixtureModel::ValidatedAsPaid" },
      }],
      postcondition_entries
    )
  end

  def test_postcondition_entries_layer_b_unless_predicate_uses_when_false
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:a, unless_: :free?)
    ]
    CondPresenceFixtureModel.test_columns = [Column.new('a', true, :string)]

    assert_equal(
      [{
        "class" => "CondPresenceFixtureModel",
        "method" => "free?",
        "when_false" => { "self" => "CondPresenceFixtureModel & CondPresenceFixtureModel::ValidatedUnlessFree" },
      }],
      postcondition_entries
    )
  end

  def test_postcondition_entries_mix_layer_a_and_layer_b
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:name),
      presence_validator(:a, if_: :paid?),
    ]
    CondPresenceFixtureModel.test_columns = [
      Column.new('name', true, :string),
      Column.new('a', true, :string),
    ]

    entries = postcondition_entries
    assert_equal VALIDATED_METHODS.length + 1, entries.length

    layer_a = entries.select { |e| e["when_true"]&.fetch("self") == "CondPresenceFixtureModel & CondPresenceFixtureModel::Validated" }
    assert_equal VALIDATED_METHODS.sort, layer_a.map { |e| e["method"] }.sort

    layer_b = entries.detect { |e| e["method"] == "paid?" }
    assert_equal(
      { "self" => "CondPresenceFixtureModel & CondPresenceFixtureModel::ValidatedAsPaid" },
      layer_b["when_true"]
    )
  end

  def test_postcondition_entries_empty_when_no_validators
    assert_equal [], postcondition_entries
  end

  def test_postcondition_entries_empty_when_only_polymorphic_validators_and_no_id
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:thing),
      presence_validator(:other, if_: :paid?),
    ]
    CondPresenceFixtureModel.test_associations = {
      thing: Association.new(:belongs_to, nil, true, { optional: true }),
      other: Association.new(:belongs_to, nil, true, { optional: true }),
    }

    assert_equal [], postcondition_entries
  end

  def test_postcondition_entries_skip_layer_a_when_only_conditional_validators
    CondPresenceFixtureModel.test_validators = [
      presence_validator(:a, if_: :paid?)
    ]
    CondPresenceFixtureModel.test_columns = [Column.new('a', true, :string)]

    entries = postcondition_entries
    refute(
      entries.any? { |e| VALIDATED_METHODS.include?(e["method"]) },
      "no Validated postconditions when there are no unconditional presence validators"
    )
  end

  # -------------------------------------------------------------------
  # Through-derived markers (issue felixefelip/rbs_rails#2)
  #
  # When this model is a *host* with `has_one :x, through: :y`, and the
  # *target* of `:y` carries a marker that narrows `:x`, the generator
  # mirrors that marker on the host as `MarkerNameViaY` and emits a
  # `via_receiver` sidecar entry.
  # -------------------------------------------------------------------

  def teardown_through_fixtures
    ThroughFixtureTarget.test_validators = nil
    ThroughFixtureTarget.test_columns = nil
    ThroughFixtureTarget.test_associations = nil
    ThroughFixtureHost.test_associations = nil
  end

  # Build a `has_one :source_name, through: :through_name` reflection on the
  # host pointing through `target_klass` to the named source attr.
  # @return ThroughReflection
  def build_through(name:, through_name:, target_klass:, source_name:)
    through_ref = SimpleReflection.new(:belongs_to, through_name, target_klass, false, {})
    source_ref  = SimpleReflection.new(:belongs_to, source_name, nil, false, {})
    ThroughReflection.new(:has_one, name, ThroughFixtureFinalKlass, { through: through_name }, through_ref, source_ref)
  end

  def host_generator
    RbsRails::ActiveRecord::Generator.new(ThroughFixtureHost)
  end

  def through_derived_markers
    host_generator.send(:through_derived_markers)
  end

  def host_postcondition_entries
    host_generator.postcondition_entries
  end

  def test_through_derived_marker_for_conditional_target_marker
    ThroughFixtureTarget.test_validators = [
      presence_validator(:logistics_operator, if_: :shipment?)
    ]
    ThroughFixtureTarget.test_associations = {
      logistics_operator: Association.new(:belongs_to, ThroughFixtureFinalKlass, false, { optional: true })
    }
    ThroughFixtureHost.test_associations = {
      logistics_operator: build_through(
        name: :logistics_operator,
        through_name: :order_import,
        target_klass: ThroughFixtureTarget,
        source_name: :logistics_operator
      )
    }

    expected = <<~RBS.chomp
      class ::ThroughFixtureHost::ValidatedAsShipmentViaOrderImport
        def logistics_operator: () -> ::ThroughFixtureFinalKlass
      end
    RBS
    assert_equal expected, through_derived_markers
  ensure
    teardown_through_fixtures
  end

  def test_through_postcondition_entries_attach_via_receiver_for_target_predicate
    ThroughFixtureTarget.test_validators = [
      presence_validator(:logistics_operator, if_: :shipment?)
    ]
    ThroughFixtureTarget.test_associations = {
      logistics_operator: Association.new(:belongs_to, ThroughFixtureFinalKlass, false, { optional: true })
    }
    ThroughFixtureHost.test_associations = {
      logistics_operator: build_through(
        name: :logistics_operator,
        through_name: :order_import,
        target_klass: ThroughFixtureTarget,
        source_name: :logistics_operator
      )
    }

    entries = host_postcondition_entries
    via_entry = entries.detect { |e| e["class"] == "ThroughFixtureTarget" && e["method"] == "shipment?" }

    refute_nil via_entry, "expected a via_receiver entry keyed on the target predicate"
    assert_equal(
      {
        "via_receiver" => [
          {
            "through" => "ThroughFixtureHost#order_import",
            "as" => "ThroughFixtureHost & ThroughFixtureHost::ValidatedAsShipmentViaOrderImport",
          }
        ]
      },
      via_entry["when_true"]
    )
  ensure
    teardown_through_fixtures
  end

  def test_through_derived_marker_for_unconditional_validated_marker
    # Target has an unconditional presence validator on the source attr → it
    # contributes a `Validated` marker. The derived marker is `ValidatedViaY`
    # and is triggered by the standard valid?/save/update set.
    ThroughFixtureTarget.test_validators = [
      presence_validator(:logistics_operator)
    ]
    ThroughFixtureTarget.test_associations = {
      logistics_operator: Association.new(:belongs_to, ThroughFixtureFinalKlass, false, { optional: true })
    }
    ThroughFixtureHost.test_associations = {
      logistics_operator: build_through(
        name: :logistics_operator,
        through_name: :order_import,
        target_klass: ThroughFixtureTarget,
        source_name: :logistics_operator
      )
    }

    expected = <<~RBS.chomp
      class ::ThroughFixtureHost::ValidatedViaOrderImport
        def logistics_operator: () -> ::ThroughFixtureFinalKlass
      end
    RBS
    assert_equal expected, through_derived_markers

    entries = host_postcondition_entries.select { |e| e["class"] == "ThroughFixtureTarget" }
    methods = entries.map { |e| e["method"] }.sort
    assert_equal %w[save save! update update! valid?], methods
    entries.each do |entry|
      assert_equal(
        [{
          "through" => "ThroughFixtureHost#order_import",
          "as" => "ThroughFixtureHost & ThroughFixtureHost::ValidatedViaOrderImport",
        }],
        entry["when_true"]["via_receiver"]
      )
    end
  ensure
    teardown_through_fixtures
  end

  def test_through_unless_predicate_uses_when_false_branch
    ThroughFixtureTarget.test_validators = [
      presence_validator(:logistics_operator, unless_: :no_shipment?)
    ]
    ThroughFixtureTarget.test_associations = {
      logistics_operator: Association.new(:belongs_to, ThroughFixtureFinalKlass, false, { optional: true })
    }
    ThroughFixtureHost.test_associations = {
      logistics_operator: build_through(
        name: :logistics_operator,
        through_name: :order_import,
        target_klass: ThroughFixtureTarget,
        source_name: :logistics_operator
      )
    }

    entry = host_postcondition_entries.detect { |e| e["method"] == "no_shipment?" }
    refute_nil entry
    assert_nil entry["when_true"]
    refute_nil entry["when_false"]
  ensure
    teardown_through_fixtures
  end

  def test_through_marker_empty_when_target_has_no_narrowing_on_source
    # Target has a presence validator, but on a *different* attr — no
    # narrowing for the source attr → no derived marker on the host.
    ThroughFixtureTarget.test_validators = [
      presence_validator(:other_field, if_: :shipment?)
    ]
    ThroughFixtureTarget.test_columns = [Column.new('other_field', true, :string)]
    ThroughFixtureHost.test_associations = {
      logistics_operator: build_through(
        name: :logistics_operator,
        through_name: :order_import,
        target_klass: ThroughFixtureTarget,
        source_name: :logistics_operator
      )
    }

    assert_equal '', through_derived_markers
    assert_empty host_postcondition_entries.select { |e| e["class"] == "ThroughFixtureTarget" }
  ensure
    teardown_through_fixtures
  end

  def test_through_marker_skipped_when_target_has_no_markers
    # Target has no validators → no markers → nothing for the host to derive.
    ThroughFixtureHost.test_associations = {
      logistics_operator: build_through(
        name: :logistics_operator,
        through_name: :order_import,
        target_klass: ThroughFixtureTarget,
        source_name: :logistics_operator
      )
    }

    assert_equal '', through_derived_markers
    assert_empty host_postcondition_entries
  ensure
    teardown_through_fixtures
  end

  def test_no_through_associations_emits_empty_string
    ThroughFixtureHost.test_associations = {}

    assert_equal '', through_derived_markers
  ensure
    teardown_through_fixtures
  end

  def test_has_many_through_is_ignored
    # Has-many through has no single-receiver `via_receiver` chain (the
    # intermediate is a CollectionProxy), so the generator skips it.
    ThroughFixtureTarget.test_validators = [
      presence_validator(:logistics_operator, if_: :shipment?)
    ]
    ThroughFixtureTarget.test_associations = {
      logistics_operator: Association.new(:belongs_to, ThroughFixtureFinalKlass, false, { optional: true })
    }
    refl = build_through(
      name: :logistics_operators,
      through_name: :order_imports,
      target_klass: ThroughFixtureTarget,
      source_name: :logistics_operator
    )
    # Force the macro to has_many — the generator should skip.
    has_many_refl = ThroughReflection.new(
      :has_many, refl.name, refl.klass, refl.options, refl.through_reflection, refl.source_reflection
    )
    ThroughFixtureHost.test_associations = { logistics_operators: has_many_refl }

    assert_equal '', through_derived_markers
  ensure
    teardown_through_fixtures
  end

  def test_nested_through_is_skipped
    # When the through reflection is itself a `through:` (multi-hop), the
    # generator skips. Steep Phase 2's `via_receiver` only handles a single
    # hop; nested would need Phase 3+.
    ThroughFixtureTarget.test_validators = [
      presence_validator(:logistics_operator, if_: :shipment?)
    ]
    ThroughFixtureTarget.test_associations = {
      logistics_operator: Association.new(:belongs_to, ThroughFixtureFinalKlass, false, { optional: true })
    }
    nested_through = SimpleReflection.new(:has_one, :order_import, ThroughFixtureTarget, false, { through: :something_else })
    source_ref = SimpleReflection.new(:belongs_to, :logistics_operator, nil, false, {})
    refl = ThroughReflection.new(:has_one, :logistics_operator, ThroughFixtureFinalKlass, { through: :order_import }, nested_through, source_ref)
    ThroughFixtureHost.test_associations = { logistics_operator: refl }

    assert_equal '', through_derived_markers
  ensure
    teardown_through_fixtures
  end

  def test_multiple_sources_via_same_through_assoc_share_one_derived_marker
    # Target has two attrs narrowed by the same marker (ValidatedAsShipment
    # via if: :shipment?). Host has two through-assocs that share the same
    # `through:`. Both narrowed decls land in the same Via* class.
    ThroughFixtureTarget.test_validators = [
      presence_validator([:logistics_operator, :carrier], if_: :shipment?)
    ]
    ThroughFixtureTarget.test_associations = {
      logistics_operator: Association.new(:belongs_to, ThroughFixtureFinalKlass, false, { optional: true }),
      carrier: Association.new(:belongs_to, ThroughFixtureFinalKlass, false, { optional: true }),
    }
    ThroughFixtureHost.test_associations = {
      logistics_operator: build_through(
        name: :logistics_operator,
        through_name: :order_import,
        target_klass: ThroughFixtureTarget,
        source_name: :logistics_operator
      ),
      carrier: build_through(
        name: :carrier,
        through_name: :order_import,
        target_klass: ThroughFixtureTarget,
        source_name: :carrier
      ),
    }

    expected = <<~RBS.chomp
      class ::ThroughFixtureHost::ValidatedAsShipmentViaOrderImport
        def logistics_operator: () -> ::ThroughFixtureFinalKlass
        def carrier: () -> ::ThroughFixtureFinalKlass
      end
    RBS
    assert_equal expected, through_derived_markers

    via_entries = host_postcondition_entries.select { |e| e["class"] == "ThroughFixtureTarget" && e["method"] == "shipment?" }
    assert_equal 1, via_entries.size, "the host should emit a single entry per (target, predicate); the via_receiver array stays single-element here"
  ensure
    teardown_through_fixtures
  end
end
