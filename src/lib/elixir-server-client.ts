export type ForemanServerCommand = {
  command_id: string;
  command_type: string;
  schema_version?: number;
  payload?: Record<string, unknown>;
  metadata?: Record<string, unknown>;
};

export type ForemanServerOk = {
  ok: true;
  events: string[];
  projection_version: number;
  correlation_id: string;
};

export type ForemanServerError = {
  ok: false;
  error: {
    code: "VALIDATION_FAILED" | "CONFLICT" | "UNAUTHORIZED" | "UNSUPPORTED" | "INTERNAL";
    message: string;
    details: Record<string, unknown>;
    retryable: boolean;
    correlation_id?: string;
  };
};

export type ForemanServerResponse = ForemanServerOk | ForemanServerError;

export class ElixirServerClient {
  constructor(
    private readonly baseUrl: string,
    private readonly authToken?: string,
  ) {}

  async sendCommand(command: ForemanServerCommand): Promise<ForemanServerResponse> {
    const response = await fetch(new URL("/api/v1/commands", this.baseUrl), {
      method: "POST",
      headers: this.headers(command),
      body: JSON.stringify({ schema_version: 1, payload: {}, metadata: {}, ...command }),
    });

    const body = (await response.json()) as ForemanServerResponse;
    if (!body.ok || response.ok) return body;

    return {
      ok: false,
      error: {
        code: "INTERNAL",
        message: `unexpected Foreman server status ${response.status}`,
        details: body,
        retryable: false,
        correlation_id: command.metadata?.correlation_id as string | undefined,
      },
    };
  }

  private headers(command: ForemanServerCommand): Record<string, string> {
    const headers: Record<string, string> = {
      "content-type": "application/json",
    };

    const correlationId = command.metadata?.correlation_id;
    if (typeof correlationId === "string") headers["x-correlation-id"] = correlationId;
    if (this.authToken) headers.authorization = `Bearer ${this.authToken}`;

    return headers;
  }
}
