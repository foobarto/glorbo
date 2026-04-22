# Graph Report - lib  (2026-04-23)

## Corpus Check
- 223 files · ~163,576 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 2601 nodes · 4913 edges · 103 communities detected
- Extraction: 78% EXTRACTED · 22% INFERRED · 0% AMBIGUOUS · INFERRED: 1073 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 25|Community 25]]
- [[_COMMUNITY_Community 26|Community 26]]
- [[_COMMUNITY_Community 27|Community 27]]
- [[_COMMUNITY_Community 28|Community 28]]
- [[_COMMUNITY_Community 29|Community 29]]
- [[_COMMUNITY_Community 30|Community 30]]
- [[_COMMUNITY_Community 31|Community 31]]
- [[_COMMUNITY_Community 32|Community 32]]
- [[_COMMUNITY_Community 33|Community 33]]
- [[_COMMUNITY_Community 34|Community 34]]
- [[_COMMUNITY_Community 35|Community 35]]
- [[_COMMUNITY_Community 36|Community 36]]
- [[_COMMUNITY_Community 37|Community 37]]
- [[_COMMUNITY_Community 38|Community 38]]
- [[_COMMUNITY_Community 39|Community 39]]
- [[_COMMUNITY_Community 40|Community 40]]
- [[_COMMUNITY_Community 41|Community 41]]
- [[_COMMUNITY_Community 42|Community 42]]
- [[_COMMUNITY_Community 43|Community 43]]
- [[_COMMUNITY_Community 44|Community 44]]
- [[_COMMUNITY_Community 45|Community 45]]
- [[_COMMUNITY_Community 46|Community 46]]
- [[_COMMUNITY_Community 47|Community 47]]
- [[_COMMUNITY_Community 48|Community 48]]
- [[_COMMUNITY_Community 49|Community 49]]
- [[_COMMUNITY_Community 50|Community 50]]
- [[_COMMUNITY_Community 51|Community 51]]
- [[_COMMUNITY_Community 52|Community 52]]
- [[_COMMUNITY_Community 53|Community 53]]
- [[_COMMUNITY_Community 54|Community 54]]
- [[_COMMUNITY_Community 55|Community 55]]
- [[_COMMUNITY_Community 56|Community 56]]
- [[_COMMUNITY_Community 57|Community 57]]
- [[_COMMUNITY_Community 58|Community 58]]
- [[_COMMUNITY_Community 59|Community 59]]
- [[_COMMUNITY_Community 60|Community 60]]
- [[_COMMUNITY_Community 61|Community 61]]
- [[_COMMUNITY_Community 62|Community 62]]
- [[_COMMUNITY_Community 63|Community 63]]
- [[_COMMUNITY_Community 64|Community 64]]
- [[_COMMUNITY_Community 65|Community 65]]
- [[_COMMUNITY_Community 66|Community 66]]
- [[_COMMUNITY_Community 67|Community 67]]
- [[_COMMUNITY_Community 68|Community 68]]
- [[_COMMUNITY_Community 69|Community 69]]
- [[_COMMUNITY_Community 70|Community 70]]
- [[_COMMUNITY_Community 71|Community 71]]
- [[_COMMUNITY_Community 72|Community 72]]
- [[_COMMUNITY_Community 73|Community 73]]
- [[_COMMUNITY_Community 74|Community 74]]
- [[_COMMUNITY_Community 75|Community 75]]
- [[_COMMUNITY_Community 76|Community 76]]
- [[_COMMUNITY_Community 77|Community 77]]
- [[_COMMUNITY_Community 78|Community 78]]
- [[_COMMUNITY_Community 79|Community 79]]
- [[_COMMUNITY_Community 80|Community 80]]
- [[_COMMUNITY_Community 81|Community 81]]
- [[_COMMUNITY_Community 82|Community 82]]
- [[_COMMUNITY_Community 83|Community 83]]
- [[_COMMUNITY_Community 84|Community 84]]
- [[_COMMUNITY_Community 85|Community 85]]
- [[_COMMUNITY_Community 86|Community 86]]
- [[_COMMUNITY_Community 87|Community 87]]
- [[_COMMUNITY_Community 88|Community 88]]
- [[_COMMUNITY_Community 89|Community 89]]
- [[_COMMUNITY_Community 90|Community 90]]
- [[_COMMUNITY_Community 91|Community 91]]
- [[_COMMUNITY_Community 92|Community 92]]
- [[_COMMUNITY_Community 93|Community 93]]
- [[_COMMUNITY_Community 94|Community 94]]
- [[_COMMUNITY_Community 95|Community 95]]
- [[_COMMUNITY_Community 96|Community 96]]
- [[_COMMUNITY_Community 97|Community 97]]
- [[_COMMUNITY_Community 98|Community 98]]
- [[_COMMUNITY_Community 99|Community 99]]
- [[_COMMUNITY_Community 100|Community 100]]
- [[_COMMUNITY_Community 101|Community 101]]
- [[_COMMUNITY_Community 102|Community 102]]

