# Skill: Code Review

## When to Use

When reviewing code changes for correctness, security, maintainability, and
alignment with DESIGN.md.

## Checklist

### Architecture Alignment
- [ ] Matches DESIGN.md specification for the component
- [ ] Supervision tree structure is correct
- [ ] Filesystem paths match Section 3 directory structure
- [ ] Permission model follows Section 7

### Correctness
- [ ] Logic handles edge cases
- [ ] Error paths are covered
- [ ] No race conditions in concurrent code
- [ ] GenServer state transitions are valid

### Security (DESIGN.md Section 12)
- [ ] No path traversal (user input used in file paths)
- [ ] No command injection (user input in shell commands)
- [ ] Permissions checked before message routing
- [ ] API keys not logged or written to company directories
- [ ] Audit events logged for significant actions

### OTP Best Practices
- [ ] GenServer public API wraps calls/casts
- [ ] Crash isolation — failure in one agent doesn't cascade
- [ ] `handle_continue` for expensive init
- [ ] Proper use of supervision strategies

### Testing
- [ ] Tests exist for the change
- [ ] Tests cover happy path and error cases
- [ ] Async tests where possible
- [ ] No test pollution (temp dirs cleaned up)

### Code Quality
- [ ] `mix format` clean
- [ ] No compiler warnings
- [ ] No dead code
- [ ] Clear naming
- [ ] Comments only where logic isn't self-evident
