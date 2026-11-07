/**
 * Halogen NPU models for Pi.
 *
 * halogen (https://github.com/peonist-ai/halogen-flash-server) runs on the liltig
 * box: the Flash chat model on the GPU, small models on the Ryzen AI NPU behind the
 * same port. This extension exposes two of them to Pi as non-chat catalog models:
 *
 *   flux2-klein-4b  -> /v1/images/generations  as an `image` model
 *   decider-4b      -> /v1/systemone           as a `classifier` model
 *
 * Pi declares non-chat models from extensions only: `models.json` model entries have
 * no `type` field (https://pi.dev/docs/latest/models-configuration), so there is
 * nothing to put there. Pi reaches both types through the `codemode` tool
 * (`models.getAvailableOfType("image")`, `models.generateImages()`,
 * `models.classify()`), so settings.json needs `"defaultTools": ["+codemode"]`.
 * See https://pi.dev/docs/latest/models#use-image-models
 *
 * `generate_image` below is the same flux2 model as a plain tool. The catalog path
 * returns base64 blocks and never writes to disk
 * (https://pi.dev/docs/latest/models#use-image-models), so this one saves the PNG
 * and hands back the path.
 *
 * halogen side: docs/NPU.md. PNG only, fixed 4 steps, prompt truncated to 512
 * tokens, one image request at a time on the NPU, ~3.2 s at 512x512 and ~9.7 s at
 * 1024x1024.
 */

import { createProvider, StringEnum } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { Type } from "typebox";

const BASE_URL = (process.env.HALOGEN_BASE ?? "http://liltig:8731/v1").replace(/\/+$/, "");
const IMAGE_MODEL_ID = process.env.HALOGEN_IMAGE_MODEL ?? "flux2-klein-4b";
const CLASSIFIER_MODEL_ID = process.env.HALOGEN_DECIDER_MODEL ?? "decider-4b";
const SAVE_DIR = process.env.HALOGEN_IMAGE_DIR ?? join(homedir(), "Pictures", "halogen");

/** Every size flux2-klein-4b serves; the server 400s on anything else. */
const SIZES = [
	"256x256",
	"512x512",
	"768x512",
	"512x768",
	"768x768",
	"1024x1024",
	"1024x768",
	"768x1024",
	"1024x576",
	"576x1024",
	"640x512",
	"512x640",
	"896x512",
	"512x896",
	"1024x448",
	"448x1024",
	"1024x512",
	"512x1024",
	"1024x640",
	"640x1024",
] as const;

const DEFAULT_SIZE = "1024x1024";
/** 1024x1024 draws in under 10 s alone; the NPU queues one request at a time. */
const TIMEOUT_MS = 180_000;

const ZERO_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

type Block =
	| { type: "text"; text: string }
	| { type: "image"; data: string; mimeType: string };

function endpoint(baseUrl: string, path: string): string {
	return new URL(path, `${baseUrl.replace(/\/+$/, "")}/`).toString();
}

function pickSignal(signal: AbortSignal | undefined): AbortSignal {
	const timeout = AbortSignal.timeout(TIMEOUT_MS);
	if (!signal) return timeout;
	// AbortSignal.any needs Node 20 / Bun. Without it, compose by hand: returning
	// `signal` alone would drop TIMEOUT_MS entirely, so a wedged NPU request would
	// hang until pi aborted it.
	// SAFETY: on Node 20+/Bun `AbortSignal.any` exists with signature
	// (signals: AbortSignal[]) => AbortSignal; the cast only papers over its absence on
	// older runtimes, which is why the result is treated as optional below.
	const any = (AbortSignal as unknown as { any?: (signals: AbortSignal[]) => AbortSignal }).any;
	if (any) return any([signal, timeout]) ?? timeout;
	const controller = new AbortController();
	if (signal.aborted) controller.abort(signal.reason);
	else signal.addEventListener("abort", () => controller.abort(signal.reason), { once: true });
	timeout.addEventListener("abort", () => controller.abort(timeout.reason), { once: true });
	return controller.signal;
}

/** POST `body` as JSON and return the parsed body, or throw with halogen's message. */
async function post(url: string, body: Record<string, unknown>, signal?: AbortSignal) {
	const response = await fetch(url, {
		method: "POST",
		headers: { "content-type": "application/json", authorization: "Bearer halogen" },
		body: JSON.stringify(body),
		signal: pickSignal(signal),
	});
	const text = await response.text();
	let json: Record<string, any> | undefined;
	try {
		json = text ? JSON.parse(text) : undefined;
	} catch {
		/* leave undefined and report the status below */
	}
	if (!response.ok) {
		const message = json?.error?.message ?? json?.error ?? json?.message ?? text.slice(0, 400);
		throw new Error(`${url} -> ${response.status}: ${String(message)}`);
	}
	return json ?? {};
}

