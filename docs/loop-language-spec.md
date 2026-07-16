# LOOP Language Specification

Status: exploratory language proposal  
Language version: LOOP/1  
Document version: 0.3.0  
Intended implementation: Codex Loops on Elixir/OTP

## 1. Scope and conformance

LOOP is the **Language of Obligations, Outcomes, and Proofs**. It is a small,
typed language for work performed by stochastic agents and deterministic
tools. Its source is simultaneously:

- an executable workflow;
- an information-flow diagram;
- a responsibility assignment;
- an authority request;
- a budget;
- and an auditable claim about what constitutes success.

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT,
RECOMMENDED, NOT RECOMMENDED, MAY, and OPTIONAL in this document are to be
interpreted as described by RFC 2119 and RFC 8174 when, and only when, they
appear in all capitals.

A conforming LOOP/1 implementation MUST implement every normative rule in this
document. Extensions MUST reject or version-gate syntax whose meaning is not
defined here. A runtime MUST NOT silently reinterpret an unsupported feature.

## 2. The problem LOOP is solving

Existing workflow languages mostly describe control flow. Agent workflows have
five additional questions that cannot be left in prose:

1. What exact information reaches each model turn?
2. Which agent owns the next obligation?
3. What authority and durable effects can that obligation exercise?
4. What typed value and proof must it return?
5. Which external rule permits the result to replace its predecessor?

Natural-language-only orchestration repeats those facts in long prompts.
Conventional DAGs hide responsibility inside node configuration. General
programming languages permit too much ambient state. Extremely compressed
agent codes save tokens by making human review harder.

LOOP makes the common path symbolic and the dangerous path verbal:

~~~loop
change
-> @reviewer[R("."), X, E, retry(2)] {
  "Falsify correctness, security, compatibility, and rollback safety."
}
-> review:Review
~~~

Read it literally: the value named “change” flows to the accountable stochastic
role “reviewer”; the role may read the workspace and execute commands, owes
evidence, may repair an invalid typed answer twice, and owes a Review.

## 3. Design lenses

LOOP is designed through the following lenses. No one lens is allowed to
dominate the language.

### 3.1 Selective model workspace

Anthropic's J-space research reports a small collection of word-linked internal
features that is selectively active during deliberate, multi-step reasoning.
The relevant lesson is not to imitate hidden activations or invent a “language
Claude speaks.” J-space emerged in the studied model; it was not a programming
language authored by Claude.

The useful design constraint is that an agent's public working set SHOULD be
small, stable, named, and task-selective. LOOP therefore routes exact typed
values, not accumulated transcripts. Every turn receives one generated
obligation card with a few stable handles.

### 3.2 Symbolic communication

Recent multi-agent research suggests that compact, reusable symbolic protocols
can substantially reduce communication tokens when they retain variable
bindings, constraints, transformations, and verification tags. The same work
also shows the failure mode: excessive compression harms correctness and makes
the protocol opaque.

LOOP assigns symbols only to high-frequency, invariant meanings:

| Form | One meaning |
|---|---|
| <code>value -> operation -> result:Type</code> | immutable information and obligation flow |
| <code>@role</code> | accountable stochastic agent |
| <code>$check</code> | deterministic runtime operation |
| <code>left <=> right</code> | atomic paired comparison |
| <code>=> label:disposition(value)</code> | declared terminal business outcome |

Rare or safety-critical concepts remain words: <code>blocked</code>,
<code>otherwise</code>, <code>evidence</code>, <code>under root</code>,
<code>adopt</code>, <code>sealed</code>, and <code>outcome_unknown</code>.

### 3.3 Human audit

A reviewer MUST be able to answer, without opening a prompt template:

- what each agent sees;
- what each agent owes;
- what it may read, write, and execute;
- where concurrency begins and joins;
- why repetition terminates;
- what evidence gates adoption;
- and which final outcomes are possible.

The authored ribbon is optimized for reading flow. The compiler also generates
a versioned obligation IR and a contract matrix. These are projections of the
same plan, not separately authored documents.

### 3.4 Programming-language semantics

LOOP borrows immutability and value orientation from functional languages,
explicit lineage from SSA, edges from dataflow systems, and authority envelopes
from effect systems. It deliberately does not borrow Lisp surface syntax.
Parentheses denote tuples and calls, not the program itself.

Source order is execution order unless <code>par</code> or <code>each</code>
explicitly introduces concurrency. There is no implicit “ready nodes run
together” rule.

### 3.5 Distributed-systems reality

An agent attempt may settle, fail before starting, or become unknowable after
starting. LOOP therefore distinguishes business outcomes from operational run
status and never pretends that retry makes an at-most-once effect exactly once.
Plans, values, attempts, and proofs are content-addressed and journaled.

### 3.6 Recursive improvement

Improvement is not self-assertion. A candidate may replace an incumbent only
through an atomic, paired, externally governed comparison. The proposer cannot
edit the root policy, protected suite, proof, or promotion pointer.

LOOP supports bounded, certified improvement of program values. It does not
claim general recursive self-improvement, which has not been demonstrated.

### 3.7 Token economics

Token efficiency is measured, not inferred from character count. In an
indicative local comparison, a verbose responsibility block took 92–95 tokens
under two common tokenizer families; its ASCII ribbon took 40–41. A Unicode
arrow/glyph version took 43–44 despite having fewer characters. Consequently:

- canonical structural syntax is ASCII;
- common semantics receive short forms;
- domain concepts keep descriptive names;
- and the compiler reports token cost for each supported provider tokenizer.

### 3.8 Adversarial safety

Models are untrusted producers. They do not choose their own authority,
disposition, evaluation cohort, or retry interpretation. Data is never
interpolated into instructions. Unknown execution state is never coerced into a
failure, rejection, or success.

## 4. Goals and non-goals

