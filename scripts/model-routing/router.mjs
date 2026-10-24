#!/usr/bin/env node

/**
 * Routes a task to a verdict based on the model and harness that are actually
 * running, so an agent stops guessing whether it should attempt the work.
 *
 * Usage:
 *   node scripts/model-routing/router.mjs detect [--model <id>] [--harness <name>] [--json]
 *   node scripts/model-routing/router.mjs tasks  [--model <id>] [--harness <name>] [--json]
 *   node scripts/model-routing/router.mjs route --task <id> [--model <id>] [--json]
 *   node scripts/model-routing/router.mjs list   [--json]
 *   node scripts/model-routing/router.mjs check  [--json]
 *
 * Exit codes: 0 allowed, 3 refused, 2 usage error, 1 registry error.
 */

import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const registryPath = path.join(scriptDir, 'registry.json');

export const EXIT = {
	allowed: 0,
	registry: 1,
	usage: 2,
	refused: 3,
};

const SKIP_KEY = '$comment';

/** Lowercase, drop the provider prefix and common version suffixes. */
export function normalizeModelId(raw) {
	if (typeof raw !== 'string') return '';
	let id = raw.trim().toLowerCase();
	if (!id) return '';
	id = id.split('/').pop() ?? id;
	id = id.replace(/:(latest|free|stable|preview)$/, '');
	id = id.replace(/\s+/g, '');
	return id;
}

/** `*` matches any run of characters, `?` a single character. No other metacharacters. */
export function globToRegExp(pattern) {
	const escaped = pattern
		.trim()
		.toLowerCase()
		.replace(/[.+^${}()|[\]\\]/g, '\\$&')
		.replace(/\*/g, '.*')
		.replace(/\?/g, '.');
	return new RegExp(`^${escaped}$`);
}

/**
 * Specificity is the longest literal run in the pattern, not the total literal
 * count: `*flash-lite*` (10) must beat `*gemini-*-flash*` (7), which otherwise
 * still matches a `-flash-lite` id.
 */
function literalLength(pattern) {
	return pattern
		.split(/[*?]+/)
		.reduce((longest, run) => Math.max(longest, run.length), 0);
}

/**
 * Most specific pattern wins, so `gpt-5-mini` is not swallowed by `*gpt-5*`.
 * Ties fall back to declaration order in registry.json.
 */
export function matchProfile(registry, modelId) {
	const id = normalizeModelId(modelId);
	if (!id) return { profileId: undefined, pattern: undefined, score: 0 };

	let best;
	for (const [profileId, profile] of Object.entries(registry.profiles)) {
		if (profileId.startsWith('$')) continue;
		for (const pattern of profile.match ?? []) {
			if (!globToRegExp(pattern).test(id)) continue;
			const score = literalLength(pattern);
			if (!best || score > best.score) best = { profileId, pattern, score };
		}
	}
	return best ?? { profileId: undefined, pattern: undefined, score: 0 };
}

function nonEmpty(value) {
	return typeof value === 'string' && value.trim() !== '';
}

/** Explicit flag beats Arena runtime vars, which beat provider-specific vars. */
export function detectModel(registry, { modelFlag, env = process.env } = {}) {
	if (nonEmpty(modelFlag)) {
		return { modelId: modelFlag.trim(), source: '--model flag', confidence: 'high' };
	}

	for (const entry of registry.detection.modelEnvVars) {
		const value = env[entry.name];
		if (nonEmpty(value)) {
			return { modelId: value.trim(), source: `$${entry.name}`, confidence: entry.confidence };
		}
	}

	return { modelId: undefined, source: 'no model reported', confidence: 'none' };
}

export function detectHarness(registry, { harnessFlag, env = process.env } = {}) {
	if (nonEmpty(harnessFlag)) {
		return { harness: harnessFlag.trim(), source: '--harness flag' };
	}

	for (const entry of registry.detection.harnessEnvVars) {
		if (nonEmpty(env[entry.name])) {
			return { harness: entry.harness, source: `$${entry.name}` };
		}
	}

	return { harness: registry.detection.defaultHarness ?? 'generic', source: 'default' };
}

