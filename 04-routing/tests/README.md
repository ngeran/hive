# JSNAPy tests

Host-side state verification for the fabric, run over NETCONF through the
per-node NodePort Services (32001–32010) by `just verify`. Both starter
suites pass on all 10 nodes (2026-09-07).

## Run

```bash
just verify                        # every tests/*.yml, all 10 nodes
just verify intf-basic             # just that file (name = file minus .yml)
```

Exit code is non-zero if any test fails — chain it after `just load-configs`
to prove a milestone actually stuck. `just verify` also auto-seeds
`~/.jsnapy/` on first use (jsnapy needs its `jsnapy.cfg` + `logging.yml`).

## Writing tests

**Format gotchas — all hit the hard way in one afternoon:**

- A test file holds one or more top-level `test_<name>` suites. The main
  file (which `just verify` generates) references suites **by file name** —
  inline test dicts give a cryptic `stat: path should be string, not dict`.
- **Operands are not YAML.** jsnapy splits the `xpath, operand` line itself
  and does **not** strip quotes — write `regex: host-name, ^P-1$`, never
  `regex: host-name, '^P-1$'` (the quote chars silently become part of the
  pattern, and an inline `(?i)` then lands at "position 1" → `PatternError`).
- **No backslashes in operands** (`\d`, `\s`, …): jsnapy formats its
  pass/fail messages by `re.sub`-ing the operands themselves, and a
  backslash there is a hard `re.error` on Python 3.12+. Write `[0-9]`.
- **Unknown operators crash late**: jsnapy has `regex`, not `match` — an
  unknown op records nothing and later dies with `IndexError` in
  `expression_builder`, far from the real mistake.
- **No xpath predicates/functions**: `//physical-interface[oper-status]`
  finds zero nodes ("Nodes are not present in given Xpath"). Plain node
  paths only.
- `ignore-null: True` on an operator skips (not fails) items where the
  tested node is absent.

Example milestone suite (day1 IS-IS), using only proven constructs:

```yaml
test_isis_adjacencies:
  - command: show isis adjacency
  - iterate:
      xpath: //isis-adjacency
      id: ./interface-name
      tests:
        - is-equal: adjacency-state, Up
          ignore-null: True
          info: adjacency up
          err: FAIL - adjacency down
```

Dump the real XML once (`just cli p1 "show isis adjacency | display xml"`)
and take xpaths from it — don't guess element names. BGP established:
iterate `//bgp-peer` on `show bgp summary`, `is-equal: peer-state, Established`.

## cRPD XML quirks (verified against snapshot XML)

- `show interfaces terse` puts `<oper-status>` on the **logical** units
  (`ethN.0`, `lsi.0`, …) only — `<physical-interface>` elements carry just
  `<name>` and nested units. Iterate `//physical-interface/logical-interface`
  for link state (see `intf-basic.yml`).
- Hostnames are P-1..P-4 / PE-1,2 / RR-1,2 but the CEs are lowercase `ce1`,
  `ce2` — hostname assertions must accept both.
- Element values may carry surrounding newlines; anchors (`^…$`) still
  matched in practice, but prefer alternations over `^…$` if a value ever
  gains padding.
- Config that lives under a group shows up only via `show configuration`
  (full dump); a subtree like `show configuration system` can be empty.
