import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
	detectHarness,
	detectModel,
	EXIT,
	globToRegExp,
	loadRegistry,
	matchProfile,
	normalizeModelId,
	resolveProfile,
	routeAll,
	routeTask,
	validateRegistry,
} from './router.mjs';

const registry = loadRegistry();
const routerPath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'router.mjs');

const resolve = (options) => resolveProfile(registry, { env: {}, ...options });
const route = (taskId, options) => routeTask(registry, taskId, resolve(options));

describe('normalizeModelId', () => {
	it('lowercases and drops the provider prefix', () => {
		assert.equal(normalizeModelId('Anthropic/Claude-Opus-4-5'), 'claude-opus-4-5');
	});

	it('drops common version suffixes', () => {
		assert.equal(normalizeModelId('claude-3-5-sonnet:latest'), 'claude-3-5-sonnet');
	});

	it('returns an empty string for non-strings', () => {
		assert.equal(normalizeModelId(undefined), '');
		assert.equal(normalizeModelId('   '), '');
	});
});

describe('globToRegExp', () => {
	it('treats * as any run of characters and ? as one', () => {
		assert.ok(globToRegExp('*sonnet*').test('claude-3-5-sonnet-latest'));
		assert.ok(globToRegExp('gpt-?').test('gpt-5'));
		assert.ok(!globToRegExp('gpt-?').test('gpt-55'));
	});

	it('does not treat regex metacharacters in patterns as syntax', () => {
		assert.ok(globToRegExp('qwen2.5*').test('qwen2.5-max'));
		assert.ok(!globToRegExp('qwen2.5*').test('qwen2x5-max'));
	});
});

describe('detectModel', () => {
	it('prefers the explicit flag over the environment', () => {
		const detected = detectModel(registry, {
			modelFlag: 'claude-opus-4-5',
			env: { ARENA_MODEL: 'gpt-5' },
		});
		assert.equal(detected.modelId, 'claude-opus-4-5');
		assert.equal(detected.confidence, 'high');
	});

	it('prefers Arena runtime vars over provider vars', () => {
		const detected = detectModel(registry, {
			env: { ANTHROPIC_MODEL: 'claude-opus-4-5', ARENA_MODEL: 'gpt-5-mini' },
		});
		assert.equal(detected.modelId, 'gpt-5-mini');
		assert.equal(detected.source, '$ARENA_MODEL');
	});

	it('reports no confidence when nothing is set', () => {
		const detected = detectModel(registry, { env: {} });
		assert.equal(detected.modelId, undefined);
		assert.equal(detected.confidence, 'none');
	});

	it('ignores blank values', () => {
		const detected = detectModel(registry, { env: { ARENA_MODEL: '   ' } });
		assert.equal(detected.modelId, undefined);
	});
});

describe('detectHarness', () => {
	it('recognises an Arena sandbox', () => {
		assert.equal(detectHarness(registry, { env: { E2B_SANDBOX_ID: 'abc' } }).harness, 'arena');
	});

	it('falls back to generic', () => {
		assert.equal(detectHarness(registry, { env: {} }).harness, 'generic');
	});
});

describe('matchProfile', () => {
	it('matches a family and ignores version drift', () => {
		assert.equal(matchProfile(registry, 'claude-opus-4-5').profileId, 'anthropic-claude-opus');
		assert.equal(matchProfile(registry, 'claude-opus-6').profileId, 'anthropic-claude-opus');
	});

	it('lets the most specific pattern win', () => {
		assert.equal(matchProfile(registry, 'gpt-5').profileId, 'openai-frontier');
		assert.equal(matchProfile(registry, 'gpt-5-mini').profileId, 'openai-mini');
		assert.equal(matchProfile(registry, 'gemini-2.5-flash').profileId, 'google-gemini-flash');
		assert.equal(
			matchProfile(registry, 'gemini-2.5-flash-lite').profileId,
			'google-gemini-flash-lite',
		);
	});

	it('falls back to the weakest profile for an unknown id', () => {
		const resolved = resolve({ modelFlag: 'brand-new-model' });
		assert.equal(resolved.recognized, false);
		assert.equal(resolved.profile.tier, 'unknown');
	});
});