## God Nodes (most connected - your core abstractions)
1. `read()` - 112 edges
2. `Glorbo.Company.Router` - 101 edges
3. `parse()` - 95 edges
4. `default_root()` - 78 edges
5. `GlorboWeb.AgentLive` - 78 edges
6. `GlorboWeb.CompanyLive` - 70 edges
7. `exists?()` - 67 edges
8. `Glorbo.Agent.Dispatch` - 55 edges
9. `Glorbo.Agent.Server` - 53 edges
10. `GlorboWeb.KanbanLive` - 50 edges

## Surprising Connections (you probably didn't know these)
- `compute_health()` --calls--> `run_checks()`  [INFERRED]
  lib/glorbo_web/components/sidebar.ex → lib/glorbo/doctor.ex
- `kill_running_agents()` --calls--> `stop_inflight()`  [INFERRED]
  lib/glorbo/emergency_stop.ex → lib/glorbo/agent/server.ex
- `stop_agent()` --calls--> `lookup()`  [INFERRED]
  lib/glorbo/company/agent_supervisor.ex → lib/glorbo/path_grant_store.ex
- `resolve_audit_server()` --calls--> `lookup()`  [INFERRED]
  lib/glorbo/company/scheduler.ex → lib/glorbo/path_grant_store.ex
- `resolve_audit_server()` --calls--> `lookup()`  [INFERRED]
  lib/glorbo/company/proposals_sink.ex → lib/glorbo/path_grant_store.ex

## Communities

### Community 0 - "Community 0"
Cohesion: 0.03
Nodes (103): GlorboWeb.BrainDumpLive, do_convert(), emit_audit(), flat_recent(), handle_event(), load_and_assign(), mount(), today_string() (+95 more)

### Community 1 - "Community 1"
Cohesion: 0.03
Nodes (98): decode(), Glorbo.CLI.Parsers.CodexJsonl, decode_line(), GlorboWeb.CompanyLive, activity_hint(), agent_pill_label(), agent_pill_status(), agent_runtime_status() (+90 more)

### Community 2 - "Community 2"
Cohesion: 0.03
Nodes (71): GlorboWeb.MCP.Tools.ApproveTask, audit_opt(), do_call(), mcp_actor(), GlorboWeb.MCP.Tools.CaptureBrainDump, do_call(), Glorbo.CLI, dispatch() (+63 more)

### Community 3 - "Community 3"
Cohesion: 0.04
Nodes (101): Glorbo.Security.ACLMapper, check_action(), request_approval(), rm(), Glorbo.Company.Router, append_line!(), append_task_comment(), atomic_write() (+93 more)

### Community 4 - "Community 4"
Cohesion: 0.03
Nodes (74): Glorbo.CLI.Lifecycle.Down, do_run(), glorbo_home(), help_text(), run(), stop_running(), wait_for_exit(), GlorboWeb.ErrorHTML (+66 more)

### Community 5 - "Community 5"
Cohesion: 0.03
Nodes (74): Glorbo.FileSpec.AgentMd, canonical_key_order(), docs(), frontmatter_schema(), kind(), Glorbo.FileSpec, classify_by_kind(), specs() (+66 more)

### Community 6 - "Community 6"
Cohesion: 0.04
Nodes (80): GlorboWeb.AgentLive, action_class(), agent_dir(), agent_name(), agent_pill_label(), agent_pill_status(), audit_for_this_agent?(), backfill_stdout() (+72 more)

