---
name: querying-codex
description: Invoke OpenAI Codex CLI for second opinions, code review, and reasoning from a different architecture. Prioritized by alice for maximum model diversity.
---

# Codex Skill

Second opinions and specialized reasoning via OpenAI's Codex CLI.

## When to Use

- Getting a second opinion from a different model architecture (OpenAI vs Anthropic)
- Code review from an independent perspective
- Complex reasoning that benefits from o3/o4-mini's chain-of-thought
- Cross-validating alice's hypotheses
- Research validation

**Don't use for**: Simple questions that don't need a second perspective. Just ask directly.

## Why Codex?

Alice prioritizes Codex over other second-opinion sources because:
1. **Architecture diversity**: Different training, different blind spots
2. **Reasoning models**: o3/o4-mini excel at step-by-step reasoning
3. **Read-only safe**: Sandbox modes prevent unintended modifications

## CLI Reference

```bash
codex exec [OPTIONS] [PROMPT]
  -m, --model <MODEL>          # gpt-5.2, o3, o4-mini
  -s, --sandbox <MODE>         # read-only, workspace-write, danger-full-access
  -c, --config <KEY=VALUE>     # Config options (e.g., reasoning=xhigh)
  --full-auto                  # Low-friction sandboxed execution
  -o, --output-last-message    # Write last message to file
  --json                       # Output as JSONL
  -C, --cd <DIR>               # Working directory
  --search                     # Enable web search
```

## Safe Defaults

**ALWAYS use read-only sandbox unless explicitly required:**

```bash
codex exec -s read-only "..."
```

| Sandbox Mode | Use Case |
|--------------|----------|
| `read-only` | Second opinions, analysis, review (DEFAULT) |
| `workspace-write` | NEVER for alice (she is read-only) |
| `danger-full-access` | NEVER for second opinions |

## Invocation Patterns

### Basic Second Opinion

```bash
codex exec -s read-only -m gpt-5.2 -c reasoning=xhigh "You are reviewing a software project.

Problem: <describe the issue>

Current hypothesis: <what you think>

Do you agree? What would you add or change?

---
End with:
---SUMMARY---
[Your final analysis in 2-3 sentences]
"
```

### Workflow Integration

Codex has access to shell tools. **Instruct Codex to use jwz and tissue directly**:

```bash
codex exec -s read-only -m gpt-5.2 -c reasoning=xhigh "You are reviewing a software project.

TOOLS AVAILABLE:
- jwz read 'issue:<id>' - Read prior discussion
- jwz post 'issue:<id>' --role codex -m '...' - Post your findings
- tissue list - See open issues
- tissue show <id> - Get issue details
- tissue new 'title' -t bug -p <priority> - Create issue if you find problems
- tissue comment <id> -m '...' - Add comments to issues

WORKFLOW:
1. First, read prior context: jwz read 'issue:<id>'
2. Analyze the problem
3. Post your findings: jwz post 'issue:<id>' --role codex -m '[codex] ANALYSIS: ...'
4. If you find new issues, create them: tissue new '...'

Problem: <describe the issue>

Do your analysis, use the tools, then end with:
---SUMMARY---
[Your final analysis in 2-3 sentences]
"
```

**Codex will**:
- Read prior discussion from jwz before analyzing
- Post its findings directly to jwz with `--role codex`
- Create tissue issues if it discovers problems
- Add comments to existing issues with relevant findings

### Architecture Review

```bash
codex exec -s read-only -m gpt-5.2 -c reasoning=xhigh "You are reviewing a system architecture.

TOOLS: Use jwz and tissue for context and recording.
- jwz read 'issue:<id>' - Prior discussion
- jwz post 'issue:<id>' --role codex -m '...' - Post findings
- tissue new 'title' -t <tag> -p <priority> - Create issues
- tissue comment <id> -m '...' - Add to existing issues

System: <describe architecture>

Proposed design: <the design>

Concerns:
1. <concern 1>
2. <concern 2>

WORKFLOW:
1. Read prior context from jwz
2. Evaluate the concerns
3. Post your analysis to jwz
4. Create tissue issues for any problems found

---
End with:
---SUMMARY---
AGREE/DISAGREE with concerns
Key insight: [most important point]
Recommendation: [action to take]
"
```

### Code Review

```bash
codex exec -s read-only "You are reviewing code for correctness and style.

File: <path>
Language: <language>

\`\`\`<language>
<code snippet>
\`\`\`

Review for:
- Correctness bugs
- Edge cases
- Performance issues
- Style problems

---
End with:
---SUMMARY---
Issues found: [count]
Severity: HIGH/MEDIUM/LOW
Key issue: [most important]
"
```

### Research Validation

```bash
codex exec -s read-only --search "You are validating research findings.

Claim: <the claim to validate>

Sources cited: <list sources>

Questions:
1. Are these sources credible?
2. Do they support the claim?
3. What's missing?

---
End with:
---SUMMARY---
VALID/INVALID/PARTIAL
Confidence: HIGH/MEDIUM/LOW
Key gap: [if any]
"
```

### Debug Hypothesis Testing

```bash
codex exec -s read-only -m o4-mini "You are debugging a software issue.

Symptoms: <what's happening>

Hypotheses (ranked by probability):
1. (60%) <hypothesis 1> - Evidence: <X>
2. (25%) <hypothesis 2> - Evidence: <Y>
3. (10%) <hypothesis 3> - Evidence: <Z>

Do you agree with the ranking? What would you add?

---
End with:
---SUMMARY---
Top hypothesis: [which one]
Missing consideration: [what we might have missed]
"
```

## Model Selection

