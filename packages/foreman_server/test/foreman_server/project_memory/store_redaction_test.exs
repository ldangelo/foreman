defmodule ForemanServer.ProjectMemory.StoreRedactionTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias ForemanServer.Identity
  alias ForemanServer.ProjectMemory.Store

  test "secrets never reach disk; benign text is untouched; sha is of the redacted bytes",
       %{tmp_dir: dir} do
    content = """
    We deploy with the Makefile. Run `mix test --warnings-as-errors` before pushing.
    Authorization: Bearer abc.def.ghi
    API_KEY=sk-live-123
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEAxyz
    -----END RSA PRIVATE KEY-----
    The staging password is hunter2-unique and stays private.
    """

    assert {:ok, entry} =
             Store.write(dir, ["hunter2-unique"], %{
               name: "deploy",
               description: "d",
               content: content
             })

    disk = File.read!(Path.join(dir, ".foreman/memory/deploy.md"))

    for secret <- ["abc.def.ghi", "sk-live-123", "MIIEowIBAAKCAQEAxyz", "hunter2-unique"],
        do: refute(disk =~ secret)

    assert disk =~ "[REDACTED]"
    assert disk =~ "Run `mix test --warnings-as-errors` before pushing."
    assert entry.redactions >= 4
    assert entry.sha256 == Identity.sha256(disk)
    refute entry.sha256 == Identity.sha256(content)
  end

  test "secrets in the description are redacted too", %{tmp_dir: dir} do
    assert {:ok, _} =
             Store.write(dir, [], %{name: "a", description: "token=abcdef123456", content: "ok"})

    refute File.read!(Path.join(dir, ".foreman/memory/a.md")) =~ "abcdef123456"
    refute File.read!(Path.join(dir, ".foreman/memory/MEMORY.md")) =~ "abcdef123456"
  end
end
