# Round 3: review decision and concurrence check

The two prose sections added for the review decision were authored blind: a fresh
sub-agent with no access to the repository or to the ADL modules wrote them from
the intent briefs below alone, then they were placed verbatim (re-wrapped) in
`templates/promptmodule-coordinator.yaml` (section "Deciding how the results get
checked") and `templates/promptmodule-analyst-review.yaml` (section "When you are
asked to concur"). The ADL crew carries the same intent as the `review-decision`
module and the `analyst-concurrence-check` component.

Parity check: one sentence was added to the coordinator section after authoring
("Any of these reasons for "full" wins over "concur" when both seem to fit."), so the
prose states the same precedence the ADL rules carry. The ADL side gained the
inputs of the call, the worked example, and the grounding reminder the prose had.

## Intent brief: coordinator

- After the tool-using agents have gathered data for a question, the coordinator is
  asked, in a separate call of its own, to decide how the crew checks those results
  before the final answer is written. The call gives it the question, counts of how
  the agents responded (already counted, so it does not count contributions itself),
  which analysts were picked for the question, and the gathered results. The answer
  format is spelled out in that call; the reason is one short sentence.
- Three choices. "concur": one analyst gives a quick second opinion, agreeing or
  naming what is missing or wrong; if it objects the crew runs a full review anyway.
  "full": the analysts picked for the question all review the results. "none": skip
  the check; this crew never uses it, because every answer gets at least a second
  opinion.
- "concur" fits when the gathered results directly answer the question as asked.
- "full" fits when a tool agent failed or raised a concern, contributions disagree,
  the question asks for judgment, a recommendation, trade-offs, a root cause, or ties
  facts across layers or domains, or the answer needs counting, totals, ranking,
  sorting, percentages, or other arithmetic (that belongs to the compute analyst, a
  tool; nobody eyeballs a count). When unsure, "full".
- The guidance is only for that decision call and never appears in the final answer.

## Intent brief: analyst

- Sometimes, instead of a full review, the coordinator sends a concurrence check: it
  believes the gathered results already answer the question and asks this one
  analyst for a quick second opinion.
- The analyst checks that the results answer the question as asked: the right scope,
  complete, and consistent with each other.
- If they do, it replies in a sentence or two confirming that, adding only a
  correction or caveat it is sure of.
- If something is missing, wrong, or not backed by the gathered data, it starts its
  reply with the exact text "CONCERN:" followed by what is missing or wrong, which
  sends the question to a full review.
- The reply stays short, with no redoing of the gathering and no restating of the
  data at length. The usual grounding still applies.
