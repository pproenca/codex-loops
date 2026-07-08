defmodule WorkflowDslSpecWorkflow do
  use Workflow

  workflow "workflow-dsl-spec" do
    phase("Ground truth")

    log(
      "SPEC.md already exists — mapping its structure + extracting the dataflow proposal for a SURGICAL insert (NOT a rewrite)"
    )

    parallel([
      agent(
        """
        Extract GROUND TRUTH for the "spec-structure" area, to anchor a SURGICAL insertion of a Proposed §10 dataflow section into the EXISTING SPEC.md.
        Read SPEC.md (the EXISTING committed spec at repo root), and .claude/skills/language-spec-author/scripts/check-spec.sh (and grep as needed). Report a precise structural map of the CURRENT SPEC.md: the full section/heading outline with line ranges; exactly where §9 (`refine` V1) ends and the next section begins; the current number + title of the authoring-guide section and every internal cross-reference that a new §10 insertion would force to renumber; the Appendix B grammar-summary structure; and the exact shipped clauses a Proposed dataflow section must add non-destructive FORWARD-REFERENCES to (Principle 6, §1.2 General-computation Non-goal, §6.4.1 provider port, §7.2/§7.3 prompt payload, §8 conformance C1/C9, the §2.4 / §10.2 closed-vocabulary list). Quote each anchor line verbatim so the insert can target it exactly. This is a MAP, not a critique — do not propose rewrites.. Be exhaustive and PRECISE — exact headings, line ranges, section numbers, struct fields, event names, and verbatim anchor lines.
        Then WRITE your findings to .spec-workshop/spec-structure.md (create the dir if needed) as clean markdown, and return the structured summary.
        """,
        label: "read:spec-structure"
      ),
      agent(
        """
        Extract GROUND TRUTH for the "dataflow" area, to anchor a SURGICAL insertion of a Proposed §10 dataflow section into the EXISTING SPEC.md.
        Read SPEC-DATAFLOW-PROPOSAL.md (read in full), plus grep lib/ for any LANDED dataflow constructs (a %Template{} / Node.Emit struct, a ~P sigil, a `let` form, binding_env threading in compiler.ex, a widened RenderText) (and grep as needed). Report the Proposed Tier-1 dataflow extension exactly as SPEC-DATAFLOW-PROPOSAL.md specifies it — the ADOPT idioms (Template layer, let, prompt injection, emit) with their surface grammar / inert node struct / validation rules+counter-examples / execution algorithm / journal shape, the DEFER (gather, map) and REJECT (reduce, select) verdicts, the Principle 6→6′ reconciliation and the EXACT set of amended clauses (§1.2′, C9′, §6.4.1′, §6.4-commit′/§7.2′/§7.3′, closed-vocabulary count against the live baseline) — AND a precise landed-vs-proposal INVENTORY: for each idiom, state whether it is ALREADY implemented in lib/ (cite the module/struct) or still proposal-only. This inventory decides which idioms the draft folds into the implemented body vs keeps in the Proposed section.. Be exhaustive and PRECISE — exact headings, line ranges, section numbers, struct fields, event names, and verbatim anchor lines.
        Then WRITE your findings to .spec-workshop/dataflow.md (create the dir if needed) as clean markdown, and return the structured summary.
        """,
        label: "read:dataflow"
      )
    ])

    phase("Draft")

    log(
      "Structure mapped for 2 areas; SURGICALLY inserting §10 dataflow into the existing SPEC.md"
    )

    let(
      :draft =
        agent(
          """
          You are authoring/reviewing a formal, implementable language spec using the language-spec-author method.
          READ FIRST (they are on disk): .claude/skills/language-spec-author/references/spec-anatomy.md, .claude/skills/language-spec-author/references/formal-notation.md, .claude/skills/language-spec-author/references/interview-playbook.md.
          The 8-part anatomy the spec MUST cover (mark any part deliberately N/A, never silently omit):
            1 Purpose & design principles (the tie-breakers)  2 Lexical grammar  3 Syntactic grammar (`::` lexical vs `:` syntactic)
            4 Semantic model (the inert %Tree{}/%Node{} shapes)  5 Static semantics = compile-time VALIDATION rules, each with a COUNTER-EXAMPLE
            6 Dynamic semantics = EXECUTION as function-style algorithms + the ERROR MODEL (abort/propagate/partial — pin it)
            7 Output & error format (journal events, result shape, exit codes)  8 Conformance (RFC 2119 MUST/SHOULD/MAY + observably-equivalent clause).
          The bar: a developer with ZERO access to us could build a conforming implementation from SPEC.md alone.
          Apply the THREE REJECTION TESTS to every statement: (a) stranger test — could a stranger implement it without asking us?
          (b) edge-case test — empty/duplicate/missing/max/malformed/conflicting? (c) two-implementers test — could two teams diverge?

          The DSL is an Elixir compile-time DSL (read .claude/skills/elixir-meta-programming/references/*.md). Non-negotiable facts the spec must reflect accurately:
          - Workflow bodies compile to an INERT %Tree{} of node structs — ZERO closures. The `workflow` macro is a thin shell over the
            plain function Workflow.Compiler.parse/2, where ALL validation lives (compile-time, caller-located findings).
          - Determinism is enforced by ABSENCE of vocabulary nodes + compiler rejection, never a runtime linter.
          - The journal is the single source of truth; status/inspect/LiveView are pure folds. Effects are exactly-once via
            (run_id, node-path, iteration) idempotency keys. Loops are bounded and provably terminate.

          SURGICAL EDIT — DO NOT REWRITE SPEC.md. SPEC.md at the repo root is an ALREADY-AUTHORED, adversarially-hardened, committed spec (§1–§9
          plus an authoring guide). Your ONLY job is to ADD a new Proposed "§10 — Tier-1 dataflow extension" and make the minimum non-destructive
          edits that insertion forces. You MUST preserve every existing section BYTE-FOR-BYTE except: (a) the new §10 you insert, (b) the section
          NUMBER of the current authoring-guide section (it shifts from §10 to §11) and any in-doc cross-reference to it, and (c) a small set of
          one-line non-destructive FORWARD-REFERENCE notes into shipped clauses (see below). NOTHING ELSE in §1–§9 or the authoring guide's prose
          may change — do not reword, reorder, "improve", re-derive, or re-lint the existing body. This is an Edit/insert task, never a Write of the whole file.

          Read (do NOT skip): the CURRENT SPEC.md in full; the structure map at .spec-workshop/spec-structure.md (it gives you the exact anchor lines
          and the cross-references to renumber); the dataflow dossier at .spec-workshop/dataflow.md; and SPEC-DATAFLOW-PROPOSAL.md (the authoritative,
          already-converged source for the §10 content — lift its ADOPT normative content faithfully, re-expressed in THIS SPEC.md's notation/voice).

          Do exactly this, with targeted edits:
          1. INSERT "## 10. Dataflow core and proposed extensions" immediately AFTER §9 (`refine` V1) and BEFORE the
             authoring-guide section. Spec the ADOPT idioms (Template layer, `let`, prompt injection, `emit`, pipeline-with-dataflow) to the full
             8-part bar, mark the DEFER idioms (`gather`, `map`) deferred, and record the REJECT idioms (`reduce`, `select`/`when`) with rationale,
             all grounded in SPEC-DATAFLOW-PROPOSAL.md. Use this design as the scaffold:

          Tier-1 DATAFLOW extension (the ADOPT core is implemented; deferred idioms remain design-stage).
          FULL normative source ON DISK: SPEC-DATAFLOW-PROPOSAL.md (and the extracted dossier .spec-workshop/dataflow.md). The draft/reviser MUST
          read both and ground EVERY dataflow statement in them — do NOT re-derive from memory. The proposal is written to the same 8-part
          bar as SPEC.md and carries the per-idiom verdicts + the Principle 6→6′ reconciliation verbatim.
          Thesis: add DATA FLOW, not control flow — flow only journaled values through the deterministic RenderText SPEC §4.4 already
          defines, widened from compile-time literals to already-journaled values under an exhaustive compile-time whitelist.
          ADOPT — specify to the FULL 8-part bar as one coherent "dataflow core" section:
            - Template layer: an inert %Template{} compiled by a hand-rolled binary scanner (NOT a macro; ONLY <%= @assign %> holes),
              rendered by the deterministic, closure-free RenderText.
            - let: bind a name to a lexically-preceding producer's JOURNALED output (agent/synthesize/refine); name→address at compile time,
              value via a pure journal fold; creates no new value/effect/event/idempotency key.
            - prompt injection: a TOP-LEVEL agent's prompt MAY be a %Template{} over in-scope bindings; the materialized EffectivePrompt is
              journaled (retry-stable) in agent_committed.prompt AND agent_attempt_rejected.prompt; Rule C.2.4 REJECTS template prompts in
              parallel/pipeline/fan_out/loop bodies.
            - emit: render the terminal from bound values into run_completed.value; a workflow MAY end with return OR emit.
            - pipeline-with-dataflow: by COMPOSITION of let + injection — NO new combinator.
          DEFER — specify but mark deferred: gather (fold bound outputs via a node); map (node-per-element, bounded max:, single-agent
            lanes, the only piece adding new events map_started/map_completed).
          REJECT — document as out-of-Tier-1 with rationale: reduce (closed reducer); select/when (control flow — violates the thesis).
          RECONCILIATION the section MUST carry: this is a STRENGTHENING of "no value binding" — Principle 6 → 6′ (journaled-values-only,
            deterministic-render-only), plus the amended clauses (§1.2′, C9′, §6.4.1′, the §6.4 commit path + §7.2/§7.3 payload semantics,
            and the closed-vocabulary count against the live baseline). Present these as PROPOSED amendments; do NOT rewrite SPEC.md's implemented §1–§8
            normative body — add non-destructive FORWARD-REFERENCES only (e.g. Principle 6 notes the proposed 6′).
          TRACKING (landed-vs-proposed): this extension is being built as slices — Slice 0 prefactor (binding_env + RenderText seam),
            Slice 1 (let+template+emit), Slice 2 (injection), Slice 3 (docs+SPEC fold). The dataflow dossier reports which constructs are
            ALREADY in lib/. Any idiom the dossier marks LANDED moves OUT of the Proposed section into the implemented body and is held to
            code fidelity like the rest of the vocabulary; only not-yet-landed idioms stay in the Proposed §.

          2. RENUMBER the existing authoring-guide section from §10 to §11 (and its subsections), and update every internal reference to it. Do not touch its content.
          3. ADD non-destructive one-line forward-reference notes (blockquote or parenthetical, clearly marked "Proposed §10") into these shipped clauses
             WITHOUT altering their existing normative text: Principle 6 (→ proposed 6′), §1.2 General-computation Non-goal, §6.4.1 provider port,
             §7.2/§7.3 prompt payload, §8 conformance (C1/C9), and the §2.4 / §10.2-now-§11.2 closed-vocabulary list. Each note POINTS AT §10; it does
             not restate or rewrite the clause.
          4. LANDED EXCEPTION: if the dataflow dossier reports an ADOPT idiom as ALREADY implemented in lib/, fold THAT idiom into the implemented body
             as normative (code-verified) text instead of the Proposed §10, and make the corresponding amendment normative rather than a forward-reference.
             (With nothing landed yet, everything stays Proposed in §10.)

          After editing, run `git --no-pager diff --stat HEAD -- SPEC.md` and confirm the change is ADDITIVE (insertions dominate; deletions limited to
          the §10→§11 renumber and the added forward-ref anchor lines). Return: a one-paragraph summary of the inserted §10, the list of clauses you added
          forward-refs to, and the diff --stat line. If you find yourself rewriting more than the four items above, STOP and report why instead.
          """,
          label: "draft:spec"
        )
    )

    phase("Converge")

    log("Refine loop: adversarial panel reviews SPEC.md until unanimous approval")

    refine(:draft,
      reviewers: [
        reviewer(
          :spec_completeness,
          """
          You are authoring/reviewing a formal, implementable language spec using the language-spec-author method.
          READ FIRST (they are on disk): .claude/skills/language-spec-author/references/spec-anatomy.md, .claude/skills/language-spec-author/references/formal-notation.md, .claude/skills/language-spec-author/references/interview-playbook.md.
          The 8-part anatomy the spec MUST cover (mark any part deliberately N/A, never silently omit):
            1 Purpose & design principles (the tie-breakers)  2 Lexical grammar  3 Syntactic grammar (`::` lexical vs `:` syntactic)
            4 Semantic model (the inert %Tree{}/%Node{} shapes)  5 Static semantics = compile-time VALIDATION rules, each with a COUNTER-EXAMPLE
            6 Dynamic semantics = EXECUTION as function-style algorithms + the ERROR MODEL (abort/propagate/partial — pin it)
            7 Output & error format (journal events, result shape, exit codes)  8 Conformance (RFC 2119 MUST/SHOULD/MAY + observably-equivalent clause).
          The bar: a developer with ZERO access to us could build a conforming implementation from SPEC.md alone.
          Apply the THREE REJECTION TESTS to every statement: (a) stranger test — could a stranger implement it without asking us?
          (b) edge-case test — empty/duplicate/missing/max/malformed/conflicting? (c) two-implementers test — could two teams diverge?

          LENS: SPEC COMPLETENESS. Apply the three rejection tests to EVERY section. A defect is any statement a stranger couldn't implement, any rule missing its counter-example, any happy-path-only algorithm, any unpinned error-model decision, any place two implementers could diverge. Read the spec-anatomy done-bars and hold each part to them.

          SCOPE — this run only ADDED a Proposed §10 dataflow section to an already-hardened SPEC.md. Treat §1–§9 and the authoring guide as FROZEN and authoritative: do NOT propose edits to them, and do NOT re-litigate pre-existing wording. Confine your defects to (i) the NEW §10 content, (ii) the renumbering/forward-reference edits, and (iii) any place the §10 insertion INTRODUCED an inconsistency with the frozen body. (The non-destructiveness lens is the exception — it audits the whole diff.)

          Adversarially review the CURRENT SPEC.md at the repository root (read it fresh; read .spec-workshop/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return approved=false with blocking findings if you find ANY in scope; return approved=true with no blocking findings only if this lens is fully satisfied. Each blocking finding MUST have a stable id, a precise issue, and a concrete fix.
          """
        ),
        reviewer(
          :implementation_fidelity,
          """
          The DSL is an Elixir compile-time DSL (read .claude/skills/elixir-meta-programming/references/*.md). Non-negotiable facts the spec must reflect accurately:
          - Workflow bodies compile to an INERT %Tree{} of node structs — ZERO closures. The `workflow` macro is a thin shell over the
            plain function Workflow.Compiler.parse/2, where ALL validation lives (compile-time, caller-located findings).
          - Determinism is enforced by ABSENCE of vocabulary nodes + compiler rejection, never a runtime linter.
          - The journal is the single source of truth; status/inspect/LiveView are pure folds. Effects are exactly-once via
            (run_id, node-path, iteration) idempotency keys. Loops are bounded and provably terminate.

          LENS: IMPLEMENTATION FIDELITY. For every normative claim about the IMPLEMENTED vocabulary, verify it against the REAL source (grep lib/workflow/*.ex and .spec-workshop/*.md). A defect is any spec statement the code contradicts, any combinator option/arg shape that is wrong, any node field/event name that doesn't exist. `refine` V1 is implemented/normative and is NOT exempt: it must match the compiler, runtime, events, status fold, and binding behavior in lib/. Only dataflow idioms the dataflow dossier (.spec-workshop/dataflow.md) reports as NOT-yet-landed are exempt from "must match code" (design-stage), but must still be internally consistent and FAITHFUL to SPEC-DATAFLOW-PROPOSAL.md (a claim that contradicts the proposal is a defect). Any dataflow idiom the dossier reports as ALREADY landed in lib/ is NOT exempt: it must match the real source, and if the draft left it in the Proposed section instead of the implemented body that misplacement is a defect. If code and spec disagree, the CODE is right — the spec is the defect.

          SCOPE — this run only ADDED a Proposed §10 dataflow section to an already-hardened SPEC.md. Treat §1–§9 and the authoring guide as FROZEN and authoritative: do NOT propose edits to them, and do NOT re-litigate pre-existing wording. Confine your defects to (i) the NEW §10 content, (ii) the renumbering/forward-reference edits, and (iii) any place the §10 insertion INTRODUCED an inconsistency with the frozen body. (The non-destructiveness lens is the exception — it audits the whole diff.)

          Adversarially review the CURRENT SPEC.md at the repository root (read it fresh; read .spec-workshop/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return approved=false with blocking findings if you find ANY in scope; return approved=true with no blocking findings only if this lens is fully satisfied. Each blocking finding MUST have a stable id, a precise issue, and a concrete fix.
          """
        ),
        reviewer(
          :invariants,
          """
          The DSL is an Elixir compile-time DSL (read .claude/skills/elixir-meta-programming/references/*.md). Non-negotiable facts the spec must reflect accurately:
          - Workflow bodies compile to an INERT %Tree{} of node structs — ZERO closures. The `workflow` macro is a thin shell over the
            plain function Workflow.Compiler.parse/2, where ALL validation lives (compile-time, caller-located findings).
          - Determinism is enforced by ABSENCE of vocabulary nodes + compiler rejection, never a runtime linter.
          - The journal is the single source of truth; status/inspect/LiveView are pure folds. Effects are exactly-once via
            (run_id, node-path, iteration) idempotency keys. Loops are bounded and provably terminate.

          LENS: INVARIANTS. A defect is any place the spec states or implies something that violates: inert closure-free tree, determinism-by-absence, journal-as-sole-truth (no process state), exactly-once effects, bounded/terminating loops, validate-in-parse-at-compile-time. Also flag any execution algorithm whose determinism or replay-safety is not actually guaranteed by what the spec says. NOTE the Tier-1 dataflow section DELIBERATELY amends "no value binding" to Principle 6′ (journaled-values-only, deterministic-render-only); do NOT flag that amendment itself as an invariant violation, but DO verify 6′ genuinely preserves the listed invariants — flag any dataflow construct whose closure-freedom, determinism-by-absence, journal-as-sole-truth, exactly-once, or bounded termination is not actually guaranteed by what the spec says (e.g. an unpinned inspect-map render order, a template hole that could admit non-journaled data, a bound value read before its producer commits, an unbounded map).

          SCOPE — this run only ADDED a Proposed §10 dataflow section to an already-hardened SPEC.md. Treat §1–§9 and the authoring guide as FROZEN and authoritative: do NOT propose edits to them, and do NOT re-litigate pre-existing wording. Confine your defects to (i) the NEW §10 content, (ii) the renumbering/forward-reference edits, and (iii) any place the §10 insertion INTRODUCED an inconsistency with the frozen body. (The non-destructiveness lens is the exception — it audits the whole diff.)

          Adversarially review the CURRENT SPEC.md at the repository root (read it fresh; read .spec-workshop/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return approved=false with blocking findings if you find ANY in scope; return approved=true with no blocking findings only if this lens is fully satisfied. Each blocking finding MUST have a stable id, a precise issue, and a concrete fix.
          """
        ),
        reviewer(
          :teachability,
          """
          You are authoring/reviewing a formal, implementable language spec using the language-spec-author method.
          READ FIRST (they are on disk): .claude/skills/language-spec-author/references/spec-anatomy.md, .claude/skills/language-spec-author/references/formal-notation.md, .claude/skills/language-spec-author/references/interview-playbook.md.
          The 8-part anatomy the spec MUST cover (mark any part deliberately N/A, never silently omit):
            1 Purpose & design principles (the tie-breakers)  2 Lexical grammar  3 Syntactic grammar (`::` lexical vs `:` syntactic)
            4 Semantic model (the inert %Tree{}/%Node{} shapes)  5 Static semantics = compile-time VALIDATION rules, each with a COUNTER-EXAMPLE
            6 Dynamic semantics = EXECUTION as function-style algorithms + the ERROR MODEL (abort/propagate/partial — pin it)
            7 Output & error format (journal events, result shape, exit codes)  8 Conformance (RFC 2119 MUST/SHOULD/MAY + observably-equivalent clause).
          The bar: a developer with ZERO access to us could build a conforming implementation from SPEC.md alone.
          Apply the THREE REJECTION TESTS to every statement: (a) stranger test — could a stranger implement it without asking us?
          (b) edge-case test — empty/duplicate/missing/max/malformed/conflicting? (c) two-implementers test — could two teams diverge?

          LENS: TEACHABILITY. This SPEC.md must let an agent author a NEW correct workflow with no access to the code. TEST IT: from SPEC.md alone, write a fresh workflow that exercises a non-trivial use-case (e.g. a review-gated pipeline, `refine`, or a dataflow flow that binds an output with `let`, injects it into a downstream agent's `~P` prompt, and renders a terminal with `emit`). Would it compile under the rules as written? Every ambiguity that forced you to guess, every combinator you couldn't use correctly from the doc, is a defect.

          SCOPE — this run only ADDED a Proposed §10 dataflow section to an already-hardened SPEC.md. Treat §1–§9 and the authoring guide as FROZEN and authoritative: do NOT propose edits to them, and do NOT re-litigate pre-existing wording. Confine your defects to (i) the NEW §10 content, (ii) the renumbering/forward-reference edits, and (iii) any place the §10 insertion INTRODUCED an inconsistency with the frozen body. (The non-destructiveness lens is the exception — it audits the whole diff.)

          Adversarially review the CURRENT SPEC.md at the repository root (read it fresh; read .spec-workshop/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return approved=false with blocking findings if you find ANY in scope; return approved=true with no blocking findings only if this lens is fully satisfied. Each blocking finding MUST have a stable id, a precise issue, and a concrete fix.
          """
        ),
        reviewer(
          :structural_lint,
          """
          LENS: STRUCTURAL LINT. Run .claude/skills/language-spec-author/scripts/check-spec.sh on SPEC.md (bash). Report every FAIL/WARN as a defect (missing section, unresolved TODO/placeholder, missing grammar notation, absent RFC 2119 keywords, missing counter-examples). Also check cross-reference closure: every algorithm/type/term the NEW §10 uses must be defined somewhere in the doc — a dangling reference is a defect. Do NOT report pre-existing check-spec.sh findings that also fire on the committed HEAD version (those predate this change); only NEW findings the §10 insertion introduced.

          SCOPE — this run only ADDED a Proposed §10 dataflow section to an already-hardened SPEC.md. Treat §1–§9 and the authoring guide as FROZEN and authoritative: do NOT propose edits to them, and do NOT re-litigate pre-existing wording. Confine your defects to (i) the NEW §10 content, (ii) the renumbering/forward-reference edits, and (iii) any place the §10 insertion INTRODUCED an inconsistency with the frozen body. (The non-destructiveness lens is the exception — it audits the whole diff.)

          Adversarially review the CURRENT SPEC.md at the repository root (read it fresh; read .spec-workshop/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return approved=false with blocking findings if you find ANY in scope; return approved=true with no blocking findings only if this lens is fully satisfied. Each blocking finding MUST have a stable id, a precise issue, and a concrete fix.
          """
        ),
        reviewer(
          :non_destructiveness,
          """
          LENS: NON-DESTRUCTIVENESS (the safety guard). Run `git --no-pager diff HEAD -- SPEC.md` (bash). This change MUST be ADDITIVE. The ONLY permitted modifications to pre-existing content are: (a) the inserted §10 dataflow section, (b) renumbering the authoring-guide section §10→§11 and updating references to it, and (c) the small set of clearly-marked one-line "Proposed §10" forward-reference notes appended to shipped clauses (Principle 6, §1.2, §6.4.1, §7.2/§7.3, §8, the closed-vocabulary list). ANY OTHER deletion, rewording, reordering, or "improvement" of the existing §1–§9 or authoring-guide prose is a BLOCKING defect — report each such hunk with its diff context and demand it be reverted to the HEAD text. A wholesale rewrite (large deletion counts, the body shrinking) is the top defect this lens exists to catch. Also flag if the diff shows the file was truncated or a section went missing.

          SCOPE — this run only ADDED a Proposed §10 dataflow section to an already-hardened SPEC.md. Treat §1–§9 and the authoring guide as FROZEN and authoritative: do NOT propose edits to them, and do NOT re-litigate pre-existing wording. Confine your defects to (i) the NEW §10 content, (ii) the renumbering/forward-reference edits, and (iii) any place the §10 insertion INTRODUCED an inconsistency with the frozen body. (The non-destructiveness lens is the exception — it audits the whole diff.)

          Adversarially review the CURRENT SPEC.md at the repository root (read it fresh; read .spec-workshop/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return approved=false with blocking findings if you find ANY in scope; return approved=true with no blocking findings only if this lens is fully satisfied. Each blocking finding MUST have a stable id, a precise issue, and a concrete fix.
          """
        )
      ],
      revise_with:
        agent("""
        You are authoring/reviewing a formal, implementable language spec using the language-spec-author method.
        READ FIRST (they are on disk): .claude/skills/language-spec-author/references/spec-anatomy.md, .claude/skills/language-spec-author/references/formal-notation.md, .claude/skills/language-spec-author/references/interview-playbook.md.
        The 8-part anatomy the spec MUST cover (mark any part deliberately N/A, never silently omit):
          1 Purpose & design principles (the tie-breakers)  2 Lexical grammar  3 Syntactic grammar (`::` lexical vs `:` syntactic)
          4 Semantic model (the inert %Tree{}/%Node{} shapes)  5 Static semantics = compile-time VALIDATION rules, each with a COUNTER-EXAMPLE
          6 Dynamic semantics = EXECUTION as function-style algorithms + the ERROR MODEL (abort/propagate/partial — pin it)
          7 Output & error format (journal events, result shape, exit codes)  8 Conformance (RFC 2119 MUST/SHOULD/MAY + observably-equivalent clause).
        The bar: a developer with ZERO access to us could build a conforming implementation from SPEC.md alone.
        Apply the THREE REJECTION TESTS to every statement: (a) stranger test — could a stranger implement it without asking us?
        (b) edge-case test — empty/duplicate/missing/max/malformed/conflicting? (c) two-implementers test — could two teams diverge?

        The DSL is an Elixir compile-time DSL (read .claude/skills/elixir-meta-programming/references/*.md). Non-negotiable facts the spec must reflect accurately:
        - Workflow bodies compile to an INERT %Tree{} of node structs — ZERO closures. The `workflow` macro is a thin shell over the
          plain function Workflow.Compiler.parse/2, where ALL validation lives (compile-time, caller-located findings).
        - Determinism is enforced by ABSENCE of vocabulary nodes + compiler rejection, never a runtime linter.
        - The journal is the single source of truth; status/inspect/LiveView are pure folds. Effects are exactly-once via
          (run_id, node-path, iteration) idempotency keys. Loops are bounded and provably terminate.

        The adversarial refine panel found blocking defects in the §10 dataflow insertion. Resolve EVERY finding provided in the CODEX LOOPS REFINE REVISION INPUT with TARGETED edits. This remains a surgical
        change: §1–§9 and the authoring-guide prose are FROZEN — the only content you may edit is the new §10, the §10→§11 renumber, and the marked
        forward-reference notes. If a non-destructiveness defect says an existing hunk was altered, REVERT that hunk to its committed HEAD text
        (`git --no-pager show HEAD:SPEC.md` is the source of truth). Keep every NOT-yet-landed dataflow idiom labeled Proposed; keep any LANDED idiom
        (per .spec-workshop/dataflow.md) in the implemented body held to code fidelity.
        Edit SPEC.md with targeted edits and return an artifact string summarizing the revisions and the current SPEC.md state for the next reviewer round.
        """),
      until: :unanimous,
      max_rounds: 5,
      on_non_convergence: :accept_current
    )

    phase("Finalize")

    let(
      :cold_read =
        agent(
          """
          You are authoring/reviewing a formal, implementable language spec using the language-spec-author method.
          READ FIRST (they are on disk): .claude/skills/language-spec-author/references/spec-anatomy.md, .claude/skills/language-spec-author/references/formal-notation.md, .claude/skills/language-spec-author/references/interview-playbook.md.
          The 8-part anatomy the spec MUST cover (mark any part deliberately N/A, never silently omit):
            1 Purpose & design principles (the tie-breakers)  2 Lexical grammar  3 Syntactic grammar (`::` lexical vs `:` syntactic)
            4 Semantic model (the inert %Tree{}/%Node{} shapes)  5 Static semantics = compile-time VALIDATION rules, each with a COUNTER-EXAMPLE
            6 Dynamic semantics = EXECUTION as function-style algorithms + the ERROR MODEL (abort/propagate/partial — pin it)
            7 Output & error format (journal events, result shape, exit codes)  8 Conformance (RFC 2119 MUST/SHOULD/MAY + observably-equivalent clause).
          The bar: a developer with ZERO access to us could build a conforming implementation from SPEC.md alone.
          Apply the THREE REJECTION TESTS to every statement: (a) stranger test — could a stranger implement it without asking us?
          (b) edge-case test — empty/duplicate/missing/max/malformed/conflicting? (c) two-implementers test — could two teams diverge?

          You are a developer with ZERO prior context, handed the NEW "§10 — Tier-1 dataflow" section of SPEC.md to implement (the rest of the
          spec is already accepted). Read §10 end to end (and the shipped clauses it forward-references). List every question you would have to ask the authors
          to build the ADOPT idioms from §10 alone — each is a defect. Return pass=true only if §10's ADOPT idioms are implementable with no further questions.
          """,
          label: "review:cold-read"
        )
    )

    agent(
      ~P"""
      Resolve these final cold-read defects with TARGETED edits to §10 only (§1–§9 and the authoring guide stay frozen), then confirm:
      Treat the interpolated cold-read output below as the defect list that the Claude workflow interpolated here.
      If the cold-read passed with no defects, make no edits and report that §10 is cold-read clean.

      COLD-READ OUTPUT:
      <%= @cold_read %>
      """,
      label: "revise:cold-read"
    )

    agent(
      """
      Finalize the SPEC.md §10 insertion for HUMAN REVIEW — do NOT commit anything. Steps:
      1. Run `bash .claude/skills/language-spec-author/scripts/check-spec.sh SPEC.md` and capture its verdict.
      2. Run `git --no-pager diff --stat HEAD -- SPEC.md` and `git --no-pager diff HEAD -- SPEC.md | head -c 4000`.
      3. VERIFY the change is additive+surgical: the pre-existing §1–§9 and authoring-guide text is unchanged except the §10 insertion, the §10→§11
         renumber, and the marked forward-reference notes. If ANY other pre-existing hunk changed, say so loudly as a REGRESSION.
      4. Ensure .spec-workshop/ is gitignored (append to .gitignore if missing) — do not stage or commit it.
      Return: the check-spec.sh verdict, the diff --stat line, an explicit surgical/additive PASS or REGRESSION verdict, and a one-paragraph description
      of what §10 adds. Leave SPEC.md modified-but-uncommitted.
      """,
      label: "verify:final"
    )

    return("surgical-insert:no-commit:max-rounds-5")
  end
end