LOOP/1 has these goals:

- make typed information flow visible from left to right;
- make exactly one owner visible at every stochastic obligation;
- make concurrency, feedback, budgets, and stop conditions explicit;
- route the smallest relevant context instead of full histories;
- produce executable and mockable plans;
- preserve exact provenance through resume and replay;
- support ordinary work and guarded program improvement with one small kernel;
- compile without executing host-language code.

LOOP/1 is not:

- a general-purpose language;
- an Elixir macro DSL;
- a prompt templating language;
- a shell language;
- a latent agent-to-agent code;
- a mutable blackboard;
- a mechanism for live self-modification;
- or a guarantee that model-produced evidence is true.

## 5. A complete first reading

The following workflow inventories a repository change, reviews each material
change concurrently, and issues a release decision. It is executable source,
not pseudocode.

~~~loop
LOOP/1

type Risk = Enum[:low, :medium, :high]

type Change {
  path: Path
  summary: Text(600)
  risk: Risk
}

type Inventory {
  summary: Text(1200)
  changes: List(Change, 64)
  unknowns: List(Text(400), 16)
}

type Review {
  path: Path
  verdict: Enum[:pass, :warning, :block, :inaccessible]
  finding: Text(1200)
  evidence: List(Evidence, 16)
}

type ReleaseDecision {
  status: Enum[:ready, :conditional, :block]
  rationale: Text(1600)
  actions: List(Text(400), 16)
  evidence: List(Evidence, 32)
}

flow release_readiness(
  base_ref: Text(200),
  head_ref: Text(200),
) -> ReleaseDecision
[turns<=160, tokens<=800000, active<=4, generations<=0]
allow [R("."), X] {
  goal "Decide whether the exact repository change is safe to release."

  outcomes {
    => ready:success(decision)
      when decision.status in [:ready, :conditional]
    => not_ready:blocked(decision)
      otherwise
  }

  (base_ref, head_ref)
  -> @scout[R("."), X, E, retry(2)] {
    """
    Inventory every behavior-changing diff and material unknown.
    Cite repository evidence. Make no edits.
    """
  }
  -> inventory:Inventory

  inventory.changes
  -> each change [par<=4, empty=:ok] {
    change
    -> @reviewer[R("."), X, E, retry(2)] {
      """
      Try to falsify release safety for this change.
      Check correctness, security, compatibility, rollback, and tests.
      Report inaccessible evidence as inaccessible, never as a pass.
      """
    }
    -> review:Review

    yield review
  }
  -> reviews:List(Review, 64)

  (inventory, reviews)
  -> @judge[E, retry(2)] {
    """
    Set ready, conditional, or block from the supplied findings.
    Every warning and blocker must cite supplied evidence.
    """
  }
  -> decision:ReleaseDecision
}
~~~

The information route is visible without inference:

~~~text
(base_ref, head_ref) -> @scout -> inventory
inventory.changes    -> each @reviewer -> reviews
(inventory, reviews) -> @judge -> decision
decision             => ready | not_ready
~~~

The workflow asks for at most 160 provider turns because 64 reviews, with two
schema-repair retries each, dominate the bound. The compiler MUST reject a
budget lower than the statically provable minimum or worst-case bound for the
declared structure.

## 6. Core semantic model

### 6.1 Values

Every runtime value is an immutable pair:

~~~text
TypedValue = {
  value: canonical typed data,
  provenance: Provenance
}
~~~

Provenance contains the producing node, attempt, input digests, plan digest,
provider identity or deterministic tool identity, attached evidence,
uncertainties, and commit event. Routing a value routes both its data and its
provenance. A workflow cannot forge or edit provenance.

Values are never implicitly copied from a prior turn's transcript. An agent sees
only the values on its incoming edge plus the workspace capabilities in its
contract.

### 6.2 Obligations

An operation between an incoming edge and outgoing binding is an obligation.

An <code>@role</code> obligation is stochastic. The role name is accountable for
producing the outgoing typed value under its contract and instruction.

A <code>$check</code> obligation is deterministic relative to its input values,
plan, content-addressed artifacts, executable identity, and declared
environment. It produces runtime-attested evidence.

The outgoing binding is what the operation owes. If an operation does not
produce a conforming value, its obligation has not settled successfully.

### 6.3 Edges and context

The expression left of <code>-></code> is the complete data context of the next
operation. A single reference supplies one value. A tuple supplies its named
values in written order.

There is no ambient binding capture. A role may use workspace paths through
<code>R</code>, but workspace access is authority, not hidden message context.
The generated obligation card lists routed data and workspace authority
separately.

### 6.4 Authority and effects

Contracts use this closed vocabulary:

| Form | Meaning |
|---|---|
| <code>R("pattern")</code> | read matching workspace paths |
| <code>W("pattern")</code> | read and durably write matching workspace paths |
| <code>X</code> | execute approved commands in the isolated workspace |
| <code>E</code> | return at least one structurally valid evidence reference |
| <code>retry(n)</code> | retry a settled invalid output at most n times |
| <code>timeout(s)</code> | deterministic operation wall-duration limit |
| <code>cwd("path")</code> | deterministic operation working directory |
| <code>output(bytes)</code> | inline stdout/stderr byte limit |

<code>R</code>, <code>W</code>, and <code>X</code> are requested grants. The
effective grant set is the union of requested grants, intersected with the flow
ceiling, runtime policy, caller authority, and provider enforcement capability.
It is not the intersection of individual contract entries.

<code>W</code> is both authority and an effect declaration. A successful
stochastic operation commits only changes matching its W patterns. Changes
outside those patterns fail the operation. Omitting W means the workspace is
read-only, including to commands launched through X.

The default contract is no workspace capability, no durable effect, no
required evidence, and no output retry. Defaults are expanded in the audit
projection.

