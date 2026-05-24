# Dialyzer baseline + burn-down

Glorbo adopted dialyxir in Glorbo v0.22.x. The first analysis surfaced **163**
success-typing warnings — none introduced by a single change, all
pre-existing. Fixing all 163 at once is out of scope, so CI uses a
**count-regression gate**: `mix dialyzer` runs in CI and the build fails
only if the warning count **exceeds the baseline below**. This catches
net-new type errors without maintaining per-warning ignore entries
(dialyxir's `.exs` tuple matcher keys on dialyzer's absolute file path,
which isn't portable across CI vs local checkouts; `.dialyzer_ignore.exs`
is kept intentionally empty).

```
DIALYZER_BASELINE = 168
```

> **163 → 166 (P2 security wave, 2026-05-22).** The wave added 4 private
> helpers — `bound_target/1`, `bound_detail/1` (dispatch.ex), `approval_detail/1`,
> `valid_replay_slug?/1` (reindex.ex) — that are verifiably called and tested, but
> whose *caller* functions are already in this baseline as `unused_fun`
> false-positives (dialyzer can't trace the audit-line fold / dep-injection paths),
> so the new callees inherit the same false flag. Net +3.
>
> **166 → 167 (PR #35 round-3 review-feedback wave, 2026-05-24).** Added
> `sanitise_rejected_action/1` (dispatch.ex) — bounds `Map.get(event, :action)`
> samples in the `agent.tool_audit_rejected` audit row to 80 bytes via
> `Util.UTF8.safe_byte_slice` (Copilot review). Verifiably called from
> `emit_tool_audits/5`, but `emit_tool_audits` is itself already in this
> baseline as `unused_fun` (same dialyzer-can't-trace-audit-fold pattern
> as the P2 wave), so the new callee inherits the same false flag. Net +1.
>
> **167 → 168 (PR #37 round-5 wave, 2026-05-25).** Added several new
> private helpers: `stat_memory_candidate/2`, `read_memory_entry/2`,
> `memory_dir_safe?/1` (agent_live.ex); `candidate_safe?/1`
> (formatter.ex); `ensure_real_directory/1` (doctor/fixer.ex);
> `refuse_dedicated_subtree/1` (actions/agents.ex). One of these
> inherits the `unused_fun` false flag from an already-baselined caller
> (same pattern as the P2 wave + round 3). Net +1.

**Burn-down:** when you fix warnings, lower the baseline number in
`.github/workflows/ci.yml` (the `baseline=` in the Dialyzer step). When it
reaches 0, drop the count gate and make `mix dialyzer` blocking outright.

## Priority (likely-real bugs — fix these first)

Most of the 163 are systematic false-positives (dep-injection `unused_fun`,
defensive `pattern_match*`, `MapSet` opacity). These categories are more
likely to be genuine and should be reviewed first:

```
lib/glorbo/actions/projects.ex:150:guard_fail The guard clause can never succeed.
lib/glorbo/agent/dispatch.ex:1110:guard_fail The guard clause can never succeed.
lib/glorbo/agent/dispatch.ex:225:68:call The function call invoke will not succeed.
lib/glorbo/agent/dispatch.ex:949:guard_fail The guard clause can never succeed.
lib/glorbo/audit/query.ex:43:15:call The function call stream! will not succeed.
lib/glorbo/cli.ex:411:48:call The function call restore will not succeed.
lib/glorbo/cli/harness.ex:112:50:call The function call read will not succeed.
lib/glorbo/cli/harness.ex:299:36:call The function call request_with_retries will not succeed.
lib/glorbo/cli/lifecycle/distribution.ex:61:15:call The function call start will not succeed.
lib/glorbo/cli/lifecycle/run.ex:70:63:call The function call execute will not succeed.
lib/glorbo/file_spec/task_md.ex:43:7:callback_type_mismatch Type mismatch for @callback frontmatter_schema.
lib/glorbo/filesystem/reindex.ex:584:15:call The function call stream! will not succeed.
lib/glorbo/filesystem/reindex.ex:690:13:call The function call stream! will not succeed.
lib/glorbo/filesystem/reindex.ex:837:13:call The function call stream! will not succeed.
lib/glorbo/filesystem/reindex.ex:99:invalid_contract Invalid type specification for function run.
lib/glorbo/search.ex:250:17:call The function call stream! will not succeed.
lib/glorbo/shell/views/audit/data.ex:58:15:call The function call stream! will not succeed.
lib/glorbo/task_definition.ex:946:guard_fail The guard clause can never succeed.
lib/glorbo_web/controllers/audit_export_controller.ex:34:19:call The function call stream! will not succeed.
lib/glorbo_web/live/activity_live.ex:235:15:call The function call stream! will not succeed.
lib/glorbo_web/live/agent_live.ex:2157:15:call The function call stream! will not succeed.
lib/glorbo_web/live/audit_live.ex:375:17:call The function call stream! will not succeed.
lib/glorbo_web/live/audit_live.ex:404:17:call The function call stream! will not succeed.
lib/glorbo_web/live/company_live.ex:1169:35:call The function call wake will not succeed.
lib/glorbo_web/live/company_live.ex:1994:guard_fail The guard clause can never succeed.
lib/glorbo_web/live/inbox_live.ex:497:15:call The function call stream! will not succeed.
lib/glorbo_web/live/kanban_live.ex:1384:62:neg_guard_fail The guard test can never succeed.
lib/glorbo_web/live/kanban_live.ex:197:guard_fail The guard clause can never succeed.
lib/glorbo_web/live/task_chain_live.ex:68:guard_fail The guard clause can never succeed.
lib/glorbo_web/live/task_chain_live.ex:71:guard_fail The guard clause can never succeed.
lib/glorbo_web/live/task_live.ex:397:guard_fail The guard clause can never succeed.
lib/glorbo_web/live/task_live.ex:725:15:call The function call stream! will not succeed.
lib/glorbo_web/mcp/session.ex:430:60:guard_fail The guard clause can never succeed.
lib/glorbo_web/mcp/tools/get_company_health.ex:173:17:call The function call stream! will not succeed.
lib/glorbo_web/mcp/tools/query_audit.ex:132:15:call The function call stream! will not succeed.
lib/mix/tasks/glorbo.kill.ex:49:9:call The function call exit_with will not succeed.
lib/mix/tasks/glorbo.kill.ex:54:9:call The function call exit_with will not succeed.
lib/mix/tasks/glorbo.kill.ex:79:9:call The function call exit_with will not succeed.
lib/mix/tasks/glorbo.kill.ex:87:7:call The function call exit_with will not succeed.
```

## Full baseline inventory (163)

<details><summary>all current dialyzer warnings</summary>

```
lib/glorbo/actions.ex:737:8:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo/actions/channels.ex:165:8:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo/actions/projects.ex:150:guard_fail The guard clause can never succeed.
lib/glorbo/agent/dispatch.ex:949:guard_fail The guard clause can never succeed.
lib/glorbo/agent/dispatch.ex:1110:guard_fail The guard clause can never succeed.
lib/glorbo/agent/dispatch.ex:225:68:call The function call invoke will not succeed.
lib/glorbo/agent/dispatch.ex:463:8:unused_fun Function check_runtime_untracked_allowed/3 will never be called.
lib/glorbo/agent/dispatch.ex:773:23:call_without_opaque Type mismatch in call without opaque term in member?.
lib/glorbo/agent/dispatch.ex:784:51:call_with_opaque Type mismatch in call with opaque term in resolve_regular_binary.
lib/glorbo/agent/dispatch.ex:865:8:unused_fun Function maybe_auto_mark_task_done/2 will never be called.
lib/glorbo/agent/dispatch.ex:1113:8:unused_fun Function compute_duration/2 will never be called.
lib/glorbo/agent/dispatch.ex:1118:8:unused_fun Function finalize_usage/3 will never be called.
lib/glorbo/agent/dispatch.ex:1137:8:unused_fun Function record_usage/4 will never be called.
lib/glorbo/agent/dispatch.ex:1239:8:unused_fun Function emit_complete_audit/6 will never be called.
lib/glorbo/agent/dispatch.ex:1273:8:unused_fun Function maybe_put_tokens/2 will never be called.
lib/glorbo/agent/dispatch.ex:1279:8:unused_fun Function maybe_put_cost/4 will never be called.
lib/glorbo/agent/dispatch.ex:1290:8:unused_fun Function pricing_known?/2 will never be called.
lib/glorbo/agent/dispatch.ex:1302:8:unused_fun Function extract_tool_calls/1 will never be called.
lib/glorbo/agent/dispatch.ex:1305:8:unused_fun Function emit_tool_audits/5 will never be called.
lib/glorbo/agent/dispatch.ex:1333:8:unused_fun Function maybe_put_tool_calls/2 will never be called.
lib/glorbo/agent/dispatch.ex:1340:8:unused_fun Function maybe_put_target/2 will never be called.
lib/glorbo/agent/dispatch.ex:1343:8:unused_fun Function maybe_put_detail/2 will never be called.
lib/glorbo/agent/dispatch.ex:1364:8:unused_fun Function maybe_check_task_budget/4 will never be called.
lib/glorbo/agent/dispatch.ex:1378:8:unused_fun Function cost_cents_from_usage/2 will never be called.
lib/glorbo/agent/dispatch.ex:1388:8:unused_fun Function emit_task_overspend/5 will never be called.
lib/glorbo/agent/dispatch.ex:1406:8:unused_fun Function maybe_check_loop/2 will never be called.
lib/glorbo/agent/dispatch.ex:1430:8:unused_fun Function preview/1 will never be called.
lib/glorbo/agent/loop_detector.ex:472:8:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo/approvals/gate.ex:564:8:pattern_match_cov The pattern variable _other@1 can never match the type, because it is covered by previous clauses.
lib/glorbo/approvals/gate.ex:577:8:pattern_match The pattern can never match the type %Glorbo.TaskDefinition{
lib/glorbo/audit/query.ex:43:15:call The function call stream! will not succeed.
lib/glorbo/audit/query.ex:52:8:unused_fun Function push_match/5 will never be called.
lib/glorbo/audit/query.ex:64:8:unused_fun Function decode_line/1 will never be called.
lib/glorbo/audit/query.ex:71:8:unused_fun Function matches?/3 will never be called.
lib/glorbo/backup.ex:56:14:pattern_match The pattern can never match the type {:error, {:precreate_failed, atom()}}.
lib/glorbo/backup.ex:202:30:pattern_match The pattern can never match the type {:error, {:precreate_failed, atom()}}.
lib/glorbo/backup.ex:209:16:pattern_match_cov The pattern pattern {'error', _reason@1} can never match the type, because it is covered by previous clauses.
lib/glorbo/backup.ex:239:8:no_return Function create_archive/2 has no local return.
lib/glorbo/backup.ex:246:8:pattern_match The pattern can never match the type 
lib/glorbo/benchmarks.ex:331:8:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo/benchmarks/orchestrator.ex:197:7:pattern_match_cov The pattern variable _other@1 can never match the type, because it is covered by previous clauses.
lib/glorbo/cli.ex:411:48:call The function call restore will not succeed.
lib/glorbo/cli/dispatcher.ex:1040:8:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo/cli/dispatcher/acp/client.ex:585:8:pattern_match The pattern can never match the type 
lib/glorbo/cli/dispatcher/acp/client.ex:589:8:pattern_match The pattern can never match the type 
lib/glorbo/cli/harness.ex:580:unused_fun Function safe_write/2 will never be called.
lib/glorbo/cli/harness.ex:112:41:no_return The created anonymous function has no local return.
lib/glorbo/cli/harness.ex:112:50:call The function call read will not succeed.
lib/glorbo/cli/harness.ex:208:8:no_return Function converse/3 has no local return.
lib/glorbo/cli/harness.ex:230:8:no_return Function loop/7 has no local return.
lib/glorbo/cli/harness.ex:278:8:no_return Function chat_completion/3 has no local return.
lib/glorbo/cli/harness.ex:299:36:call The function call request_with_retries will not succeed.
lib/glorbo/cli/harness.ex:326:8:unused_fun Function decode_response_body/1 will never be called.
lib/glorbo/cli/harness.ex:335:8:unused_fun Function extract_message/2 will never be called.
lib/glorbo/cli/harness.ex:344:8:unused_fun Function merge_usage/2 will never be called.
lib/glorbo/cli/harness.ex:364:8:unused_fun Function build_usage/4 will never be called.
lib/glorbo/cli/harness.ex:386:8:unused_fun Function execute_tool_calls/4 will never be called.
lib/glorbo/cli/harness.ex:401:8:unused_fun Function tool_result/2 will never be called.
lib/glorbo/cli/harness.ex:417:8:unused_fun Function count_tool_call/2 will never be called.
lib/glorbo/cli/harness.ex:421:8:unused_fun Function maybe_append_event/2 will never be called.
lib/glorbo/cli/harness.ex:424:8:unused_fun Function maybe_put_audit_events/2 will never be called.
lib/glorbo/cli/harness.ex:458:8:unused_fun Function normalize_content/1 will never be called.
lib/glorbo/cli/harness.ex:529:8:unused_fun Function error_detail/1 will never be called.
lib/glorbo/cli/harness.ex:545:8:pattern_match The pattern can never match the type {:credentials_read_failed, _} | {:invalid_credentials_toml, _} | {:invalid_prompt, _}.
lib/glorbo/cli/harness.ex:548:8:pattern_match The pattern can never match the type {:credentials_read_failed, _} | {:invalid_credentials_toml, _} | {:invalid_prompt, _}.
lib/glorbo/cli/harness.ex:551:8:pattern_match The pattern can never match the type {:credentials_read_failed, _} | {:invalid_credentials_toml, _} | {:invalid_prompt, _}.
lib/glorbo/cli/harness.ex:554:8:pattern_match The pattern can never match the type {:credentials_read_failed, _} | {:invalid_credentials_toml, _} | {:invalid_prompt, _}.
lib/glorbo/cli/harness.ex:557:8:pattern_match The pattern can never match the type {:credentials_read_failed, _} | {:invalid_credentials_toml, _} | {:invalid_prompt, _}.
lib/glorbo/cli/harness.ex:566:8:pattern_match The pattern can never match the type {:invalid_prompt, _}.
lib/glorbo/cli/harness.ex:569:8:pattern_match The pattern can never match the type {:invalid_prompt, _}.
lib/glorbo/cli/harness.ex:570:8:pattern_match The pattern can never match the type {:invalid_prompt, _}.
lib/glorbo/cli/harness.ex:571:8:pattern_match The pattern can never match the type {:invalid_prompt, _}.
lib/glorbo/cli/harness.ex:573:8:pattern_match The pattern can never match the type 
lib/glorbo/cli/harness.ex:574:8:pattern_match_cov The pattern variable _other@1 can never match the type, because it is covered by previous clauses.
lib/glorbo/cli/harness.ex:576:8:unused_fun Function maybe_suffix/1 will never be called.
lib/glorbo/cli/install.ex:205:8:pattern_match_cov The pattern variable _other@1 can never match the type, because it is covered by previous clauses.
lib/glorbo/cli/lifecycle/distribution.ex:58:8:no_return Function do_start/0 has no local return.
lib/glorbo/cli/lifecycle/distribution.ex:61:15:call The function call start will not succeed.
lib/glorbo/cli/lifecycle/run.ex:70:63:call The function call execute will not succeed.
lib/glorbo/cli/lifecycle/run.ex:94:18:pattern_match The pattern can never match the type 
lib/glorbo/cli/lifecycle/serve.ex:70:7:pattern_match The pattern can never match the type {:error, :already_started, atom()}.
lib/glorbo/cli/lifecycle/serve.ex:82:16:pattern_match The pattern can never match the type :ok | {:error, :already_started, atom()}.
lib/glorbo/cli/parsers/native_v1.ex:30:13:pattern_match The pattern can never match the type 
lib/glorbo/cli/scaffold/company.ex:98:16:pattern_match The pattern can never match the type {:error, {:bad_manifest, _}}.
lib/glorbo/cli/scaffold/company.ex:105:16:pattern_match_cov The pattern pattern {'error', _reason@2} can never match the type, because it is covered by previous clauses.
lib/glorbo/company/agent_boot.ex:130:8:pattern_match_cov The pattern pattern <_, _, _> can never match the type, because it is covered by previous clauses.
lib/glorbo/company/router.ex:479:8:pattern_match The pattern can never match the type {:agent, binary()} | {:chat, binary()}.
lib/glorbo/company/router.ex:608:8:pattern_match The pattern can never match the type 
lib/glorbo/company/router.ex:609:8:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo/company/router.ex:616:8:pattern_match_cov The pattern variable _other@1 can never match the type, because it is covered by previous clauses.
lib/glorbo/company/router.ex:2121:8:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo/file_spec/formatter.ex:79:7:pattern_match_cov The pattern variable _other@1 can never match the type, because it is covered by previous clauses.
lib/glorbo/file_spec/task_md.ex:43:7:callback_type_mismatch Type mismatch for @callback frontmatter_schema.
lib/glorbo/file_spec/validator.ex:142:48:pattern_match The pattern can never match the type 
lib/glorbo/filesystem/reindex.ex:99:invalid_contract Invalid type specification for function run.
lib/glorbo/filesystem/reindex.ex:892:unused_fun Function non_neg_int/1 will never be called.
lib/glorbo/filesystem/reindex.ex:457:8:unused_fun Function dirname_company_slug/1 will never be called.
lib/glorbo/filesystem/reindex.ex:469:8:unused_fun Function audit_company_slug/1 will never be called.
lib/glorbo/filesystem/reindex.ex:481:8:unused_fun Function safe_agent_slug/1 will never be called.
lib/glorbo/filesystem/reindex.ex:520:8:unused_fun Function decode_capped_line/3 will never be called.
lib/glorbo/filesystem/reindex.ex:584:15:call The function call stream! will not succeed.
lib/glorbo/filesystem/reindex.ex:589:29:no_return The created anonymous function has no local return.
lib/glorbo/filesystem/reindex.ex:608:8:unused_fun Function decode_audit_line/3 will never be called.
lib/glorbo/filesystem/reindex.ex:615:8:unused_fun Function build_audit_row/2 will never be called.
lib/glorbo/filesystem/reindex.ex:639:8:unused_fun Function stringify_or/2 will never be called.
lib/glorbo/filesystem/reindex.ex:643:8:unused_fun Function parse_audit_ts/1 will never be called.
lib/glorbo/filesystem/reindex.ex:690:13:call The function call stream! will not succeed.
lib/glorbo/filesystem/reindex.ex:701:8:unused_fun Function fold_approval_line/4 will never be called.
lib/glorbo/filesystem/reindex.ex:711:8:unused_fun Function apply_approval_event/4 will never be called.
lib/glorbo/filesystem/reindex.ex:745:8:unused_fun Function update_resolution/6 will never be called.
lib/glorbo/filesystem/reindex.ex:837:13:call The function call stream! will not succeed.
lib/glorbo/filesystem/reindex.ex:848:8:unused_fun Function sum_budget_line/4 will never be called.
lib/glorbo/filesystem/reindex.ex:858:8:unused_fun Function apply_budget_usage/3 will never be called.
lib/glorbo/home_history/tx.ex:252:41:call_with_opaque Type mismatch in call with opaque term in put_tx.
lib/glorbo/inbox/archive.ex:23:contract_with_opaque The @spec for list has an opaque subtype which is violated by the success typing.
lib/glorbo/inbox/archive.ex:39:11:call_without_opaque Type mismatch in call without opaque term in put.
lib/glorbo/inbox/archive.ex:45:11:call_without_opaque Type mismatch in call without opaque term in delete.
lib/glorbo/init/orchestrator.ex:152:7:pattern_match_cov The pattern variable _other@1 can never match the type, because it is covered by previous clauses.
lib/glorbo/restore.ex:390:7:pattern_match_cov The pattern variable _other@1 can never match the type, because it is covered by previous clauses.
lib/glorbo/sandbox/bwrap.ex:209:13:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo/sandbox/bwrap.ex:767:20:pattern_match_cov The pattern pattern {'error', _reason@1} can never match the type, because it is covered by previous clauses.
lib/glorbo/sandbox/unsandboxed.ex:156:18:pattern_match_cov The pattern pattern {'error', _reason@1} can never match the type, because it is covered by previous clauses.
lib/glorbo/schedule/nl.ex:214:pattern_match The pattern can never match the type integer(), binary() | {integer(), integer()}.
lib/glorbo/search.ex:250:17:call The function call stream! will not succeed.
lib/glorbo/shell/views/audit/data.ex:58:15:call The function call stream! will not succeed.
lib/glorbo/task_definition.ex:946:guard_fail The guard clause can never succeed.
lib/glorbo/task_definition.ex:958:8:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo_web/components/audit_entry.ex:206:8:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo_web/components/statusbar.ex:262:7:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo_web/controllers/audit_export_controller.ex:34:19:call The function call stream! will not succeed.
lib/glorbo_web/live/activity_live.ex:235:15:call The function call stream! will not succeed.
lib/glorbo_web/live/agent_live.ex:346:34:pattern_match The pattern can never match the type {:error, :contract_file}.
lib/glorbo_web/live/agent_live.ex:686:7:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo_web/live/agent_live.ex:2157:15:call The function call stream! will not succeed.
lib/glorbo_web/live/agent_live.ex:2169:8:unused_fun Function push_history_row/3 will never be called.
lib/glorbo_web/live/audit_live.ex:222:9:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo_web/live/audit_live.ex:375:17:call The function call stream! will not succeed.
lib/glorbo_web/live/audit_live.ex:404:17:call The function call stream! will not succeed.
lib/glorbo_web/live/company_live.ex:1994:guard_fail The guard clause can never succeed.
lib/glorbo_web/live/company_live.ex:977:13:pattern_match The pattern can never match the type 
lib/glorbo_web/live/company_live.ex:1169:35:call The function call wake will not succeed.
lib/glorbo_web/live/inbox_live.ex:497:15:call The function call stream! will not succeed.
lib/glorbo_web/live/kanban_live.ex:197:guard_fail The guard clause can never succeed.
lib/glorbo_web/live/kanban_live.ex:1384:62:neg_guard_fail The guard test can never succeed.
lib/glorbo_web/live/project_live.ex:400:8:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo_web/live/task_chain_live.ex:68:guard_fail The guard clause can never succeed.
lib/glorbo_web/live/task_chain_live.ex:71:guard_fail The guard clause can never succeed.
lib/glorbo_web/live/task_live.ex:397:guard_fail The guard clause can never succeed.
lib/glorbo_web/live/task_live.ex:725:15:call The function call stream! will not succeed.
lib/glorbo_web/live/task_live.ex:734:8:unused_fun Function accumulate_usage/3 will never be called.
lib/glorbo_web/mcp/plug.ex:490:8:pattern_match_cov The pattern variable __conn@1 can never match the type, because it is covered by previous clauses.
lib/glorbo_web/mcp/session.ex:430:60:guard_fail The guard clause can never succeed.
lib/glorbo_web/mcp/tools/create_company.ex:58:7:pattern_match_cov The pattern pattern {'new_company', _, _msg@2} can never match the type, because it is covered by previous clauses.
lib/glorbo_web/mcp/tools/get_agent.ex:82:8:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo_web/mcp/tools/get_agent.ex:91:8:pattern_match_cov The pattern variable _other@1 can never match the type, because it is covered by previous clauses.
lib/glorbo_web/mcp/tools/get_company_health.ex:173:17:call The function call stream! will not succeed.
lib/glorbo_web/mcp/tools/list_agents.ex:104:8:pattern_match_cov The pattern variable _ can never match the type, because it is covered by previous clauses.
lib/glorbo_web/mcp/tools/list_agents.ex:112:8:pattern_match_cov The pattern variable _other@1 can never match the type, because it is covered by previous clauses.
lib/glorbo_web/mcp/tools/query_audit.ex:132:15:call The function call stream! will not succeed.
lib/mix/tasks/glorbo.kill.ex:49:9:call The function call exit_with will not succeed.
lib/mix/tasks/glorbo.kill.ex:54:9:call The function call exit_with will not succeed.
lib/mix/tasks/glorbo.kill.ex:79:9:call The function call exit_with will not succeed.
lib/mix/tasks/glorbo.kill.ex:87:7:call The function call exit_with will not succeed.
```

</details>