### Community 7 - "Community 7"
Cohesion: 0.03
Nodes (65): Glorbo.CLI.Parsers.ClaudeJsonl, accumulate(), count_tool_calls(), decode_line(), parse(), Glorbo.Config, atomic_write_secret!(), erl_cookie() (+57 more)

### Community 8 - "Community 8"
Cohesion: 0.04
Nodes (86): Glorbo.Agent.Dispatch, attempt_with_retries(), audit_fun(), build_ctx(), build_retry_task(), check_budget(), check_company_budget(), check_emergency_stop() (+78 more)

### Community 9 - "Community 9"
Cohesion: 0.03
Nodes (72): mark_director_approval(), Glorbo.Company.AgentBoot, boot_one(), do_boot(), maybe_register_heartbeat(), run(), start_and_register(), Glorbo.Company.AgentSupervisor (+64 more)

### Community 10 - "Community 10"
Cohesion: 0.04
Nodes (71): Glorbo.CLI.Scaffold.Agent, detect_missing_skills(), do_run(), do_scaffold(), glorbo_home(), help_text(), maybe_write_heartbeat(), maybe_write_soul() (+63 more)

### Community 11 - "Community 11"
Cohesion: 0.04
Nodes (64): write(), Glorbo.BrainDump, apply_section_removal(), build_entry(), convert_to_task(), date_string(), delete_entry(), derive_title() (+56 more)

### Community 12 - "Community 12"
Cohesion: 0.04
Nodes (61): Glorbo.DB.Bootstrap, child_spec(), do_migrate(), migrations_path(), start_link(), table_exists?(), Glorbo.CLI.Lifecycle.Daemon, do_spawn() (+53 more)

### Community 13 - "Community 13"
Cohesion: 0.05
Nodes (64): Glorbo.Company.BudgetTracker, default_budgets_fun(), emit_alert_audit(), emit_audit(), emit_hard_stop(), extract_yaml_field(), fetch_used(), handle_call() (+56 more)

### Community 14 - "Community 14"
Cohesion: 0.04
Nodes (58): GlorboWeb.Actions, extract_frontmatter(), hire_argv(), hire_task?(), lookup_requesting_agent(), maybe_put_assigned_to(), maybe_rotate_channel(), maybe_scaffold_hired_agent() (+50 more)

### Community 15 - "Community 15"
Cohesion: 0.05
Nodes (50): Glorbo.Inbox.Archive, list(), path(), GlorboWeb.AuditLive, action_match?(), actor_match?(), audit_path(), entry_id() (+42 more)

### Community 16 - "Community 16"
Cohesion: 0.07
Nodes (54): load_path_requests(), reload_config(), call(), GlorboWeb.InboxLive, approval_key(), audit_key(), handle_event(), handle_info() (+46 more)

### Community 17 - "Community 17"
Cohesion: 0.05
Nodes (51): Glorbo.Backup, default_output_path(), ensure_down(), format_cli_result(), help_text(), maybe_checkpoint(), recheck_down(), run() (+43 more)

### Community 18 - "Community 18"
Cohesion: 0.07
Nodes (50): Glorbo.Filesystem.Reindex, accumulate_result(), cleanup_vanished(), company_prefix(), do_run(), infer_agent_name(), infer_company_name(), infer_company_name_from_agent_path() (+42 more)

### Community 19 - "Community 19"
Cohesion: 0.06
Nodes (30): Glorbo.CLI.Registry.Detection, apply_regex(), detect_all(), detect_one(), probe_one(), probe_versions(), try_fallback_paths(), Glorbo.CLI.Registry.Loader (+22 more)

### Community 20 - "Community 20"
Cohesion: 0.06
Nodes (38): Glorbo.Agent.LoopDetector, agent_slug_from_state_path(), apply_one_resolution(), apply_resolution_files(), blank?(), decode_line(), default_fs_fun(), emit_loop_audit() (+30 more)

### Community 21 - "Community 21"
Cohesion: 0.06
Nodes (38): GlorboWeb.MCP.Plug, attach_and_stream(), build_context(), call(), client_name(), dispatch_by_method(), dispatch_request(), ensure_session() (+30 more)

