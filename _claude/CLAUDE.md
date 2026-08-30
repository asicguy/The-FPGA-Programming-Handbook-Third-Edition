# Engineering Instructions

Instructions in this file are binding. If a request conflicts with a rule here,
say so and ask before proceeding.

## Test-Driven Development

TDD is the default for all behavior changes. The cycle is red → green → refactor.

1. **Red.** Write a failing test first. Run it. Confirm it fails for the reason
   you expect. A test that passes before the implementation exists is not a test.
2. **Green.** Write the minimum code that makes the test pass. Resist adding
   unasked-for generality.
3. **Refactor.** Clean up with the suite green. No behavior changes in this step.

Rules:

- Never write implementation code before a failing test exists for it.
- Never modify a test to make failing code pass. If the test is wrong, say so
  explicitly and explain why before changing it.
- One logical assertion per test. Test names describe behavior, not methods:
  `rejects_expired_token`, not `test_validate`.
- Cover the boundary and error paths, not just the happy path.
- Do not mock what you own. Mock at process boundaries: network, clock,
  filesystem, randomness.
- If a change is genuinely untestable (pure config, generated code, formatting),
  say which exemption applies rather than silently skipping tests.
- Every new feature, logic change, or bug fix must be accompanied by unit tests.
- Aim for near 100% coverage on core logic.
- Always run tests uncached.

## Development Flow

For any non-trivial task, follow this sequence and do not skip ahead:

1. **Understand.** Read the relevant code before proposing changes. Cite the
   files and functions involved.
2. **Plan.** State the approach, the files you will touch, and the tests you
   will write. For anything beyond a one-file change, get confirmation on the
   plan before writing code.
3. **Test.** Write the failing test.
4. **Implement.** Make it pass.
5. **Verify.** Run the full check suite (below). Paste real output — never claim
   a command passed without running it.
6. **Review.** Re-read your own diff before presenting it. Remove debug output,
   commented-out code, and stray TODOs.

Stop and ask when: requirements are ambiguous, the fix requires a schema or API
contract change, the change touches auth/permissions/billing, or the blast
radius is larger than the plan predicted.

## Build Hygiene

Before any work is presented as complete, all of these must pass locally:

1. Use verilator or Vivado xsim to lint designs.
2. Simulation can be done using Verilator, Vivado, Icarus verilog or GHDL for VHDL.
3. Use Vivado for building designs. Use the version defined in the project CLAUDE.md.

- Zero new warnings. Warnings are errors that haven't happened yet.
- Never disable a lint rule, add `# type: ignore`, `any`, `@ts-expect-error`, or
  skip a test to get green. If a suppression is truly correct, it needs an
  inline comment explaining why and it must be raised in the summary.
- Never commit with a failing or skipped test.
- No new dependency without asking first. Justify it against the standard
  library and existing deps.
- Leave the codebase's existing style alone. Match surrounding conventions over
  personal preference.

## Change Scope

- Change only what the task requires. Unrelated improvements go in the summary
  as suggestions, not in the diff.
- No opportunistic refactoring, renaming, reformatting, or reorganizing of files
  you happen to be passing through.
- No speculative abstraction. Build for the case in front of you.
- Do not delete or rewrite code you don't understand. Ask what it's for.
- Prefer the smallest diff that fully solves the problem. A large diff needs a
  justification in the summary.
- Never touch generated files, lockfiles, CI config, or migrations as a side
  effect. Those are deliberate, standalone changes.
- No drive by fixes. If you identify an unrelated bug or typo flag it for later correction in a new pass.

## Multi-Agent Coordination

When work is split across subagents or parallel sessions:

- **One owner per file.** Two agents must never hold the same file open for
  writing. Partition by module or layer, not by task phase.
- **Contracts first.** Interfaces, type signatures, and schemas are agreed and
  committed before parallel work starts. Everyone codes against the contract.
- **Delegate with a full brief.** A subagent gets: the goal, the files it owns,
  the files it must not touch, the acceptance test, and the return format.
  Subagents do not inherit conversation context — assume they know nothing.
- **Return findings, not narration.** Subagent output is a summary of what
  changed, what was learned, and what is still open.
- **Verify before merging.** The parent runs the full check suite after
  integrating subagent work. Never trust a subagent's claim that tests pass.
- **Serialize the risky parts.** Migrations, dependency changes, and shared
  config are done by one agent, alone, in a dedicated step.
- Read-heavy work (search, audit, investigation) parallelizes well.
  Write-heavy work usually doesn't.

## Execution Discipline

- Do what was asked. Nothing more, nothing less.
- Verify, don't assume. Read the file before editing it. Run the command before
  reporting its result.
- Never fabricate: no invented file paths, API names, config keys, test results,
  or benchmark numbers. "I don't know" and "let me check" are correct answers.
- Report failure immediately and plainly. Do not work around a blocker in a way
  that hides it.
- If you try the same fix twice and it fails twice, stop and explain the
  situation instead of trying a third variation.
- No unrequested files. No README, no summary doc, no example script unless
  asked for.
- Summaries state what changed and what still needs attention. No victory laps.

## Commit Messages

Conventional Commits. Imperative mood. Subject line ≤ 72 characters, no
trailing period.

```
<type>(<scope>): <subject>

<body: why this change, not what the diff shows>

<footer: Refs #123 / BREAKING CHANGE: ...>
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `perf`, `build`, `ci`, `chore`.

- The body explains motivation and the alternatives rejected. The diff already
  shows what changed.
- Breaking changes require a `BREAKING CHANGE:` footer describing the migration.
- One logical change per commit. Never mix a refactor with a behavior change.
- If a commit needs "and" in the subject line, it should be two commits.
- Do not commit unless asked. Never push, force-push, amend published history,
  or open a PR without explicit instruction.

## Project Context

<!-- Fill this in per repo. Delete if this is your user-level file. -->

- **Stack:**
- **Entry points:**
- **Architecture notes:**
- **Known sharp edges:**

## Phase Records

Approved Phase Plans are copied to `docs/phase-<N>-plan.md` as the durable
in-repo record of the plan summarized in each Phase's opening empty commit.