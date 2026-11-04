import { readFile } from "node:fs/promises";
import "./check-design.mjs";
import "./check-ios.mjs";
import "./check-api.mjs";
import "./check-environments.mjs";
import "./check-secrets.mjs";

const required = ["id", "title", "description", "acceptance", "dependsOn", "tier", "status"];
const allowedStatuses = new Set(["todo", "in_progress", "review", "done", "blocked"]);
const allowedTiers = new Set(["planner", "worker"]);

const source = JSON.parse(await readFile(new URL("../planning/tasks.json", import.meta.url), "utf8"));
if (!Array.isArray(source.tasks) || source.tasks.length === 0) throw new Error("planning/tasks.json: brak tasks[]");

const ids = new Set();
for (const task of source.tasks) {
  for (const field of required) if (!(field in task)) throw new Error(`${task.id ?? "?"}: brak pola ${field}`);
  if (ids.has(task.id)) throw new Error(`duplikat ID: ${task.id}`);
  ids.add(task.id);
  if (!Array.isArray(task.acceptance) || task.acceptance.length === 0) throw new Error(`${task.id}: brak kryteriow odbioru`);
  if (!Array.isArray(task.dependsOn)) throw new Error(`${task.id}: dependsOn nie jest lista`);
  if (!allowedStatuses.has(task.status)) throw new Error(`${task.id}: nieznany status ${task.status}`);
  if (!allowedTiers.has(task.tier)) throw new Error(`${task.id}: nieznany tier ${task.tier}`);
}

for (const task of source.tasks) {
  for (const dependency of task.dependsOn) {
    if (!ids.has(dependency)) throw new Error(`${task.id}: brak zaleznosci ${dependency}`);
    if (dependency === task.id) throw new Error(`${task.id}: zaleznosc od samego siebie`);
  }
}

console.log(`OK: ${source.tasks.length} zadan, unikalne ID i poprawne zaleznosci`);

// Deterministic worker tests require no network, provider or database.
await import('../backend/tests/worker.test.mjs');

await import('../backend/tests/images.test.mjs');
const { execFileSync } = await import('node:child_process');
execFileSync('python3', ['-B', 'backend/tests/test_image_decoder.py'], { stdio: 'inherit' });

await import('../backend/tests/ai-provider.test.mjs');

await import('../backend/tests/exports.test.mjs');

await import('../backend/tests/deletion.test.mjs');

await import('../backend/tests/recognition.test.mjs');

await import('../backend/tests/candidates.test.mjs');

await import('../backend/tests/outfit-generation.test.mjs');

await import('../backend/tests/ai-evaluation.test.mjs');
