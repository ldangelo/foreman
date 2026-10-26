defmodule ForemanServer.Incarnation do
  @moduledoc """
  Identity of this server incarnation: one opaque value per BEAM VM lifetime.

  Durable records that are only meaningful while the process that wrote them
  is alive (a `BeadsDbLease` hold taken by `BeadsDbLease.with_lease/4` around
  one `br` call) carry the incarnation that wrote them. After a restart (a
  `kill -9`, an OOM kill, or a SIGTERM that cuts a `try/after` short) no
  process of the old incarnation exists any more, so a record tagged with
  another incarnation is known to be dead — without a clock, a TTL or a guess.

  The id is created by `ForemanServer.Application.start/2` before any child
  starts, and lazily on first use otherwise (a VM that never started the
  application); it is stable until the VM exits.
  """

  @key {__MODULE__, :id}

  @doc "The incarnation id of this VM."
  @spec id() :: String.t()
  def id do
    case :persistent_term.get(@key, nil) do
      id when is_binary(id) -> id
      nil -> create()
    end
  end

  defp create do
    id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    :persistent_term.put(@key, id)
    id
  end
end
