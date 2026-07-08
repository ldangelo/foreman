# Task for worker

[Read from: /Users/ldangelo/Development/Fortium/foreman/context.md, /Users/ldangelo/Development/Fortium/foreman/plan.md]

You graphify extraction subagent. Read files listed extract knowledge graph fragment. Output ONLY valid JSON matching schema below - no explanation, no markdown fences, no preamble. Files (chunk 1 3):
/Users/ldangelo/Development/Fortium/foreman/graphify-out/.graphify_chunk_01_files.txt

IMPORTANT: read the file list from that path, then read those files. Write ONLY the JSON result to absolute path /Users/ldangelo/Development/Fortium/foreman/graphify-out/.graphify_chunk_01.json. Do not just return it in chat.

Rules: - EXTRACTED: relationship explicit in source (import, call, citation) - INFERRED: reasonable inference (shared structure, implied dependency) - AMBIGUOUS: uncertain — flag it, do not omit - Code files: semantic edges AST cannot find. Do not re-extract imports. adding `calls` edges: source caller, target callee, never reversed; keep `calls` within one language. - Doc/paper files: named concepts, entities, citations. Store rationale (WHY decisions made) `rationale` attribute on relevant node, not separate node. Use `file_type:"rationale"` concept-like nodes (ideas, principles, mechanisms) `file_type:"concept"` named concepts. `file_type` MUST be one exactly six values: `code`, `document`, `paper`, `image`, `rationale`, `concept`. Any other value invalid will rejected. - Image files: use vision — understand image IS, not just OCR - DEEP_MODE=false. - Semantic similarity: if two concepts solve same problem represent same idea without structural link (no import, call, citation), add `semantically_similar_to` edge marked INFERRED confidence_score 0.6-0.95. Non-obvious cross-file links only. - Hyperedges: if 3+ nodes share concept, flow, pattern not captured pairwise edges, add hyperedge top-level `hyperedges` array. Use sparingly. Max 3 per chunk. - If file YAML frontmatter (--- ... ---), copy source_url, captured_at. Confidence scores: EXTRACTED 1.0; INFERRED one of 0.95,0.85,0.75,0.65,0.55,0.5; AMBIGUOUS 0.1-0.3. ID `[a-z0-9_]`, slashes. Format `{stem}_{entity}` where stem is `{parent_dir}_{filename_without_ext}` immediate parent directory + filename stem, both lowercased non-alphanumeric chars replaced by `_`; entity symbol name similarly normalized. Only one level parent. Top-level files use just filename stem. Never append chunk sequence suffixes. Output exactly JSON: {"nodes":[{"id":"session_validatetoken","label":"Human Readable Name","file_type":"code|document|paper|image|rationale|concept","source_file":"relative/path","source_location":null,"source_url":null,"captured_at":null,"author":null,"contributor":null}],"edges":[{"source":"node_id","target":"node_id","relation":"calls|implements|references|cites|conceptually_related_to|shares_data_with|semantically_similar_to|rationale_for","confidence":"EXTRACTED|INFERRED|AMBIGUOUS","confidence_score":1.0,"source_file":"relative/path","source_location":null,"weight":1.0}],"hyperedges":[{"id":"snake_case_id","label":"Human Readable Label","nodes":["node_id1","node_id2","node_id3"],"relation":"participate_in|implement|form","confidence":"EXTRACTED|INFERRED","confidence_score":0.75,"source_file":"relative/path"}],"input_tokens":0,"output_tokens":0}

---
Update progress at: /Users/ldangelo/Development/Fortium/foreman/.pi-subagents/artifacts/progress/569fd11b/progress.md

## Acceptance Contract
Acceptance level: checked
Completion is not accepted from prose alone. End with a structured acceptance report.

Criteria:
- criterion-1: Implement the requested change without widening scope

Required evidence: changed-files, tests-added, commands-run, residual-risks, no-staged-files

Finish with a fenced JSON block tagged `acceptance-report` in this shape:
Use empty arrays when no items apply; array fields contain strings unless object entries are shown.
```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "specific proof"
    }
  ],
  "changedFiles": [
    "src/file.ts"
  ],
  "testsAddedOrUpdated": [
    "test/file.test.ts"
  ],
  "commandsRun": [
    {
      "command": "command",
      "result": "passed",
      "summary": "short result"
    }
  ],
  "validationOutput": [
    "validation output or concise summary"
  ],
  "residualRisks": [
    "none"
  ],
  "noStagedFiles": true,
  "diffSummary": "short description of the diff",
  "reviewFindings": [
    "blocker: file.ts:12 - issue found, or no blockers"
  ],
  "manualNotes": "anything else the parent should know"
}
```