LOOP/1 has no arbitrary network mutation capability. A future version must
introduce network reads and writes as separate, auditable capabilities.

### 6.5 Isolation

Every operation executes in an isolated snapshot derived from its committed
inputs. A read-only operation discards its overlay. A W operation atomically
commits matching changes only after its typed output and evidence settle.

An output-validation retry starts from the same committed snapshot and a fresh
overlay. A runtime MUST NOT retry an attempt whose provider outcome is unknown.

### 6.6 Outcomes versus run status

An outcome is a declared business result. A run status is an operational fact.
They are different namespaces.

LOOP/1 dispositions are:

- <code>success</code>
- <code>blocked</code>
- <code>unsafe</code>
- <code>inconclusive</code>
- <code>no_change</code>
- <code>exhausted</code>

Only the runtime evaluates an outcome clause. Agents cannot emit a disposition.
Expected domain inability, such as an inaccessible repository, MUST be modeled
inside a declared value type and handled by an outcome.

Run statuses are:

- <code>completed</code>, with exactly one declared outcome;
- <code>failed</code>, for a settled operational or validation failure;
- <code>outcome_unknown</code>, for an unsettled started attempt;
- <code>budget_exhausted</code>;
- <code>cancelled</code>.

An operational status MUST NOT be converted to a declared outcome.

### 6.7 Source order and concurrency

Flow forms execute in source order. A later form may use only flow parameters
and bindings committed by earlier forms.

Only <code>par</code>, <code>each</code>, and the evaluation lanes inside
<code>$judge</code> introduce concurrency. Concurrent branches begin from the
same committed snapshot. Their outputs become visible after a barrier and in
canonical source or list order.

Two branches whose W patterns may overlap are a validation error. A runtime
MUST NOT resolve overlapping writes by completion order.

## 7. Type and wire model

### 7.1 Type constructors

LOOP/1 has these closed scalar and bounded type constructors:

| Type | Meaning |
|---|---|
| <code>Bool</code> | true or false |
| <code>Int(min, max)</code> | signed integer in the inclusive range |
| <code>Text(max)</code> | UTF-8 text of at most max bytes |
| <code>Path</code> | normalized workspace-relative POSIX path |
| <code>Digest</code> | runtime-issued SHA-256 digest |
| <code>Evidence</code> | runtime-issued evidence handle |
| <code>Artifact</code> | runtime-issued immutable artifact handle |
| <code>Enum[:a, :b]</code> | one member of a finite tag set |
| <code>Optional(T)</code> | either null or a T |
| <code>List(T, max)</code> | ordered list containing at most max T values |
| <code>Variant[:tag(T), ...]</code> | tagged union with one payload |
| <code>Program(I, O)</code> | sealed executable LOOP program from I to O |
| <code>Suite(I, O)</code> | sealed protected evaluation suite |
| <code>Policy(T)</code> | sealed root policy governing T |
| <code>LoopResult(T)</code> | bounded-loop value, status, and iteration count |
| <code>EvolutionResult(T)</code> | evolution value, status, and proof chain |
| <code>CheckResult</code> | deterministic command result and expectations |
| <code>Comparison</code> | runtime-attested paired comparison proof |

Every text, list, and integer MUST be bounded in source. There is no unbounded
string, collection, map, float, or arbitrary JSON type.

A named record is closed:

~~~loop
type Finding {
  severity: Enum[:info, :warning, :block]
  summary: Text(800)
  evidence: List(Evidence, 8)
}
~~~

Unknown fields are invalid. Missing required fields are invalid. Recursive type
definitions are invalid in LOOP/1.

### 7.2 Type identity

Named records are nominal. Two differently named records with identical fields
are not equal types. A type alias is transparent after expansion. Constructor
arguments and agent outputs require exact type equality after alias expansion;
LOOP/1 has no implicit coercion or structural subtyping.

Program compatibility is stricter than input/output type equality. Compatible
programs MUST also have:

- the same declared outcome labels and dispositions;
- the same LOOP major version and compatible plan version;
- no wider requested authority or resource ceilings;
- a runtime and provider profile accepted by the root policy;
- and a canonical manifest accepted by that policy.

### 7.3 JSON representation

The provider wire representation is JSON:

- Bool and Int use JSON booleans and integers.
- Text and Path use JSON strings.
- Enum values use strings without the source colon.
- Records use objects with their declared field names.
- Lists use arrays.
- Optional uses a value or null.
- Variant uses <code>{"tag":"name","value":...}</code>.
- Evidence, Artifact, Digest, Program, Suite, Policy, and Comparison use opaque
  runtime handles outside provider-produced program source.

Integers MUST remain in the interoperable range
−9,007,199,254,740,991 through 9,007,199,254,740,991.

### 7.4 Program, suite, and policy values

A caller supplies Program, Suite, and Policy inputs as runtime-issued,
content-addressed handles. Suite and Policy values MUST NOT be produced by an
agent in LOOP/1.

When an agent owes Program(I, O), its generated value schema is:

~~~json
{"source": "LOOP/1\n..."}
~~~

The runtime parses, validates, normalizes, compiles, and seals that source. The
outgoing binding receives a Program handle only if the source:

- declares exactly I as input and O as output;
- satisfies the compatibility envelope;
- requests no prohibited capability;
- is no larger than 1 MiB of normalized UTF-8;
- and compiles under the pinned LOOP version.

An agent consuming a Program receives its canonical source and public manifest
as a read-only routed artifact. It does not receive protected suite or root
policy contents.

### 7.5 Canonicalization and identity

Source identity is computed as follows:

1. Decode strict UTF-8.
2. Replace CRLF and CR with LF.
3. Preserve all other bytes, including comments and insignificant whitespace.
4. Compute SHA-256 over
   <code>"LOOP-SOURCE/1\0" || normalized_source_bytes</code>.