/**
 * halogen's image side is OpenAI's `/v1/images/generations` shape: `data[]` with
 * `b64_json` (or a `data:` URL in `url`). Pi ships only `openrouter-images`, which
 * talks chat completions with `modalities: ["image"]` and does not apply here, so
 * this is the small custom ImageApi halogen needs.
 */
async function generateImages(model: any, context: any, options?: any) {
	const output = {
		api: model.api,
		provider: model.provider,
		model: model.id,
		output: [] as Block[],
		errorMessage: undefined as string | undefined,
		stopReason: "stop" as "stop" | "error" | "aborted",
		timestamp: Date.now(),
	};
	try {
		const input: Block[] = Array.isArray(context?.input) ? context.input : [];
		const prompt = input
			.filter((block): block is { type: "text"; text: string } => block?.type === "text")
			.map((block) => block.text)
			.join("\n")
			.trim();
		if (!prompt) throw new Error("a text prompt is required");
		if (input.some((block) => block?.type === "image")) {
			throw new Error(
				"flux2-klein-4b generations take no input images; halogen edits are a separate multipart /v1/images/edits",
			);
		}

		const metadata: Record<string, unknown> = options?.metadata ?? {};
		const body: Record<string, unknown> = {
			model: model.id,
			prompt,
			size: typeof metadata.size === "string" ? metadata.size : DEFAULT_SIZE,
			response_format: "b64_json",
			output_format: "png",
		};
		// Schema bounds are advisory to the model; this is the limit that actually holds.
		if (typeof metadata.n === "number") body.n = Math.min(4, Math.max(1, Math.trunc(metadata.n)));
		if (typeof metadata.seed === "number") body.seed = Math.trunc(metadata.seed);

		const json = await post(endpoint(model.baseUrl, "images/generations"), body, options?.signal);
		for (const item of json.data ?? []) {
			const data =
				typeof item?.b64_json === "string"
					? item.b64_json
					: typeof item?.url === "string" && item.url.startsWith("data:")
						? item.url.slice(item.url.indexOf(",") + 1)
						: undefined;
			if (data) output.output.push({ type: "image", data, mimeType: "image/png" });
		}
		if (output.output.length === 0) throw new Error("halogen returned no image data");
	} catch (error) {
		output.stopReason = options?.signal?.aborted ? "aborted" : "error";
		output.errorMessage = error instanceof Error ? error.message : String(error);
	}
	return output;
}

/**
 * halogen answers TypeSafe's System One request on `/v1/systemone`, so the request
 * and answer shape follow it: pi's `bool` question is wire-level `noul`.
 */
async function classify(model: any, context: any, options?: any) {
	const output = {
		api: model.api,
		provider: model.provider,
		model: model.id,
		answers: {} as Record<string, unknown>,
		usage: undefined as Record<string, unknown> | undefined,
		errorMessage: undefined as string | undefined,
		stopReason: "stop" as "stop" | "error" | "aborted",
		timestamp: Date.now(),
	};
	try {
		if (context?.images?.length) {
			throw new Error(`${model.id} judges text state only; it has no vision tower`);
		}
		const questions: Record<string, unknown> = {};
		for (const [id, question] of Object.entries<any>(context?.questions ?? {})) {
			questions[id] =
				question?.type === "bool"
					? { type: "noul", instructions: question.instructions }
					: question;
		}

		const json = await post(
			endpoint(model.baseUrl, "systemone"),
			{ model: model.id, state: context?.state ?? "", questions },
			options?.signal,
		);
		for (const [id, question] of Object.entries<any>(context?.questions ?? {})) {
			const answer = json.answers?.[id];
			if (!answer) throw new Error(`no answer for question "${id}"`);
			if (question?.type === "choice") {
				output.answers[id] = {
					type: "choice",
					choice: answer.choice,
					probabilities: answer.probabilities ?? {},
					confidence: answer.confidence ?? 0,
				};
			} else if (question?.type === "score") {
				output.answers[id] = { type: "score", score: answer.score ?? 0, confidence: answer.confidence ?? 0 };
			} else {
				output.answers[id] = { type: "bool", probability: answer.noul ?? 0 };
			}
		}
		if (json.usage) {
			const input = json.usage.input_tokens ?? json.usage.prompt_tokens ?? 0;
			const completion = json.usage.output_tokens ?? json.usage.completion_tokens ?? 0;
			output.usage = {
				input,
				output: completion,
				cacheRead: 0,
				cacheWrite: 0,
				totalTokens: input + completion,
				cost: { ...ZERO_COST, total: 0 },
			};
		}
	} catch (error) {
		output.stopReason = options?.signal?.aborted ? "aborted" : "error";
		output.errorMessage = error instanceof Error ? error.message : String(error);
	}
	return output;
}

