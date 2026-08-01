defmodule ForemanServerWeb.Layouts do
  @moduledoc false

  use Phoenix.Component

  attr(:inner_content, :any, required: true)

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Foreman debug</title>
        <script defer src="/debug-live.js">
        </script>
        <style>
          :root {
            color-scheme: dark;
            font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          }

          body {
            margin: 0;
            background: #0f172a;
            color: #e2e8f0;
          }

          a {
            color: #93c5fd;
          }

          code,
          pre {
            font-family: "SFMono-Regular", SFMono-Regular, ui-monospace, Menlo, Monaco, Consolas, monospace;
          }
        </style>
      </head>
      <body>
        <%= @inner_content %>
      </body>
    </html>
    """
  end

  attr(:inner_content, :any, required: true)

  def app(assigns) do
    ~H"""
    <%= @inner_content %>
    """
  end
end
