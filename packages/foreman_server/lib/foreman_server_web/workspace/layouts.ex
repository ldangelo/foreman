defmodule ForemanServerWeb.Workspace.Layouts do
  @moduledoc """
  Root layout of the project workspace LiveViews.

  The rest of the browser surface renders without a root layout (and ships no
  client JavaScript), so the workspace carries its own: the CSRF meta tag, the
  two vendored client libraries served from `/assets/vendor/` (see the endpoint)
  and the LiveSocket bootstrap. A page title and a visible-focus stylesheet live
  here too, so every workspace page has the same landmarks and focus ring.
  """

  use Phoenix.Component

  @doc "Root layout: `<html>` shell plus the LiveSocket bootstrap."
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>{assigns[:page_title] || "Foreman"}</title>
        <style>
          :root { color-scheme: light dark; }
          body { font-family: system-ui, sans-serif; margin: 0; line-height: 1.4; }
          a:focus-visible, button:focus-visible, input:focus-visible, textarea:focus-visible,
          select:focus-visible, [tabindex]:focus-visible { outline: 3px solid #1d4ed8; outline-offset: 2px; }
          .ws-skip { position: absolute; left: -999px; }
          .ws-skip:focus { left: 8px; top: 8px; background: Canvas; padding: 4px 8px; }
          .ws-layout { display: grid; grid-template-columns: minmax(280px, 2fr) 3fr; gap: 16px; padding: 16px; }
          @media (max-width: 900px) { .ws-layout { grid-template-columns: 1fr; } }
          .ws-card { border: 1px solid #8884; border-radius: 6px; padding: 8px 12px; margin: 8px 0; }
          .ws-dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; background: #b91c1c; }
          .ws-muted { opacity: .75; }
          .ws-error { color: #b91c1c; font-weight: 600; }
          .ws-msg { white-space: pre-wrap; overflow-wrap: anywhere; }
          .ws-msg-operator { border-left: 4px solid #1d4ed8; padding-left: 8px; }
          [role="tablist"] button[aria-selected="true"] { font-weight: 700; text-decoration: underline; }
          @media (prefers-reduced-motion: reduce) { * { animation: none !important; transition: none !important; } }
        </style>
      </head>
      <body>
        <a class="ws-skip" href="#main">Skip to content</a>
        {@inner_content}
        <script src="/assets/vendor/phoenix.min.js">
        </script>
        <script src="/assets/vendor/phoenix_live_view.min.js">
        </script>
        <script>
          var csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {params: {_csrf_token: csrf}});
          liveSocket.connect();
        </script>
      </body>
    </html>
    """
  end
end
