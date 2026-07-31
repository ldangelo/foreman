defmodule ForemanServer.VcsAdapter.Default do
  @moduledoc """
  Default GitHub-backed implementation for VCS adapter operations.

  The adapter uses the GitHub REST API to validate clone inputs, create branch
  refs, and open pull requests. `clone/2` returns clone metadata for the target
  repository so callers can keep the actual workspace materialization behind the
  adapter boundary.
  """

  @behaviour ForemanServer.VcsAdapter

  @default_base_url "https://api.github.com"
  @default_timeout 5_000

  @impl true
  def clone(input, opts) do
    with {:ok, repo} <- required_binary(value(input, :repo), :repo),
         {:ok, path} <- required_binary(value(input, :path), :path),
         {:ok, body} <- get_json(repo_path(repo), opts) do
      {:ok,
       %{
         repo: repo,
         path: path,
         clone_url: body["clone_url"],
         ssh_url: body["ssh_url"],
         default_branch: body["default_branch"]
       }
       |> put_if(:base_ref, value(input, :base_ref))}
    end
  end

  @impl true
  def branch(input, opts) do
    with {:ok, repo} <- required_binary(value(input, :repo), :repo),
         {:ok, branch} <- required_binary(value(input, :branch), :branch),
         {:ok, base_ref} <- required_binary(value(input, :base_ref, "main"), :base_ref),
         {:ok, ref_body} <- get_json("#{repo_path(repo)}/git/ref/heads/#{URI.encode_www_form(base_ref)}", opts),
         {:ok, body} <-
           post_json(
             "#{repo_path(repo)}/git/refs",
             %{ref: "refs/heads/#{branch}", sha: get_in(ref_body, ["object", "sha"])} ,
             opts
           ) do
      {:ok,
       %{
         repo: repo,
         branch: branch,
         base_ref: base_ref,
         ref: body["ref"],
         sha: get_in(body, ["object", "sha"]) || get_in(ref_body, ["object", "sha"])
       }}
    end
  end

  @impl true
  def create_pr(input, opts) do
    with {:ok, repo} <- required_binary(value(input, :repo), :repo),
         {:ok, branch} <- required_binary(value(input, :branch), :branch),
         {:ok, base_branch} <- required_binary(value(input, :base_branch, "main"), :base_branch),
         {:ok, title} <- required_binary(value(input, :title), :title),
         {:ok, body} <-
           post_json(
             "#{repo_path(repo)}/pulls",
             %{
               title: title,
               body: value(input, :body),
               head: branch,
               base: base_branch
             },
             opts
           ) do
      {:ok,
       %{
         repo: repo,
         pr_number: body["number"],
         pr_url: body["html_url"],
         api_url: body["url"],
         state: body["state"],
         branch: branch,
         base_branch: base_branch,
         title: title
       }}
    end
  end

  defp get_json(path, opts), do: request_json(:get, path, nil, opts)
  defp post_json(path, payload, opts), do: request_json(:post, path, payload, opts)

  defp request_json(method, path, payload, opts) do
    transport = Keyword.get(opts, :transport, &http_request/5)
    url = base_url(opts) <> path
    headers = request_headers(opts)
    encoded_body = if payload, do: Jason.encode!(compact_payload(payload)), else: nil

    case transport.(method, url, headers, encoded_body, request_options(opts)) do
      {:ok, %{status: status, body: body}} when status >= 200 and status <= 299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}

      other ->
        {:error, {:invalid_transport_response, other}}
    end
  end

  defp http_request(method, url, headers, nil, options) do
    request = {String.to_charlist(url), char_headers(headers)}
    perform_request(method, request, options)
  end

  defp http_request(method, url, headers, body, options) do
    request = {String.to_charlist(url), char_headers(headers), ~c"application/json", String.to_charlist(body)}
    perform_request(method, request, options)
  end

  defp perform_request(method, request, options) do
    case :httpc.request(method, request, [timeout: options.timeout], [body_format: :binary]) do
      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:ok, %{status: status, body: decode_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_headers(opts) do
    [
      {"accept", "application/vnd.github+json"},
      {"content-type", "application/json"},
      {"user-agent", "foreman-server"},
      {"x-github-api-version", "2022-11-28"}
    ]
    |> maybe_put_auth_header(token(opts))
  end

  defp maybe_put_auth_header(headers, nil), do: headers
  defp maybe_put_auth_header(headers, token), do: [{"authorization", "Bearer #{token}"} | headers]

  defp request_options(opts) do
    %{timeout: Keyword.get(opts, :timeout, @default_timeout)}
  end

  defp token(opts) do
    Keyword.get(opts, :token) || Application.get_env(:foreman_server, :github_token) || System.get_env("GITHUB_TOKEN")
  end

  defp base_url(opts) do
    Keyword.get(opts, :base_url, Application.get_env(:foreman_server, :github_api_base_url, @default_base_url))
    |> String.trim_trailing("/")
  end

  defp repo_path(repo) do
    case String.split(repo, "/", parts: 2) do
      [owner, name] when owner != "" and name != "" ->
        "/repos/#{URI.encode_www_form(owner)}/#{URI.encode_www_form(name)}"

      _ ->
        raise ArgumentError, "repo must be owner/name"
    end
  end

  defp decode_body(body) when body in [nil, ""], do: %{}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp char_headers(headers) do
    Enum.map(headers, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp compact_payload(payload) when is_map(payload) do
    payload
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp value(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
