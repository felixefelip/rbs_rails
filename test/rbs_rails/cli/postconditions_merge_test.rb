require 'test_helper'
require 'rbs_rails/cli'

# Tightly-scoped tests for `CLI#merge_postcondition_entries`. The merge
# collapses duplicate (class, method) entries so a target's `self:` from
# its own generator and any number of `via_receiver:` entries from host
# generators (issue felixefelip/rbs_rails#2) end up as a single sidecar
# entry per predicate.
class PostconditionsMergeTest < Minitest::Test
  def merge(entries)
    RbsRails::CLI.new.send(:merge_postcondition_entries, entries)
  end

  def test_passes_through_single_entry
    entries = [
      { "class" => "Foo", "method" => "valid?",
        "when_true" => { "self" => "Foo & Foo::Validated" } }
    ]
    assert_equal entries, merge(entries)
  end

  def test_combines_self_and_via_receiver_for_same_key
    entries = [
      { "class" => "OrderImport", "method" => "shipment?",
        "when_true" => { "self" => "OrderImport & OrderImport::ValidatedAsShipment" } },
      { "class" => "OrderImport", "method" => "shipment?",
        "when_true" => { "via_receiver" => [{ "through" => "Order#order_import",
                                              "as" => "Order & Order::ValidatedAsShipmentViaOrderImport" }] } }
    ]

    assert_equal(
      [{
        "class" => "OrderImport", "method" => "shipment?",
        "when_true" => {
          "self" => "OrderImport & OrderImport::ValidatedAsShipment",
          "via_receiver" => [
            { "through" => "Order#order_import",
              "as" => "Order & Order::ValidatedAsShipmentViaOrderImport" }
          ]
        }
      }],
      merge(entries)
    )
  end

  def test_concats_via_receiver_from_multiple_hosts
    entries = [
      { "class" => "Inner", "method" => "ready?",
        "when_true" => { "self" => "Inner & Inner::Ready" } },
      { "class" => "Inner", "method" => "ready?",
        "when_true" => { "via_receiver" => [{ "through" => "HostA#inner",
                                              "as" => "HostA & HostA::WithReady" }] } },
      { "class" => "Inner", "method" => "ready?",
        "when_true" => { "via_receiver" => [{ "through" => "HostB#inner",
                                              "as" => "HostB & HostB::WithReady" }] } }
    ]

    merged = merge(entries)
    assert_equal 1, merged.size
    assert_equal "Inner & Inner::Ready", merged[0]["when_true"]["self"]
    assert_equal(
      [
        { "through" => "HostA#inner", "as" => "HostA & HostA::WithReady" },
        { "through" => "HostB#inner", "as" => "HostB & HostB::WithReady" },
      ],
      merged[0]["when_true"]["via_receiver"]
    )
  end

  def test_sorts_via_receiver_for_stable_output
    entries = [
      { "class" => "Inner", "method" => "ready?",
        "when_true" => { "via_receiver" => [{ "through" => "HostB#inner", "as" => "HostB & HostB::W" }] } },
      { "class" => "Inner", "method" => "ready?",
        "when_true" => { "via_receiver" => [{ "through" => "HostA#inner", "as" => "HostA & HostA::W" }] } }
    ]

    merged = merge(entries)
    assert_equal(
      %w[HostA#inner HostB#inner],
      merged[0]["when_true"]["via_receiver"].map { |v| v["through"] }
    )
  end

  def test_deduplicates_identical_via_receivers
    same = { "through" => "Order#order_import",
             "as" => "Order & Order::ValidatedAsShipmentViaOrderImport" }
    entries = [
      { "class" => "OrderImport", "method" => "shipment?",
        "when_true" => { "via_receiver" => [same] } },
      { "class" => "OrderImport", "method" => "shipment?",
        "when_true" => { "via_receiver" => [same] } }
    ]
    merged = merge(entries)
    assert_equal [same], merged[0]["when_true"]["via_receiver"]
  end

  def test_separate_branches_kept_independent
    entries = [
      { "class" => "Inner", "method" => "fail?",
        "when_true" => { "self" => "Inner & Inner::Failed" } },
      { "class" => "Inner", "method" => "fail?",
        "when_false" => { "via_receiver" => [{ "through" => "Outer#inner",
                                               "as" => "Outer & Outer::WhenNotFail" }] } }
    ]

    merged = merge(entries)
    assert_equal 1, merged.size
    assert_equal "Inner & Inner::Failed", merged[0]["when_true"]["self"]
    assert_equal(
      [{ "through" => "Outer#inner", "as" => "Outer & Outer::WhenNotFail" }],
      merged[0]["when_false"]["via_receiver"]
    )
  end

  def test_different_keys_stay_separate
    entries = [
      { "class" => "A", "method" => "x?",
        "when_true" => { "self" => "A & A::M" } },
      { "class" => "B", "method" => "y?",
        "when_true" => { "self" => "B & B::N" } }
    ]
    assert_equal 2, merge(entries).size
  end

  def test_first_self_wins_when_duplicated
    # Two generators emitting a `self:` for the same key is not expected
    # (the target's own generator is the only source), but if it happens
    # the first one is kept and the second is silently dropped.
    entries = [
      { "class" => "Dup", "method" => "ok?",
        "when_true" => { "self" => "Dup & Dup::First" } },
      { "class" => "Dup", "method" => "ok?",
        "when_true" => { "self" => "Dup & Dup::Second" } }
    ]

    merged = merge(entries)
    assert_equal "Dup & Dup::First", merged[0]["when_true"]["self"]
  end
end