### Community 22 - "Community 22"
Cohesion: 0.07
Nodes (40): Glorbo.Agent.Server, apply_task_actions(), broadcast_status(), call_inbox_scan(), compose_memory_section(), compose_prompt(), director_wake_task(), dispatch_result_to_exit_status() (+32 more)

### Community 23 - "Community 23"
Cohesion: 0.1
Nodes (28): GlorboWeb.ChannelLive, archivable?(), archive_segment_path(), channel_path(), count_headers(), do_archive(), handle_event(), handle_info() (+20 more)

### Community 24 - "Community 24"
Cohesion: 0.08
Nodes (20): GlorboWeb.MCP.Args, require_safe_identifier(), require_safe_yaml_scalar(), require_slug(), require_slugs(), Glorbo.CLI.Scaffold.Company, do_scaffold(), glorbo_home() (+12 more)

### Community 25 - "Community 25"
Cohesion: 0.12
Nodes (28): load_rollups(), Gep.Formatter, format(), gep_label(), Glorbo.Doctor.Formatter, color(), format_row(), format_summary() (+20 more)

### Community 26 - "Community 26"
Cohesion: 0.11
Nodes (19): Glorbo.Budget.CompanyCap, list_agent_slugs(), parse_cap(), read_cap(), used_this_month(), load_budget_cap_state(), GlorboWeb.CostsLive, build_company_caps() (+11 more)

### Community 27 - "Community 27"
Cohesion: 0.12
Nodes (25): GlorboWeb.CoreComponents, icon(), GlorboWeb.MCP.Tools.GetAgent, description(), do_call(), input_schema(), network_to_wire(), permission_strings() (+17 more)

### Community 28 - "Community 28"
Cohesion: 0.09
Nodes (16): Glorbo.TaskDefinition, atomic_write(), derive_project(), do_atomic_write(), ensure_regular_file_or_absent(), finalize(), load_frontmatter(), maybe_loop_back_recurring() (+8 more)

### Community 29 - "Community 29"
Cohesion: 0.07
Nodes (2): Glorbo.Agent.Parser, read_file()

### Community 30 - "Community 30"
Cohesion: 0.12
Nodes (22): Glorbo.Application, maybe_write_pidfile(), release_argv(), run_cli_and_halt(), running_standalone?(), start(), start_supervision_tree(), start_supervision_tree_for_serve() (+14 more)

### Community 31 - "Community 31"
Cohesion: 0.14
Nodes (21): Glorbo.Sandbox.Bwrap, agent_owned_flags(), approved_path_flags(), baseline_flags(), build_argv(), close_stdout_tee(), do_run_via_port(), drain_port() (+13 more)

### Community 32 - "Community 32"
Cohesion: 0.18
Nodes (23): Glorbo.Network.Proxy, accept_loop(), classify_unlisted(), default_allowlist(), dispatch_request(), evaluate_and_tunnel(), handle_connection(), handle_info() (+15 more)

### Community 33 - "Community 33"
Cohesion: 0.15
Nodes (17): GlorboWeb.MCP.Tools.QueryAudit, after_since?(), before_until?(), clamp_limit(), current_year_month(), do_call(), enumerate_months(), filter_by() (+9 more)

### Community 34 - "Community 34"
Cohesion: 0.15
Nodes (19): Glorbo.Company.TaskScheduler, arm(), default_write_inbox(), do_scan(), emit_audit(), fire(), handle_call(), handle_info() (+11 more)

### Community 35 - "Community 35"
Cohesion: 0.13
Nodes (13): Glorbo.FileSpec.Formatter, atomic_write(), build_stats(), check_one(), do_format(), emit_pair(), emit_pairs(), ensure_trailing_newline() (+5 more)

### Community 36 - "Community 36"
Cohesion: 0.15
Nodes (8): GlorboWeb.Components.AuditEntry, action_phrase(), actor_initials(), actor_kind(), audit_entry(), describe_complete(), humanize_ms(), to_sentence()

### Community 37 - "Community 37"
Cohesion: 0.23
Nodes (6): GlorboWeb.MCP.Tools.GetChannel, clamp_limit(), do_call(), maybe_filter_since(), nilify(), parse_iso()

### Community 38 - "Community 38"
Cohesion: 0.23
Nodes (6): GlorboWeb.MCP.Tools.ListPendingApprovals, build_entry(), do_call(), find_task_file(), mtime_iso(), scan_agent()

