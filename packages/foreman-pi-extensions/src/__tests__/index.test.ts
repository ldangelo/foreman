/**
 * Tests for the index barrel: verifies that all three extensions and their
 * factory functions are properly exported, and that ALL_EXTENSIONS contains
 * the expected members in the correct order.
 */

import { describe, it, expect } from 'vitest';
import {
  toolGate,
  budget,
  audit,
  ALL_EXTENSIONS,
  PI_EXTENSIONS_VERSION,
  createToolGateExtension,
  createBudgetExtension,
  createAuditExtension,
} from '../index.js';

describe('index barrel exports', () => {
  describe('toolGate singleton', () => {
    it('has a name field', () => {
      expect(typeof toolGate.name).toBe('string');
      expect(toolGate.name.length).toBeGreaterThan(0);
    });

    it('has a version field', () => {
      expect(typeof toolGate.version).toBe('string');
      expect(toolGate.version.length).toBeGreaterThan(0);
    });
  });

  describe('budget singleton', () => {
    it('has a name field', () => {
      expect(typeof budget.name).toBe('string');
      expect(budget.name.length).toBeGreaterThan(0);
    });

    it('has a version field', () => {
      expect(typeof budget.version).toBe('string');
      expect(budget.version.length).toBeGreaterThan(0);
    });
  });

  describe('audit singleton', () => {
    it('has a name field', () => {
      expect(typeof audit.name).toBe('string');
      expect(audit.name.length).toBeGreaterThan(0);
    });

    it('has a version field', () => {
      expect(typeof audit.version).toBe('string');
      expect(audit.version.length).toBeGreaterThan(0);
    });
  });

  describe('ALL_EXTENSIONS', () => {
    it('has exactly 3 items', () => {
      expect(ALL_EXTENSIONS).toHaveLength(3);
    });

    it('first item is toolGate', () => {
      expect(ALL_EXTENSIONS[0]).toBe(toolGate);
    });

    it('second item is budget', () => {
      expect(ALL_EXTENSIONS[1]).toBe(budget);
    });

    it('third item is audit', () => {
      expect(ALL_EXTENSIONS[2]).toBe(audit);
    });

    it('all items have name and version fields', () => {
      for (const ext of ALL_EXTENSIONS) {
        expect(typeof ext.name).toBe('string');
        expect(typeof ext.version).toBe('string');
      }
    });
  });

  describe('PI_EXTENSIONS_VERSION', () => {
    it('is a non-empty string', () => {
      expect(typeof PI_EXTENSIONS_VERSION).toBe('string');
      expect(PI_EXTENSIONS_VERSION.length).toBeGreaterThan(0);
    });

    it('follows semver-like format', () => {
      expect(PI_EXTENSIONS_VERSION).toMatch(/^\d+\.\d+\.\d+/);
    });
  });

  describe('factory functions', () => {
    it('createToolGateExtension is callable and returns an extension', () => {
      const ext = createToolGateExtension();
      expect(typeof ext.name).toBe('string');
      expect(typeof ext.version).toBe('string');
    });

    it('createBudgetExtension is callable and returns an extension', () => {
      const ext = createBudgetExtension();
      expect(typeof ext.name).toBe('string');
      expect(typeof ext.version).toBe('string');
    });

    it('createAuditExtension is callable and returns an extension', () => {
      const ext = createAuditExtension();
      expect(typeof ext.name).toBe('string');
      expect(typeof ext.version).toBe('string');
    });

    it('createToolGateExtension accepts an optional audit callback', () => {
      const calls: object[] = [];
      const ext = createToolGateExtension((e) => calls.push(e));
      expect(ext).toBeDefined();
    });

    it('createBudgetExtension accepts an optional audit callback', () => {
      const calls: object[] = [];
      const ext = createBudgetExtension((e) => calls.push(e));
      expect(ext).toBeDefined();
    });

    it('createAuditExtension accepts an optional output directory', () => {
      const ext = createAuditExtension('/tmp/foreman-test-audit');
      expect(ext).toBeDefined();
    });
  });
});