| Model | Best For |
|-------|----------|
| `gpt-5.2` | Extreme thoroughness, exhaustive review, high-stakes decisions |
| `o3` | Complex reasoning, architecture decisions, multi-step analysis |
| `o4-mini` | Quick second opinions, code review, debugging |

**Default to `gpt-5.2`** for tasks requiring careful, exhaustive review. Use `o4-mini` only for quick, low-stakes opinions.

### Reasoning Effort

For GPT 5.2, use the `reasoning` config to control thoroughness:

```bash
# Maximum thoroughness (recommended for critical reviews)
codex exec -s read-only -m gpt-5.2 -c reasoning=xhigh "..."

# High thoroughness
codex exec -s read-only -m gpt-5.2 -c reasoning=high "..."

# Standard
codex exec -s read-only -m gpt-5.2 "..."
```

| Reasoning Level | Use Case |
|-----------------|----------|
| `xhigh` | Security review, architecture decisions, correctness proofs |
| `high` | Code review, design tradeoffs, debugging complex issues |
| (default) | General second opinions |

## Output Parsing

All prompts request `---SUMMARY---` marker for reliable extraction:

```bash
# Capture full output
codex exec -s read-only "..." > /tmp/codex-opinion.log 2>&1

# Extract summary
sed -n '/---SUMMARY---/,$ p' /tmp/codex-opinion.log
```

For structured parsing, use `--json`:

```bash
codex exec -s read-only --json "..." | jq '.content'
```

## Integration with Alice

Alice uses Codex as her primary second opinion source:

```bash
# In alice's workflow:
STATE_DIR="/tmp/idle-alice-$$"
mkdir -p "$STATE_DIR"

if command -v codex >/dev/null 2>&1; then
    codex exec -s read-only "..." > "$STATE_DIR/opinion.log" 2>&1
    sed -n '/---SUMMARY---/,$ p' "$STATE_DIR/opinion.log"
fi

rm -rf "$STATE_DIR"
```

Alice incorporates the summary into her analysis under "Second Opinion" section.

## Posting to jwz

Record second opinions for discovery:

```bash
jwz post "issue:<id>" --role alice \
  -m "[alice] SECOND_OPINION: codex on <topic>
Model: o4-mini
Agreement: AGREE|DISAGREE|PARTIAL
Key insight: <summary>"
```

## Error Handling

| Error | Cause | Action |
|-------|-------|--------|
| `command not found` | Codex CLI not installed | Fall back to `gemini` or `claude -p` |
| Timeout | Model taking too long | Retry with `o4-mini` or reduce prompt |
| Empty response | Prompt too vague | Restructure with clearer question |
| No summary marker | Model didn't follow format | Retry with explicit format instructions |

### Timeout Handling

```bash
# Set timeout to prevent hung invocations (recommended: 180s for xhigh reasoning)
timeout 180 codex exec -s read-only -m gpt-5.2 -c reasoning=xhigh "..." \
  > /tmp/codex-opinion.log 2>&1 || echo "Timeout - retry with o4-mini"
```

### Malformed Output Detection

```bash
# Check for valid summary marker
if ! grep -q "^---SUMMARY---" /tmp/codex-opinion.log; then
    echo "WARNING: No summary marker found - review full output"
    cat /tmp/codex-opinion.log
fi
```

### Fallback Chain

```bash
if ! command -v codex >/dev/null 2>&1; then
    # Fall back to gemini or claude -p
    gemini -s "..." || claude -p "..."
fi
```

## Discovery

```bash
# Find prior Codex opinions
jwz search "SECOND_OPINION: codex"

# Find by topic
jwz search "SECOND_OPINION:" | grep "<topic>"
```

## Examples

### Compiler Design

```bash
# Type system soundness review
codex exec -s read-only -m gpt-5.2 -c reasoning=xhigh "Review this bidirectional
type inference algorithm for soundness. Does the subsumption rule preserve
principal types? Are there cases where inference diverges?"

# IR optimization pass review
codex exec -s read-only -m gpt-5.2 -c reasoning=xhigh "This SSA-based dead code
elimination pass claims to be sound for programs with exceptions.
Verify: does it correctly handle exceptional control flow edges?"
```

### Operating Systems

```bash
# Memory subsystem review
codex exec -s read-only -m gpt-5.2 -c reasoning=xhigh "Review this slab allocator
implementation for the kernel. Concerns: fragmentation under adversarial
workloads, cache coloring correctness, NUMA-awareness. Be exhaustive."

# Concurrency primitive verification
codex exec -s read-only -m gpt-5.2 -c reasoning=xhigh "This lock-free queue uses
acquire-release semantics. Verify memory ordering correctness.
Are there ABA problems? Missing fences?"
```

### Research Collaboration

```bash
# Paper contribution review
codex exec -s read-only -m gpt-5.2 -c reasoning=xhigh "We claim our probabilistic
programming system achieves asymptotically optimal inference for conjugate models.
Review the proof sketch. Are the assumptions realistic? Missing cases?"

# Experimental methodology
codex exec -s read-only -m gpt-5.2 -c reasoning=xhigh "This benchmark shows 3x
speedup vs baseline. Review methodology: are we comparing fairly?
What confounds might explain the difference?"
```

### Recording Findings

```bash
# After any significant review, record to jwz
jwz post "issue:compiler-type-inference" --role alice \
  -m "[alice] SECOND_OPINION: codex on type inference soundness
Model: gpt-5.2 (reasoning=xhigh)
Agreement: PARTIAL
Key insight: Subsumption rule is sound but inference may not terminate
for rank-2 types without proper occurs check"

# Create follow-up issue if needed
tissue new "Add occurs check to type inference" -t bug -p 1
```
