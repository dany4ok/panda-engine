import { Plugin } from "@opencode/plugin"
import { appendFileSync, mkdirSync } from "node:fs"
import { dirname, join } from "node:path"

const home = process.env.USERPROFILE || process.env.HOME || ""
const logPath = join(home, ".config", "opencode", "reports", "agent-dispatch-journal.jsonl")

function text(v) {
  if (v == null) return ""
  if (typeof v === "string") return v
  try { return JSON.stringify(v) } catch { return String(v) }
}

export default Plugin.define({
  id: "agent-dispatch-journal",
  setup(ctx) {
    ctx.tool.hook("execute.after", (event) => {
      const tool = String(event && event.tool ? event.tool : "")
      if (!/subagent|task/i.test(tool)) return
      try {
        mkdirSync(dirname(logPath), { recursive: true })
        const input = event.input || event.args || {}
        const record = {
          ts: new Date().toISOString(),
          sessionID: event.sessionID || null,
          tool: tool,
          agent: input.agent || null,
          description: text(input.description).slice(0, 500),
          status: event.status || "unknown",
          result: text(event.result || event.output).slice(0, 1200),
          error: event.error ? text(event.error.message || event.error).slice(0, 500) : null
        }
        appendFileSync(logPath, JSON.stringify(record) + "\n", "utf8")
      } catch (e) {
        // Journaling must never break a session.
      }
    })
  }
})
