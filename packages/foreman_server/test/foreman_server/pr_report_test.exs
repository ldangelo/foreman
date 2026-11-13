defmodule ForemanServer.PrReportTest do
  @moduledoc """
  TRD-019: `PrReport.render/2` over a risk record. The record's free text (a finding's
  description, path and source, a rationale detail, a sensitive path) is untrusted agent or PR
  text: it must come out redacted, neutralised and bounded, the marker line must survive every
  cut, and a secret that reaches a closed field must stop publication.
  """

  use ExUnit.Case, async: true

  alias ForemanServer.PrReport

  @secret "s3cr3t-Value-4f9a2c71"
  @run_id "run-abc123"
  @head "0123456789abcdef0123456789abcdef01234567"
  @digest "fedcba9876543210"
  @zwsp "\u200B"

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        "severity" => "major",
        "path" => "lib/a.ex",
        "line" => 12,
        "description" => "a plain description",
        "disposition" => "open",
        "source" => "review"
      },
      overrides
    )
  end

  defp record(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: @run_id,
        head_sha: @head,
        digest: @digest,
        level: "HIGH",
        rubric_version: "1",
        rationale: [
          %{
            "rule" => "checks",
            "level" => "HIGH",
            "basis" => "machine",
            "detail" => "required checks not passing: check_failed"
          },
          %{
            "rule" => "judgement",
            "level" => "HIGH",
            "basis" => "agent_claim",
            "detail" => "the judgement is missing"
          }
        ],
        evidence: %{
          "checks" => %{"status" => "ineligible", "reasons" => ["check_failed", "check_pending"]},
          "findings" => %{
            "status" => "recorded",
            "defect" => nil,
            "unresolved" => %{"critical" => 1, "major" => 0}
          },
          "judgement" => %{"status" => "recorded", "level" => "LOW"},
          "files" => %{
            "changed" => 3,
            "listed" => 3,
            "additions" => 10,
            "deletions" => 2,
            "incomplete" => false
          },
          "sensitive_hits" => [%{"path" => ".github/workflows/ci.yml", "group" => "ci"}]
        },
        unresolved_findings: [finding()],
        instructions: ["Read each finding before approving."],
        judgement: %{"status" => "recorded", "level" => "LOW", "head_sha" => @head}
      },
      overrides
    )
  end

  defp render!(record, secrets \\ [@secret]) do
    assert {:ok, body} = PrReport.render(record, secrets: secrets)
    body
  end

  describe "the body of a risk record" do
    test "starts with the marker line and states level, rubric, rationale bases, reasons, findings and instructions" do
      body = render!(record())
      [first | _] = String.split(body, "\n")

      assert first == PrReport.marker(@run_id, @head, @digest)
      assert String.starts_with?(first, PrReport.marker_prefix())

      assert PrReport.parse_marker(body) ==
               {:ok, %{run_id: @run_id, head_sha: @head, digest: @digest}}

      assert body =~ "## Foreman PR risk report: HIGH"
      assert body =~ "Rubric version: 1"
      assert body =~ @head

      assert body =~
               "[machine-observed] checks (HIGH): required checks not passing: check\\_failed"

      assert body =~ "[agent-authored] judgement (HIGH)"
      assert body =~ "reason codes: check\\_failed, check\\_pending"
      assert body =~ "Review findings (agent-authored)"
      assert body =~ "Model judgement (agent-authored): status recorded, level LOW"
      assert body =~ "Unresolved findings (agent-authored claims, not verified)"
      assert body =~ "major, open: lib/a.ex:12: a plain description"
      assert body =~ "### Instructions"
      assert body =~ "Read each finding before approving."
      assert body =~ "approval stays a human decision"
    end

    test "a record with string keys (a replayed event) renders the same body" do
      atom_keyed = record()
      string_keyed = Map.new(atom_keyed, fn {key, value} -> {Atom.to_string(key), value} end)

      assert render!(string_keyed) == render!(atom_keyed)
    end

    test "a record without a safe marker field or a known level renders nothing" do
      for bad <- [
            record(%{run_id: "run --> <script>"}),
            record(%{head_sha: "abc\ndef"}),
            record(%{digest: nil}),
            record(%{level: "CRITICAL"}),
            record(%{level: nil})
          ] do
        assert PrReport.render(bad, secrets: []) == {:error, :invalid_record}
      end
    end

    test "a missing or malformed redaction list renders nothing rather than redacting nothing" do
      assert PrReport.render(record(), []) == {:error, :redaction_unavailable}
      assert PrReport.render(record(), secrets: nil) == {:error, :redaction_unavailable}
      assert PrReport.render(record(), secrets: [@secret, 12]) == {:error, :redaction_unavailable}
      assert {:ok, _body} = PrReport.render(record(), secrets: [])
    end
  end

  describe "marker" do
    test "is read from the first line only" do
      marker = PrReport.marker(@run_id, @head, @digest)

      assert {:ok, %{run_id: @run_id}} = PrReport.parse_marker(marker <> "\nrest")
      assert PrReport.parse_marker("hello\n" <> marker) == :error
      assert PrReport.parse_marker(" " <> marker) == :error
      assert PrReport.parse_marker("") == :error
      assert PrReport.parse_marker(String.replace(marker, "v1", "v2")) == :error
    end

    test "survives the 2000-character cut PrStatus applies to comment bodies" do
      body = render!(record())
      assert String.length(body) > 600

      assert PrReport.parse_marker(String.slice(body, 0, 2000)) ==
               {:ok, %{run_id: @run_id, head_sha: @head, digest: @digest}}
    end
  end

  describe "untrusted text" do
    @hostile "Leak " <>
               @secret <>
               " ping @octocat and @org/team <script>alert(1)</script> <!-- hide --> " <>
               "```elixir\nFixes #123\n``` [click](https://evil.example/x) www.evil.example " <>
               "\n## Injected heading\n- item\r\n> quote | cell"

    test "a finding description is redacted, neutralised and one line" do
      body = render!(record(%{unresolved_findings: [finding(%{"description" => @hostile})]}))

      refute body =~ @secret
      refute body =~ "@octocat"
      refute body =~ "@org"
      assert body =~ "@" <> @zwsp <> "octocat"
      refute body =~ "<script"
      assert body =~ "&lt;script&gt;"
      refute body =~ "```"
      refute body =~ "Fixes #123"
      refute body =~ "](https://"
      refute body =~ "://evil"
      refute body =~ "www.evil"
      refute body =~ "\n## Injected"
      refute body =~ "\n- item"
      refute body =~ "\n> quote"

      # the one marker is the only HTML comment opener in the whole body
      assert body |> String.split("<!--") |> length() == 2

      [line] = body |> String.split("\n") |> Enum.filter(&String.contains?(&1, "Leak"))
      assert line =~ "Injected heading"
    end

    test "a finding path and source, a rationale detail, a sensitive path and an instruction get the same treatment" do
      hostile = "x " <> @secret <> " @octocat <b>bold</b> `code` \nnew"

      body =
        render!(
          record(%{
            unresolved_findings: [finding(%{"path" => hostile, "source" => hostile})],
            rationale: [
              %{"rule" => "checks", "level" => "HIGH", "basis" => "machine", "detail" => hostile}
            ],
            instructions: [hostile],
            evidence:
              put_in(record().evidence, ["sensitive_hits"], [
                %{"path" => hostile, "group" => "ci"}
              ])
          })
        )

      refute body =~ @secret
      refute body =~ "@octocat"
      refute body =~ "<b>"
      refute body =~ "`code`"
      refute body =~ "\nnew"
      assert body =~ "\\`code\\`"
    end

    test "a free-text value is cut to at most 500 characters after neutralising" do
      long = String.duplicate("X", 2000)
      angle = String.duplicate("<", 400)

      body =
        render!(
          record(%{
            unresolved_findings: [
              finding(%{"description" => long}),
              finding(%{"description" => angle, "path" => "b.ex"})
            ]
          })
        )

      [x_run] = Regex.run(~r/X+…?/, body)
      assert String.length(x_run) <= 500
      assert String.ends_with?(x_run, "…")

      [angle_run] = Regex.run(~r/(?:&lt;)+…?/, body)
      assert String.length(angle_run) <= 500
      assert String.ends_with?(angle_run, ";…")
    end

    test "neutralise/1 makes markup, mentions, references, links and breaks inert" do
      assert PrReport.neutralise("a & b < c > d") == "a &amp; b &lt; c &gt; d"
      assert PrReport.neutralise("@user") == "@" <> @zwsp <> "user"
      assert PrReport.neutralise("Fixes #12") == "Fixes \\#" <> @zwsp <> "12"
      assert PrReport.neutralise("https://x.y") == "https:" <> @zwsp <> "//x.y"
      assert PrReport.neutralise("WWW.x.y") == "WWW" <> @zwsp <> ".x.y"

      assert PrReport.neutralise("`a` *b* _c_ [d](e) ![f](g) h|i ~j~") =~
               "\\`a\\` \\*b\\* \\_c\\_"

      assert PrReport.neutralise("a\r\nb\n\nc\td") == "a b c d"
      assert PrReport.neutralise("a\u0000b\u202Ec\u200Bd\u2028e") == "abcd e"
      assert PrReport.neutralise("<!-- x -->") == "&lt;\\!-- x --&gt;"
      assert PrReport.neutralise(<<"ok", 0xFF, "end">>) == "okend"

      assert PrReport.neutralise("see GH-12 and gh-7") ==
               "see GH-" <> @zwsp <> "12 and gh-" <> @zwsp <> "7"

      assert PrReport.neutralise("GH-x") == "GH-x"
      assert PrReport.neutralise("$a$ $$b$$") == "\\$a\\$ \\$\\$b\\$\\$"
      assert PrReport.neutralise(":smile: and 10:30") == ":" <> @zwsp <> "smile: and 10:30"
    end
  end

  describe "redaction details" do
    test "overlapping secrets are replaced longest first, whatever the order of the list" do
      text = "x zzqq1234yyxx y zzqq1234 z"

      for secrets <- [["zzqq1234", "zzqq1234yyxx"], ["zzqq1234yyxx", "zzqq1234"]] do
        body =
          render!(record(%{unresolved_findings: [finding(%{"description" => text})]}), secrets)

        refute body =~ "zzqq1234"
        refute body =~ "yyxx"
        assert body =~ "x \\[REDACTED\\] y \\[REDACTED\\] z"
      end
    end

    test "a secret full of regex metacharacters is matched literally" do
      secret = "p.ss(w*rd)+?[x]|^$\\{1}"
      decoy = "pXss(w*rd)+?[x]|^$\\{1}"
      text = "a #{secret} b #{decoy} c"

      body =
        render!(record(%{unresolved_findings: [finding(%{"description" => text})]}), [secret])

      refute body =~ PrReport.neutralise(secret)
      assert body =~ "pXss"
      assert body =~ "\\[REDACTED\\]"
    end

    test "a secret that neutralising rewrites is redacted in free text and still refused in a closed field" do
      secrets = ["ghp_abc123", "star*secret1", "hash#secret1", "at@secret1", "br[ack]et1"]

      for secret <- secrets do
        body =
          render!(
            record(%{unresolved_findings: [finding(%{"description" => "k #{secret} k"})]}),
            [
              secret
            ]
          )

        refute body =~ secret
        refute body =~ PrReport.neutralise(secret)

        assert PrReport.render(
                 record(%{
                   evidence: put_in(record().evidence, ["checks", "reasons"], ["code_" <> secret])
                 }),
                 secrets: [secret]
               ) == {:error, :redaction_failed}
      end
    end

    test "a secret with an invisible character inside is redacted in free text and refused in a closed field" do
      secret = "secretvalue99"
      hidden = "secret\u200Bvalue99"

      body =
        render!(record(%{unresolved_findings: [finding(%{"description" => "k #{hidden} k"})]}), [
          secret
        ])

      refute body =~ "secretvalue99"
      refute body =~ "secret"
      assert body =~ "\\[REDACTED\\]"

      assert PrReport.render(
               record(%{evidence: put_in(record().evidence, ["checks", "status"], hidden)}),
               secrets: [secret]
             ) == {:error, :redaction_failed}
    end

    test "a secret hidden by combining marks, selectors or fillers is redacted in free text and refused in a closed field" do
      secret = "secretvalue99"

      for hidden <- ["\u034F", "\uFE0F", "\u180B", "\u3164", "\u2800", "\u0301", "\u200B"] do
        spread = "secret" <> hidden <> "value" <> hidden <> "99"

        body =
          render!(
            record(%{unresolved_findings: [finding(%{"description" => "k #{spread} k"})]}),
            [secret]
          )

        refute body =~ "secret"
        refute body =~ "value99"
        assert body =~ "k \\[REDACTED\\] k"

        assert PrReport.render(
                 record(%{evidence: put_in(record().evidence, ["checks", "status"], spread)}),
                 secrets: [secret]
               ) == {:error, :redaction_failed}
      end
    end

    test "hidden characters around the secret are kept, and legitimate combining marks are not touched" do
      body =
        render!(
          record(%{
            unresolved_findings: [
              finding(%{"description" => "caf\u0065\u0301 \u034Fsecretvalue99\u034F end"})
            ]
          }),
          ["secretvalue99"]
        )

      assert body =~ "caf\u0065\u0301 "
      assert body =~ "\\[REDACTED\\]"
      refute body =~ "secretvalue99"
    end

    test "a secret straddling a cut is redacted whole before anything is cut" do
      secret = "qrstuv1234wxyz"
      # the invisible characters are dropped by neutralising, so the secret lands inside the first
      # 2000 characters of the visible text
      filler = String.duplicate("\u200B", 1996)

      body =
        render!(
          record(%{
            unresolved_findings: [finding(%{"description" => filler <> secret <> " tail"})]
          }),
          [secret]
        )

      refute body =~ "qrst"
      assert body =~ "\\[REDACTED\\] tail"
    end

    test "a secret in a closed field beyond the closed cut is still refused" do
      long = String.duplicate("c", 100) <> @secret

      assert PrReport.render(
               record(%{evidence: put_in(record().evidence, ["checks", "reasons"], [long])}),
               secrets: [@secret]
             ) == {:error, :redaction_failed}
    end
  end

  describe "the post-render scan" do
    test "a secret in a closed field (a reason code, a rule name, the level text) returns no body" do
      assert PrReport.render(
               record(%{
                 evidence: put_in(record().evidence, ["checks", "reasons"], ["check_" <> @secret])
               }),
               secrets: [@secret]
             ) == {:error, :redaction_failed}

      assert PrReport.render(
               record(%{
                 rationale: [
                   %{
                     "rule" => @secret,
                     "level" => "HIGH",
                     "basis" => "machine",
                     "detail" => "d"
                   }
                 ]
               }),
               secrets: [@secret]
             ) == {:error, :redaction_failed}

      assert PrReport.render(record(%{rubric_version: @secret}), secrets: [@secret]) ==
               {:error, :redaction_failed}
    end

    test "the same record without that secret in the list is rendered" do
      assert {:ok, _body} =
               PrReport.render(record(%{rubric_version: @secret}), secrets: ["other-value-1"])
    end
  end

  describe "the body budget" do
    defp many_findings do
      # every field at the 500-character cap, expanded by entities: far over 16 KB in total
      for index <- 1..20 do
        severity = Enum.at(~w(minor nitpick major critical), rem(index, 4))

        finding(%{
          "severity" => severity,
          "path" => "p#{index}-" <> String.duplicate("<", 300),
          "description" => "d#{index}-" <> String.duplicate("<", 300),
          "source" => "s#{index}-" <> String.duplicate("<", 300)
        })
      end
    end

    test "is at most 16384 bytes, lists the most severe first, counts the rest and keeps the marker" do
      body = render!(record(%{unresolved_findings: many_findings()}))

      assert byte_size(body) <= PrReport.max_body_bytes()
      assert byte_size(body) <= 16_384
      assert String.starts_with?(body, PrReport.marker(@run_id, @head, @digest))
      assert {:ok, _} = PrReport.parse_marker(body)

      severities =
        ~r/^- (critical|major|minor|nitpick), open:/m
        |> Regex.scan(body, capture: :all_but_first)
        |> List.flatten()

      shown = length(severities)
      assert shown > 0 and shown < 20

      rank = %{"critical" => 0, "major" => 1, "minor" => 2, "nitpick" => 3}
      assert severities == Enum.sort_by(severities, &rank[&1])
      assert "critical" in severities

      [count] =
        Regex.run(~r/(\d+) more unresolved findings are not shown here\./, body,
          capture: :all_but_first
        )

      assert String.to_integer(count) == 20 - shown

      assert body |> String.trim_trailing() |> String.split("\n") |> List.last() =~
               "claims written by an agent"

      assert body =~ "### Instructions"
    end

    test "a report that fits lists every finding and no count line" do
      body =
        render!(record(%{unresolved_findings: [finding(), finding(%{"severity" => "minor"})]}))

      refute body =~ "more unresolved findings"
      assert length(Regex.scan(~r/^- (major|minor), open:/m, body)) == 2
    end

    test "the worst case of untrusted text still fits: every list at its cap, four-byte and escaped characters" do
      emoji = String.duplicate("\u{1F600}", 600)
      mention = String.duplicate("@", 600)
      angle = String.duplicate("<", 600)
      long_closed = String.duplicate("\u{1F600}", 200)

      lists = fn text -> for n <- 1..30, do: text <> "#{n}" end

      record =
        record(%{
          rubric_version: long_closed,
          instructions: lists.(emoji),
          rationale:
            for text <- lists.(mention) do
              %{
                "rule" => long_closed,
                "level" => "HIGH",
                "basis" => long_closed,
                "detail" => text
              }
            end,
          unresolved_findings:
            for text <- lists.(angle) do
              finding(%{
                "severity" => long_closed,
                "path" => emoji,
                "description" => text,
                "source" => mention,
                "disposition" => long_closed
              })
            end,
          evidence: %{
            "checks" => %{"status" => long_closed, "reasons" => lists.(long_closed)},
            "findings" => %{
              "status" => long_closed,
              "defect" => long_closed,
              "unresolved" => Map.new(1..10, &{"#{long_closed}#{&1}", long_closed})
            },
            "files" => %{
              "changed" => long_closed,
              "listed" => long_closed,
              "additions" => long_closed,
              "deletions" => long_closed,
              "incomplete" => long_closed
            },
            "sensitive_hits" =>
              for(text <- lists.(emoji), do: %{"path" => text, "group" => long_closed})
          },
          judgement: %{"status" => long_closed, "level" => long_closed, "defect" => long_closed}
        })

      body = render!(record, [])

      assert byte_size(body) <= 16_384
      assert String.starts_with?(body, PrReport.marker(@run_id, @head, @digest))
      assert body =~ ~r/\d+ more unresolved findings are not shown here\./
      assert body =~ ~r/\d+ more rationale lines are not shown here\./
      assert body =~ "### Instructions"
      assert String.ends_with?(body, "not proof that a check ran.")
    end

    test "findings that no longer fit once the other lists are listed are counted, never refused" do
      long = String.duplicate("<", 600)

      body =
        render!(
          record(%{
            rationale:
              for n <- 1..20 do
                %{
                  "rule" => "files",
                  "level" => "HIGH",
                  "basis" => "machine",
                  "detail" => long <> "#{n}"
                }
              end,
            instructions: for(n <- 1..20, do: long <> "#{n}"),
            unresolved_findings:
              for(n <- 1..20, do: finding(%{"description" => long, "path" => long <> "#{n}"}))
          })
        )

      assert byte_size(body) <= 16_384

      [rest] =
        Regex.run(~r/(\d+) more unresolved findings are not shown here\./, body,
          capture: :all_but_first
        )

      shown = length(Regex.scan(~r/^- major, open:/m, body))
      assert shown + String.to_integer(rest) == 20
      assert shown >= 1
    end

    test "one finding too big for what is left does not hide the findings after it" do
      emoji = String.duplicate("\u{1F600}", 600)
      long = String.duplicate("<", 600)
      wide = String.duplicate("\u{1F600}", 100)

      huge_first =
        finding(%{
          "severity" => "critical",
          "path" => emoji,
          "description" => emoji,
          "source" => emoji
        })

      normal = for n <- 1..10, do: finding(%{"severity" => "major", "line" => n})

      body =
        render!(
          record(%{
            rationale:
              for n <- 1..20 do
                %{
                  "rule" => "files",
                  "level" => "HIGH",
                  "basis" => "machine",
                  "detail" => long <> "#{n}"
                }
              end,
            instructions: for(n <- 1..20, do: long <> "#{n}"),
            evidence: %{
              "checks" => %{"status" => wide, "reasons" => for(n <- 1..20, do: wide <> "#{n}")},
              "findings" => %{"status" => wide, "defect" => wide, "unresolved" => %{wide => wide}},
              "files" => %{
                "changed" => wide,
                "listed" => wide,
                "additions" => wide,
                "deletions" => wide,
                "incomplete" => wide
              },
              "sensitive_hits" =>
                for(n <- 1..20, do: %{"path" => long <> "#{n}", "group" => "ci"})
            },
            unresolved_findings: [huge_first | normal]
          })
        )

      assert byte_size(body) <= 16_384
      refute body =~ emoji

      assert length(Regex.scan(~r/^- major, open: lib\/a\.ex:\d+: a plain description/m, body)) ==
               10

      assert body =~ "1 more unresolved findings are not shown here."
    end

    test "the budget is in bytes: multibyte and zero-width-escaped text" do
      cjk = String.duplicate("漢", 600)
      mention = String.duplicate("@", 600)

      for text <- [cjk, mention] do
        findings =
          for n <- 1..20 do
            finding(%{"path" => text, "description" => text, "source" => text, "line" => n})
          end

        body = render!(record(%{unresolved_findings: findings}))

        assert byte_size(body) <= 16_384
        assert body =~ ~r/\d+ more unresolved findings are not shown here\./
        assert String.length(body) < byte_size(body)
      end
    end

    test "the marker line is intact when the findings alone are far over the budget" do
      findings =
        for n <- 1..20, do: finding(%{"description" => String.duplicate("漢", 600), "line" => n})

      body = render!(record(%{unresolved_findings: findings}))

      assert byte_size(body) <= 16_384
      assert [first, _rest] = String.split(body, "\n", parts: 2)
      assert first == PrReport.marker(@run_id, @head, @digest)
      assert {:ok, %{run_id: @run_id}} = PrReport.parse_marker(body)
    end
  end
end