### Community 39 - "Community 39"
Cohesion: 0.33
Nodes (10): Glorbo.Sandbox.Unsandboxed, close_stdout_tee(), do_run_via_port(), drain_loop(), drain_port(), open_stdout_tee(), run_via_port(), safe_port_close() (+2 more)

### Community 40 - "Community 40"
Cohesion: 0.2
Nodes (5): GlorboWeb.Markdown.Linkify, html_escape(), linkify_text(), GlorboWeb.Markdown, detokenize_mentions()

### Community 41 - "Community 41"
Cohesion: 0.36
Nodes (9): GlorboWeb.AuditExportController, build_csv(), csv_cell(), detail_as_json(), export(), header_row(), needs_quoting?(), neutralise_formula() (+1 more)

### Community 42 - "Community 42"
Cohesion: 0.33
Nodes (9): GlorboWeb.Components.BudgetRing, aria_label(), budget_ring(), center_text(), color(), over_cap?(), ratio(), two_decimals() (+1 more)

### Community 43 - "Community 43"
Cohesion: 0.27
Nodes (5): GlorboWeb.MCP.Tools.ListProposals, do_call(), load(), maybe_filter_status(), nilify()

### Community 44 - "Community 44"
Cohesion: 0.29
Nodes (1): GlorboWeb.Components.CompanyCard

### Community 45 - "Community 45"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.HeartbeatMd

### Community 46 - "Community 46"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.SoulMd

### Community 47 - "Community 47"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.MemoryIndexMd

### Community 48 - "Community 48"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.SentinelApprovalMd

### Community 49 - "Community 49"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.SentinelStuckMd

### Community 50 - "Community 50"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.SentinelResolutionMd

### Community 51 - "Community 51"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.BraindumpMd

### Community 52 - "Community 52"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.ChannelLogMd

### Community 53 - "Community 53"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.InboxArchiveJson

### Community 54 - "Community 54"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.AuditMonthJsonl

### Community 55 - "Community 55"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.MemoryEntryMd

### Community 56 - "Community 56"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.SkillMd

### Community 57 - "Community 57"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.EmergencyStopMd

### Community 58 - "Community 58"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.InboxMessageMd

### Community 59 - "Community 59"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.GoalMd

### Community 60 - "Community 60"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.ConfigMd

### Community 61 - "Community 61"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.TaskMd

### Community 62 - "Community 62"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.ProjectMd

### Community 63 - "Community 63"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.CompanyMd

### Community 64 - "Community 64"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.PathRequestMd

### Community 65 - "Community 65"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.ProposalMd

### Community 66 - "Community 66"
Cohesion: 0.33
Nodes (1): Glorbo.FileSpec.TaskCommentsMd

### Community 67 - "Community 67"
Cohesion: 0.4
Nodes (1): Glorbo.Agent.FileLayout

### Community 68 - "Community 68"
Cohesion: 0.5
Nodes (3): GlorboWeb.TimeFormat, do_relative(), relative()

### Community 69 - "Community 69"
Cohesion: 0.4
Nodes (1): GlorboWeb.Components.Icon

### Community 70 - "Community 70"
Cohesion: 0.4
Nodes (1): GlorboWeb.Components.StdoutTail

### Community 71 - "Community 71"
Cohesion: 0.5
Nodes (3): GlorboWeb.Components.StatBreakdown, resolve_color(), stat_breakdown()

### Community 72 - "Community 72"
Cohesion: 0.4
Nodes (1): GlorboWeb.Components.ChatDrawer

### Community 73 - "Community 73"
Cohesion: 0.5
Nodes (1): Glorbo.CLI.DoctorFix

### Community 74 - "Community 74"
Cohesion: 0.5
Nodes (1): Glorbo.CLI.Parsers.GeminiStdout

### Community 75 - "Community 75"
Cohesion: 0.5
Nodes (1): Glorbo.CLI.Registry.Provider

### Community 76 - "Community 76"
Cohesion: 0.67
Nodes (3): GlorboWeb.Components.Spark, normalize(), spark()

### Community 77 - "Community 77"
Cohesion: 0.67
Nodes (3): GlorboWeb.Components.ChannelMessage, author_kind(), channel_message()

