defmodule ForemanServer.GitHub.PrComment do
  @moduledoc """
  TRD-019: the comments of one pull request, read and written with `gh`.

  The first GitHub content write of Foreman. It needs no checkout: owner, repository and number
  come from the PR URL (`GitHub.PrStatus.parse_pr_url/1`, github.com URLs only) and every call
  goes through `Reconcilers.Command.run/4` with no `:cd`, so each call is bounded
  (`Command.default_timeout_ms/0` unless `opts[:timeout_ms]` says otherwise) and a runner that
  never answers is `{:error, {:timeout, ms}}`.

    * `list/2` runs `gh pr view <url> --json comments` and returns every comment, oldest first,
      as `%{id, url, body, viewer_did_author, minimized, created_at}`: `id` is the GraphQL node
      id, minimised comments are kept and bodies are not cut (unlike `PrStatus.comments`).
    * `create/3` runs `gh api repos/<owner>/<repo>/issues/<n>/comments -f body=<body>`.
    * `update/3` runs `gh api -X PATCH repos/<owner>/<repo>/issues/comments/<id> -f body=<body>`
      with the numeric id parsed from the comment URL fragment `#issuecomment-<id>`.

  `create/3` and `update/3` answer `{:ok, %{id, rest_id, url}}` (`node_id`, `id` and `html_url`
  of the GitHub answer: `id` is the same GraphQL node id `list/2` shows). `-f` sends a raw
  string (`-F` would convert `true`, `null`, integers and `@file` in a body), and the body is
  never sent on stdin because the runner takes none.

  Errors are typed and never success: a non-zero exit is `{:gh_failed, code, output}`, an answer
  that is not JSON is `{:gh_unparsable, text}`, a URL that is not a github.com pull request
  (or comment) URL, or an item or answer of the wrong shape, is
  `{:gh_unexpected_payload, term}`, and `Command.run/4`'s own errors (`{:command_not_run, ..}`,
  `{:timeout, ms}`, ...) pass through.

  `opts`: `:command_runner` (3-arity `(cmd, args, opts)` returning `{output, exit_code}`;
  `System.cmd/3` by default) and `:timeout_ms`.

  Production caller: none until the publisher (TRD-021).
  """

  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.Idempotency.Reconcilers.Command

  @type comment :: %{
          id: String.t(),
          url: String.t() | nil,
          body: String.t(),
          viewer_did_author: boolean(),
          minimized: boolean(),
          created_at: String.t()
        }

  @type written :: %{id: String.t() | nil, rest_id: pos_integer(), url: String.t()}

  @type error ::
          {:gh_failed, integer(), String.t()}
          | {:gh_unparsable, String.t()}
          | {:gh_unexpected_payload, term()}
          | term()

  @doc "Every comment of the PR, oldest first, minimised ones included."
  @spec list(String.t(), keyword()) :: {:ok, [comment()]} | {:error, error()}
  def list(pr_url, opts \\ []) when is_binary(pr_url) and is_list(opts) do
    with {:ok, _owner, _name, _number} <- PrStatus.parse_pr_url(pr_url),
         {:ok, output} <- run(["pr", "view", pr_url, "--json", "comments"], opts) do
      parse_list(output)
    end
  end

  @doc "Adds a comment with `body` to the PR."
  @spec create(String.t(), String.t(), keyword()) :: {:ok, written()} | {:error, error()}
  def create(pr_url, body, opts \\ [])
      when is_binary(pr_url) and is_binary(body) and is_list(opts) do
    with {:ok, owner, name, number} <- PrStatus.parse_pr_url(pr_url),
         {:ok, output} <-
           run(
             ["api", "repos/#{owner}/#{name}/issues/#{number}/comments", "-f", "body=" <> body],
             opts
           ) do
      parse_written(output)
    end
  end

  @doc """
  Replaces the body of the comment at `comment_url` (`https://github.com/o/r/pull/7#issuecomment-123`).
  A URL without the fragment, or outside github.com, runs nothing.
  """
  @spec update(String.t(), String.t(), keyword()) :: {:ok, written()} | {:error, error()}
  def update(comment_url, body, opts \\ [])
      when is_binary(comment_url) and is_binary(body) and is_list(opts) do
    with {:ok, owner, name, comment_id} <- parse_comment_url(comment_url),
         {:ok, output} <-
           run(
             [
               "api",
               "-X",
               "PATCH",
               "repos/#{owner}/#{name}/issues/comments/#{comment_id}",
               "-f",
               "body=" <> body
             ],
             opts
           ) do
      parse_written(output)
    end
  end

  @doc "Owner, repository and numeric REST id of a comment URL, or a typed error."
  @spec parse_comment_url(String.t()) ::
          {:ok, String.t(), String.t(), non_neg_integer()}
          | {:error, {:gh_unexpected_payload, term()}}
  def parse_comment_url(url) when is_binary(url) do
    case Regex.run(comment_url_pattern(), url) do
      [_url, owner, name, id] when owner not in [".", ".."] and name not in [".", ".."] ->
        {:ok, owner, name, String.to_integer(id)}

      _other ->
        {:error, {:gh_unexpected_payload, {:unrecognised_comment_url, url}}}
    end
  end

  defp comment_url_pattern,
    do:
      ~r{\Ahttps://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(?:pull|issues)/\d+#issuecomment-(\d+)\z}

  defp run(args, opts) do
    runner = Keyword.get(opts, :command_runner) || (&System.cmd/3)

    case Command.run(runner, "gh", args,
           timeout_ms: Keyword.get(opts, :timeout_ms, Command.default_timeout_ms())
         ) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, {:gh_failed, code, String.trim(output)}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_list(output) do
    case Jason.decode(output) do
      {:ok, %{"comments" => items}} when is_list(items) -> collect(items, [])
      {:ok, other} -> {:error, {:gh_unexpected_payload, other}}
      {:error, _} -> {:error, {:gh_unparsable, String.slice(output, 0, 200)}}
    end
  end

  defp collect([], acc), do: {:ok, acc |> Enum.reverse() |> Enum.sort_by(& &1.created_at)}

  defp collect([item | rest], acc) do
    case comment(item) do
      {:ok, comment} -> collect(rest, [comment | acc])
      :error -> {:error, {:gh_unexpected_payload, item}}
    end
  end

  defp comment(
         %{
           "id" => id,
           "body" => body,
           "viewerDidAuthor" => author,
           "isMinimized" => minimized,
           "createdAt" => created
         } = item
       )
       when is_binary(id) and id != "" and is_binary(body) and is_boolean(author) and
              is_boolean(minimized) and is_binary(created) do
    case Map.get(item, "url") do
      url when is_binary(url) or is_nil(url) ->
        {:ok,
         %{
           id: id,
           url: url,
           body: body,
           viewer_did_author: author,
           minimized: minimized,
           created_at: created
         }}

      _other ->
        :error
    end
  end

  defp comment(_other), do: :error

  # An answer that is not clean JSON (a warning of `gh` merged into stdout with an exit 0) is a
  # typed error, not a success: the write may have happened, and TRD-020's reconciler finds the
  # comment by its marker before any retry, so a duplicate comment cannot follow from it.
  defp parse_written(output) do
    case Jason.decode(output) do
      {:ok, %{"id" => rest_id, "html_url" => url} = answer}
      when is_integer(rest_id) and rest_id > 0 and is_binary(url) and url != "" ->
        case Map.get(answer, "node_id") do
          node when is_binary(node) or is_nil(node) ->
            {:ok, %{id: node, rest_id: rest_id, url: url}}

          _other ->
            {:error, {:gh_unexpected_payload, answer}}
        end

      {:ok, other} ->
        {:error, {:gh_unexpected_payload, other}}

      {:error, _} ->
        {:error, {:gh_unparsable, String.slice(output, 0, 200)}}
    end
  end
end
