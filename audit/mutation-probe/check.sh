#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
# SPDX-License-Identifier: LicenseRef-DCL-1.0
# Mutation-probe suite. forge rebuilds on every run, so the mutated source is
# what runs. A fixed fuzz seed keeps the fork's account set identical across
# probes (the local anvil cache stays warm), and any RPC failure prints no tally
# so the probe scores it NO-RUN instead of a false KILL.
export BASE_RPC_URL="${BASE_RPC_URL:-http://127.0.0.1:8547}"
export FOUNDRY_FUZZ_SEED=0x5eed FOUNDRY_INVARIANT_SHRINK_RUN_LIMIT=0 FOUNDRY_FUZZ_RUNS=256 FOUNDRY_INVARIANT_RUNS=16 FOUNDRY_INVARIANT_DEPTH=32
out=$(forge test 2>&1); rc=$?
if printf '%s' "$out" | grep -qE "error sending request|operation timed out|Too Many Requests|failed to get account"; then
  printf '%s\n' "$out" | grep -E "error sending request|timed out|Too Many" | head -3
  echo "RPC failure: refusing to score this run"
  exit 2
fi
printf '%s\n' "$out"
exit $rc
