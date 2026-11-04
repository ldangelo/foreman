defmodule ForemanServerWeb.Workspace.Layouts do
  @moduledoc """
  Root layout of the project workspace LiveViews and of the operator run
  dashboard (`/dashboard/runs`).

  The rest of the browser surface renders without a root layout (and ships no
  client JavaScript), so these pages carry their own: the CSRF meta tag, the
  two vendored client libraries served from `/assets/vendor/` (see the endpoint),
  the LiveSocket bootstrap and one inline handler for the `library-download` event
  the Library tab pushes (a file's bytes travel over the authenticated socket; a
  link to the API could not send the token). A page title and a visible-focus
  stylesheet live here too, so every page has the same landmarks and focus ring.
  The skip link targets `#main`: each page marks its `<main>` with that id.
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
          :root {
            color-scheme: light dark;
            --bg: #faf9f5; --card: #ffffff; --card-2: #f5f3ec; --border: #e5e2d9;
            --text: #1f1e1d; --muted: #6b685f; --accent: #c15f3c; --accent-text: #ffffff;
            --ok: #3d7a36; --warn: #9a6212; --err: #b3382c; --info: #2559b8;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #262624; --card: #30302e; --card-2: #3a3936; --border: #44433f;
              --text: #f2f0ea; --muted: #a8a59c; --accent: #d97757; --accent-text: #1f1e1d;
              --ok: #7bb274; --warn: #e0a458; --err: #e5766b; --info: #6aa2e8;
            }
          }
          * { box-sizing: border-box; }
          body { font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
            margin: 0; font-size: 15px; line-height: 1.55; background: var(--bg); color: var(--text); }
          a { color: var(--accent); }
          a:focus-visible, button:focus-visible, input:focus-visible, textarea:focus-visible,
          select:focus-visible, summary:focus-visible, [tabindex]:focus-visible {
            outline: 2px solid var(--accent); outline-offset: 2px; }
          code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
          .ws-skip { position: absolute; left: -999px; }
          .ws-skip:focus { left: 8px; top: 8px; background: var(--card); color: var(--text); padding: 4px 8px; }
          .ws-main { max-width: 1440px; margin: 0 auto; padding: 24px; }
          .ws-muted { color: var(--muted); }
          .ws-error { color: var(--err); font-weight: 600; }

          /* header */
          .ws-header { display: flex; flex-wrap: wrap; align-items: flex-start; gap: 12px 16px;
            padding-bottom: 16px; border-bottom: 1px solid var(--border); margin-bottom: 24px; }
          .ws-header-title { flex: 1 1 auto; min-width: 0; }
          .ws-header h1 { margin: 0; font-size: 28px; line-height: 1.2; font-weight: 600; }
          .ws-goal { margin: 4px 0 0; font-size: 15px; color: var(--muted); overflow-wrap: anywhere;
            display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
          .ws-header-actions { margin-left: auto; display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }

          /* chips */
          .chip { display: inline-flex; align-items: center; font-size: 12px; font-weight: 600;
            line-height: 1.4; padding: 2px 8px; border-radius: 999px;
            border: 1px solid var(--muted); color: var(--muted); background: transparent; }
          .chip--ok { border-color: var(--ok); color: var(--ok); }
          .chip--info { border-color: var(--info); color: var(--info); }
          .chip--warn { border-color: var(--warn); color: var(--warn); }
          .chip--err { border-color: var(--err); color: var(--err); }
          .chip--muted { border-color: var(--muted); color: var(--muted); }

          /* buttons */
          button, .btn { font: inherit; }
          .btn, button.ws-btn { display: inline-flex; align-items: center; justify-content: center;
            min-height: 36px; font-size: 14px; padding: 0 14px; border-radius: 8px;
            border: 1px solid var(--border); background: transparent; color: var(--text);
            cursor: pointer; text-decoration: none; }
          .btn--primary, button.ws-btn--primary { background: var(--accent); color: var(--accent-text); border-color: var(--accent); }
          .btn[disabled], button.ws-btn[disabled], button[disabled] { opacity: .5; cursor: not-allowed; }
          .btn--link { min-height: 0; padding: 0; border: 0; background: none; color: var(--accent); font-size: 14px; cursor: pointer; }
          button:not(.btn):not(.btn--link):not([role="tab"]) { min-height: 34px; font-size: 14px; padding: 2px 12px;
            border-radius: 8px; border: 1px solid var(--border); background: transparent; color: var(--text); cursor: pointer; }
          summary { cursor: pointer; }

          /* layout: thread sidebar | main column | project panels. Stacked below 1100px (sidebar
             compact and scrolling, then the main column, then the panels); the app shell below
             takes over from 1100px. */
          .ws-layout { display: grid; grid-template-columns: minmax(0, 1fr); gap: 20px; align-items: start; }
          .ws-main-col { min-width: 0; }
          .ws-threads { min-width: 0; max-height: 320px; overflow-y: auto; }
          .ws-side { min-width: 0; display: flex; flex-direction: column; gap: 12px; }
          @media (max-width: 700px) { .ws-main { padding: 16px; } }

          /* cards */
          .ws-card { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 16px; }
          .ws-panels { display: flex; flex-direction: column; gap: 12px; }
          .ws-panels:empty { display: none; }
          .ws-panel { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 16px; }
          .ws-panel h2 { margin: 0 0 8px; font-size: 16px; font-weight: 600; }
          .ws-panel-head { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; }
          .ws-panel-list { list-style: none; margin: 8px 0 0; padding: 0; }
          .ws-panel-list li { margin: 6px 0; overflow-wrap: anywhere; }
          .ws-count { font-size: 13px; color: var(--muted); font-weight: 400; }
          .ws-ellipsis { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; }
          .ws-clamp-8 { display: -webkit-box; -webkit-line-clamp: 8; -webkit-box-orient: vertical; overflow: hidden; }
          .ws-clamp-1 { display: -webkit-box; -webkit-line-clamp: 1; -webkit-box-orient: vertical; overflow: hidden; }
          .ws-clamp-2 { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }

          /* conversation */
          .conv-card { display: flex; flex-direction: column; gap: 16px; }
          .conv-head { display: flex; align-items: center; gap: 8px; }
          .conv-head h2 { margin: 0; font-size: 16px; font-weight: 600; }
          .conv-card #proposals { flex: none; max-height: 30vh; overflow-y: auto; }
          .conv-transcript { display: flex; flex-direction: column-reverse; height: 65vh;
            overflow-y: auto; padding: 16px; background: transparent; border: 1px solid var(--border); border-radius: 8px; }
          .conv-inner { display: flex; flex-direction: column; gap: 12px; }
          .msg { overflow-wrap: anywhere; max-width: 90%; }
          .msg-text { white-space: pre-wrap; overflow-wrap: anywhere; }
          .ws-msg { white-space: pre-wrap; overflow-wrap: anywhere; margin: 0 0 8px; }
          .msg--operator { align-self: flex-end; max-width: 80%; background: var(--card-2);
            border: 1px solid var(--border); border-radius: 12px; padding: 10px 14px; }
          .msg--coordinator, .msg--agent { align-self: flex-start; }
          .msg--stderr { align-self: flex-start; color: var(--muted);
            border-left: 2px solid var(--warn); padding-left: 12px; }
          .msg--system { align-self: stretch; font-size: 13px; color: var(--muted);
            border-left: 2px solid var(--border); padding-left: 12px; }
          .msg--verdict { align-self: stretch; max-width: 100%; font-size: 13px; color: var(--muted);
            border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; }
          .msg-meta { display: flex; gap: 8px; align-items: baseline; margin: 0 0 4px; font-size: 13px; color: var(--muted); }
          .msg-sender { font-weight: 600; }
          .msg details > summary { cursor: pointer; }
          .composer textarea { width: 100%; min-height: 76px; background: var(--card-2);
            border: 1px solid var(--border); border-radius: 8px; padding: 12px; color: var(--text); font: inherit; }
          .composer-row { display: flex; justify-content: flex-end; margin-top: 8px; }
          .ws-vh { position: absolute; width: 1px; height: 1px; margin: -1px; padding: 0; overflow: hidden;
            clip: rect(0 0 0 0); white-space: nowrap; border: 0; }

          /* thread sidebar */
          .ws-group-title { font-size: 13px; font-weight: 600; text-transform: uppercase;
            letter-spacing: .04em; color: var(--muted); margin: 12px 0 6px; }
          .ws-dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; background: var(--err); }
          .ws-threads h2.ws-group-title { display: flex; align-items: center; gap: 8px; margin: 16px 0 4px; }
          .thread-rows { list-style: none; margin: 0; padding: 0; }
          .thread-row { display: flex; flex-direction: column; justify-content: center; gap: 2px; min-height: 44px;
            padding: 6px 10px; border-left: 3px solid transparent; border-radius: 8px;
            color: var(--text); text-decoration: none; }
          .thread-row:hover { background: var(--card-2); }
          .thread-row[aria-current="page"] { background: var(--card); border-left-color: var(--accent); }
          .thread-row--chat { flex-direction: row; align-items: center; justify-content: space-between; gap: 8px; }
          .thread-row-title { font-weight: 500; min-width: 0; overflow: hidden; overflow-wrap: anywhere;
            display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
          .thread-row-meta { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
          .thread-dot { flex: none; width: 8px; height: 8px; border-radius: 50%; background: var(--muted); }
          .thread-dot--ok { background: var(--ok); }
          .thread-dot--info { background: var(--info); }
          .thread-dot--warn { background: var(--warn); }
          .thread-dot--err { background: var(--err); }

          /* thread pane */
          .thread-pane { display: flex; flex-direction: column; gap: 12px; }
          .thread-pane-head { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
          .thread-pane-head p { margin: 0; }
          .thread-back { align-self: flex-start; font-size: 13px; text-decoration: none; }
          .thread-pane-titlerow { display: flex; align-items: flex-start; gap: 8px; min-width: 0; }
          .thread-pane-title { margin: 0; min-width: 0; font-size: 18px; font-weight: 600; line-height: 1.3;
            overflow-wrap: anywhere; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;
            overflow: hidden; }
          .thread-pane-titlerow .chip { flex: none; margin-top: 2px; }
          .thread-meta { display: flex; align-items: baseline; gap: 6px; min-width: 0; overflow: hidden;
            font-size: 12px; white-space: nowrap; }
          .thread-meta > * { flex: none; }
          .thread-meta > .thread-branch { flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; }
          .thread-meta .btn--link { font-size: 12px; }
          .thread-hint { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; }
          .thread-controls { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; }
          .thread-controls-details > summary { font-size: 13px; color: var(--muted); }
          .thread-controls-details[open] > .thread-controls { margin-top: 8px; }
          .thread-actions, .thread-pr-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
          .ws-pr-action { display: inline-flex; }
          .thread-approvals { display: flex; flex-direction: column; gap: 8px; padding: 10px 12px;
            border: 1px solid var(--border); border-radius: 8px; }
          .ws-approval { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; }
          .thread-composer textarea { min-height: 52px; }
          .thread-note { margin: 0; }

          /* tabs */
          [role="tablist"] { display: flex; gap: 4px; flex-wrap: wrap; border-bottom: 1px solid var(--border); margin-bottom: 12px; }
          [role="tablist"] button { min-height: 32px; padding: 6px 12px; border: 0; background: none; color: var(--muted); border-radius: 8px 8px 0 0; cursor: pointer; }
          [role="tablist"] button[aria-selected="true"] { color: var(--text); font-weight: 600; box-shadow: inset 0 -2px 0 var(--accent); }
          table { border-collapse: collapse; width: 100%; }
          th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--border); font-size: 14px; }

          fieldset { border: 1px solid var(--border); border-radius: 8px; }
          input[type="text"], textarea { background: var(--card-2); border: 1px solid var(--border);
            border-radius: 8px; color: var(--text); font: inherit; padding: 6px 8px; }
          [role="tablist"] button:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }

          /* app shell (from 1100px): the page is exactly the viewport and the sidebar, the main card
             and the project panels scroll on their own; the log takes what the card's header and
             composer leave. Placed last so it wins over the stacked rules above. */
          @media (min-width: 1100px) {
            .ws-main { height: 100vh; display: flex; flex-direction: column; }
            .ws-header { flex: none; margin-bottom: 16px; }
            .ws-layout { flex: 1; min-height: 0; grid-template-columns: 264px minmax(0, 1fr) 320px;
              grid-template-rows: minmax(0, 1fr); align-items: stretch; }
            .ws-threads, .ws-side { max-height: none; min-height: 0; overflow-y: auto; }
            .ws-main-col { display: flex; flex-direction: column; min-height: 0; }
            .conv-card, .thread-pane { flex: 1; min-height: 0; }
            .conv-transcript { flex: 1; min-height: 0; height: auto; }
          }
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
          window.addEventListener("phx:library-download", function (event) {
            var bytes = Uint8Array.from(atob(event.detail.data), function (c) { return c.charCodeAt(0); });
            var url = URL.createObjectURL(new Blob([bytes], {type: "application/octet-stream"}));
            var link = document.createElement("a");
            link.href = url;
            link.download = event.detail.name;
            document.body.appendChild(link);
            link.click();
            link.remove();
            setTimeout(function () { URL.revokeObjectURL(url); }, 40000);
          });
        </script>
      </body>
    </html>
    """
  end
end
