defmodule Workflow.JSONPointerTest do
  use ExUnit.Case, async: true

  alias Workflow.JSONPointer

  test "validates and decodes RFC 6901 pointers" do
    assert JSONPointer.valid?("")
    assert JSONPointer.valid?("/")
    assert JSONPointer.valid?("/a~1b/~0key")
    refute JSONPointer.valid?("a")
    refute JSONPointer.valid?("/~2")
    refute JSONPointer.valid?(<<"/", 255>>)
    refute JSONPointer.valid?(:not_a_string)

    assert {:ok, "a/b~c"} = JSONPointer.decode_token("a~1b~0c")
    assert {:ok, "~1"} = JSONPointer.decode_token("~01")
    assert {:error, :invalid_escape} = JSONPointer.decode_token("~2")
  end

  test "resolves nested values and distinguishes missing from present nil" do
    json = %{"a/b" => %{"~key" => [nil, %{"value" => false}]}, "" => "empty key"}

    assert {:present, ^json} = JSONPointer.resolve(json, "")
    assert {:present, "empty key"} = JSONPointer.resolve(json, "/")
    assert {:present, nil} = JSONPointer.resolve(json, "/a~1b/~0key/0")
    assert {:present, false} = JSONPointer.resolve(json, "/a~1b/~0key/1/value")
    assert :missing = JSONPointer.resolve(json, "/a~1b/~0key/2")
    assert :missing = JSONPointer.resolve(json, "/~2")
  end

  test "list positions must be canonical unsigned decimal indexes" do
    list = ["zero", "one"]

    assert JSONPointer.canonical_index?("0")
    assert JSONPointer.canonical_index?("10")
    refute JSONPointer.canonical_index?("01")
    refute JSONPointer.canonical_index?("+1")
    refute JSONPointer.canonical_index?("-0")

    assert {:present, "one"} = JSONPointer.resolve(list, "/1")
    assert :missing = JSONPointer.resolve(list, "/01")
    assert :missing = JSONPointer.resolve(list, "/+1")
    assert :missing = JSONPointer.resolve(list, "/-0")
  end

  test "string keys take precedence and atom compatibility is optional" do
    json = %{"value" => "string", value: false, fallback: nil}

    assert {:present, "string"} = JSONPointer.resolve(json, "/value")
    assert {:present, nil} = JSONPointer.resolve(json, "/fallback")
    assert :missing = JSONPointer.resolve(json, "/fallback", atom_keys: false)
  end
end