### Community 78 - "Community 78"
Cohesion: 0.5
Nodes (1): GlorboWeb.Components.TaskDetailForm

### Community 79 - "Community 79"
Cohesion: 0.5
Nodes (1): GlorboWeb.Components.TaskCard

### Community 80 - "Community 80"
Cohesion: 0.67
Nodes (1): Glorbo.Init

### Community 81 - "Community 81"
Cohesion: 0.67
Nodes (1): Glorbo.Budget

### Community 82 - "Community 82"
Cohesion: 0.67
Nodes (1): Glorbo.CLI.PathTransforms

### Community 83 - "Community 83"
Cohesion: 0.67
Nodes (1): Glorbo.CLI.Parsers.None

### Community 84 - "Community 84"
Cohesion: 0.67
Nodes (1): GlorboWeb.ErrorJSON

### Community 85 - "Community 85"
Cohesion: 0.67
Nodes (1): GlorboWeb.Components.AgentCard

### Community 86 - "Community 86"
Cohesion: 0.67
Nodes (1): GlorboWeb.Components.TabBar

### Community 87 - "Community 87"
Cohesion: 0.67
Nodes (1): GlorboWeb.Components.HealthDot

### Community 88 - "Community 88"
Cohesion: 0.67
Nodes (1): GlorboWeb.Layouts

### Community 89 - "Community 89"
Cohesion: 0.67
Nodes (1): GlorboWeb.Components.StatusPill

### Community 90 - "Community 90"
Cohesion: 0.67
Nodes (1): GlorboWeb.Components.StatCard

### Community 91 - "Community 91"
Cohesion: 1.0
Nodes (1): Glorbo

### Community 92 - "Community 92"
Cohesion: 1.0
Nodes (1): Glorbo.Repo

### Community 93 - "Community 93"
Cohesion: 1.0
Nodes (1): Glorbo.Company

### Community 94 - "Community 94"
Cohesion: 1.0
Nodes (1): Glorbo.AuditEvent

### Community 95 - "Community 95"
Cohesion: 1.0
Nodes (1): Glorbo.Agent

### Community 96 - "Community 96"
Cohesion: 1.0
Nodes (1): Glorbo.Agent.Spec

### Community 97 - "Community 97"
Cohesion: 1.0
Nodes (1): Glorbo.Filesystem.ReindexState

### Community 98 - "Community 98"
Cohesion: 1.0
Nodes (1): Glorbo.CLI.Audit

### Community 99 - "Community 99"
Cohesion: 1.0
Nodes (1): GlorboWeb.Endpoint

### Community 100 - "Community 100"
Cohesion: 1.0
Nodes (1): GlorboWeb.Router

### Community 101 - "Community 101"
Cohesion: 1.0
Nodes (1): GlorboWeb.MCP.Tool

### Community 102 - "Community 102"
Cohesion: 1.0
Nodes (1): Gep.Record