Typed data is serialized with RFC 8785 JSON Canonicalization Scheme and hashed
over <code>"LOOP-VALUE/1\0" || type_identity || "\0" || jcs_bytes</code>.

The compiler serializes Plan V2 as RFC 8785 canonical JSON and hashes it over
<code>"LOOP-PLAN/2\0" || plan_bytes</code>. A conforming implementation MUST
journal the normalized source digest, compiler identity, Plan V2 bytes, and
plan digest before execution.

Evidence and artifact handles contain a kind prefix and content digest. A
handle is valid only if it resolves in the run's immutable content store and
its recorded producer is in the binding's provenance ancestry.

## 8. Authored forms

### 8.1 File shape

A LOOP/1 file:

- MUST contain strict UTF-8 and be at most 1 MiB after normalization;
- MUST begin with <code>LOOP/1</code>;
- MUST contain zero or more type declarations;
- MUST contain exactly one flow declaration;
- MUST end after that declaration;
- SHOULD use the extension <code>.loop</code>.

It does not define a module, import host code, interpolate environment
variables, or evaluate at compile time.

### 8.2 Flow header

~~~loop
flow name(input: InputType) -> OutputType
[turns<=40, tokens<=160000, active<=4, generations<=0]
allow [R("."), W("docs/**"), X] {
  ...
}
~~~

The four bounds are REQUIRED:

- <code>turns</code>: maximum provider turns, including evaluation turns;
- <code>tokens</code>: maximum provider input plus output tokens;
- <code>active</code>: maximum concurrently active operations;
- <code>generations</code>: maximum evolution generations.

Each bound is also capped by runtime policy. A zero generation bound prohibits
<code>evolve</code>.

The allow list is the complete workflow authority ceiling. Every node contract
must be a subset. A flow with no workspace authority writes <code>allow []</code>.

The goal is one short human statement. It appears in audit views but is not
automatically appended to every agent instruction.

### 8.3 Outcomes

~~~loop
outcomes {
  => publish:success(result) when result.status == :approved
  => hold:blocked(result) otherwise
}
~~~

An outcomes block MUST contain one or more ordered clauses and exactly one final
<code>otherwise</code>. Labels MUST be unique. Every clause MUST return a value
whose type is exactly the flow output type.

After all source forms settle, predicates are evaluated in order. The first true
clause is selected; otherwise selects the final clause. Outcome predicates may
refer to committed top-level bindings even though the block is written near the
flow header. They cannot inspect hidden prompts, transcripts, or protected
suite data.

### 8.4 Stochastic agent

~~~loop
(issue, constraints)
-> @planner[R("lib/**"), X, E, retry(1)] {
  "Find the root cause and return the smallest evidence-backed plan."
}
-> plan:Plan
~~~

The role identifier is an accountability label, not a provider selection.
Provider policy is pinned by the run.

The instruction block MUST contain exactly one text literal and has no
interpolation. Routed values are placed in a separate DATA section of the
obligation card. Text that resembles a reference or source expression remains
literal text.

An agent result has the conceptual envelope:

~~~text
{
  value: T,
  evidence: List(Evidence, 32),
  uncertainties: List(Text(1000), 16)
}
~~~

Only <code>value</code> is bound as T. Evidence and uncertainty remain in its
provenance and travel with it. If T itself contains Evidence fields, every
handle must also resolve in the attempt ledger.

<code>E</code> requires at least one evidence handle. Evidence handles are
minted by runtime-mediated file reads, commands, artifacts, checks, and
comparisons. A model-authored string is not evidence.

<code>retry(n)</code> permits n fresh attempts after a settled schema or local
validation rejection, with 0 ≤ n ≤ 5. It does not permit retry after an
unsettled started attempt, budget exhaustion, cancellation, or a durable commit.

### 8.5 Deterministic check

~~~loop
candidate
-> $verify[R("."), X, timeout(120), cwd("."), output(65536)] {
  run ["loop-check", artifact(candidate)]
  expect exit == 0
  expect stderr == ""
}
-> proof:CheckResult
~~~

A check command is an argument vector, never a shell string. Allowed arguments
are:

- a text literal;
- <code>value(ref)</code>, for a scalar typed value;
- <code>json(ref)</code>, for one RFC 8785 JSON argument;
- <code>artifact(ref)</code>, for the path of a read-only mounted artifact.

There is no interpolation, glob expansion, command substitution, pipeline,
redirection, or implicit shell.

Check expectations may compare exit to an Int and stdout or stderr to Text, or
use <code>contains</code> for bounded text. All expectations are conjoined.
A command that starts and exits produces CheckResult even when expectations
fail. Failure to start is an operational failure. A connection loss after an
external executor accepted the command is outcome_unknown.

CheckResult contains the executable digest, argv digest, environment digest,
exit status, bounded stdout and stderr, truncation flags, produced artifact
handles, expectation results, and <code>passed</code>. The runtime attaches the
whole result as deterministic evidence.

### 8.6 Pure construction

Records may be assembled without a turn:

~~~loop
(patch, tests, review)
-> RepairState(patch=patch, tests=tests, review=review)
-> next:RepairState
~~~

Every declared field appears exactly once. Arguments are named, evaluated from
routed references, and require exact field types. Constructors have no
authority, effects, or hidden computation.

### 8.7 Explicit parallelism

~~~loop
patch
-> par [active<=2] {
  patch
  -> $tests[R("."), X, timeout(180)] {
    run ["mix", "test"]
    expect exit == 0
  }
  -> tests:CheckResult

  patch
  -> @reviewer[R("."), X, E] {
    "Falsify the patch against the issue, compatibility, and security."
  }
  -> review:Review
}

(patch, tests, review)
-> @judge[E] { "Decide whether the exact patch is ready." }
-> decision:Decision
~~~

