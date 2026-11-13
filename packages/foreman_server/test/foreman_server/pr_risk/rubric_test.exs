defmodule ForemanServer.PrRisk.RubricTest do
  use ExUnit.Case, async: true

  alias ForemanServer.PrEvidence.Reason
  alias ForemanServer.PrRisk.Rubric
  alias ForemanServer.PrRisk.Rubric.Inputs
  alias ForemanServer.PrRisk.Rubric.Result

  @head "aaaa1111"
  @lib "packages/foreman_server/lib/foreman_server/"

  defp file(path, additions \\ 1, deletions \\ 1),
    do: %{path: path, additions: additions, deletions: deletions}

  defp finding(severity, disposition),
    do: %{
      "severity" => severity,
      "disposition" => disposition,
      "path" => "lib/a.ex",
      "line" => 1,
      "description" => "d",
      "source" => "s"
    }

  defp findings(list, overrides \\ %{}),
    do:
      Map.merge(
        %{head_sha: @head, status: "recorded", defect: nil, findings: list, judgement: nil},
        overrides
      )

  # Inputs with no trigger at all: the LOW baseline every test perturbs.
  defp low(overrides \\ []) do
    base = %Inputs{
      head_sha: @head,
      files: [file("lib/a.ex")],
      changed_files: 1,
      additions: 10,
      deletions: 5,
      checks: %{status: :eligible, reasons: []},
      findings: findings([]),
      base_branch: "main",
      recorded_base: "main",
      judgement: %{status: "recorded", level: "LOW"}
    }

    struct!(base, overrides)
  end

  defp rule(%Result{rationale: r}, name), do: Enum.find(r, &(&1.rule == name))

  defp sized(n_files),
    do: low(files: for(i <- 1..n_files, do: file("lib/f#{i}.ex")), changed_files: n_files)

  describe "LOW" do
    test "no trigger and a LOW judgement for this head is LOW with every rule that held" do
      result = Rubric.classify(low())

      assert result.level == "LOW"
      assert result.rubric_version == "1"
      assert result.instructions == []
      assert result.sensitive_hits == []
      assert Enum.all?(result.rationale, &(&1.level == "LOW"))

      assert Enum.map(result.rationale, & &1.rule) ==
               ~w(checks files lines paths sensitive_path base_branch findings unresolved judgement)

      assert rule(result, "checks").basis == "machine"
      assert rule(result, "findings").basis == "agent_claim"
    end

    test "nitpicks, fixed findings and a declined minor are not unresolved" do
      list = [
        finding("nitpick", "open"),
        finding("critical", "fixed"),
        finding("minor", "declined"),
        finding("nitpick", "declined")
      ]

      result = Rubric.classify(low(findings: findings(list)))
      assert result.level == "LOW"
      assert result.unresolved == %{critical: 0, major: 0, minor: 0, nitpick: 1}
    end

    test "string keys and string statuses read like atoms (live and replayed fold agree)" do
      inputs =
        low(
          checks: %{"status" => "eligible", "reasons" => []},
          findings: %{
            "head_sha" => @head,
            "status" => "recorded",
            "defect" => nil,
            "findings" => []
          },
          judgement: %{"status" => "recorded", "level" => "LOW"},
          files: [%{"path" => "lib/a.ex"}]
        )

      assert Rubric.classify(inputs).level == "LOW"
    end
  end

  describe "HIGH triggers (one each)" do
    test "a sensitive path names the group and the path" do
      result = Rubric.classify(low(files: [file(".github/workflows/ci.yml")], changed_files: 1))

      assert result.level == "HIGH"
      assert %{level: "HIGH", basis: "machine", detail: detail} = rule(result, "sensitive_path")
      assert detail =~ "CI"
      assert detail =~ ".github/workflows/ci.yml"
      assert result.sensitive_hits == [%{path: ".github/workflows/ci.yml", group: "CI"}]
      assert Enum.any?(result.instructions, &(&1 =~ "sensitive path"))
    end

    test "an unavailable path list" do
      result = Rubric.classify(low(files: nil))
      assert result.level == "HIGH"
      assert rule(result, "paths").level == "HIGH"
    end

    test "a path list shorter than changed_files" do
      result = Rubric.classify(low(files: [file("lib/a.ex")], changed_files: 2))
      assert result.level == "HIGH"
      assert %{level: "HIGH", detail: detail} = rule(result, "paths")
      assert detail =~ "1 of 2"
      assert rule(result, "files").level == "LOW"
    end

    test "a missing changed-files count" do
      result = Rubric.classify(low(changed_files: nil))
      assert rule(result, "paths").level == "HIGH"
      assert result.level == "HIGH"
    end

    test "missing line counts" do
      assert Rubric.classify(low(additions: nil)).level == "HIGH"
      assert Rubric.classify(low(deletions: nil)).level == "HIGH"
    end

    test "a base branch that differs from the recorded base" do
      result = Rubric.classify(low(base_branch: "release"))
      assert result.level == "HIGH"
      assert rule(result, "base_branch").detail =~ "differs"
    end

    test "no recorded base (a secondary repository's PR)" do
      assert Rubric.classify(low(recorded_base: nil)).level == "HIGH"
      assert Rubric.classify(low(recorded_base: nil, base_branch: nil)).level == "HIGH"
      assert Rubric.classify(low(base_branch: nil)).level == "HIGH"
    end

    test "findings missing, absent, malformed, in the earlier format or for another head" do
      cases = [
        {nil, "missing"},
        {findings([], %{status: "absent"}), "absent"},
        {findings([], %{status: "malformed", defect: "invalid_json"}), "malformed"},
        {findings([], %{status: "malformed", defect: "legacy_format"}), "legacy_format"},
        {findings([], %{head_sha: "bbbb2222"}), "other_head"},
        {findings([], %{status: "bogus"}), "malformed"}
      ]

      for {record, label} <- cases do
        result = Rubric.classify(low(findings: record))
        assert result.level == "HIGH", label
        assert %{level: "HIGH", basis: "agent_claim", detail: detail} = rule(result, "findings")
        assert detail =~ label
        assert result.unresolved == nil
        assert rule(result, "unresolved") == nil
      end
    end

    test "findings with no decided head are for another head" do
      result = Rubric.classify(low(head_sha: nil))
      assert rule(result, "findings").detail =~ "other_head"
      assert result.level == "HIGH"
    end

    test "an unresolved critical or major finding" do
      for severity <- ["critical", "major"] do
        result = Rubric.classify(low(findings: findings([finding(severity, "open")])))
        assert result.level == "HIGH"
        assert rule(result, "unresolved").level == "HIGH"
      end
    end

    test "a critical or major finding marked declined still counts" do
      for severity <- [:critical, :major] do
        result =
          Rubric.classify(
            low(findings: findings([finding(Atom.to_string(severity), "declined")]))
          )

        assert result.level == "HIGH"
        assert result.unresolved[severity] == 1
      end
    end

    test "a fixed critical finding is not unresolved" do
      result = Rubric.classify(low(findings: findings([finding("critical", "fixed")])))
      assert result.level == "LOW"
    end

    test "judgement missing, absent, malformed, without a level, for another head" do
      cases = [
        nil,
        %{status: "absent", level: nil},
        %{status: "malformed", level: nil},
        %{status: "recorded", level: nil},
        %{status: "recorded", level: "SEVERE"},
        %{status: "other_head", level: "LOW"},
        %{status: "recorded", level: "LOW", head_sha: "bbbb2222"}
      ]

      for judgement <- cases do
        result = Rubric.classify(low(judgement: judgement))
        assert result.level == "HIGH", inspect(judgement)
        assert %{level: "HIGH", basis: "agent_claim"} = rule(result, "judgement")
      end
    end

    test "a judgement carried by findings of another head is for another head" do
      result =
        Rubric.classify(
          low(
            findings: findings([], %{head_sha: "bbbb2222"}),
            judgement: %{status: "recorded", level: "LOW"}
          )
        )

      assert rule(result, "judgement").detail =~ "another head"
      assert rule(result, "judgement").level == "HIGH"
    end

    test "a judgement bound to this head by its own head_sha is accepted" do
      result =
        Rubric.classify(low(judgement: %{status: "recorded", level: "LOW", head_sha: @head}))

      assert result.level == "LOW"
    end

    test "a HIGH judgement over otherwise LOW inputs" do
      result = Rubric.classify(low(judgement: %{status: "recorded", level: "HIGH"}))
      assert result.level == "HIGH"
    end
  end

  describe "checks input" do
    test "only :eligible is LOW" do
      assert rule(Rubric.classify(low()), "checks").level == "LOW"
    end

    test "off, ineligible, unknown, waived and absent inputs are HIGH naming the reasons" do
      reasons = [
        %Reason{code: :skipped, subject: "ci", detail: nil},
        %{code: :checks_truncated},
        :stale,
        "failing"
      ]

      for checks <- [
            %{status: :off, reasons: []},
            %{status: :ineligible, reasons: reasons},
            %{status: :unknown, reasons: [%Reason{code: :evidence_unreadable}]},
            %{status: :waived, reasons: [%Reason{code: :missing}]},
            %{status: "ineligible", reasons: reasons},
            %{status: :something_else, reasons: []},
            nil
          ] do
        result = Rubric.classify(low(checks: checks))
        assert result.level == "HIGH", inspect(checks)
        assert rule(result, "checks").level == "HIGH"
      end

      detail =
        Rubric.classify(low(checks: %{status: :ineligible, reasons: reasons}))
        |> rule("checks")
        |> Map.fetch!(:detail)

      assert detail =~ "skipped, checks_truncated, stale, failing"
    end
  end

  describe "MEDIUM triggers" do
    test "an unresolved minor finding over LOW machine inputs" do
      result = Rubric.classify(low(findings: findings([finding("minor", "open")])))
      assert result.level == "MEDIUM"
      assert rule(result, "unresolved").level == "MEDIUM"
      assert Enum.any?(result.instructions, &(&1 =~ "unresolved findings"))
    end

    test "a MEDIUM judgement" do
      result = Rubric.classify(low(judgement: %{status: "recorded", level: "MEDIUM"}))
      assert result.level == "MEDIUM"
      assert rule(result, "judgement").level == "MEDIUM"
    end

    test "a MEDIUM size" do
      assert Rubric.classify(sized(11)).level == "MEDIUM"
      assert Rubric.classify(low(additions: 150, deletions: 51)).level == "MEDIUM"
    end
  end

  describe "thresholds (section 11 boundaries)" do
    test "changed files: 10 LOW, 11 MEDIUM, 25 MEDIUM, 26 HIGH" do
      for {n, level} <- [{10, "LOW"}, {11, "MEDIUM"}, {25, "MEDIUM"}, {26, "HIGH"}] do
        result = Rubric.classify(sized(n))
        assert rule(result, "files").level == level, "#{n} files"
        assert result.level == level, "#{n} files"
      end
    end

    test "changed files read changed_files, not the length of a shorter list" do
      result = Rubric.classify(low(files: [file("lib/a.ex")], changed_files: 26))
      assert rule(result, "files").level == "HIGH"
    end

    test "lines: 200 LOW, 201 MEDIUM, 800 MEDIUM, 801 HIGH (additions plus deletions)" do
      for {add, del, level} <- [
            {200, 0, "LOW"},
            {100, 100, "LOW"},
            {0, 201, "MEDIUM"},
            {101, 100, "MEDIUM"},
            {400, 400, "MEDIUM"},
            {0, 801, "HIGH"},
            {401, 400, "HIGH"}
          ] do
        result = Rubric.classify(low(additions: add, deletions: del))
        assert rule(result, "lines").level == level, "#{add}+#{del}"
        assert result.level == level, "#{add}+#{del}"
      end
    end
  end

  describe "raise-only" do
    test "a judgement lower than the floor leaves the floor and only changes its own line" do
      # a MEDIUM floor (11 files): a LOW judgement cannot lower it
      floor = sized(11)
      judged_low = Rubric.classify(%{floor | judgement: %{status: "recorded", level: "LOW"}})

      judged_medium =
        Rubric.classify(%{floor | judgement: %{status: "recorded", level: "MEDIUM"}})

      assert judged_low.level == "MEDIUM"
      assert rule(judged_low, "judgement").level == "LOW"
      assert judged_medium.level == "MEDIUM"

      strip = fn %Result{rationale: r} -> Enum.reject(r, &(&1.rule == "judgement")) end
      assert strip.(judged_low) == strip.(judged_medium)

      # a HIGH floor (base branch) stays HIGH under a LOW judgement
      high = Rubric.classify(low(base_branch: "release"))
      assert high.level == "HIGH"
      assert rule(high, "judgement").level == "LOW"
    end

    test "a judgement higher than the floor raises it" do
      assert Rubric.classify(low(judgement: %{status: "recorded", level: "MEDIUM"})).level ==
               "MEDIUM"

      assert Rubric.classify(%{sized(11) | judgement: %{status: "recorded", level: "HIGH"}}).level ==
               "HIGH"

      # the raised level is above the floor the machine rules alone give
      floor = Rubric.classify(%{sized(11) | judgement: %{status: "recorded", level: "LOW"}})
      raised = Rubric.classify(%{sized(11) | judgement: %{status: "recorded", level: "HIGH"}})
      assert floor.level == "MEDIUM"
      assert raised.level == "HIGH"
    end

    test "a LOW judgement never removes a findings or unresolved HIGH" do
      result =
        Rubric.classify(
          low(
            findings: findings([finding("major", "open")]),
            judgement: %{status: "recorded", level: "LOW"}
          )
        )

      assert result.level == "HIGH"
    end
  end

  describe "LOW is unreachable" do
    test "gate off, an empty policy, or a waiver" do
      for checks <- [
            %{status: :off, reasons: []},
            %{status: :ineligible, reasons: [%Reason{code: :no_checks_configured}]},
            %{status: :waived, reasons: [%Reason{code: :skipped}]}
          ] do
        assert Rubric.classify(low(checks: checks)).level == "HIGH"
      end
    end
  end

  describe "determinism" do
    test "the same inputs give the identical result and the version is part of it" do
      inputs = low(findings: findings([finding("minor", "open")]), files: [file(".env")])
      a = Rubric.classify(inputs)
      b = Rubric.classify(inputs)
      assert a == b
      assert a.rubric_version == Rubric.version()
      assert Rubric.version() == "1"
      assert {:ok, json} = Jason.encode(a)
      assert json =~ ~s("rubric_version":"1")
    end

    test "rationale carries one line per rule with a closed vocabulary" do
      result = Rubric.classify(low())

      for line <- result.rationale do
        assert line.rule in Rubric.rules()
        assert line.level in ["LOW", "MEDIUM", "HIGH"]
        assert line.basis in ["machine", "agent_claim"]
        assert is_binary(line.detail)
      end
    end
  end

  describe "sensitive-path table v1" do
    @hits [
      {"CI", ".github/workflows/ci.yml"},
      {"CI", ".github/workflows/sub/dir/x.yml"},
      {"CI scripts", "scripts/ci/changed-code.sh"},
      {"Runtime configuration", "packages/foreman_server/config/runtime.exs"},
      {"Migrations", "packages/foreman_server/priv/repo/migrations/20260101_a.exs"},
      {"Bundled workflows and prompts", "packages/foreman_server/priv/defaults/workflows/x.yaml"},
      {"Merge, approval and effect code", @lib <> "aggregates/run.ex"},
      {"Merge, approval and effect code", @lib <> "pr_gate.ex"},
      {"Merge, approval and effect code", @lib <> "run_pr_merge.ex"},
      {"Merge, approval and effect code", @lib <> "command_gateway.ex"},
      {"Merge, approval and effect code", @lib <> "github/pr_merge.ex"},
      {"Merge, approval and effect code", @lib <> "workflow/approver_authorizer.ex"},
      {"Merge, approval and effect code", @lib <> "workflow/merge_gate.ex"},
      {"Merge, approval and effect code", @lib <> "idempotency/effect.ex"},
      {"Evidence, risk and report code", @lib <> "pr_evidence.ex"},
      {"Evidence, risk and report code", @lib <> "pr_observation.ex"},
      {"Evidence, risk and report code", @lib <> "pr_watch_fold.ex"},
      {"Evidence, risk and report code", @lib <> "pr_risk.ex"},
      {"Evidence, risk and report code", @lib <> "pr_report.ex"},
      {"Evidence, risk and report code", @lib <> "aggregates/run/pr_watch.ex"},
      {"Evidence, risk and report code", @lib <> "github/pr_status.ex"},
      {"Evidence, risk and report code", @lib <> "workflow/review_findings.ex"},
      {"Evidence, risk and report code", @lib <> "pr_risk/rubric.ex"},
      {"Evidence, risk and report code", @lib <> "pr_report/render.ex"},
      {"Authentication and secrets",
       "packages/foreman_server/lib/foreman_server_web/plugs/bearer_auth.ex"},
      {"Authentication and secrets", @lib <> "mcp/auth.ex"},
      {"Authentication and secrets", @lib <> "mcp/policy.ex"},
      {"Authentication and secrets", @lib <> "aggregates/project_secret.ex"},
      {"Authentication and secrets", @lib <> "config_providers/secrets.ex"},
      {"Instruction files", "AGENTS.md"},
      {"Instruction files", "docs/sub/CLAUDE.md"},
      {"Dependency and build manifests", "mix.exs"},
      {"Dependency and build manifests", "packages/foreman_server/mix.exs"},
      {"Dependency and build manifests", "packages/foreman_server/mix.lock"},
      {"Dependency and build manifests", "go.mod"},
      {"Dependency and build manifests", "packages/x/package.json"},
      {"Dependency and build manifests", "package-lock.json"},
      {"Dependency and build manifests", "devbox.json"},
      {"Dependency and build manifests", "devbox.lock"},
      {"Dependency and build manifests", "deploy/Dockerfile"},
      {"Dependency and build manifests", "docker-compose.yml"},
      {"Secret-like names", "config/my_secret.txt"},
      {"Secret-like names", "deploy/Secrets.yaml"},
      {"Secret-like names", "config/SECRET_KEY.pem"},
      {"Secret-like names", "infra/secret.tfvars"},
      {"Secret-like names", "app/secrets.yaml"},
      {"Secret-like names", ".env"},
      {"Secret-like names", "deploy/.env.production"}
    ]

    @misses [
      # a base name that merely contains a manifest name
      "mix.exs.bak",
      "notmix.exs",
      "mix.exs/readme",
      "devbox.json.orig",
      "my-Dockerfile",
      "package.json5",
      "AGENTS.md.txt",
      "docs/CLAUDE.md.old",
      # a directory name that is only part of a prefix
      ".github/workflows",
      ".github/workflows-old/ci.yml",
      ".github/workflow/ci.yml",
      "x/.github/workflows/ci.yml",
      "scripts/ci",
      "scripts/cidr/x.sh",
      "scripts/ci-old/x.sh",
      "packages/foreman_server/config",
      "packages/foreman_server/configs/x.exs",
      "packages/foreman_server/priv/repo/migrations",
      "packages/foreman_server/priv/repo/migrations_old/x.exs",
      "packages/foreman_server/priv/defaults/workflows",
      "packages/foreman_server/priv/defaults/prompts/x.md",
      @lib <> "idempotency",
      @lib <> "idempotency_v2/x.ex",
      @lib <> "pr_risk_extra/x.ex",
      @lib <> "pr_report.exs",
      @lib <> "pr_reports/x.ex",
      "packages/foreman_server/lib/foreman_server_web/plugs",
      "packages/foreman_server/lib/foreman_server_web/plugs_old/x.ex",
      # an exact path under another root, or a lookalike name
      "lib/foreman_server/pr_gate.ex",
      "docs/" <> @lib <> "pr_gate.ex",
      @lib <> "pr_gate.exs",
      @lib <> "xaggregates/run.ex",
      @lib <> "aggregates/run/other.ex",
      @lib <> "pr_evidence_helper.ex",
      @lib <> "mcp/authx.ex",
      # near-miss names that do not contain `secret` or start with `.env`
      "docs/secre.md",
      "app/environment.ex",
      "a.env",
      "deploy/Env.yaml",
      "lib/a.ex",
      ""
    ]

    test "a path in each group is HIGH naming that group" do
      for {group, path} <- @hits do
        assert Rubric.sensitive_group(path) == group, path
        result = Rubric.classify(low(files: [file(path)], changed_files: 1))
        assert result.level == "HIGH", path
        assert result.sensitive_hits == [%{path: path, group: group}], path
        assert rule(result, "sensitive_path").detail =~ group, path
      end
    end

    test "every one of the eleven table groups is covered" do
      assert @hits |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
               Enum.sort([
                 "CI",
                 "CI scripts",
                 "Authentication and secrets",
                 "Bundled workflows and prompts",
                 "Dependency and build manifests",
                 "Evidence, risk and report code",
                 "Instruction files",
                 "Merge, approval and effect code",
                 "Migrations",
                 "Runtime configuration",
                 "Secret-like names"
               ])
    end

    test "a path that only resembles one is no hit" do
      for path <- @misses do
        assert Rubric.sensitive_group(path) == nil, inspect(path)
        result = Rubric.classify(low(files: [file(path)], changed_files: 1))
        assert result.sensitive_hits == [], inspect(path)
        assert rule(result, "sensitive_path").level == "LOW", inspect(path)
      end
    end

    test "hits are computed from the paths: a payload cannot supply them" do
      forged = low(files: [%{path: "lib/a.ex", additions: 1, deletions: 1, sensitive: true}])
      assert Rubric.classify(forged).sensitive_hits == []
    end

    test "hits are listed per sensitive path across several files" do
      files = [file("AGENTS.md"), file("lib/a.ex"), file("go.mod")]
      result = Rubric.classify(low(files: files, changed_files: 3))

      assert result.sensitive_hits == [
               %{path: "AGENTS.md", group: "Instruction files"},
               %{path: "go.mod", group: "Dependency and build manifests"}
             ]
    end

    test "non-binary paths are no hit" do
      assert Rubric.sensitive_group(nil) == nil
      assert Rubric.sensitive_group(:atom) == nil
    end
  end
end