/** Free locally, so Pi lists the models without a credential dance. */
const provider = createProvider({
	id: "halogen-npu",
	name: "Halogen NPU (liltig)",
	baseUrl: BASE_URL,
	auth: {
		apiKey: {
			name: "Halogen (local, no key needed)",
			async resolve() {
				return { auth: { apiKey: "halogen" }, source: "no key required" };
			},
		},
	},
	models: [
		{
			type: "image",
			id: IMAGE_MODEL_ID,
			name: "FLUX.2 Klein 4B (liltig NPU)",
			api: "halogen-images",
			provider: "halogen-npu",
			baseUrl: BASE_URL,
			input: ["text"],
			output: ["image"],
			cost: ZERO_COST,
		},
		{
			type: "classifier",
			id: CLASSIFIER_MODEL_ID,
			name: "Decider 4B (liltig NPU)",
			api: "halogen-system-one",
			provider: "halogen-npu",
			baseUrl: BASE_URL,
			input: ["text"],
			contextWindow: 8192,
			cost: ZERO_COST,
		},
	],
	images: { "halogen-images": { generateImages } },
	classifiers: { "halogen-system-one": { classify } },
});

function slug(text: string): string {
	return (
		text
			.toLowerCase()
			.replace(/[^a-z0-9]+/g, "-")
			.replace(/^-+|-+$/g, "")
			.slice(0, 48) || "image"
	);
}

export default function halogenNpu(pi: ExtensionAPI) {
	pi.registerProvider(provider);

	pi.registerTool({
		name: "generate_image",
		label: "Generate Image",
		description:
			"Draw an image from a text prompt with flux2-klein-4b on the liltig NPU (text-to-image only: it takes no " +
			"reference images; edits are a separate endpoint this tool does not reach). Returns the image(s) and writes " +
			"them all to disk; extra images are suffixed -2, -3…",
		promptSnippet: "Draw or render an image from a text prompt on the local NPU",
		promptGuidelines: [
			"Keep generate_image prompts under about 500 tokens (truncated at 512); describe subject, lighting and framing literally, and keep any in-image text to a few words because rendered lettering is often garbled.",
		],
		parameters: Type.Object({
			prompt: Type.String({ description: "What to draw" }),
			size: Type.Optional(StringEnum(SIZES, { description: "Pixel size", default: DEFAULT_SIZE })),
			n: Type.Optional(
				Type.Number({
					description:
						"Images to draw. Leave unset for one; set >1 only if the user asks for options or variants, as a " +
						"single call rather than several (the NPU is serial, ~10 s per image at 1024x1024).",
					default: 1,
					minimum: 1,
					maximum: 4,
				}),
			),
			seed: Type.Optional(
				Type.Number({ description: "Same seed and prompt gives the same image; omit for variation" }),
			),
			path: Type.Optional(
				Type.String({
					description: `Where to write the PNG; extra images get -2, -3… suffixes. Default ${SAVE_DIR}/<prompt-slug>-<time>.png`,
				}),
			),
		}),

		async execute(_toolCallId, params, signal) {
			const size = params.size ?? DEFAULT_SIZE;
			const result = await generateImages(
				{ api: "halogen-images", provider: "halogen-npu", id: IMAGE_MODEL_ID, baseUrl: BASE_URL },
				{ input: [{ type: "text", text: params.prompt }] },
				{ signal, metadata: { size, n: params.n, seed: params.seed } },
			);
			if (result.stopReason !== "stop") {
				return {
					content: [{ type: "text", text: `Image generation failed: ${result.errorMessage}` }],
					details: { ok: false, error: result.errorMessage },
				};
			}

			const images = result.output.filter(
				(block): block is { type: "image"; data: string; mimeType: string } => block.type === "image",
			);
			const files: string[] = [];
			try {
				const base = params.path
					? resolve(params.path.replace(/^@/, ""))
					: join(SAVE_DIR, `${slug(params.prompt)}-${new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)}.png`);
				mkdirSync(dirname(base), { recursive: true, mode: 0o755 });
				images.forEach((image, i) => {
					// Only the first image keeps the requested path verbatim; the rest get a suffix.
					const file = i === 0 ? base : `${base.replace(/\.png$/i, "")}-${i + 1}.png`;
					writeFileSync(file, Buffer.from(image.data, "base64"));
					files.push(file);
				});
			} catch (error) {
				// The image is still usable from the tool result; only the save failed.
				return {
					content: [
						{ type: "text", text: `Drew ${images.length} image(s) at ${size}, but saving failed: ${String(error)}` },
						...images,
					],
					details: { ok: true, size, files, saveError: String(error) },
				};
			}

			return {
				content: [
					{
						type: "text",
						text: `${images.length} image(s), ${size}, flux2-klein-4b on the liltig NPU. Saved: ${files.join(", ")}`,
					},
					...images,
				],
				details: { ok: true, size, files },
			};
		},
	});
}