/** Resolves the running profile: detection + matching + harness capabilities. */
export function resolveProfile(registry, options = {}) {
	const detection = detectModel(registry, options);
	const harnessDetection = detectHarness(registry, options);
	const match = matchProfile(registry, detection.modelId);
	const recognized = Boolean(match.profileId);
	const profile = match.profileId
		? { id: match.profileId, ...registry.profiles[match.profileId] }
		: { id: 'fallback', ...registry.fallbackProfile };
	const harness = registry.harnesses[harnessDetection.harness] ?? registry.harnesses.generic;

	return {
		modelId: detection.modelId ?? null,
		recognized,
		detectedVia: detection.source,
		confidence: detection.confidence,
		matchedPattern: match.pattern ?? null,
		profile,
		harness: harnessDetection.harness,
		harnessDetectedVia: harnessDetection.source,
		harnessCapabilities: harness,
	};
}

function tierRank(registry, tier) {
	return registry.tiers[tier] ?? registry.tiers.unknown ?? 0;
}

export function capabilityKeys(registry) {
	return Object.keys(registry.capabilities).filter((key) => !key.startsWith('$'));
}

function missingCapabilities(requirements, available) {
	return requirements.filter((requirement) => available?.[requirement] !== true);
}

/**
 * A task is refused for a reason the agent can name out loud: below the tier
 * minimum, missing a model capability, missing a harness capability, or a hard
 * refusal that no model may route around.
 */
export function routeTask(registry, taskId, resolved) {
	const task = registry.taskClasses[taskId];
	if (!task) return undefined;

	const reasons = [];
	const { profile, harness, harnessCapabilities } = resolved;

	if (task.hardRefuse) {
		reasons.push({ code: 'hard-refuse', detail: 'out of scope for any model in this repo' });
	}

	const minTier = task.minTier;
	if (minTier && tierRank(registry, profile.tier) < tierRank(registry, minTier)) {
		reasons.push({
			code: 'tier',
			detail: `model tier ${profile.tier} is below the ${minTier} minimum`,
		});
	}

	const missingModel = missingCapabilities(task.requires ?? [], profile.capabilities);
	for (const capability of missingModel) {
		reasons.push({ code: 'model-capability', detail: `model cannot ${capability}` });
	}

	const unknownHarness = [];
	for (const capability of task.requiresHarness ?? []) {
		const value = harnessCapabilities?.[capability];
		if (value === true) continue;
		if (value === 'unknown') {
			unknownHarness.push(capability);
			continue;
		}
		reasons.push({
			code: 'harness-capability',
			detail: `harness "${harness}" has no ${capability}`,
		});
	}

	const hardRefused = reasons.some((reason) => reason.code === 'hard-refuse');
	const blocked = reasons.length > 0;

	let verdict = 'allow';
	if (hardRefused) verdict = 'refused';
	else if (blocked) verdict = 'refused';
	else if (unknownHarness.length > 0) verdict = 'guardrails';

	return {
		taskId,
		task,
		verdict,
		reasons,
		unknownHarness,
		guardrails: task.guardrails ?? [],
		alternatives: task.alternatives ?? [],
	};
}

export function routeAll(registry, resolved) {
	return Object.entries(registry.taskClasses)
		.filter(([taskId]) => !taskId.startsWith('$'))
		.map(([taskId]) => routeTask(registry, taskId, resolved));
}

export function loadRegistry(filePath = registryPath) {
	const raw = readFileSync(filePath, 'utf8');
	try {
		return JSON.parse(raw);
	} catch (error) {
		throw new Error(`registry.json is not valid JSON: ${error.message}`);
	}
}

/**
 * Structural checks that keep the registry honest. Returns an array of
 * problems; an empty array means the registry is usable.
 */
