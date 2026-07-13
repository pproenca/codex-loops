workflow "workflow-dsl-spec" do
  phase("Ground truth")

  log("SPEC.md already exists — mapping current structure, §10 dataflow, and §11 authoring guide for maintenance")

  parallel([
    agent(
      """
      Extract GROUND TRUTH for the "spec-structure" area, to support a targeted maintenance audit of the CURRENT SPEC.md.
      Read SPEC.md (the existing committed spec at repo root), and .claude/skills/language-spec-author/scripts/check-spec.sh (and grep as needed). Report a precise structural map of the CURRENT SPEC.md: the full section/heading outline with line ranges; the §9 (`refine` V1), §10 dataflow, and §11 authoring-guide boundaries; every internal cross-reference to §10 dataflow and §11 authoring guidance; the Appendix B grammar-summary structure; and the current clauses that define or reference dataflow behavior (Principle 6, §1.2 General-computation Non-goal, §2.4 closed vocabulary, §3 syntax, §4 semantic model, §5 validation, §6 execution/provider port, §7 output payloads, §8 conformance, §10 dataflow, and §11 authoring guidance). Quote each anchor line verbatim so maintenance edits can target them exactly. This is a MAP, not a critique — do not propose rewrites. Be exhaustive and PRECISE — exact headings, line ranges, section numbers, struct fields, event names, and verbatim anchor lines.
      Then WRITE your findings to .spec-workshop/spec-structure.md (create the dir if needed) as clean markdown, and return the structured summary.
      """,
      label: "read:spec-structure"
    ),
    agent(
      """
      Extract GROUND TRUTH for the "dataflow" area, treating §10 as the current normative home for the implemented dataflow core.
      Read SPEC.md §10 and the §11 authoring-guide dataflow examples, then grep lib/ and test/ for the implemented dataflow constructs (%Workflow.Template{}, Workflow.Node.Emit, Workflow.Node.EmitResult, the ~P sigil, `let` producers, binding_env threading, RenderText, rendered prompt journaling, and run_completed terminal values). Report the §10 implemented core exactly as the CURRENT SPEC.md states it: Template layer, `let`, top-level prompt injection, `emit`, `emit_result`, and pipeline-by-composition; also report the §10 DEFER surface (`gather`, `map`) and REJECT surface (`reduce`, `select`/`when`) as boundaries the compiler should continue to reject. For each claim, cite the spec anchor and the source/test evidence that confirms or contradicts it. This dossier decides what maintenance edits are needed to keep SPEC.md aligned with the landed implementation. Be exhaustive and PRECISE — exact headings, line ranges, section numbers, struct fields, event names, and verbatim anchor lines.
      Then WRITE your findings to .spec-workshop/dataflow.md (create the dir if needed) as clean markdown, and return the structured summary.
      """,
      label: "read:dataflow"
    )
  ])

  phase("Draft")

  log("Structure mapped for 2 areas; auditing and maintaining the current SPEC.md")

  let(
    :draft =
      agent(
        """
        You are authoring/reviewing a formal, implementable language spec using the language-spec-author method.
        READ FIRST (they are on disk): .claude/skills/language-spec-author/references/spec-anatomy.md, .claude/skills/language-spec-author/references/formal-notation.md, .claude/skills/language-spec-author/references/interview-playbook.md.
        The 8-part anatomy the spec MUST cover (mark any part deliberately N/A, never silently omit):
          1 Purpose & design principles (the tie-breakers)  2 Lexical grammar  3 Syntactic grammar (`::` lexical vs `:` syntactic)
          4 Semantic model (the inert %Tree{}/%Node{} shapes)  5 Static semantics = load-time VALIDATION rules, each with a COUNTER-EXAMPLE
          6 Dynamic semantics = EXECUTION as function-style algorithms + the ERROR MODEL (abort/propagate/partial — pin it)
          7 Output & error format (journal events, result shape, exit codes)  8 Conformance (RFC 2119 MUST/SHOULD/MAY + observably-equivalent clause).
        The bar: a developer with ZERO access to us could build a conforming implementation from SPEC.md alone.
        Apply the THREE REJECTION TESTS to every statement: (a) stranger test — could a stranger implement it without asking us?
        (b) edge-case test — empty/duplicate/missing/max/malformed/conflicting? (c) two-implementers test — could two teams diverge?

        The language is path-first, Elixir-shaped data that is parsed but never compiled or evaluated. Non-negotiable facts the spec must reflect accurately:
        - A script is exactly one bare top-level `workflow "name" do ... end` form. Workflow.Compiler.compile/3 turns its body into an
          INERT %Tree{} of node structs — ZERO closures — and owns ALL load-time validation through caller-located findings.
        - Determinism is enforced by ABSENCE of vocabulary nodes + compiler rejection, never a runtime linter.
        - The journal is the single source of truth; status/inspect/LiveView are pure folds. Effects are exactly-once via
          (run_id, node-path, iteration) idempotency keys. Loops are bounded and provably terminate.

        MAINTENANCE EDIT — DO NOT REWRITE SPEC.md. SPEC.md at the repo root is an already-authored, adversarially-hardened, committed spec. §10 is the current normative home for implemented dataflow core; §11 is the current authoring guide. Your job is to audit and maintain the current document, making only targeted corrections for drift. You MUST preserve unrelated content byte-for-byte. This is a maintenance pass, never a rewrite.

        Read (do NOT skip): the CURRENT SPEC.md in full; the structure map at .spec-workshop/spec-structure.md (it gives you exact anchor lines and current §10/§11 references); and the dataflow dossier at .spec-workshop/dataflow.md (it gives you the code-fidelity inventory for the landed dataflow core and the DEFER/REJECT boundaries).

        Do exactly this, with targeted edits only when the audit finds drift:
        1. Audit the section map: §10 MUST remain "Dataflow core and proposed extensions" and §11 MUST remain "Authoring guide for agents". Fix only incorrect headings, internal links, or cross-references involving the current §10/§11 structure.
        2. Audit §10 as normative dataflow content. The implemented core is Template layer, `let` over supported producers, top-level `agent(~P"...")` prompt injection, `emit`, `emit_result`, and pipeline-by-composition. Keep `gather`/`map` clearly DEFER and `reduce`/`select`/`when` clearly REJECT. Repair any wording that frames the implemented core as future-only, design-only, or outside the current spec.
        3. Audit §11 as the current authoring guide. Its closed vocabulary, top mistakes, and worked use-cases MUST teach the current §10 dataflow core accurately: final `return`/`emit`/`emit_result`, previous `let` bindings only, top-level template prompts only, and literal-only nested prompts.
        4. Audit implementation fidelity for every normative dataflow claim you touch. If SPEC.md and source disagree, the code is the defect oracle for implemented behavior; DEFER/REJECT surfaces are checked only for clear exclusion from the current compiler vocabulary.
        5. Keep design provenance secondary to SPEC.md. Historical proposal notes may explain why the current shape exists, but they MUST NOT imply that the implemented dataflow core is absent from the current language.

        After editing, run `bash .claude/skills/language-spec-author/scripts/check-spec.sh SPEC.md` and `git --no-pager diff --stat HEAD -- SPEC.md`. Return: the check verdict, the diff --stat line, the precise clauses you changed, and a one-paragraph summary of the current §10/§11 maintenance result. If the required repair would become a broad rewrite, STOP and report why instead.
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
          4 Semantic model (the inert %Tree{}/%Node{} shapes)  5 Static semantics = load-time VALIDATION rules, each with a COUNTER-EXAMPLE
          6 Dynamic semantics = EXECUTION as function-style algorithms + the ERROR MODEL (abort/propagate/partial — pin it)
          7 Output & error format (journal events, result shape, exit codes)  8 Conformance (RFC 2119 MUST/SHOULD/MAY + observably-equivalent clause).
        The bar: a developer with ZERO access to us could build a conforming implementation from SPEC.md alone.
        Apply the THREE REJECTION TESTS to every statement: (a) stranger test — could a stranger implement it without asking us?
        (b) edge-case test — empty/duplicate/missing/max/malformed/conflicting? (c) two-implementers test — could two teams diverge?

        LENS: SPEC COMPLETENESS. Apply the three rejection tests to EVERY section. A defect is any statement a stranger couldn't implement, any rule missing its counter-example, any happy-path-only algorithm, any unpinned error-model decision, any place two implementers could diverge. Read the spec-anatomy done-bars and hold each part to them.

        SCOPE — this run maintains the current SPEC.md. §10 dataflow core is normative and §11 is the current authoring guide; do not ask to add a new §10 or renumber the guide. Confine defects to (i) current §10 dataflow correctness, (ii) §11 authoring-guide fidelity, (iii) cross-reference/heading drift involving §10/§11, and (iv) unintended changes introduced by this maintenance pass. (The non-destructiveness lens is the exception — it audits the whole diff.)

        Adversarially review the CURRENT SPEC.md at the repository root (read it fresh; read .spec-workshop/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return approved=false with blocking findings if you find ANY in scope; return approved=true with no blocking findings only if this lens is fully satisfied. Each blocking finding MUST have a stable id, a precise issue, and a concrete fix.
        """,
        adapter: :findings_v1
      ),
      reviewer(
        :implementation_fidelity,
        """
        The language is path-first, Elixir-shaped data that is parsed but never compiled or evaluated. Non-negotiable facts the spec must reflect accurately:
        - A script is exactly one bare top-level `workflow "name" do ... end` form. Workflow.Compiler.compile/3 turns its body into an
          INERT %Tree{} of node structs — ZERO closures — and owns ALL load-time validation through caller-located findings.
        - Determinism is enforced by ABSENCE of vocabulary nodes + compiler rejection, never a runtime linter.
        - The journal is the single source of truth; status/inspect/LiveView are pure folds. Effects are exactly-once via
          (run_id, node-path, iteration) idempotency keys. Loops are bounded and provably terminate.

        LENS: IMPLEMENTATION FIDELITY. For every normative claim about the IMPLEMENTED vocabulary, verify it against the REAL source (grep lib/workflow/*.ex and .spec-workshop/*.md). A defect is any spec statement the code contradicts, any combinator option/arg shape that is wrong, any node field/event name that doesn't exist. `refine` V1 is implemented/normative and is NOT exempt: it must match the compiler, runtime, events, status fold, and binding behavior in lib/. The §10 implemented dataflow core is also NOT exempt: Template, `let`, top-level prompt injection, `emit`, `emit_result`, and pipeline-by-composition must match the compiler/runtime/events. Treat the §10 DEFER/REJECT surfaces as documented boundaries; do not require code for them, but verify SPEC.md clearly excludes them from the current compiler vocabulary. If code and spec disagree, the CODE is right — the spec is the defect.

        SCOPE — this run maintains the current SPEC.md. §10 dataflow core is normative and §11 is the current authoring guide; do not ask to add a new §10 or renumber the guide. Confine defects to (i) current §10 dataflow correctness, (ii) §11 authoring-guide fidelity, (iii) cross-reference/heading drift involving §10/§11, and (iv) unintended changes introduced by this maintenance pass. (The non-destructiveness lens is the exception — it audits the whole diff.)

        Adversarially review the CURRENT SPEC.md at the repository root (read it fresh; read .spec-workshop/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return approved=false with blocking findings if you find ANY in scope; return approved=true with no blocking findings only if this lens is fully satisfied. Each blocking finding MUST have a stable id, a precise issue, and a concrete fix.
        """,
        adapter: :findings_v1
      ),
      reviewer(
        :invariants,
        """
        The language is path-first, Elixir-shaped data that is parsed but never compiled or evaluated. Non-negotiable facts the spec must reflect accurately:
        - A script is exactly one bare top-level `workflow "name" do ... end` form. Workflow.Compiler.compile/3 turns its body into an
          INERT %Tree{} of node structs — ZERO closures — and owns ALL load-time validation through caller-located findings.
        - Determinism is enforced by ABSENCE of vocabulary nodes + compiler rejection, never a runtime linter.
        - The journal is the single source of truth; status/inspect/LiveView are pure folds. Effects are exactly-once via
          (run_id, node-path, iteration) idempotency keys. Loops are bounded and provably terminate.

        LENS: INVARIANTS. A defect is any place the spec states or implies something that violates: inert closure-free tree, determinism-by-absence, journal-as-sole-truth (no process state), exactly-once effects, bounded/terminating loops, validate-while-parsing-at-load-time. Also flag any execution algorithm whose determinism or replay-safety is not actually guaranteed by what the spec says. NOTE the §10 dataflow core adopts the journaled-values-only, deterministic-render-only rule as current normative behavior; do NOT flag value binding itself as an invariant violation, but DO verify the rule preserves the listed invariants — flag any dataflow construct whose closure-freedom, determinism-by-absence, journal-as-sole-truth, exactly-once, or bounded termination is not actually guaranteed by what the spec says (e.g. an unpinned inspect-map render order, a template hole that could admit non-journaled data, a bound value read before its producer commits, an unbounded map).

        SCOPE — this run maintains the current SPEC.md. §10 dataflow core is normative and §11 is the current authoring guide; do not ask to add a new §10 or renumber the guide. Confine defects to (i) current §10 dataflow correctness, (ii) §11 authoring-guide fidelity, (iii) cross-reference/heading drift involving §10/§11, and (iv) unintended changes introduced by this maintenance pass. (The non-destructiveness lens is the exception — it audits the whole diff.)

        Adversarially review the CURRENT SPEC.md at the repository root (read it fresh; read .spec-workshop/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return approved=false with blocking findings if you find ANY in scope; return approved=true with no blocking findings only if this lens is fully satisfied. Each blocking finding MUST have a stable id, a precise issue, and a concrete fix.
        """,
        adapter: :findings_v1
      ),
      reviewer(
        :teachability,
        """
        You are authoring/reviewing a formal, implementable language spec using the language-spec-author method.
        READ FIRST (they are on disk): .claude/skills/language-spec-author/references/spec-anatomy.md, .claude/skills/language-spec-author/references/formal-notation.md, .claude/skills/language-spec-author/references/interview-playbook.md.
        The 8-part anatomy the spec MUST cover (mark any part deliberately N/A, never silently omit):
          1 Purpose & design principles (the tie-breakers)  2 Lexical grammar  3 Syntactic grammar (`::` lexical vs `:` syntactic)
          4 Semantic model (the inert %Tree{}/%Node{} shapes)  5 Static semantics = load-time VALIDATION rules, each with a COUNTER-EXAMPLE
          6 Dynamic semantics = EXECUTION as function-style algorithms + the ERROR MODEL (abort/propagate/partial — pin it)
          7 Output & error format (journal events, result shape, exit codes)  8 Conformance (RFC 2119 MUST/SHOULD/MAY + observably-equivalent clause).
        The bar: a developer with ZERO access to us could build a conforming implementation from SPEC.md alone.
        Apply the THREE REJECTION TESTS to every statement: (a) stranger test — could a stranger implement it without asking us?
        (b) edge-case test — empty/duplicate/missing/max/malformed/conflicting? (c) two-implementers test — could two teams diverge?

        LENS: TEACHABILITY. This SPEC.md must let an agent author a NEW correct workflow with no access to the code. TEST IT: from SPEC.md alone, write a fresh workflow that exercises a non-trivial use-case (e.g. a review-gated pipeline, `refine`, or a dataflow flow that binds an output with `let`, injects it into a downstream agent's `~P` prompt, and renders a terminal with `emit`). Would it compile under the rules as written? Every ambiguity that forced you to guess, every combinator you couldn't use correctly from the doc, is a defect.

        SCOPE — this run maintains the current SPEC.md. §10 dataflow core is normative and §11 is the current authoring guide; do not ask to add a new §10 or renumber the guide. Confine defects to (i) current §10 dataflow correctness, (ii) §11 authoring-guide fidelity, (iii) cross-reference/heading drift involving §10/§11, and (iv) unintended changes introduced by this maintenance pass. (The non-destructiveness lens is the exception — it audits the whole diff.)

        Adversarially review the CURRENT SPEC.md at the repository root (read it fresh; read .spec-workshop/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return approved=false with blocking findings if you find ANY in scope; return approved=true with no blocking findings only if this lens is fully satisfied. Each blocking finding MUST have a stable id, a precise issue, and a concrete fix.
        """,
        adapter: :findings_v1
      ),
      reviewer(
        :structural_lint,
        """
        LENS: STRUCTURAL LINT. Run .claude/skills/language-spec-author/scripts/check-spec.sh on SPEC.md (bash). Report every FAIL/WARN as a defect (missing section, unresolved TODO/placeholder, missing grammar notation, absent RFC 2119 keywords, missing counter-examples). Also check cross-reference closure: every algorithm/type/term the current §10 and §11 use must be defined somewhere in the doc — a dangling reference is a defect. Distinguish inherited global warnings from drift in the maintained §10/§11 surface.

        SCOPE — this run maintains the current SPEC.md. §10 dataflow core is normative and §11 is the current authoring guide; do not ask to add a new §10 or renumber the guide. Confine defects to (i) current §10 dataflow correctness, (ii) §11 authoring-guide fidelity, (iii) cross-reference/heading drift involving §10/§11, and (iv) unintended changes introduced by this maintenance pass. (The non-destructiveness lens is the exception — it audits the whole diff.)

        Adversarially review the CURRENT SPEC.md at the repository root (read it fresh; read .spec-workshop/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return approved=false with blocking findings if you find ANY in scope; return approved=true with no blocking findings only if this lens is fully satisfied. Each blocking finding MUST have a stable id, a precise issue, and a concrete fix.
        """,
        adapter: :findings_v1
      ),
      reviewer(
        :non_destructiveness,
        """
        LENS: NON-DESTRUCTIVENESS (the safety guard). Run `git --no-pager diff HEAD -- SPEC.md` (bash). This change MUST be targeted maintenance. Permitted modifications are audit-driven corrections to SPEC.md drift, cross-references, §10 dataflow fidelity, and §11 authoring-guide fidelity. ANY unrelated deletion, rewording, reordering, or "improvement" of existing prose is a BLOCKING defect — report each such hunk with its diff context and demand it be reverted to the HEAD text. A wholesale rewrite (large deletion counts, the body shrinking) is the top defect this lens exists to catch. Also flag if the diff shows the file was truncated, §10 disappeared, or §11 stopped being the authoring guide.

        SCOPE — this run maintains the current SPEC.md. §10 dataflow core is normative and §11 is the current authoring guide; do not ask to add a new §10 or renumber the guide. Confine defects to (i) current §10 dataflow correctness, (ii) §11 authoring-guide fidelity, (iii) cross-reference/heading drift involving §10/§11, and (iv) unintended changes introduced by this maintenance pass. (The non-destructiveness lens is the exception — it audits the whole diff.)

        Adversarially review the CURRENT SPEC.md at the repository root (read it fresh; read .spec-workshop/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return approved=false with blocking findings if you find ANY in scope; return approved=true with no blocking findings only if this lens is fully satisfied. Each blocking finding MUST have a stable id, a precise issue, and a concrete fix.
        """,
        adapter: :findings_v1
      )
    ],
    revise_with:
      agent("""
      You are authoring/reviewing a formal, implementable language spec using the language-spec-author method.
      READ FIRST (they are on disk): .claude/skills/language-spec-author/references/spec-anatomy.md, .claude/skills/language-spec-author/references/formal-notation.md, .claude/skills/language-spec-author/references/interview-playbook.md.
      The 8-part anatomy the spec MUST cover (mark any part deliberately N/A, never silently omit):
        1 Purpose & design principles (the tie-breakers)  2 Lexical grammar  3 Syntactic grammar (`::` lexical vs `:` syntactic)
        4 Semantic model (the inert %Tree{}/%Node{} shapes)  5 Static semantics = load-time VALIDATION rules, each with a COUNTER-EXAMPLE
        6 Dynamic semantics = EXECUTION as function-style algorithms + the ERROR MODEL (abort/propagate/partial — pin it)
        7 Output & error format (journal events, result shape, exit codes)  8 Conformance (RFC 2119 MUST/SHOULD/MAY + observably-equivalent clause).
      The bar: a developer with ZERO access to us could build a conforming implementation from SPEC.md alone.
      Apply the THREE REJECTION TESTS to every statement: (a) stranger test — could a stranger implement it without asking us?
      (b) edge-case test — empty/duplicate/missing/max/malformed/conflicting? (c) two-implementers test — could two teams diverge?

      The language is path-first, Elixir-shaped data that is parsed but never compiled or evaluated. Non-negotiable facts the spec must reflect accurately:
      - A script is exactly one bare top-level `workflow "name" do ... end` form. Workflow.Compiler.compile/3 turns its body into an
        INERT %Tree{} of node structs — ZERO closures — and owns ALL load-time validation through caller-located findings.
      - Determinism is enforced by ABSENCE of vocabulary nodes + compiler rejection, never a runtime linter.
      - The journal is the single source of truth; status/inspect/LiveView are pure folds. Effects are exactly-once via
        (run_id, node-path, iteration) idempotency keys. Loops are bounded and provably terminate.

      The adversarial refine panel found blocking defects in the SPEC.md maintenance pass. Resolve EVERY finding provided in the CODEX LOOPS REFINE REVISION INPUT with TARGETED edits. §10 dataflow core is normative; §11 is the current authoring guide. If a non-destructiveness defect says an unrelated hunk was altered, REVERT that hunk to its committed HEAD text (`git --no-pager show HEAD:SPEC.md` is the source of truth). Keep DEFER/REJECT dataflow surfaces clearly excluded from the current compiler vocabulary, and keep historical design provenance secondary to SPEC.md.
      Edit SPEC.md with targeted edits and return an artifact string summarizing the revisions and the current SPEC.md state for the next reviewer round.
      """),
    until: :unanimous,
    max_rounds: 5,
    on_non_convergence: :accept_current,
    gates: [
      cold_read: [
        reviewer:
          reviewer(
            :cold_read,
            """
            You are a developer with ZERO prior context, handed the revised SPEC.md section produced by the refine loop. Read the section end to end
            and list every question you would have to ask the authors to implement it. Each unanswered question is a blocking finding.
            Return approved=true only if the section is implementable with no further questions.
            """,
            adapter: :findings_v1
          ),
        when: path_exists("")
      ],
      repair_when: path_non_empty("/coldRead/openFindings"),
      halt_when: path_non_empty("/roleFailures")
    ]
  )

  phase("Finalize")

  agent(
    """
    Finalize the current SPEC.md maintenance pass for HUMAN REVIEW — do not commit anything. Steps:
    1. Run `bash .claude/skills/language-spec-author/scripts/check-spec.sh SPEC.md` and capture its verdict.
    2. Run `git --no-pager diff --stat HEAD -- SPEC.md` and `git --no-pager diff HEAD -- SPEC.md | head -c 4000`.
    3. VERIFY the change is targeted maintenance: §10 remains the current normative home for implemented dataflow core, §11 remains the current authoring guide, and no stale language tells agents to add a new §10 or treat the implemented dataflow core as future-only. If ANY unrelated pre-existing hunk changed, say so loudly as a REGRESSION.
    4. Ensure .spec-workshop/ is gitignored (append to .gitignore if missing) — do not stage or commit it.
    Return: the check-spec.sh verdict, the diff --stat line, an explicit targeted-maintenance PASS or REGRESSION verdict, and a one-paragraph description
    of the §10/§11 maintenance result. Leave SPEC.md modified-but-uncommitted.
    """,
    label: "verify:final"
  )

  return("spec-maintenance:no-commit:max-rounds-5")
end