describe('routeTask verdicts', () => {
	it('allows a frontier model to refactor across files', () => {
		const result = route('multi-file-refactor', { modelFlag: 'claude-opus-4-5' });
		assert.equal(result.verdict, 'allow');
		assert.deepEqual(result.reasons, []);
	});

	it('refuses the same task on an efficient model and explains the gap', () => {
		const result = route('multi-file-refactor', { modelFlag: 'claude-haiku-4-5' });
		assert.equal(result.verdict, 'refused');
		assert.ok(result.reasons.some((reason) => reason.code === 'tier'));
		assert.ok(result.alternatives.length > 0);
	});

	it('lets an efficient model do work that does not need frontier reasoning', () => {
		assert.equal(
			route('commit-and-pr-text', { modelFlag: 'claude-haiku-4-5' }).verdict,
			'allow',
		);
		assert.equal(
			route('deterministic-computation', { modelFlag: 'some-7b-model' }).verdict,
			'allow',
		);
	});

	it('refuses a task the harness cannot perform', () => {
		const result = route('audio-transcription', {
			modelFlag: 'claude-opus-4-5',
			env: { GITHUB_ACTIONS: 'true' },
		});
		assert.equal(result.verdict, 'refused');
		assert.ok(result.reasons.some((reason) => reason.code === 'harness-capability'));
	});

	it('returns guardrails instead of refusing when a harness capability is unverified', () => {
		const result = route('pr-merge', { modelFlag: 'claude-opus-4-5', env: {} });
		assert.equal(result.verdict, 'guardrails');
		assert.deepEqual(result.unknownHarness, ['githubWrite']);
		assert.ok(result.guardrails.length > 0);
	});

	it('never lets a stronger model route around a hard refusal', () => {
		for (const taskId of ['secret-handling', 'fabricated-evidence', 'unauthorized-mutation']) {
			const result = route(taskId, { modelFlag: 'claude-opus-4-5' });
			assert.equal(result.verdict, 'refused', taskId);
			assert.ok(result.reasons.some((reason) => reason.code === 'hard-refuse'), taskId);
		}
	});

	it('treats an unidentified model as the weakest, not the strongest', () => {
		const result = route('architecture-design', { env: {} });
		assert.equal(result.verdict, 'refused');
		assert.ok(result.reasons.some((reason) => reason.detail.includes('unknown')));
	});

	it('returns undefined for an unknown task class', () => {
		assert.equal(routeTask(registry, 'not-a-task', resolve({})), undefined);
	});

	it('classifies every task class for every profile', () => {
		const profiles = Object.keys(registry.profiles).filter((key) => !key.startsWith('$'));
		for (const profileId of profiles) {
			const modelFlag = registry.profiles[profileId].match[0].replaceAll('*', 'x');
			for (const result of routeAll(registry, resolve({ modelFlag }))) {
				assert.ok(
					['allow', 'guardrails', 'refused'].includes(result.verdict),
					`${profileId}/${result.taskId}`,
				);
			}
		}
	});
});

describe('validateRegistry', () => {
	it('accepts the committed registry', () => {
		assert.deepEqual(validateRegistry(registry), []);
	});

	it('rejects a profile that references an unknown capability', () => {
		const broken = structuredClone(registry);
		broken.profiles['anthropic-claude-opus'].capabilities.teleportation = true;
		assert.ok(validateRegistry(broken).some((problem) => problem.includes('teleportation')));
	});

	it('rejects a task with no refusal alternative', () => {
		const broken = structuredClone(registry);
		broken.taskClasses['bug-root-cause'].alternatives = [];
		assert.ok(validateRegistry(broken).some((problem) => problem.includes('refusal alternative')));
	});

	it('rejects duplicate match patterns across profiles', () => {
		const broken = structuredClone(registry);
		broken.profiles['anthropic-claude-sonnet'].match.push('*opus*');
		assert.ok(validateRegistry(broken).some((problem) => problem.includes('declared by both')));
	});

	it('rejects a hard refusal that depends on model tier', () => {
		const broken = structuredClone(registry);
		broken.taskClasses['secret-handling'].minTier = 'frontier';
		assert.ok(validateRegistry(broken).some((problem) => problem.includes('must not depend')));
	});
});

describe('cli', () => {
	const run = (args, env = {}) =>
		execFileSync(process.execPath, [routerPath, ...args], {
			encoding: 'utf8',
			env: { PATH: process.env.PATH, ...env },
			stdio: ['ignore', 'pipe', 'pipe'],
		});

	const runExpectStatus = (args, env = {}) => {
		try {
			run(args, env);
			return 0;
		} catch (error) {
			return error.status;
		}
	};

	it('exits 0 when the registry is valid', () => {
		assert.match(run(['check']), /Registry OK/);
	});

	it('exits 0 for an allowed task and 3 for a refused one', () => {
		assert.equal(
			runExpectStatus(['route', '--task', 'bug-root-cause', '--model', 'gpt-5']),
			EXIT.allowed,
		);
		assert.equal(
			runExpectStatus(['route', '--task', 'bug-root-cause', '--model', 'claude-haiku-4-5']),
			EXIT.refused,
		);
	});

	it('exits 2 for an unknown task class', () => {
		assert.equal(runExpectStatus(['route', '--task', 'nope']), EXIT.usage);
	});

	it('emits parseable JSON for machine callers', () => {
		const output = run(['tasks', '--model', 'claude-opus-4-5', '--json']);
		const parsed = JSON.parse(output);
		assert.equal(parsed.tier, 'frontier');
		assert.equal(parsed.results.length > 10, true);
		assert.ok(parsed.results.every((result) => !('$comment' in result.task)));
	});

	it('honours a model reported through the environment', () => {
		const output = run(['detect', '--json'], { ARENA_MODEL: 'claude-sonnet-4-5' });
		assert.equal(JSON.parse(output).profile.tier, 'balanced');
	});
});
