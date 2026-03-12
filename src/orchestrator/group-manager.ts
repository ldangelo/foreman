import type { ForemanStore, TaskGroup } from "../lib/store.js";
import type { SeedsClient } from "../lib/seeds.js";

export interface GroupStatus {
  group: TaskGroup;
  members: Array<{
    seed_id: string;
    status: string;
    title: string;
  }>;
  total: number;
  completed: number;
  progress: number; // 0-100
}

export class GroupManager {
  constructor(
    private store: ForemanStore,
    private seeds: SeedsClient,
  ) {}

  /**
   * Check if all members of a group are done, and if so, auto-close the group
   * and its parent seed. Returns true if the group was auto-closed.
   */
  async checkAndAutoClose(group: TaskGroup): Promise<boolean> {
    if (group.status !== "active") return false;

    const members = this.store.getGroupMembers(group.id);
    if (members.length === 0) return false;

    // Check all member statuses
    const statuses = await Promise.all(
      members.map(async (m) => {
        try {
          const seed = await this.seeds.show(m.seed_id);
          return { seed_id: m.seed_id, done: seed.status === "closed" || seed.status === "completed" };
        } catch {
          // If we can't fetch the seed (e.g. deleted), treat it as not done.
          // Safety default: groups with deleted members will never auto-close
          // unless the member is explicitly removed or the group is manually closed.
          return { seed_id: m.seed_id, done: false };
        }
      })
    );

    const allDone = statuses.every((s) => s.done);
    if (!allDone) return false;

    // All members done — close the group
    const now = new Date().toISOString();
    this.store.updateGroup(group.id, { status: "completed", completed_at: now });

    // Close parent seed if set
    if (group.parent_seed_id) {
      try {
        await this.seeds.close(group.parent_seed_id, `Task group "${group.name}" completed — all ${members.length} member(s) done`);
      } catch {
        // Parent seed might already be closed or not exist — continue
      }
    }

    return true;
  }

  /**
   * Get detailed status for a group including member statuses.
   */
  async getGroupStatus(groupId: string): Promise<GroupStatus | null> {
    const group = this.store.getGroup(groupId);
    if (!group) return null;

    const members = this.store.getGroupMembers(groupId);

    const memberStatuses = await Promise.all(
      members.map(async (m) => {
        try {
          const seed = await this.seeds.show(m.seed_id);
          return { seed_id: m.seed_id, status: seed.status, title: seed.title };
        } catch {
          return { seed_id: m.seed_id, status: "unknown", title: "(not found)" };
        }
      })
    );

    const completedCount = memberStatuses.filter(
      (m) => m.status === "closed" || m.status === "completed"
    ).length;

    return {
      group,
      members: memberStatuses,
      total: members.length,
      completed: completedCount,
      progress: members.length > 0 ? Math.round((completedCount / members.length) * 100) : 0,
    };
  }

  /**
   * Check all active groups and auto-close any that are done.
   */
  async checkAllGroups(projectId?: string): Promise<TaskGroup[]> {
    const activeGroups = this.store.listActiveGroups(projectId);
    const closed: TaskGroup[] = [];

    for (const group of activeGroups) {
      const didClose = await this.checkAndAutoClose(group);
      if (didClose) closed.push(group);
    }

    return closed;
  }
}
