# Headless Domovoy and pull request review

Domovoy runs noninteractively in the Dart VM, using the same production agent
runtime, provider adapters, compactor, Pi workspace tools, credential resolver,
JSONL sessions, chunker, vector repository and retrieval coordinator as the app.
No Flutter engine, display, external coding-agent process or nested package is
needed. Flutter tooling resolves the single root package, including its existing
native-asset build hooks. No new dependency is added by the CLI.

## Build and general execution

Use Flutter 3.41.4 / Dart 3.11.1 or compatible tooling. From the trusted checkout:

```sh
flutter pub get
dart run bin/domovoy.dart --help
dart build cli --target bin/domovoy.dart --output /tmp/domovoy-cli
/tmp/domovoy-cli/bundle/bin/domovoy --help
```

`dart build cli` is currently a Dart preview command. `dart compile exe` cannot
build this package because existing PDF dependencies have native-asset hooks.
Keep the complete generated bundle together; do not commit it. The executable
launches with DISPLAY/WAYLAND_DISPLAY unset and uses no Flutter UI.

Supply the existing `DEEPSEEK_API_KEY` through the process environment, without
putting its value in a command, prompt or file. Other providers use their normal
production manifest environment variable. The default is `deepseek-flash`; the
provider can reject unavailable explicit models, which is an execution failure.

```sh
/tmp/domovoy-cli/bundle/bin/domovoy exec --project /absolute/project \
  --prompt 'Explain the purpose and main components of this project.' --read-only
printf '%s\n' 'Inspect the selected project and explain its error handling.' | \
  /tmp/domovoy-cli/bundle/bin/domovoy exec --project /absolute/project --read-only
/tmp/domovoy-cli/bundle/bin/domovoy exec --project /absolute/project \
  --prompt-file /outside/project/task.txt --output-format jsonl \
  --output-last-message /outside/project/answer.md --state-dir /outside/project/state
```

`exec` permits real local read/write/edit/bash tasks unless `--read-only` is set.
Review always enables only read; its executor also independently rejects every
other operation, excluded path and path outside the selected root. General exec
uses the existing shell environment allowlist: API/GitHub tokens and the parent
environment are not forwarded to the tool subprocess. General shell tasks have
the user's normal OS access and should run only in an authorized local workspace.

`--provider ID --model ID` chooses a production provider/model. Curated startup
models need no asset file. Dynamic models require `--catalog-file` pointing at
the trusted checkout's `assets/models_fallback.json`; that loader and an external
state-directory catalog cache feed the production catalog refresh. `--reasoning enabled|disabled` controls the production generation setting
(default enabled; CI uses disabled to keep review latency bounded). The CLI
never fabricates capabilities for an unknown model. Keep that file outside the
model-visible snapshot when reviewing PR data.

`--rag-url http://127.0.0.1:8765` enables real project vector retrieval. Optional
`--rag-query TEXT` provides a focused retrieval question (up to 16000 UTF-8 bytes).
General exec indexes eligible source/docs in the selected workspace. State must
be outside that workspace; sessions use the existing JSONL format. A unique
external temporary state directory is used if none is supplied. Preserve it for
inspection, or remove it after the run. Concurrent processes must use distinct
state directories (the existing JSONL store has a single-writer contract).

JSONL output includes model identity, RAG progress and trace, tool calls/status,
terminal event and, only on success, a final `result` record. Text mode prints the
final answer. The last-message file is written only on success; use a fresh path
for each invocation. Exit status is 0 for success, 2 for configuration/input
errors, 1 for execution failure, and 130 for cancellation (SIGINT/SIGTERM or the
wall-clock timeout). Dynamic catalog loading/discovery observes the same
cancellation/deadline, aborts its pending HTTP requests and does not dispatch
further discovery after cancellation. Provider, network, tokenizer, embedding and index mismatch
errors fail the run; there is no successful fallback review. Default timeout is
1200 seconds, and production interactive limits are 10000 model turns/tool calls;
all are configurable. Resource limits are explicit, not silent truncation.

## Exact local review with real RAG

First start the [existing inference gateway](../tool/rag_model_service/README.md),
with its pinned Qwen3-Embedding-0.6B and tokenizer revisions. Review uses actual
1024D vectors and the existing M1 dense retrieval coordinator. CPU CI omits
optional BGE reranking; both tokenizers remain real and pinned for chunk limits. Preparation explicitly
loads only the embedding/reranker lock entries; runtime identities remain in the
lockfile. App loopback HTTP remains debug-only (profile/release deny by default);
the headless CLI explicitly opts in to its local gateway.
Do not start a competing service when a gateway is already available.

