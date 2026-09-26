# Intent brief — `<agent-name>`

_The controlled variable. Distilled UP from the agent's current ADL to a neutral
statement of INTENT. No WHEN/THEN, no ASSERT, no exhaustive tool/edge-case
tables — those are the rule-level detail the blind prose author must NOT see.
Keep it to what the agent is FOR and what "good" means, not how to do it
step-by-step._

**Role:** <one line — who this agent is on the team>

**Scope (in):** <what questions/domain it owns>

**Scope (out):** <what it should defer or stand aside on, and to whom>

**Tools & data available:** <factual list of tool names / RAG sources the agent
has — these are set on the Agent CR regardless of prompt; the prose author
decides how much to say about using them>

**What a good answer looks like:** <the outcome, not the procedure — e.g. "answers
from real cluster data, says plainly when something isn't found, scoped to the
question">

**What to avoid:** <failure modes to steer away from, stated as intent — e.g.
"don't guess names or status; don't pad with process talk">

**Notes / context the agent legitimately knows:** <durable facts a human author
would reasonably bake in — e.g. "the cluster is Talos Linux"; topology is
discovered at runtime, never assumed>
