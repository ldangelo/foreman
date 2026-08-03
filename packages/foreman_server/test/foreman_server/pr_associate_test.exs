defmodule ForemanServer.PrAssociateTest do
  use ExUnit.Case, async: true

  alias ForemanServer.PrAssociate

  describe "extract_pr_number/1" do
    test "extracts PR number from standard GitHub PR URL" do
      assert PrAssociate.extract_pr_number("https://github.com/owner/repo/pull/42") == 42
    end

    test "extracts PR number from PR URL with trailing path" do
      assert PrAssociate.extract_pr_number("https://github.com/owner/repo/pull/123/files") == 123
    end

    test "extracts PR number from PR URL with trailing fragment" do
      assert PrAssociate.extract_pr_number("https://github.com/owner/repo/pull/7#discussion") == 7
    end

    test "returns nil for non-PR URLs" do
      assert PrAssociate.extract_pr_number("https://github.com/owner/repo") == nil
    end

    test "returns nil for empty string" do
      assert PrAssociate.extract_pr_number("") == nil
    end

    test "returns nil for non-binary input" do
      assert PrAssociate.extract_pr_number(nil) == nil
      assert PrAssociate.extract_pr_number(123) == nil
    end
  end

  describe "store/2 — input validation" do
    test "returns error for non-binary run_id" do
      assert {:error, :invalid_arguments} = PrAssociate.store(nil, "https://github.com/o/r/pull/1")
      assert {:error, :invalid_arguments} = PrAssociate.store(123, "https://github.com/o/r/pull/1")
    end

    test "returns error for non-binary pr_url" do
      assert {:error, :invalid_arguments} = PrAssociate.store("run-x", nil)
      assert {:error, :invalid_arguments} = PrAssociate.store("run-x", 123)
    end

    test "returns error for empty run_id" do
      assert {:error, :invalid_run_id} = PrAssociate.store("", "https://github.com/o/r/pull/1")
    end

    test "returns error for empty pr_url" do
      assert {:error, :invalid_pr_url} = PrAssociate.store("run-y", "")
    end

    test "returns error for pr_url without scheme" do
      assert {:error, :invalid_pr_url} = PrAssociate.store("run-z", "github.com/o/r/pull/1")
    end
  end

  describe "lookup/1" do
    test "returns :not_found for non-binary input" do
      assert PrAssociate.lookup(nil) == {:error, :not_found}
      assert PrAssociate.lookup(123) == {:error, :not_found}
    end

    test "returns :not_found for unknown run_id (delegates to ProjectionStore)" do
      assert {:error, :not_found} = PrAssociate.lookup("nonexistent-run")
    end
  end
end
