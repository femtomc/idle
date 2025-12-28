# Intervention Interaction Model

## Overview

This document specifies the protocol for predictable control messages between the Terminal UI (TUI) and the idle Plugin. It replaces ad-hoc prompting with a formal, schema-based messaging system to handle user interventions during agent loops.

## Motivation

Currently, agent interactions often rely on parsing unstructured text output or checking for file existence. This fragility makes it difficult to build robust user interfaces that can reliably control the agent.

We need a strict, predictable messaging protocol to ensure that:

1. **Interventions are deterministic:** When a user clicks "Pause", the agent reliably pauses.
2. **State is unambiguous:** The UI always knows if the agent is running, paused, or finished.
3. **Race conditions are handled gracefully:** Asynchronous user actions are managed alongside agent execution.

## Relationship to Standard Events

The protocol separates **Intervention** (user requesting change) from **Observation** (agent reporting status) using two different topics and schemas.

| Aspect | Intervention Protocol | State Events |
|--------|----------------------|--------------|
| **Schema** | 0 | 1 |
| **Topic** | `loop:control` | `loop:current` |
| **Purpose** | Commands to the agent | Agent state updates |
| **Pattern** | Request-Response | Fire-and-forget |
| **Message Types** | REQUEST, ACK, RESULT | STATE, ABORT, DONE |

**Important:** A single intervention (e.g., cancel) may result in messages on BOTH topics: a RESULT on `loop:control` confirming the command, and an ABORT on `loop:current` reflecting the state change.

## Message Types

The protocol defines three message types:

| Type | Direction | Description |
|------|-----------|-------------|
| **REQUEST** | Controller -> Plugin | Initiates a command |
| **ACK** | Plugin -> Controller | Immediate acknowledgment of receipt (before execution) |
| **RESULT** | Plugin -> Controller | Final outcome of command execution |

## Commands

| Command | Description | Effect |
|---------|-------------|--------|
| **pause** | Pause current loop | Next iteration waits for resume |
| **resume** | Resume paused loop | Continues execution |
| **cancel** | Cancel loop entirely | Emits ABORT event on `loop:current` |
| **escalate** | Escalate to opus model | Switches implementor to more capable model |

## Message Schema

All messages on `loop:control` use schema version 0.

```json
{
  "schema": 0,
  "type": "REQUEST",
  "request_id": "550e8400-e29b-41d4-a716-446655440000",
  "command": "pause",
  "target": {
    "run_id": "loop-1703123456-12345",
    "issue_id": "auth-123"
  },
  "timestamp": "2024-12-28T10:00:00Z",
  "payload": {}
}
```

### Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema` | integer | Yes | Must be `0` for control messages |
| `type` | string | Yes | One of: `REQUEST`, `ACK`, `RESULT` |
| `request_id` | string | Yes | UUID v4. Correlates ACK/RESULT to original REQUEST |
| `command` | string | Yes | One of: `pause`, `resume`, `cancel`, `escalate` |
| `target` | object | Yes | Identifies the target loop |
| `target.run_id` | string | Yes | Unique ID of the loop run |
| `target.issue_id` | string | No | Issue ID if applicable |
| `timestamp` | string | Yes | ISO 8601 UTC timestamp |
| `payload` | object | Yes | Command-specific data (can be empty `{}`) |

### Payload by Command

| Command | Payload Fields |
|---------|---------------|
| `pause` | `{}` (empty) |
| `resume` | `{}` (empty) |
| `cancel` | `{}` (empty) |
| `escalate` | `{"model": "opus", "reason": "..."}` |

### RESULT Payload

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | `success` or `failure` |
| `code` | string | Error code (only if failure) |
| `message` | string | Human-readable details |

## Topic

All intervention messages are published to and consumed from:

```
loop:control
```

## Timeout and Retry Semantics

| Rule | Value | Description |
|------|-------|-------------|
| **Request Expiry** | 30 seconds | REQUEST expires if no ACK received |
| **Idempotent Retry** | Same request_id | Controller may retry with same request_id |
| **Deduplication Window** | 5 minutes | Plugin ignores duplicate request_ids within window |

### Retry Behavior

1. Controller sends REQUEST with `request_id: "abc123"`
2. No ACK received within 30 seconds
3. Controller retries with same `request_id: "abc123"`
4. Plugin either:
   - Processes if first time seeing this request_id
   - Returns cached RESULT if already processed
   - Returns `duplicate` error if in-flight

## Example Flows

### Flow A: Pause/Resume Issue

User pauses execution to fix something manually, then resumes.

**1. Controller sends REQUEST (pause)**
```json
{
  "schema": 0,
  "type": "REQUEST",
  "request_id": "req-pause-001",
  "command": "pause",
  "target": {"run_id": "loop-1703123456-12345", "issue_id": "auth-123"},
  "timestamp": "2024-12-28T10:00:00Z",
  "payload": {}
}
```

**2. Plugin sends ACK**
```json
{
  "schema": 0,
  "type": "ACK",
  "request_id": "req-pause-001",
  "command": "pause",
  "target": {"run_id": "loop-1703123456-12345", "issue_id": "auth-123"},
  "timestamp": "2024-12-28T10:00:01Z",
  "payload": {}
}
```

**3. Plugin sends RESULT**
```json
{
  "schema": 0,
  "type": "RESULT",
  "request_id": "req-pause-001",
  "command": "pause",
  "target": {"run_id": "loop-1703123456-12345", "issue_id": "auth-123"},
  "timestamp": "2024-12-28T10:00:02Z",
  "payload": {"status": "success", "message": "Loop paused at iteration 4"}
}
```