The deterministic Python helper reads Git objects without checking out or
executing PR files. It validates complete changed-file coverage, exports regular
UTF-8 source files into a fresh inert snapshot and loads project `AGENTS.md`
rules from the trusted base SHA. It uses a full three-dot diff (merge-base to
head), records both requested SHAs and the resolved merge-base, and expands
renames into delete/add paths. The generic versioned prompt contains no project
architecture rules or expected findings.

```sh
BASE=$(git rev-parse HEAD~1)
HEAD_SHA=$(git rev-parse HEAD)
python3 tool/headless/github_review.py bundle --checkout "$PWD" \
  --repo owner/repository --base "$BASE" --head "$HEAD_SHA" --out /tmp/pr-input-unique
/tmp/domovoy-cli/bundle/bin/domovoy review --project /tmp/pr-input-unique/sources \
  --review-context /tmp/pr-input-unique/review.json \
  --system-prompt-file "$PWD/prompts/review-v1.md" --rag-url http://127.0.0.1:8765 \
  --state-dir /tmp/pr-state-unique --output-format jsonl \
  --output-last-message /tmp/pr-review-unique.md > /tmp/pr-events-unique.jsonl
```

Use full 40-character SHAs. This is a local review of actual revisions; `bundle`
does not contact GitHub or publish. A review may report no verified defects.
The host appends a coverage receipt regardless of the model's wording.

The PR vector corpus includes all changed head text files, sibling code files,
current docs/doc/documentation files, READMEs and AGENTS files. Other eligible head
source files remain accessible through read. Every indexed source and retrieved
chunk, content revision, score and model fingerprint is in the JSONL trace.
Cache identities include repository/base/head, corpus content, tokenizer/model
fingerprint, dimension and chunk configuration. Changes invalidate the cache;
it is never reused as current context for another PR revision.

Limits: 512 KiB per source, 20 MiB total text snapshot, 400000 bytes complete
review context/prompt by default, and a 32000-byte selected retrieval context.
Retrieval is selected evidence; it is not a claim to have read every source file.
The collector explicitly lists excluded oversized/binary/nonregular related
sources. Unsupported changed files (including credential stores, binary files,
symlinks and submodules) or an oversized diff cause failure before review; no
changed path or hunk is silently dropped. Split such a PR for supported review.
The CLI permits a larger explicit input budget; the GitHub collector currently
fails above its fixed 400000-byte admission limit. No project tests/code run.

Source policy includes ordinary credential/secret implementation/docs and hidden
CI/config files such as `.github/workflows`, `.editorconfig` and `.gitignore`.
It excludes `.git`, known caches, `.ssh/.aws/.azure/.kube/.docker/.local`, dotenv
files, `.netrc/.npmrc/.pypirc/.git-credentials`, `.config/gh` and `.config/gcloud`,
explicit `credentials.{json,yaml,yml}`/`secrets.{json,yaml,yml}`,
`service-account.json`/`application_default_credentials.json`, day31 concrete
store names and nested store path components (case-insensitive), private-key
basenames, unrecognized binary extensions and generated lockfiles. This is a
concrete path policy, not a detector for secrets committed in arbitrary source.
The same policy protects RAG and review reads. Selected source/diff/PR content
remains untrusted data, even if it contains instructions or an AGENTS change.

## GitHub workflow and prerequisites

[The workflow](../.github/workflows/domovoy-review.yml) runs on PR opened,
synchronize, reopened and ready-for-review events. Initial support is for
**same-repository PRs by trusted repository writers**. The ordinary `pull_request`
event takes workflow YAML from the PR merge context: repository writers are
trusted to author that YAML. Checking out base code alone does not isolate YAML
from malicious repository writers. Fork PRs are explicitly skipped; stronger
untrusted-writer privilege isolation is a separate policy/deployment decision.
No `pull_request_target` or privileged fork execution is used. See GitHub's
[event documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request)
and [security guidance](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target).

The coordinator/repository owner must configure:

- Actions enabled and a base revision containing the reviewed CLI, prompt,
  dependency lock and workflow. No default-branch mutation is required for the
  candidate-branch demonstration described below.
- Repository secret `DEEPSEEK_API_KEY`, usable for real provider requests. Missing
  credentials produce an explicit SKIPPED summary, never a completed review.