export function validateRegistry(registry) {
	const problems = [];
	const seen = (prefix, keys) => {
		const duplicates = keys.filter((key, index) => keys.indexOf(key) !== index);
		for (const duplicate of new Set(duplicates)) {
			problems.push(`${prefix}: duplicate id "${duplicate}"`);
		}
	};

	if (registry.schemaVersion !== 1) problems.push('schemaVersion must be 1');
	if (!nonEmpty(registry.reviewedAt)) problems.push('reviewedAt is missing');

	const tierNames = new Set(
		Object.keys(registry.tiers ?? {}).filter((key) => !key.startsWith('$')),
	);
	if (!tierNames.has('unknown')) problems.push('tiers: "unknown" is required as the fallback band');

	const capabilities = new Set(capabilityKeys(registry));
	for (const key of ['multiFileEdit', 'toolUse', 'vision']) {
		if (!capabilities.has(key)) problems.push(`capabilities: missing canonical flag "${key}"`);
	}

	const harnessNames = new Set(
		Object.keys(registry.harnesses ?? {}).filter((key) => !key.startsWith('$')),
	);
	if (!harnessNames.has('generic')) problems.push('harnesses: "generic" fallback is required');

	for (const [harnessName, harness] of Object.entries(registry.harnesses ?? {})) {
		if (harnessName.startsWith('$')) continue;
		for (const [flag, value] of Object.entries(harness)) {
			if (flag.startsWith('$')) continue;
			if (!registry.harnessCapabilities?.[flag]) {
				problems.push(`harnesses.${harnessName}: unknown capability "${flag}"`);
			}
			if (![true, false, 'unknown'].includes(value)) {
				problems.push(`harnesses.${harnessName}.${flag}: must be true, false or "unknown"`);
			}
		}
	}

	const profileIds = Object.keys(registry.profiles ?? {}).filter((key) => !key.startsWith('$'));
	seen('profiles', profileIds);

	const patterns = [];
	for (const profileId of profileIds) {
		const profile = registry.profiles[profileId];
		if (!nonEmpty(profile.label)) problems.push(`profiles.${profileId}: label is missing`);
		if (!tierNames.has(profile.tier)) {
			problems.push(`profiles.${profileId}: unknown tier "${profile.tier}"`);
		}
		if (!Array.isArray(profile.match) || profile.match.length === 0) {
			problems.push(`profiles.${profileId}: needs at least one match pattern`);
		}
		for (const pattern of profile.match ?? []) {
			try {
				globToRegExp(pattern);
			} catch {
				problems.push(`profiles.${profileId}: invalid pattern "${pattern}"`);
			}
			patterns.push({ profileId, pattern });
		}
		for (const capability of Object.keys(profile.capabilities ?? {})) {
			if (!capabilities.has(capability)) {
				problems.push(`profiles.${profileId}: unknown capability "${capability}"`);
			}
		}
	}

	for (const { profileId, pattern } of patterns) {
		for (const other of patterns) {
			if (other.profileId === profileId || other.pattern !== pattern) continue;
			problems.push(
				`profiles: "${pattern}" is declared by both ${profileId} and ${other.profileId}`,
			);
		}
	}

	const fallback = registry.fallbackProfile;
	if (!fallback) problems.push('fallbackProfile is missing');
	else {
		if (fallback.tier !== 'unknown') problems.push('fallbackProfile.tier must be "unknown"');
		for (const capability of Object.keys(fallback.capabilities ?? {})) {
			if (!capabilities.has(capability)) {
				problems.push(`fallbackProfile: unknown capability "${capability}"`);
			}
		}
	}

	const taskIds = Object.keys(registry.taskClasses ?? {}).filter((key) => !key.startsWith('$'));
	seen('taskClasses', taskIds);

	for (const taskId of taskIds) {
		const task = registry.taskClasses[taskId];
		if (!nonEmpty(task.label)) problems.push(`taskClasses.${taskId}: label is missing`);
		if (task.minTier && !tierNames.has(task.minTier)) {
			problems.push(`taskClasses.${taskId}: unknown minTier "${task.minTier}"`);
		}
		for (const capability of task.requires ?? []) {
			if (!capabilities.has(capability)) {
				problems.push(`taskClasses.${taskId}: unknown model capability "${capability}"`);
			}
		}
		for (const capability of task.requiresHarness ?? []) {
			if (!registry.harnessCapabilities?.[capability]) {
				problems.push(`taskClasses.${taskId}: unknown harness capability "${capability}"`);
			}
		}
		if (!Array.isArray(task.guardrails) || task.guardrails.length === 0) {
			problems.push(`taskClasses.${taskId}: needs at least one guardrail`);
		}
		if (!Array.isArray(task.unsuitableExamples) || task.unsuitableExamples.length === 0) {
			problems.push(`taskClasses.${taskId}: needs at least one unsuitable example`);
		}
		if (!Array.isArray(task.alternatives) || task.alternatives.length === 0) {
			problems.push(`taskClasses.${taskId}: needs at least one refusal alternative`);
		}
		if (task.hardRefuse && task.minTier) {
			problems.push(`taskClasses.${taskId}: a hard refusal must not depend on model tier`);
		}
	}

	return problems;
}