## Knowledge Gaps
- **12 isolated node(s):** `Glorbo`, `Glorbo.Repo`, `Glorbo.Company`, `Glorbo.AuditEvent`, `Glorbo.Agent` (+7 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Community 29`** (28 nodes): `parser.ex`, `Glorbo.Agent.Parser`, `default_egress()`, `derive_company()`, `derive_slug()`, `parse_egress_mode()`, `parse_host_list()`, `parse_icon()`, `parse_reports_to()`, `parse_smart_model()`, `parse_untracked()`, `read_file()`, `reject_agents_create()`, `validate_autonomy()`, `validate_budget()`, `validate_egress()`, `validate_heartbeat()`, `validate_max_retries()`, `validate_model()`, `validate_models_aliases()`, `validate_network()`, `validate_one_permission()`, `validate_one_skill()`, `validate_permissions()`, `validate_provider()`, `validate_skills()`, `validate_slug()`, `validate_timeout()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 44`** (7 nodes): `GlorboWeb.Components.CompanyCard`, `agent_label()`, `alert_label()`, `company_card()`, `goal_label()`, `progress_state()`, `company_card.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 45`** (6 nodes): `heartbeat_md.ex`, `Glorbo.FileSpec.HeartbeatMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 46`** (6 nodes): `soul_md.ex`, `Glorbo.FileSpec.SoulMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 47`** (6 nodes): `memory_index_md.ex`, `Glorbo.FileSpec.MemoryIndexMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 48`** (6 nodes): `sentinel_approval_md.ex`, `Glorbo.FileSpec.SentinelApprovalMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 49`** (6 nodes): `sentinel_stuck_md.ex`, `Glorbo.FileSpec.SentinelStuckMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 50`** (6 nodes): `sentinel_resolution_md.ex`, `Glorbo.FileSpec.SentinelResolutionMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 51`** (6 nodes): `Glorbo.FileSpec.BraindumpMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`, `braindump_md.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 52`** (6 nodes): `Glorbo.FileSpec.ChannelLogMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`, `channel_log_md.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 53`** (6 nodes): `inbox_archive_json.ex`, `Glorbo.FileSpec.InboxArchiveJson`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 54`** (6 nodes): `Glorbo.FileSpec.AuditMonthJsonl`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`, `audit_month_jsonl.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 55`** (6 nodes): `memory_entry_md.ex`, `Glorbo.FileSpec.MemoryEntryMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 56`** (6 nodes): `skill_md.ex`, `Glorbo.FileSpec.SkillMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 57`** (6 nodes): `Glorbo.FileSpec.EmergencyStopMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`, `emergency_stop_md.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 58`** (6 nodes): `inbox_message_md.ex`, `Glorbo.FileSpec.InboxMessageMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 59`** (6 nodes): `goal_md.ex`, `Glorbo.FileSpec.GoalMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 60`** (6 nodes): `Glorbo.FileSpec.ConfigMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`, `config_md.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 61`** (6 nodes): `task_md.ex`, `Glorbo.FileSpec.TaskMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 62`** (6 nodes): `project_md.ex`, `Glorbo.FileSpec.ProjectMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 63`** (6 nodes): `Glorbo.FileSpec.CompanyMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`, `company_md.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 64`** (6 nodes): `path_request_md.ex`, `Glorbo.FileSpec.PathRequestMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 65`** (6 nodes): `proposal_md.ex`, `Glorbo.FileSpec.ProposalMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 66`** (6 nodes): `task_comments_md.ex`, `Glorbo.FileSpec.TaskCommentsMd`, `canonical_key_order()`, `docs()`, `frontmatter_schema()`, `kind()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 67`** (5 nodes): `Glorbo.Agent.FileLayout`, `agent_md_candidates()`, `agent_md_canonical()`, `heartbeat_md()`, `file_layout.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 69`** (5 nodes): `icon.ex`, `GlorboWeb.Components.Icon`, `glyph()`, `icon()`, `missing?()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 70`** (5 nodes): `stdout_tail.ex`, `GlorboWeb.Components.StdoutTail`, `exit_code_class()`, `stdout_line()`, `stdout_tail()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 72`** (5 nodes): `GlorboWeb.Components.ChatDrawer`, `chat_drawer()`, `director?()`, `short_ts()`, `chat_drawer.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 73`** (4 nodes): `Glorbo.CLI.DoctorFix`, `help_text()`, `run()`, `doctor_fix.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 74`** (4 nodes): `Glorbo.CLI.Parsers.GeminiStdout`, `parse()`, `reduce_models()`, `gemini_stdout.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 75`** (4 nodes): `provider.ex`, `Glorbo.CLI.Registry.Provider`, `prompt_modes()`, `status()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 78`** (4 nodes): `task_detail_form.ex`, `GlorboWeb.Components.TaskDetailForm`, `linkify_body()`, `task_detail_form()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 79`** (4 nodes): `task_card.ex`, `GlorboWeb.Components.TaskCard`, `recurring?()`, `task_card()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 80`** (3 nodes): `init.ex`, `Glorbo.Init`, `run()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 81`** (3 nodes): `Glorbo.Budget`, `changeset()`, `budget.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 82`** (3 nodes): `path_transforms.ex`, `Glorbo.CLI.PathTransforms`, `known?()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 83`** (3 nodes): `none.ex`, `Glorbo.CLI.Parsers.None`, `parse()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 84`** (3 nodes): `GlorboWeb.ErrorJSON`, `render()`, `error_json.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 85`** (3 nodes): `GlorboWeb.Components.AgentCard`, `agent_card()`, `agent_card.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 86`** (3 nodes): `tab_bar.ex`, `GlorboWeb.Components.TabBar`, `tab_bar()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 87`** (3 nodes): `health_dot.ex`, `GlorboWeb.Components.HealthDot`, `health_dot()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 88`** (3 nodes): `layouts.ex`, `GlorboWeb.Layouts`, `on_mount()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 89`** (3 nodes): `status_pill.ex`, `GlorboWeb.Components.StatusPill`, `status_pill()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 90`** (3 nodes): `stat_card.ex`, `GlorboWeb.Components.StatCard`, `stat_card()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 91`** (2 nodes): `glorbo.ex`, `Glorbo`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 92`** (2 nodes): `repo.ex`, `Glorbo.Repo`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 93`** (2 nodes): `Glorbo.Company`, `company.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 94`** (2 nodes): `Glorbo.AuditEvent`, `audit_event.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 95`** (2 nodes): `Glorbo.Agent`, `agent.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 96`** (2 nodes): `spec.ex`, `Glorbo.Agent.Spec`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 97`** (2 nodes): `reindex_state.ex`, `Glorbo.Filesystem.ReindexState`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 98`** (2 nodes): `Glorbo.CLI.Audit`, `audit.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 99`** (2 nodes): `GlorboWeb.Endpoint`, `endpoint.ex`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 100`** (2 nodes): `router.ex`, `GlorboWeb.Router`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 101`** (2 nodes): `tool.ex`, `GlorboWeb.MCP.Tool`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 102`** (2 nodes): `record.ex`, `Gep.Record`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `read()` connect `Community 1` to `Community 0`, `Community 3`, `Community 4`, `Community 5`, `Community 6`, `Community 7`, `Community 8`, `Community 9`, `Community 10`, `Community 11`, `Community 12`, `Community 13`, `Community 14`, `Community 15`, `Community 16`, `Community 17`, `Community 19`, `Community 20`, `Community 21`, `Community 22`, `Community 23`, `Community 25`, `Community 26`, `Community 27`, `Community 28`, `Community 29`, `Community 33`, `Community 34`, `Community 35`, `Community 37`, `Community 41`, `Community 43`?**
  _High betweenness centrality (0.181) - this node is a cross-community bridge._
- **Why does `default_root()` connect `Community 2` to `Community 1`, `Community 3`, `Community 4`, `Community 5`, `Community 6`, `Community 7`, `Community 8`, `Community 9`, `Community 10`, `Community 11`, `Community 12`, `Community 13`, `Community 14`, `Community 15`, `Community 17`, `Community 18`, `Community 19`, `Community 21`, `Community 22`, `Community 24`, `Community 27`, `Community 30`, `Community 33`, `Community 34`, `Community 37`, `Community 38`, `Community 41`, `Community 43`?**
  _High betweenness centrality (0.149) - this node is a cross-community bridge._
- **Why does `parse()` connect `Community 7` to `Community 0`, `Community 1`, `Community 2`, `Community 3`, `Community 4`, `Community 5`, `Community 6`, `Community 9`, `Community 10`, `Community 11`, `Community 12`, `Community 13`, `Community 14`, `Community 16`, `Community 17`, `Community 18`, `Community 20`, `Community 21`, `Community 22`, `Community 24`, `Community 25`, `Community 26`, `Community 28`, `Community 30`, `Community 32`, `Community 34`, `Community 35`, `Community 43`?**
  _High betweenness centrality (0.148) - this node is a cross-community bridge._
- **Are the 111 inferred relationships involving `read()` (e.g. with `parse_title()` and `scan_audit()`) actually correct?**
  _`read()` has 111 INFERRED edges - model-reasoned connections that need verification._
- **Are the 94 inferred relationships involving `parse()` (e.g. with `run_cli()` and `run_cli()`) actually correct?**
  _`parse()` has 94 INFERRED edges - model-reasoned connections that need verification._
- **Are the 77 inferred relationships involving `default_root()` (e.g. with `run()` and `run()`) actually correct?**
  _`default_root()` has 77 INFERRED edges - model-reasoned connections that need verification._
- **What connects `Glorbo`, `Glorbo.Repo`, `Glorbo.Company` to the rest of the system?**
  _12 weakly-connected nodes found - possible documentation gaps or missing edges._