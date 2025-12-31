---
name: querying-gemini
description: Invoke Google Gemini CLI for second opinions, research, and reasoning. Offers different perspective from both Claude and Codex for maximum diversity.
---

# Gemini Skill

Second opinions and research via Google's Gemini CLI.

## When to Use

- Third perspective when Codex and Claude disagree
- Research tasks that benefit from Gemini's training data
- Long-context analysis (Gemini excels at large context windows)
- Cross-validation for high-stakes decisions
- Alternative reasoning path for complex problems

**Don't use for**: Primary second opinions (prefer Codex for architecture diversity). Use Gemini as tertiary validator or for specific strengths.

## Why Gemini?

Gemini offers a third perspective distinct from both Claude and OpenAI:
1. **Different training corpus**: Google's data vs OpenAI/Anthropic
2. **Long context**: Gemini-2.5-pro handles very large inputs
3. **Research grounding**: Strong on factual/research tasks
4. **Model diversity**: Breaks consensus bias when Claude and Codex agree

## CLI Reference

```bash
gemini [OPTIONS] [QUERY..]
  -m, --model                  # gemini-2.5-pro, gemini-3-pro, etc.
  -s, --sandbox                # Run sandboxed
  -y, --yolo                   # Auto-accept all actions (AVOID)
  --approval-mode              # default, auto_edit, yolo
  -o, --output-format          # text, json, stream-json
  --include-directories        # Additional workspace dirs
```

## Safe Defaults

**ALWAYS use sandbox mode for second opinions:**

```bash
gemini -s "..."
```

| Mode | Use Case |
|------|----------|
| `-s` (sandbox) | Second opinions, analysis (DEFAULT) |
| `--approval-mode default` | If actions needed, require approval |
| `--approval-mode yolo` | NEVER for second opinions |

## Invocation Patterns

### Basic Second Opinion

```bash
gemini -s "You are providing a second opinion on a software problem.

Problem: <describe the issue>

Current analysis: <what we think>

Do you agree? What's your perspective?

---
End with:
---SUMMARY---
[Your final analysis in 2-3 sentences]
"
```

### Workflow Integration

Gemini has access to shell tools. **Instruct Gemini to use jwz and tissue directly**:

```bash
gemini -s -m gemini-2.5-pro "You are providing a second opinion on a software problem.

TOOLS AVAILABLE:
- jwz read 'issue:<id>' - Read prior discussion
- jwz search 'SECOND_OPINION: codex' - Find prior codex opinions
- jwz post 'issue:<id>' --role gemini -m '...' - Post your findings
- tissue list - See open issues
- tissue show <id> - Get issue details
- tissue new 'title' -t bug -p <priority> - Create issue if you find problems
- tissue comment <id> -m '...' - Add comments to issues

WORKFLOW:
1. First, read prior context: jwz read 'issue:<id>'
2. Check for prior codex opinions: jwz search 'SECOND_OPINION: codex'
3. Analyze the problem
4. Post your findings: jwz post 'issue:<id>' --role gemini -m '[gemini] ANALYSIS: ...'
5. If you find new issues, create them: tissue new '...'
6. If you disagree with codex, note this in your jwz post

Problem: <describe the issue>

Do your analysis, use the tools, then end with:
---SUMMARY---
[Your final analysis in 2-3 sentences]
"
```

**Gemini will**:
- Read prior discussion from jwz before analyzing
- Check for prior codex opinions and compare perspectives
- Post its findings directly to jwz with `--role gemini`
- Create tissue issues if it discovers problems
- Note disagreements with codex for consensus resolution

### Research Validation

```bash
gemini -s -m gemini-2.5-pro "You are validating research findings.

TOOLS: Use jwz and tissue for context and recording.
- jwz read 'issue:<id>' - Prior discussion
- jwz post 'issue:<id>' --role gemini -m '...' - Post findings
- tissue new 'title' -t research -p <priority> - Create issues for gaps
- tissue comment <id> -m '...' - Add to existing issues

Research claim: <the claim>

Sources cited:
1. <source 1>
2. <source 2>

WORKFLOW:
1. Read prior context from jwz
2. Validate the sources and claims
3. Post your validation to jwz
4. Create tissue issues for any gaps or corrections needed

---
End with:
---SUMMARY---
VALID/INVALID/PARTIAL
Key finding: [most important point]
Missing: [gaps if any]
"
```

### Long-Context Analysis

Gemini excels at analyzing large codebases or documents:

