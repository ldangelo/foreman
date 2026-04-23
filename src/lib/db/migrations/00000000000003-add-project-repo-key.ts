import type { MigrationBuilder } from "node-pg-migrate";

export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.addColumn("projects", {
    repo_key: {
      type: "text",
      notNull: false,
      comment: "Canonical lowercased owner/repo key for GitHub-backed projects.",
    },
  });

  pgm.sql(`
    WITH ranked AS (
      SELECT
        id,
        CASE
          WHEN github_url ~* '^https?://github\\.com/[^/]+/[^/]+' THEN
            lower(regexp_replace(github_url, '^https?://github\\.com/([^/]+/[^/.]+).*$','\\1', 'i'))
          WHEN github_url ~* '^git@github\\.com:[^/]+/[^.]+' THEN
            lower(regexp_replace(github_url, '^git@github\\.com:([^/]+/[^.]+)(?:\\.git)?$','\\1', 'i'))
          ELSE NULL
        END AS normalized_key,
        row_number() OVER (
          PARTITION BY
            CASE
              WHEN github_url ~* '^https?://github\\.com/[^/]+/[^/]+' THEN
                lower(regexp_replace(github_url, '^https?://github\\.com/([^/]+/[^/.]+).*$','\\1', 'i'))
              WHEN github_url ~* '^git@github\\.com:[^/]+/[^.]+' THEN
                lower(regexp_replace(github_url, '^git@github\\.com:([^/]+/[^.]+)(?:\\.git)?$','\\1', 'i'))
              ELSE NULL
            END
          ORDER BY created_at ASC, id ASC
        ) AS row_rank
      FROM projects
    )
    UPDATE projects p
    SET repo_key = ranked.normalized_key
    FROM ranked
    WHERE p.id = ranked.id
      AND ranked.normalized_key IS NOT NULL
      AND ranked.row_rank = 1;
  `);

  pgm.createIndex("projects", "repo_key", {
    ifNotExists: true,
    unique: true,
    where: "repo_key IS NOT NULL",
    name: "projects_repo_key_unique",
  });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropIndex("projects", "repo_key", {
    ifExists: true,
    name: "projects_repo_key_unique",
  });
  pgm.dropColumn("projects", "repo_key", {
    ifExists: true,
  });
}