- The automatic `GITHUB_TOKEN` with contents read, pull-requests read and issues
  write. The workflow pins actions by SHA and disables persisted Git credentials.
  Repository/organization policy must permit bot issue comments and these scopes.
- Ubuntu 24.04 x64 hosted runner, network access to Flutter releases, pub.dev,
  GitHub/Ollama release and weight downloads, Hugging Face pinned tokenizers and
  DeepSeek. Allow sufficient runner disk for Flutter, Python and embedding weights.
- Real gateway bootstrap and cache permissions. The workflow pins/checks the
  Ollama v0.18.2 archive SHA-256 and Qwen model digest, uses the existing pinned
  Python requirements/tokenizers, caches only weights/tokenizers, waits for health,
  and bounds the job to 45 minutes (agent to 30 minutes). No VPS or reranker
  runtime is required. Cold CPU setup/indexing can take several minutes.

A narrow execution receipt in the job log/summary reports the actual model,
embedding fingerprint, document/other-source counts, retrieved paths, tool-call
count, terminal success and exact base/head. It contains no credentials, raw
environment, reasoning or model-generated prose; missing/partial events are
reported honestly. Raw event files stay on the ephemeral runner.

The trusted base checkout uses full history. PR source is read as inert Git
objects; there is no PR checkout, build, dependency resolution, test, shell hook
or import with secrets. `gh` collects metadata/paginated files and compares them
with the exact local diff. Its isolated config directory is ephemeral and empty;
a GH_TOKEN/GITHUB_TOKEN environment credential is required for local gh commands.
Tokens are passed only to deterministic gh steps, never to the model, snapshot,
JSONL trace or tool shell. Provider credentials are present only for credential
availability and the model run. Model/tool access cannot read CI directories.

For local authenticated collection/publication, supply `GH_TOKEN` through a
secure environment (do not print it). Run:

```sh
python3 tool/headless/github_review.py collect --repo owner/repository --number 123 \
  --base "$BASE" --head "$HEAD_SHA" --checkout "$PWD" --out /tmp/pr-input-fresh
# Run the review command above against this new bundle, with fresh outputs.
python3 tool/headless/github_review.py publish --repo owner/repository --number 123 \
  --context /tmp/pr-input-fresh/review.json --result /tmp/pr-review-unique.md \
  --events /tmp/pr-events-unique.jsonl
```

The helper checks current base/head before/after collection and immediately
before publication, verifies the successful CLI result identity, then creates or
updates one `<!-- domovoy-review:v1 -->` comment owned by `github-actions[bot]`.
Human comments with that marker are ignored. Local publication should use the
same Actions bot identity; PAT-authored comments are not eligible for bot upsert.
PR concurrency cancels older runs. A post-write head check withdraws the review
as obsolete if the PR changes during publication. GitHub offers no atomic
comment-write/PR-head comparison, so there is a small detected/withdrawn race;
every posted result also visibly names its exact base/head. It is never silently
relabelled as a review of a newer commit.

For acceptance, the coordinator pushes the verified candidate branch, targets a
small demonstration PR at that branch (the trusted base already contains this
CLI), and verifies actual opened/synchronize events, a real RAG/LLM run, a bot
comment at the current head, then the same comment ID updated after a new commit.
Use a domain-logic change with truthful file/line evidence; no specific expected
finding is encoded here. Close the demonstration without merging intentional
errors. Reviews, remote configuration/pushes, Actions evidence and final merge
remain coordinator-owned; local tests or simulated gh responses do not satisfy
that live gate.

## Verification

```sh
flutter pub get
dart format .
flutter analyze
flutter test
python3 -m unittest discover -s test/infrastructure/headless -p '*_test.py'
dart run bin/domovoy.dart --help
dart build cli --target bin/domovoy.dart --output /tmp/domovoy-cli-check
```

On hosts with unsolicited probes of Flutter test harness ports, isolate only
hermetic tests using a private loopback namespace (run pub get beforehand):

```sh
unshare --user --map-root-user --net sh -c 'ip link set lo up && exec /home/kotdath/flutter/bin/flutter test --no-pub --ipv6 --concurrency=4'
```

Real provider/gateway smoke runs must stay outside that namespace. Tests use
explicit fakes for provider responses/embeddings and are separate from live
evidence. Test coverage includes the production tool loop and JSONL persistence,
read-only host enforcement, cancellation/failure, RAG code/docs and cache identity,
malformed metadata, exact Git diff/rename/base-rule coverage, source exclusions,
result receipts, stale-run withdrawal and idempotent bot-comment updates.