The expression entering <code>par</code> is the complete set of bindings the
branches may reference. Each branch MUST begin from one or more of those
bindings. Branches cannot reference sibling outputs. Branch terminal bindings
must be unique and escape together only after the barrier.

<code>active</code> is REQUIRED and may not exceed the flow bound. A branch
failure aborts the barrier. Completion order never affects output order.

### 8.8 Bounded fanout

~~~loop
findings
-> each finding with (policy) [par<=4, empty=:ok] {
  (finding, policy)
  -> @triager[E, retry(1)] { "Classify this finding under the policy." }
  -> triage:Triage

  yield triage
}
-> triage:List(Triage, 64)
~~~

The incoming value MUST be List(T, n). Each lane receives one item as the local
name plus only the explicitly listed <code>with</code> captures. Omitting
<code>with</code> captures nothing.

The body executes in lexical isolation. <code>yield</code> is REQUIRED and all
lanes yield exactly the list element type. Results preserve source-list order.

<code>par</code> is REQUIRED and must be in 1..64 and no greater than the flow
active bound. <code>empty=:ok</code> returns an empty list without executing the
body. <code>empty=:error</code> produces a settled operational failure. Expected
domain emptiness SHOULD instead be represented as data and handled by an
outcome.

### 8.9 Choice

~~~loop
assessment
-> choose {
  when assessment.verdict == :pass {
    yield assessment
  }

  otherwise {
    assessment
    -> @escalator[E] { "Turn the blockers into concrete next actions." }
    -> escalated:Assessment
    yield escalated
  }
}
-> result:Assessment
~~~

Cases are evaluated in order. Exactly one <code>otherwise</code> is REQUIRED
and MUST be last. Each branch sees only the incoming expression, creates a
lexical scope, and yields the same exact type. An unchosen branch executes
nothing.

### 8.10 Bounded feedback

~~~loop
draft
-> loop current [<=3, until next.approved] {
  current
  -> @critic[E] { "Find the most important remaining defect." }
  -> critique:Critique

  (current, critique)
  -> @reviser[E] { "Repair only the evidenced defect." }
  -> next:Draft

  yield next
}
-> revision:LoopResult(Draft)
~~~

A loop performs at least one iteration. Its positive integer bound is REQUIRED
and at most 1000. The body receives the current T, MUST yield exactly one next T,
then evaluates <code>until</code> in the completed body scope.

If the predicate is true, LoopResult has status <code>:satisfied</code>. If it
remains false at the bound, the result has status <code>:exhausted</code> and
contains the last yielded value. The result also records the iteration count
and per-generation provenance.

Bindings in an iteration are immutable. The compiler lowers <code>current</code>
and every body binding to generation-indexed SSA values. Only the yielded value
crosses the feedback edge; no transcript or unlisted body binding does.

### 8.11 Guarded program evolution

~~~loop
incumbent
-> evolve current under root safety_policy [<=8, stale<=2] {
  current
  -> @optimizer[E] {
    """
    Improve task decomposition without changing interface, authority,
    outcome semantics, or root policy.
    """
  }
  -> candidate:Program(TaskInput, TaskResult)

  current <=> candidate
  -> $judge(hidden_suite)[
       cases=64,
       trials=3,
       par<=4,
       turns<=2,
       gain>=200
     ]
  -> proof:Comparison

  adopt candidate with proof
  else keep current
}
-> evolution:EvolutionResult(Program(TaskInput, TaskResult))
~~~

The values <code>incumbent</code>, <code>safety_policy</code>, and
<code>hidden_suite</code> are caller-supplied opaque handles. The root policy
and suite MUST be outside the candidate's namespace and write authority.

The evolve body has exactly one proposer, one atomic comparison, and one
adoption clause in LOOP/1. Its generation bound must be no greater than the flow
generation bound. <code>stale</code> is the number of consecutive settled
non-adoptions that stops evolution early.

<code>current &lt;=&gt; candidate</code> is one comparison request, not two
evaluation nodes. The runtime evaluates both programs:

- on the exact same sealed case cohort and trial seeds;
- with pinned model, runtime, tools, budgets, and provider settings;
- in separate identical ephemeral snapshots;
- with writes discarded after every case;
- with network mutation prohibited;
- in randomized blinded order where the suite permits it;
- and under the root policy's hard guards.

The turn charge is
<code>2 × cases × trials × turns</code>, plus proposer turns. The compiler
includes that amount in worst-case budget validation.

Scores are integers in basis points from 0 through 10,000. <code>gain</code> is
the minimum strict candidate-minus-incumbent delta in basis points. The
effective threshold is the stricter of source and root policy.

Comparison is an opaque proof binding:

- root, incumbent, and candidate digests;
- suite, cohort, seeds, scorer, and guard digests;
- all pinned execution settings;
- aggregate incumbent and candidate scorecards;
- confidence and sample metadata required by the root;
- the measured delta;
- hard-guard results;
- and one verdict: <code>:adopt</code> or <code>:keep</code>.

Protected case contents, answers, and case-level diagnostics MUST NOT be exposed
to the proposer. A suite has a fixed query budget. Repeated probing beyond that
budget fails the comparison.

Adoption occurs only when the root validates that exact proof for that exact
parent and candidate and returns <code>:adopt</code>. A settled
<code>:keep</code> verdict retains current and increments stale. If any paired
attempt is outcome_unknown, the Comparison does not exist and the run
propagates outcome_unknown unchanged. Unknown is never treated as rejection,
failure, or zero score.

EvolutionResult reports the final value, whether any adoption occurred, the
stop reason (<code>:stale</code>, <code>:generation_limit</code>, or
<code>:unchanged</code>), generation count, and immutable proof chain.

The two-timescale pattern is expressed by evolving a task Program frequently
and an optimizer Program less frequently under separate roots. LOOP does not
grant either program authority to replace a deployed pointer from inside a run.