function formatCapabilities(map, wanted) {
	return Object.keys(map)
		.filter((key) => !key.startsWith('$'))
		.filter((key) => map[key] === wanted);
}

/** Drops `$comment` keys so JSON output is contract-only. */
function stripComments(value) {
	if (Array.isArray(value)) return value.map(stripComments);
	if (value && typeof value === 'object') {
		return Object.fromEntries(
			Object.entries(value)
				.filter(([key]) => key !== SKIP_KEY)
				.map(([key, entry]) => [key, stripComments(entry)]),
		);
	}
	return value;
}

function pad(value, width) {
	return value.length >= width ? value : value + ' '.repeat(width - value.length);
}

function printDetection(resolved, registry) {
	const { profile } = resolved;
	const can = formatCapabilities(profile.capabilities ?? {}, true);
	const cannot = formatCapabilities(profile.capabilities ?? {}, false);

	console.log(`Model profile: ${resolved.modelId ?? '(not reported)'}`);
	console.log(`  profile      ${profile.label} [${profile.tier}] (${profile.family})`);
	console.log(`  detected via ${resolved.detectedVia}`);
	console.log(`  confidence   ${resolved.confidence}`);
	if (resolved.matchedPattern) console.log(`  matched      "${resolved.matchedPattern}"`);
	if (resolved.modelId && !resolved.recognized) {
		console.log('  matched      none — unrecognised id, routing as the weakest profile');
	}
	console.log(`  harness      ${resolved.harness} (via ${resolved.harnessDetectedVia})`);
	console.log(`  can          ${can.length > 0 ? can.join(', ') : 'nothing specific'}`);
	console.log(`  cannot       ${cannot.length > 0 ? cannot.join(', ') : 'nothing'}`);
	if (resolved.confidence === 'none') {
		console.log('\nNo model was reported. Ask which model is running before promising');
		console.log('frontier work; the verdicts below assume the weakest profile.');
	}
	if (!resolved.recognized && resolved.modelId) {
		console.log('\nThis id is not in the registry. Add a profile for the family, or confirm the');
		console.log('id — until then the verdicts assume the weakest profile.');
	}
	console.log(`\nRegistry reviewed ${registry.reviewedAt}.`);
}

function printTasks(resolved, results) {
	const grouped = { allow: [], guardrails: [], refused: [] };
	for (const result of results) grouped[result.verdict].push(result);

	const { label, tier } = resolved.profile;
	console.log(`Tasks for ${label} [${tier}] · ${resolved.harness}\n`);

	for (const [verdict, rows] of Object.entries(grouped)) {
		if (rows.length === 0) continue;
		console.log(`${verdict.toUpperCase()} (${rows.length})`);
		for (const row of rows) {
			const why =
				row.reasons.length > 0 ? row.reasons.map((reason) => reason.detail).join('; ') : 'fits';
			const hint =
				row.unknownHarness.length > 0 ? `verify: ${row.unknownHarness.join(', ')}` : why;
			console.log(`  ${pad(row.taskId, 26)} ${hint}`);
		}
		console.log('');
	}
}