```bash
gemini -s -m gemini-2.5-pro --include-directories /path/to/code "
Analyze this codebase for:
1. Architectural patterns used
2. Potential issues
3. Improvement opportunities

Focus on <specific area>.

---
End with:
---SUMMARY---
Architecture: [pattern identified]
Top issue: [most important]
Recommendation: [action]
"
```

### Tie-Breaker Mode

When Codex and Claude disagree:

```bash
gemini -s -m gemini-2.5-pro "You are breaking a tie between two analyses.

TOOLS: Use jwz and tissue for context and recording.
- jwz read 'issue:<id>' - Read full discussion history
- jwz search 'SECOND_OPINION: codex' - Find codex's analysis
- jwz post 'issue:<id>' --role gemini -m '[gemini] TIE_BREAK: ...' - Post resolution
- tissue comment <id> -m '...' - Add decision rationale

Analysis A (Claude): <claude's view>

Analysis B (Codex): <codex's view>

They disagree on: <the disagreement>

WORKFLOW:
1. Read the full jwz history for context
2. Evaluate both analyses carefully
3. Post your tie-breaking decision to jwz with rationale
4. Add tissue comment explaining the resolution

---
End with:
---SUMMARY---
FAVOR: A/B/NEITHER
Confidence: HIGH/MEDIUM/LOW
Reasoning: [why]
"
```

### Design Tradeoff Analysis

```bash
gemini -s -m gemini-2.5-pro "You are analyzing design tradeoffs.

Context: <project context>

Option A: <first option>
- Pros: <list>
- Cons: <list>

Option B: <second option>
- Pros: <list>
- Cons: <list>

Which would you choose and why?

---
End with:
---SUMMARY---
RECOMMEND: A/B/NEITHER
Key factor: [deciding factor]
Risk: [main risk of choice]
"
```

### Fact-Checking

```bash
gemini -s "You are fact-checking technical claims.

Claims to verify:
1. <claim 1>
2. <claim 2>
3. <claim 3>

For each, provide:
- TRUE/FALSE/UNCERTAIN
- Correction if false
- Source if known

---
End with:
---SUMMARY---
Verified: [count]/[total]
Corrections needed: [list or 'none']
"
```

## Model Selection

| Model | Best For |
|-------|----------|
| `gemini-2.5-pro` | Long context, research, detailed analysis (RECOMMENDED DEFAULT) |
| `gemini-3-pro` | Latest capabilities, complex reasoning (when available) |

**Default to `gemini-2.5-pro`** for most tasks. Use `gemini-3-pro` for latest capabilities when available.

### Quality Controls

Gemini does not have equivalent reasoning effort controls like Codex's `-c reasoning=xhigh`. For critical reviews requiring maximum thoroughness, **prefer Codex with GPT 5.2**.

Use Gemini for:
- Tie-breaking between Claude and Codex
- Long-context analysis (>100k tokens)
- Research validation and fact-checking
- Third perspective when consensus is needed

## Output Parsing

All prompts request `---SUMMARY---` marker:

```bash
# Capture output
gemini -s "..." > /tmp/gemini-opinion.log 2>&1

# Extract summary
sed -n '/---SUMMARY---/,$ p' /tmp/gemini-opinion.log
```

For structured output:

```bash
gemini -s -o json "..." | jq '.response'
```

## Integration with Alice

Gemini is alice's tertiary source (after Codex):

```bash
# When primary (Codex) unavailable or need tie-breaker
if command -v gemini >/dev/null 2>&1; then
    gemini -s "..." > "$STATE_DIR/gemini-opinion.log" 2>&1
    sed -n '/---SUMMARY---/,$ p' "$STATE_DIR/gemini-opinion.log"
fi
```

### Multi-Model Consensus

For high-stakes decisions, alice can query multiple models:

```bash
# Query both and synthesize
codex exec -s read-only "..." > "$STATE_DIR/codex.log" 2>&1
gemini -s "..." > "$STATE_DIR/gemini.log" 2>&1

# Check agreement
CODEX_SUMMARY=$(sed -n '/---SUMMARY---/,$ p' "$STATE_DIR/codex.log")
GEMINI_SUMMARY=$(sed -n '/---SUMMARY---/,$ p' "$STATE_DIR/gemini.log")

# If they disagree, note in analysis
```

## Posting to jwz

Record Gemini opinions:

```bash
jwz post "issue:<id>" --role alice \
  -m "[alice] SECOND_OPINION: gemini on <topic>
Model: gemini-2.5-pro
Agreement: AGREE|DISAGREE|PARTIAL
Key insight: <summary>"
```