## 9. Lexical specification

### 9.1 Character repertoire

Structural source MUST be ASCII. Unicode is permitted inside strings, block
strings, and comments only. A formatter MUST emit ASCII structural syntax.
A UI MAY render arrows or comparison operators with Unicode glyphs, but copy,
save, hashing, and execution MUST use canonical ASCII source.

The scanner recognizes Unicode only after entering a string or comment. A
non-ASCII code point elsewhere is diagnostic L001.

### 9.2 Whitespace, line endings, and comments

Space, horizontal tab, and normalized LF separate tokens. Outside a text
literal they are otherwise insignificant. Comments begin with <code>#</code>
and continue through LF or end of file. Comments are retained by the lossless
CST and ignored by the semantic parser.

Tokens use longest match. In particular, <code>&lt;=&gt;</code>,
<code>-&gt;</code>, <code>=&gt;</code>, <code>&lt;=</code>,
<code>&gt;=</code>, <code>==</code>, and <code>!=</code> are each one token.

### 9.3 Identifiers

~~~grammar
LowerName  ::= [a-z][a-z0-9_]*
TypeName   ::= [A-Z][A-Za-z0-9]*
UInt       ::= "0" | [1-9][0-9]*
Int        ::= "0" | "-"? [1-9][0-9]*
Tag        ::= ":" LowerName
~~~

Flow, role, binding, parameter, and local names use LowerName. Type and record
constructor names use TypeName.

These words are reserved as declarations or binding names:

~~~text
LOOP type flow allow goal outcomes when otherwise
par each with empty yield choose loop until
evolve current under root stale adopt candidate proof keep
run expect value json artifact true false null
and or not in contains
~~~

Record fields following a dot or inside a type declaration are contextual and
may use the same spelling as a reserved word.

### 9.4 Text

A quoted text literal follows JSON string escaping and MUST NOT contain a raw
LF. A block string begins and ends with three double quotes.

For a block string, the parser:

1. removes one immediately following LF, if present;
2. removes one immediately preceding LF, if present;
3. finds the minimum leading space count among nonblank lines;
4. removes that many ASCII spaces from every nonblank line;
5. joins the remaining lines with LF.

Tabs in block-string indentation are preserved and do not contribute to the
common space count. Neither text form performs interpolation or escape
processing beyond JSON escapes in quoted text. Block strings treat backslash
and quote characters literally except for the closing triple quote.

## 10. Syntactic grammar

The grammar is extended EBNF. Bracketed items are optional, braces mean zero or
more repetitions, and a postfix plus means one or more. Literal punctuation and
words appear in quotes. Whitespace and comments may occur between tokens.

### 10.1 Program and declarations

~~~grammar
Program        ::= Header TypeDecl* FlowDecl EOF
Header         ::= "LOOP" "/" "1"

TypeDecl       ::= "type" TypeName "=" Type
                 | "type" TypeName "{" Field+ "}"
Field          ::= LowerName ":" Type

Type           ::= TypeName
                 | "Bool"
                 | "Int" "(" Int "," Int ")"
                 | "Text" "(" UInt ")"
                 | "Path"
                 | "Digest"
                 | "Evidence"
                 | "Artifact"
                 | "Enum" "[" TagList "]"
                 | "Optional" "(" Type ")"
                 | "List" "(" Type "," UInt ")"
                 | "Variant" "[" VariantList "]"
                 | "Program" "(" Type "," Type ")"
                 | "Suite" "(" Type "," Type ")"
                 | "Policy" "(" Type ")"
                 | "LoopResult" "(" Type ")"
                 | "EvolutionResult" "(" Type ")"
                 | "CheckResult"
                 | "Comparison"

TagList        ::= Tag ("," Tag)* [","]
VariantList    ::= VariantAlt ("," VariantAlt)* [","]
VariantAlt     ::= Tag "(" Type ")"
~~~

Built-in type names MUST NOT be redeclared. Record fields and enum or variant
tags MUST be unique within their declaration.

### 10.2 Flow, budget, authority, and outcomes

~~~grammar
FlowDecl       ::= "flow" LowerName "(" [Params] ")" "->" Type
                   Budget Allow "{"
                     Goal Outcomes FlowForm*
                   "}"

Params         ::= Param ("," Param)* [","]
Param          ::= LowerName ":" Type

Budget         ::= "["
                   "turns" "<=" UInt ","
                   "tokens" "<=" UInt ","
                   "active" "<=" UInt ","
                   "generations" "<=" UInt
                   "]"

Allow          ::= "allow" "[" [GrantList] "]"
GrantList      ::= Grant ("," Grant)* [","]
Grant          ::= "R" "(" Text ")"
                 | "W" "(" Text ")"
                 | "X"

Goal           ::= "goal" Text

Outcomes       ::= "outcomes" "{" Outcome+ "}"
Outcome        ::= "=>" LowerName ":" Disposition "(" Ref ")"
                   ("when" Predicate | "otherwise")

Disposition    ::= "success" | "blocked" | "unsafe"
                 | "inconclusive" | "no_change" | "exhausted"
~~~

<code>Text</code> in lexical grammar positions means either quoted Text or a
block string, not the Text type constructor.

### 10.3 Ribbons and bindings

~~~grammar
FlowForm       ::= Ribbon | ParForm

Ribbon         ::= Input "->" Stage "->" Binding
ParForm        ::= Input "->" "par" ParOptions "{" Ribbon+ "}"

Input          ::= Ref | "(" RefList ")"
RefList        ::= Ref ("," Ref)* [","]
Ref            ::= LowerName ("." LowerName)*
Binding        ::= LowerName ":" Type

Stage          ::= AgentStage
                 | CheckStage
                 | ConstructorStage
                 | EachStage
                 | ChooseStage
                 | LoopStage
                 | EvolveStage