function printRoute(result, resolved) {
	const label = result.verdict === 'refused' ? 'REFUSE' : result.verdict.toUpperCase();
	console.log(`${label}  ${result.taskId} — ${result.task.label}`);
	console.log(
		`  profile      ${resolved.profile.label} [${resolved.profile.tier}] · ${resolved.harness}`,
	);

	if (result.reasons.length > 0) {
		console.log('  why');
		for (const reason of result.reasons) console.log(`    - ${reason.detail}`);
	}
	if (result.unknownHarness.length > 0) {
		console.log('  verify first');
		for (const capability of result.unknownHarness) {
			console.log(`    - harness may lack ${capability}; check before promising the task`);
		}
	}
	console.log('  guardrails');
	for (const guardrail of result.guardrails) console.log(`    - ${guardrail}`);

	if (result.verdict === 'refused') {
		console.log('  do instead');
		for (const alternative of result.alternatives) console.log(`    - ${alternative}`);
	}
}

function printRefusalProtocol(result, resolved) {
	const why = result.reasons.map((reason) => reason.detail).join('; ');
	const instead = result.alternatives[0] ?? 'narrow the request to one file or one question';
	const upgrade = result.task.minTier
		? `To do it as asked, switch to a ${result.task.minTier}-tier model.`
		: 'This one is not a model limit, so a different model will not unblock it.';

	console.log(`\nRefusal template for "${result.taskId}":`);
	console.log(`  why:     I can't take this on because ${why} (running ${resolved.profile.label}).`);
	console.log(`  instead: ${instead}`);
	console.log(`  unblock: ${upgrade}`);
}

function printList(registry) {
	console.log('Task classes:\n');
	for (const [taskId, task] of Object.entries(registry.taskClasses)) {
		if (taskId.startsWith('$')) continue;
		const needs = [
			task.minTier ? `tier>=${task.minTier}` : null,
			...(task.requires ?? []),
			...(task.requiresHarness ?? []).map((capability) => `harness:${capability}`),
		].filter(Boolean);
		console.log(`  ${pad(taskId, 26)} ${task.label}`);
		if (needs.length > 0) console.log(`  ${' '.repeat(26)} needs ${needs.join(', ')}`);
	}
}

const USAGE = `Usage:
  node scripts/model-routing/router.mjs detect [--model <id>] [--harness <name>] [--json]
  node scripts/model-routing/router.mjs tasks  [--model <id>] [--harness <name>] [--json]
  node scripts/model-routing/router.mjs route --task <id> [--model <id>] [--harness <name>] [--json]
  node scripts/model-routing/router.mjs list   [--json]
  node scripts/model-routing/router.mjs check  [--json]

Exit codes: 0 allowed, 3 refused, 2 usage error, 1 registry error.`;

function parseArgs(argv) {
	const options = { json: false };
	const flags = { '--model': 'modelFlag', '--harness': 'harnessFlag', '--task': 'task' };

	for (let index = 0; index < argv.length; index += 1) {
		const arg = argv[index];

		if (arg === '--json') {
			options.json = true;
			continue;
		}
		if (arg === '--help' || arg === '-h') {
			options.help = true;
			continue;
		}

		const [flag, inlineValue] = arg.split('=');
		if (flags[flag]) {
			const value = inlineValue ?? argv[index + 1];
			if (!nonEmpty(value) || String(value).startsWith('--')) {
				throw new Error(`${flag} needs a value`);
			}
			if (inlineValue === undefined) index += 1;
			options[flags[flag]] = value;
			continue;
		}

		if (arg.startsWith('-')) throw new Error(`unknown argument "${arg}"`);
		if (options.command) throw new Error(`unexpected argument "${arg}"`);
		options.command = arg;
	}

	return options;
}

