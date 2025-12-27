#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "rank-bm25>=0.2.2",
# ]
# ///
"""
BM25 search over trivial agent artifacts.

Usage:
    ./scripts/search.py "query terms here"
    ./scripts/search.py --top 5 "query"
    ./scripts/search.py --agent librarian "query"
"""

import argparse
import re
import sys
from pathlib import Path

from rank_bm25 import BM25Okapi


def tokenize(text: str) -> list[str]:
    """Simple tokenizer: lowercase, split on non-alphanumeric."""
    return re.findall(r'\w+', text.lower())


def extract_metadata(content: str) -> dict[str, str]:
    """Extract YAML frontmatter metadata."""
    metadata = {}
    if content.startswith('---'):
        parts = content.split('---', 2)
        if len(parts) >= 3:
            for line in parts[1].strip().split('\n'):
                if ':' in line:
                    key, value = line.split(':', 1)
                    metadata[key.strip()] = value.strip()
    return metadata


def get_snippet(content: str, query_tokens: list[str], context: int = 100) -> str:
    """Extract a relevant snippet containing query terms."""
    content_lower = content.lower()

    # Find first occurrence of any query term
    best_pos = len(content)
    for token in query_tokens:
        pos = content_lower.find(token)
        if pos != -1 and pos < best_pos:
            best_pos = pos

    if best_pos == len(content):
        # No match found, return beginning
        return content[:context * 2].strip() + "..."

    # Extract context around match
    start = max(0, best_pos - context)
    end = min(len(content), best_pos + context)

    snippet = content[start:end].strip()
    if start > 0:
        snippet = "..." + snippet
    if end < len(content):
        snippet = snippet + "..."

    return snippet


def load_documents(base_path: Path, agent_filter: str | None = None) -> list[dict]:
    """Load all markdown documents from artifact directories."""
    documents = []

    # Agent subdirectories
    agent_dirs = ['librarian', 'reviewer', 'oracle']

    for agent in agent_dirs:
        if agent_filter and agent != agent_filter:
            continue

        agent_path = base_path / agent
        if not agent_path.exists():
            continue

        for md_file in agent_path.glob('*.md'):
            content = md_file.read_text()
            metadata = extract_metadata(content)

            documents.append({
                'path': md_file,
                'agent': agent,
                'content': content,
                'metadata': metadata,
                'tokens': tokenize(content),
            })

    return documents


def search(query: str, documents: list[dict], top_k: int = 10) -> list[tuple[dict, float]]:
    """Perform BM25 search over documents."""
    if not documents:
        return []

    # Build corpus
    corpus = [doc['tokens'] for doc in documents]
    bm25 = BM25Okapi(corpus)

    # Search
    query_tokens = tokenize(query)
    scores = bm25.get_scores(query_tokens)

    # Rank results
    ranked = sorted(zip(documents, scores), key=lambda x: x[1], reverse=True)

    # Take top results (BM25 can return negative scores with small corpora)
    results = [(doc, score) for doc, score in ranked[:top_k]]

    return results


def main():
    parser = argparse.ArgumentParser(description='BM25 search over trivial agent artifacts')
    parser.add_argument('query', help='Search query')
    parser.add_argument('--top', '-n', type=int, default=10, help='Number of results (default: 10)')
    parser.add_argument('--agent', '-a', choices=['librarian', 'reviewer', 'oracle'],
                        help='Filter to specific agent')
    parser.add_argument('--path', '-p', type=Path, default=Path('.claude/plugins/trivial'),
                        help='Path to artifacts directory')
    args = parser.parse_args()

    # Load documents
    documents = load_documents(args.path, args.agent)

    if not documents:
        print(f"No documents found in {args.path}", file=sys.stderr)
        sys.exit(1)

    # Search
    results = search(args.query, documents, args.top)

    if not results:
        print("No matching documents found.")
        sys.exit(0)

    # Output results
    query_tokens = tokenize(args.query)

    print(f"Found {len(results)} result(s) for: {args.query}\n")

    for i, (doc, score) in enumerate(results, 1):
        rel_path = doc['path'].relative_to(Path.cwd()) if doc['path'].is_relative_to(Path.cwd()) else doc['path']

        print(f"## {i}. {rel_path}")
        print(f"**Agent**: {doc['agent']} | **Score**: {score:.2f}")

        # Show metadata if present
        if doc['metadata']:
            meta_str = ' | '.join(f"{k}: {v}" for k, v in doc['metadata'].items() if k != 'agent')
            if meta_str:
                print(f"**Metadata**: {meta_str}")

        # Show snippet
        snippet = get_snippet(doc['content'], query_tokens)
        # Clean up snippet for display
        snippet = ' '.join(snippet.split())
        print(f"\n> {snippet}\n")


if __name__ == '__main__':
    main()