~~~

Every ribbon contains one operation. A second operation begins a second ribbon
from the first binding. This keeps every source segment in the same readable
shape: inputs, owner or operation, owed typed value.

### 10.4 Agents and checks

~~~grammar
AgentStage     ::= "@" LowerName [AgentContract] Instruction
AgentContract  ::= "[" [AgentItemList] "]"
AgentItemList  ::= AgentItem ("," AgentItem)* [","]
AgentItem      ::= "R" "(" Text ")"
                 | "W" "(" Text ")"
                 | "X"
                 | "E"
                 | "retry" "(" UInt ")"
Instruction    ::= "{" Text "}"

CheckStage     ::= "$" LowerName CheckContract "{"
                     RunClause ExpectClause+
                   "}"
CheckContract  ::= "[" CheckItemList "]"
CheckItemList  ::= CheckItem ("," CheckItem)* [","]
CheckItem      ::= "R" "(" Text ")"
                 | "X"
                 | "timeout" "(" UInt ")"
                 | "cwd" "(" Text ")"
                 | "output" "(" UInt ")"

RunClause      ::= "run" "[" [CommandArgs] "]"
CommandArgs    ::= CommandArg ("," CommandArg)* [","]
CommandArg     ::= Text
                 | "value" "(" Ref ")"
                 | "json" "(" Ref ")"
                 | "artifact" "(" Ref ")"

ExpectClause   ::= "expect" "exit" ("==" | "!=") Int
                 | "expect" ("stdout" | "stderr")
                   ("==" | "!=" | "contains") Text
~~~

The check contract MUST contain X exactly once. R, timeout, cwd, and output may
each occur at most once, except that R may repeat for distinct patterns.
Defaults are timeout 300 seconds, cwd ".", and output 65,536 bytes per stream.

### 10.5 Pure construction

~~~grammar
ConstructorStage ::= TypeName "(" Assignments ")"
Assignments      ::= Assignment ("," Assignment)* [","]
Assignment       ::= LowerName "=" Ref
~~~

An empty record has no constructor in LOOP/1; use an explicit Unit-like named
record only in a future language version. Current records contain at least one
field.

### 10.6 Structured control

~~~grammar
ParOptions     ::= "[" "active" "<=" UInt "]"

EachStage      ::= "each" LowerName [WithClause] EachOptions "{"
                     FlowForm* "yield" Ref
                   "}"
WithClause     ::= "with" "(" RefList ")"
EachOptions    ::= "[" "par" "<=" UInt "," "empty" "=" EmptyMode "]"
EmptyMode      ::= ":ok" | ":error"

ChooseStage    ::= "choose" "{"
                     ChooseCase+ OtherwiseCase
                   "}"
ChooseCase     ::= "when" Predicate "{"
                     FlowForm* "yield" Ref
                   "}"
OtherwiseCase ::= "otherwise" "{"
                     FlowForm* "yield" Ref
                   "}"

LoopStage      ::= "loop" LowerName
                   "[" "<=" UInt "," "until" Predicate "]"
                   "{"
                     FlowForm* "yield" Ref
                   "}"
~~~

The LowerName in EachStage binds one list element. The LowerName in LoopStage
binds the current state. These bindings exist only inside their bodies.

### 10.7 Evolution

~~~grammar
EvolveStage    ::= "evolve" "current" "under" "root" Ref EvolveOptions "{"
                     Proposal
                     ComparisonRequest
                     Adoption
                   "}"

EvolveOptions  ::= "[" "<=" UInt "," "stale" "<=" UInt "]"

Proposal       ::= "current" "->" AgentStage
                   "->" "candidate" ":" ProgramType

ProgramType    ::= "Program" "(" Type "," Type ")"

ComparisonRequest
                ::= "current" "<=>" "candidate"
                    "->" "$judge" "(" Ref ")" JudgeOptions
                    "->" "proof" ":" "Comparison"

JudgeOptions   ::= "["
                    "cases" "=" UInt ","
                    "trials" "=" UInt ","
                    "par" "<=" UInt ","
                    "turns" "<=" UInt ","
                    "gain" ">=" UInt
                  "]"

Adoption       ::= "adopt" "candidate" "with" "proof"
                   "else" "keep" "current"
~~~

The judge suite reference MUST resolve to Suite(I, O) matching the candidate
and incumbent Program(I, O). The root reference MUST resolve to
Policy(Program(I, O)).

### 10.8 Predicates

Predicate precedence, from highest to lowest, is:

1. parentheses, references, and literals;
2. <code>not</code>;
3. one non-associative comparison;
4. <code>and</code>;
5. <code>or</code>.

~~~grammar
Predicate      ::= OrExpr
OrExpr         ::= AndExpr ("or" AndExpr)*
AndExpr        ::= NotExpr ("and" NotExpr)*
NotExpr        ::= ["not"] CompareExpr
CompareExpr    ::= Primary [CompareOp Primary]
CompareOp      ::= "==" | "!=" | "<" | "<=" | ">" | ">="
                 | "in" | "contains"

Primary        ::= Ref
                 | Int
                 | Text
                 | Tag
                 | "true"
                 | "false"
                 | "null"
                 | LiteralList
                 | "count" "(" Ref ")"
                 | "present" "(" Ref ")"
                 | "(" Predicate ")"

LiteralList    ::= "[" [Primary ("," Primary)* [","]] "]"
~~~

Comparisons are type checked:

- equality operands have exactly equal types, except an Optional may compare to
  null;
- ordering operands are the same Int type;
- <code>in</code> compares a scalar with a homogeneous literal list;
- <code>contains</code> compares Text with Text;
- <code>count</code> accepts List and returns its bounded nonnegative Int;
- <code>present</code> accepts Optional and returns Bool.