*User performs manual edits...*

**4. Controller sends REQUEST (resume)**
```json
{
  "schema": 0,
  "type": "REQUEST",
  "request_id": "req-resume-001",
  "command": "resume",
  "target": {"run_id": "loop-1703123456-12345", "issue_id": "auth-123"},
  "timestamp": "2024-12-28T10:05:00Z",
  "payload": {}
}
```

**5. Plugin sends ACK and RESULT** (similar structure)

### Flow B: Cancel Grind

User decides to stop a long-running grind session.

**1. Controller sends REQUEST (cancel)**
```json
{
  "schema": 0,
  "type": "REQUEST",
  "request_id": "req-cancel-001",
  "command": "cancel",
  "target": {"run_id": "grind-1703123456-99999"},
  "timestamp": "2024-12-28T11:00:00Z",
  "payload": {}
}
```

**2. Plugin sends ACK**
```json
{
  "schema": 0,
  "type": "ACK",
  "request_id": "req-cancel-001",
  "command": "cancel",
  "target": {"run_id": "grind-1703123456-99999"},
  "timestamp": "2024-12-28T11:00:01Z",
  "payload": {}
}
```

**3. Plugin sends RESULT**
```json
{
  "schema": 0,
  "type": "RESULT",
  "request_id": "req-cancel-001",
  "command": "cancel",
  "target": {"run_id": "grind-1703123456-99999"},
  "timestamp": "2024-12-28T11:00:02Z",
  "payload": {"status": "success"}
}
```

**4. Plugin emits ABORT event on loop:current**
```json
{
  "schema": 1,
  "event": "ABORT",
  "reason": "USER_CANCELLED",
  "run_id": "grind-1703123456-99999",
  "stack": []
}
```

### Flow C: Escalate to Opus

User notices the Haiku agent is stuck and upgrades to Opus.

**1. Controller sends REQUEST (escalate)**
```json
{
  "schema": 0,
  "type": "REQUEST",
  "request_id": "req-escalate-001",
  "command": "escalate",
  "target": {"run_id": "loop-1703123456-12345", "issue_id": "complex-refactor"},
  "timestamp": "2024-12-28T12:00:00Z",
  "payload": {
    "model": "opus",
    "reason": "Stuck on complex type inference"
  }
}
```

**2. Plugin sends ACK**
```json
{
  "schema": 0,
  "type": "ACK",
  "request_id": "req-escalate-001",
  "command": "escalate",
  "target": {"run_id": "loop-1703123456-12345", "issue_id": "complex-refactor"},
  "timestamp": "2024-12-28T12:00:01Z",
  "payload": {}
}
```

**3. Plugin sends RESULT**
```json
{
  "schema": 0,
  "type": "RESULT",
  "request_id": "req-escalate-001",
  "command": "escalate",
  "target": {"run_id": "loop-1703123456-12345", "issue_id": "complex-refactor"},
  "timestamp": "2024-12-28T12:00:02Z",
  "payload": {
    "status": "success",
    "previous_model": "haiku",
    "new_model": "opus"
  }
}
```

**4. Plugin emits STATE event on loop:current**
```json
{
  "schema": 1,
  "event": "STATE",
  "run_id": "loop-1703123456-12345",
  "updated_at": "2024-12-28T12:00:02Z",
  "stack": [
    {
      "id": "loop-1703123456-12345",
      "mode": "issue",
      "iter": 5,
      "max": 10,
      "model": "opus",
      "escalation_reason": "Stuck on complex type inference"
    }
  ]
}
```

### Flow D: Already Completed (Race Condition)

Controller sends a pause request for a run that has already finished.

**1. Controller sends REQUEST (pause)**
```json
{
  "schema": 0,
  "type": "REQUEST",
  "request_id": "req-race-001",
  "command": "pause",
  "target": {"run_id": "loop-completed-xyz"},
  "timestamp": "2024-12-28T13:00:00Z",
  "payload": {}
}
```

**2. Plugin sends RESULT (failure)**
```json
{
  "schema": 0,
  "type": "RESULT",
  "request_id": "req-race-001",
  "command": "pause",
  "target": {"run_id": "loop-completed-xyz"},
  "timestamp": "2024-12-28T13:00:01Z",
  "payload": {
    "status": "failure",
    "code": "not_found",
    "message": "Run loop-completed-xyz is not active"
  }
}
```

## Error Handling

### Status Codes

| Status | Description |
|--------|-------------|
| `success` | Command executed successfully |
| `failure` | Command could not be executed (see `code`) |

### Error Codes

| Code | Description | Example Scenario |
|------|-------------|------------------|
| `not_found` | Target run_id does not exist or is not active | Pausing a finished run |
| `invalid_state` | Command cannot be performed in current state | Resuming a running loop |
| `duplicate` | Request ID was already processed | Retry within dedup window |
| `bad_request` | Malformed message or missing required fields | Missing target.run_id |

## Implementation Notes

1. **ACK timing**: ACK must be sent immediately upon receiving a valid REQUEST, before any command logic executes. This confirms message delivery, not command success.

2. **Deduplication**: Plugin should maintain a cache of `{request_id: result}` for the 5-minute window. On duplicate, return the cached result.

3. **State persistence**: If the Plugin crashes while paused, the "paused" state should be persisted in `loop:current` so it is respected upon restart.

4. **Event ordering**: RESULT on `loop:control` should be sent before (or atomically with) state events on `loop:current` to ensure the controller sees command completion first.
