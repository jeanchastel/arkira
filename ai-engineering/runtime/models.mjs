// On-demand native discovery. Called during model selection/maintenance, never per tool call.
import { codexReadClient } from "./native-codex.mjs";
const [model, effort] = process.argv.slice(2);
const client = await codexReadClient();
try {
  const models = [];
  let cursor;
  for (let page = 0; page < 10; page++) {
    const result = await client.request("model/list", {
      ...(cursor ? { cursor } : {}),
      limit: 100,
      includeHidden: true,
    });
    models.push(...result.data);
    cursor = result.nextCursor;
    if (!cursor) break;
  }
  if (cursor) throw Error("Native model catalog exceeded bounded discovery");
  if (model) {
    const found = models.find((m) => m.id === model || m.model === model);
    if (!found)
      throw Error(
        `Requested model is not advertised by this CLI runtime (access remains unverified): ${model}. No fallback was selected.`,
      );
    const supported = found.supportedReasoningEfforts.map(
      (e) => e.reasoningEffort,
    );
    if (effort && !supported.includes(effort))
      throw Error(
        `${model} does not advertise effort ${effort}. No fallback was selected.`,
      );
    console.log(
      JSON.stringify({
        model,
        effort: effort || found.defaultReasoningEffort,
        availability: "discovered",
        execution: "not_tested",
        supported_efforts: supported,
      }),
    );
  } else
    console.log(
      JSON.stringify(
        {
          checked_at: new Date().toISOString(),
          source: "native model/list",
          models,
        },
        null,
        2,
      ),
    );
} finally {
  client.close();
}