Boolean <code>and</code> and <code>or</code> short-circuit left to right.
Operational unknown state is not a predicate value and never enters this
algebra.

## 11. Static validation

Validation is whole-program, deterministic, and side-effect free. A compiler
MUST report all independent diagnostics it can establish safely, sorted by
source span then code.

### 11.1 Names and scope

- Parameters and top-level bindings MUST be unique.
- References MUST be defined before use, except references in Outcomes, which
  resolve against final top-level scope.
- Body-local bindings do not escape each, choose, or loop.
- Par branch terminal bindings escape at its barrier; other branch locals do
  not.
- Shadowing is forbidden, except the compiler-generated SSA generations of a
  loop current and evolve current.
- A role name does not create a value binding.

Invalid ambient capture:

~~~loop
items
-> each item [par<=2, empty=:ok] {
  (item, policy) -> @worker { "Use the policy." } -> out:Result
  yield out
}
-> results:List(Result, 8)
~~~

This is invalid unless policy appears in <code>with (policy)</code>.

### 11.2 Types and bounds

- Every input, output, field, binding, yield, and constructor MUST type check
  exactly.
- Text, List, and Int MUST have valid finite bounds.
- An each output MUST be List(U, n), where n equals the incoming list bound.
- Choose yields MUST have one exact type.
- Loop input and yield MUST be T; its output MUST be LoopResult(T).
- Evolve input MUST be Program(I, O); output MUST be
  EvolutionResult(Program(I, O)).
- A flow outcome value MUST equal the declared flow output type.
- Arithmetic and user-defined functions are unavailable.

Invalid widening:

~~~loop
items:List(Finding, 64)
# ...
-> results:List(Review, 128)
~~~

The only lane cardinality is the incoming bound 64.

### 11.3 Authority and effects

- Every R, W, and X request MUST be a subset of flow allow.
- Runtime policy MUST be able to enforce every requested grant or validation
  fails closed before execution.
- Path patterns MUST be normalized relative patterns without NUL, parent
  traversal, absolute roots, device names, or symlink escape.
- Concurrent W patterns MUST be provably disjoint.
- A check MUST NOT request W.
- Suite and root handles MUST not be under any W path or candidate-produced
  namespace.
- Evolution candidates MUST not widen authority.

Invalid hidden write:

~~~loop
allow [R("."), X] {
  issue
  -> @fixer[R("."), W("lib/**"), X] { "Fix it." }
  -> patch:Patch
}
~~~

W is outside the declared ceiling.

### 11.4 Structure and termination

- Par and each concurrency MUST be positive and within active.
- Each source MUST have a statically bounded List type.
- Loop bounds are 1..1000.
- Evolve bounds are positive and within generations; stale is positive and no
  greater than the generation bound.
- A choose and outcomes block MUST each end in exactly one otherwise.
- A comparison outside evolve is invalid in LOOP/1.
- Two separate incumbent and candidate checks are not a substitute for the
  atomic comparison.
- Recursion, dynamic node creation, and unbounded feedback are invalid.

Invalid implicit evaluation:

~~~loop
incumbent -> $evaluate[X] { run ["eval", artifact(incumbent)] expect exit == 0 }
-> old:CheckResult
candidate -> $evaluate[X] { run ["eval", artifact(candidate)] expect exit == 0 }
-> new:CheckResult
~~~

These checks may be useful diagnostics, but they cannot authorize adoption.
Only <code>&lt;=&gt; ... $judge</code> creates a Comparison.

### 11.5 Budget proof

The compiler computes:

- minimum provider turns;
- maximum provider turns;
- maximum simultaneously active operations;
- maximum evolution generations;
- a conservative routed-data byte bound;
- and, when tokenizer profiles are installed, conservative token bounds.

For an agent, maximum turns are <code>1 + retry</code>. For each, multiply by
the list bound. For par, sum turns but take peak active width. For loop,
multiply the body maximum by the iteration bound. For evolve, add proposer
turns and <code>2 × cases × trials × turns</code> per generation.

A declared turns or active bound smaller than the computed maximum is invalid.
Tokens are partly provider-dependent; if a hard static token maximum cannot be
proved, the compiler MUST emit a runtime reservation plan and demonstrate that
the declared cap can stop before starting the next obligation.

### 11.6 Counterexamples for safety invariants

The following are always invalid:

~~~loop
@worker { "Use {{secret}}." }                 # interpolation does not exist
$test[X] { run "mix test" expect exit == 0 } # run requires argv
@worker[retry(9)] { "..." }                  # retry exceeds five
loop current [until current.ok] { ... }      # missing finite bound
each item [par<=8] { ... }                   # missing empty behavior
adopt candidate                              # no exact proof
@maker { "Return a hidden suite." }
-> suite:Suite(Input, Output)                # agents cannot produce suites
~~~

Text resembling interpolation in the first example is literal text rather than
an interpolation expression; a linter SHOULD warn because the likely author
intent is unsupported.

### 11.7 Diagnostics

A diagnostic has this machine-readable shape:

~~~json
{
  "code": "A014",
  "severity": "error",
  "message": "W(\"lib/**\") exceeds the flow authority ceiling",
  "source": {
    "start_byte": 418,
    "end_byte": 429,
    "line": 18,
    "column": 27
  },
  "related": [
    {"message": "flow ceiling declared here", "start_byte": 300, "end_byte": 317}
  ],
  "help": "add W(\"lib/**\") to allow or remove the node write request"
}
~~~

Diagnostic code families are:

- L: lexical;
- P: parse;
- N: name and scope;
- T: type;
- A: authority and effect;
- C: concurrency and control;
- B: budget;
- E: evolution;
- O: outcome.

Compiler versions MAY add diagnostics but MUST NOT change the meaning of an
existing code within one language major version.
