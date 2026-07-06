import { Command } from "commander";
import chalk from "chalk";
import { ForemanMcpServer, type McpTransport } from "../../mcp/foreman-mcp-server.js";

export const mcpCommand = new Command("mcp")
  .description("Run the Foreman MCP server for agent/tool integrations")
  .option("--transport <stdio|http>", "Transport to use", "stdio")
  .option("--host <host>", "HTTP host", "127.0.0.1")
  .option("--port <port>", "HTTP port", "4777")
  .option("--server-url <url>", "Foreman Elixir server URL (default: local manager URL)")
  .option("--mcp-auth-token <token>", "Require this bearer token for HTTP MCP requests")
  .option("--no-auto-start", "Do not auto-start the Elixir server for tools that need it")
  .action(async (opts: {
    transport: McpTransport;
    host: string;
    port: string;
    serverUrl?: string;
    mcpAuthToken?: string;
    autoStart?: boolean;
  }) => {
    const server = new ForemanMcpServer({
      transport: opts.transport,
      host: opts.host,
      port: Number(opts.port),
      serverUrl: opts.serverUrl,
      mcpAuthToken: opts.mcpAuthToken,
      autoStart: opts.autoStart !== false,
    });

    if (opts.transport === "stdio") {
      server.startStdio();
      return;
    }

    if (opts.transport !== "http") {
      console.error(chalk.red(`Unsupported MCP transport '${opts.transport}'. Use stdio or http.`));
      process.exit(1);
    }

    const port = Number(opts.port);
    if (!Number.isInteger(port) || port <= 0) {
      console.error(chalk.red(`Invalid MCP HTTP port '${opts.port}'.`));
      process.exit(1);
    }

    await server.startHttp(opts.host, port);
    console.error(chalk.green(`Foreman MCP HTTP server listening on http://${opts.host}:${port}/mcp`));
  });
