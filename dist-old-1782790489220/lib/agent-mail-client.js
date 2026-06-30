export class NullAgentMailClient {
    agentName = null;
    async healthCheck() { return true; }
    async ensureProject(_projectPath) { }
    setRunId(_runId) { }
    async ensureAgentRegistered(roleHint) {
        this.agentName = roleHint;
        return roleHint;
    }
    async sendMessage(_to, _subject, _body) { }
    async fetchInbox(_agent, _options) { return []; }
    async acknowledgeMessage(_agent, _messageId) { }
    async reserveFiles(_paths, _agentName, _leaseSecs) { }
    async releaseFiles(_paths, _agentName) { }
}
//# sourceMappingURL=agent-mail-client.js.map