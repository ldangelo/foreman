import { PostgresStore } from "./postgres-store.js";
import { listRegisteredProjects } from "../cli/commands/project-task-support.js";
export class PostgresMailClient {
    agentName = null;
    store = null;
    runId = null;
    projectPath = null;
    async healthCheck() {
        return true;
    }
    async ensureProject(projectPath) {
        this.projectPath = projectPath;
        const projects = await listRegisteredProjects();
        const project = projects.find((record) => record.path === projectPath);
        if (!project) {
            throw new Error(`Project at '${projectPath}' is not registered with the daemon.`);
        }
        this.store = PostgresStore.forProject(project.id);
    }
    setRunId(runId) {
        this.runId = runId;
    }
    async ensureAgentRegistered(roleHint) {
        if (!this.agentName) {
            this.agentName = roleHint;
        }
        return roleHint;
    }
    async sendMessage(to, subject, body) {
        if (!this.store || !this.runId)
            return;
        await this.store.sendMessage(this.runId, this.agentName ?? "foreman", to, subject, body);
    }
    async fetchInbox(agent, options) {
        if (!this.store || !this.runId)
            return [];
        const messages = await this.store.getMessages(this.runId, agent, true);
        const sliced = messages.slice(0, options?.limit ?? 50);
        return sliced.map((m) => ({
            id: m.id,
            from: m.sender_agent_type,
            to: m.recipient_agent_type,
            subject: m.subject,
            body: m.body,
            receivedAt: m.created_at,
            acknowledged: m.read === 1,
        }));
    }
    async acknowledgeMessage(_agent, messageId) {
        if (!this.store)
            return;
        await this.store.markMessageRead(String(messageId));
    }
    async reserveFiles(_paths, _agentName, _leaseSecs) {
        // No-op for now.
    }
    async releaseFiles(_paths, _agentName) {
        // No-op for now.
    }
}
//# sourceMappingURL=postgres-mail-client.js.map