For multi-model consensus:

```bash
jwz post "issue:<id>" --role alice \
  -m "[alice] CONSENSUS: <topic>
Models: codex, gemini
Agreement: FULL|PARTIAL|SPLIT
Codex: <summary>
Gemini: <summary>
Synthesis: <reconciled view>"
```

## Error Handling

| Error | Cause | Action |
|-------|-------|--------|
| `command not found` | Gemini CLI not installed | Use Codex or claude -p |
| Rate limited | Too many requests | Back off, retry later |
| Context too large | Exceeds model limit | Chunk input or summarize |
| No summary marker | Model didn't follow format | Retry with explicit format instructions |

### Timeout Handling

```bash
# Set timeout to prevent hung invocations (recommended: 120s)
timeout 120 gemini -s -m gemini-2.5-pro "..." \
  > /tmp/gemini-opinion.log 2>&1 || echo "Timeout - retry or use codex"
```

### Malformed Output Detection

```bash
# Check for valid summary marker
if ! grep -q "^---SUMMARY---" /tmp/gemini-opinion.log; then
    echo "WARNING: No summary marker found - review full output"
    cat /tmp/gemini-opinion.log
fi
```

### Fallback Chain

```bash
if ! command -v gemini >/dev/null 2>&1; then
    # Fall back to codex or claude -p
    codex exec -s read-only "..." || claude -p "..."
fi
```

## Discovery

```bash
# Find prior Gemini opinions
jwz search "SECOND_OPINION: gemini"

# Find consensus analyses
jwz search "CONSENSUS:"

# Find by topic
jwz search "SECOND_OPINION:" | grep "<topic>"
```

## Composition with Other Skills

### With Researching Skill

Gemini can validate research alongside alice's review:

```
research ──→ alice (quality gate)
                   │
                   ▼
             gemini (fact-check) ──→ alice (synthesize)
```

### Priority Order for Second Opinions

1. **Codex** - Primary (architecture diversity from OpenAI)
2. **Gemini** - Secondary (tie-breaker, research validation)
3. **claude -p** - Fallback (fresh context, same architecture)

## Examples

### Compiler and Language Design

```bash
# Semantics verification
gemini -s -m gemini-2.5-pro "This formalization claims the effect system
is sound with respect to the operational semantics. The proof uses
logical relations. Verify the fundamental lemma holds."

# Tie-breaker on IR design
gemini -s "Codex recommends CPS for our compiler IR, Claude recommends
ANF. We need good optimization properties and debuggability.
Which is more appropriate for a research compiler?"
```

### Operating Systems and Distributed Systems

```bash
# Consistency model verification
gemini -s -m gemini-2.5-pro "Our distributed KV store claims causal
consistency. Review the vector clock implementation against
the formal definition. Are there edge cases with clock overflow?"

# Long-context kernel review
gemini -s -m gemini-2.5-pro --include-directories ./kernel/mm \
"Review this memory management subsystem for use-after-free
vulnerabilities. Focus on the interaction between the page
allocator and the slab cache."
```

### Research Collaboration

```bash
# Literature coverage check
gemini -s -m gemini-2.5-pro "We're writing a paper on probabilistic
programming inference. The related work section cites 15 papers.
What seminal works are missing? Check against POPL/PLDI/ICFP
proceedings from 2018-2024."

# Proof sketch validation
gemini -s -m gemini-2.5-pro "Our theorem claims that variational
inference converges for this model class. The proof uses
a novel Lyapunov argument. Is the construction sound?"
```

### Recording and Issue Tracking

```bash
# After significant review, record to jwz
jwz post "issue:effect-system-soundness" --role alice \
  -m "[alice] SECOND_OPINION: gemini on effect system proof
Model: gemini-2.5-pro
Agreement: PARTIAL
Key insight: Fundamental lemma holds but substitution lemma
needs strengthening for polymorphic effects"

# Create follow-up issues
tissue new "Strengthen substitution lemma for poly effects" -t bug -p 1
tissue dep add effect-substitution blocks effect-soundness

# Record consensus when models disagree
jwz post "issue:ir-design" --role alice \
  -m "[alice] CONSENSUS: CPS vs ANF for research compiler
Models: codex (gpt-5.2), gemini
Agreement: SPLIT
Codex: CPS for optimization properties
Gemini: ANF for debuggability
Synthesis: Use ANF with CPS conversion pass for optimization"
```