function main(argv) {
	let options;
	try {
		options = parseArgs(argv);
	} catch (error) {
		console.error(`${error.message}\n\n${USAGE}`);
		return EXIT.usage;
	}

	if (options.help || !options.command) {
		console.log(USAGE);
		return options.command ? EXIT.allowed : EXIT.usage;
	}

	let registry;
	try {
		registry = loadRegistry();
	} catch (error) {
		console.error(error.message);
		return EXIT.registry;
	}

	if (options.command === 'check') {
		const problems = validateRegistry(registry);
		if (options.json) {
			console.log(JSON.stringify({ ok: problems.length === 0, problems }, null, 2));
		} else if (problems.length === 0) {
			const taskCount = Object.keys(registry.taskClasses).filter((k) => !k.startsWith('$')).length;
			const profileCount = Object.keys(registry.profiles).filter((k) => !k.startsWith('$')).length;
			console.log(`Registry OK: ${profileCount} profiles, ${taskCount} task classes.`);
		} else {
			console.error(`Registry has ${problems.length} problem(s):`);
			for (const problem of problems) console.error(`  - ${problem}`);
		}
		return problems.length === 0 ? EXIT.allowed : EXIT.registry;
	}

	const resolved = resolveProfile(registry, options);

	switch (options.command) {
		case 'detect': {
			if (options.json) {
				console.log(
					JSON.stringify(
						{
							modelId: resolved.modelId,
							recognized: resolved.recognized,
							detectedVia: resolved.detectedVia,
							confidence: resolved.confidence,
							matchedPattern: resolved.matchedPattern,
							profileId: resolved.profile.id,
							profile: stripComments(resolved.profile),
							harness: resolved.harness,
							harnessDetectedVia: resolved.harnessDetectedVia,
							harnessCapabilities: resolved.harnessCapabilities,
							registryReviewedAt: registry.reviewedAt,
						},
						null,
						2,
					),
				);
			} else {
				printDetection(resolved, registry);
			}
			return EXIT.allowed;
		}

		case 'tasks': {
			const results = routeAll(registry, resolved);
			if (options.json) {
				console.log(
					JSON.stringify(
						{
							profileId: resolved.profile.id,
							tier: resolved.profile.tier,
							modelId: resolved.modelId,
							harness: resolved.harness,
							results: stripComments(results),
						},
						null,
						2,
					),
				);
			} else {
				printTasks(resolved, results);
			}
			return EXIT.allowed;
		}

		case 'list': {
			if (options.json) {
				console.log(JSON.stringify(registry.taskClasses, null, 2));
			} else {
				printList(registry);
			}
			return EXIT.allowed;
		}

		case 'route': {
			if (!options.task) {
				console.error(`route needs --task <id>\n\n${USAGE}`);
				return EXIT.usage;
			}
			const result = routeTask(registry, options.task, resolved);
			if (!result) {
				const known = Object.keys(registry.taskClasses)
					.filter((key) => !key.startsWith('$'))
					.join(', ');
				console.error(`Unknown task class "${options.task}".\nKnown: ${known}`);
				return EXIT.usage;
			}

			if (options.json) {
				console.log(
					JSON.stringify(
						{
							taskId: result.taskId,
							verdict: result.verdict,
							profileId: resolved.profile.id,
							tier: resolved.profile.tier,
							modelId: resolved.modelId,
							recognized: resolved.recognized,
							harness: resolved.harness,
							reasons: result.reasons,
							unknownHarness: result.unknownHarness,
							guardrails: result.guardrails,
							alternatives: result.alternatives,
						},
						null,
						2,
					),
				);
			} else {
				printRoute(result, resolved);
				if (result.verdict === 'refused') printRefusalProtocol(result, resolved);
			}

			return result.verdict === 'refused' ? EXIT.refused : EXIT.allowed;
		}

		default:
			console.error(`Unknown command "${options.command}"\n\n${USAGE}`);
			return EXIT.usage;
	}
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	process.exitCode = main(process.argv.slice(2));
}
