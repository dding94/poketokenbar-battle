#!/usr/bin/env node
// Creates the first group on a deployed league and prints the host's recovery code.
// Node 24, no dependencies.
//
//   read -rs OPERATOR_SECRET; export OPERATOR_SECRET
//   node server/scripts/bootstrap-group.mjs <baseUrl> <groupName> <hostNickname>
//
// The group id, host trainer id and recovery code go to the terminal once. The access key and
// the operator secret are never printed, written to a file or put in a URL.

import process from "node:process";
import { bootstrapGroup, parseArgs } from "./bootstrap-group-lib.mjs";

let options;
try {
  options = parseArgs(process.argv.slice(2), process.env);
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : "invalid arguments"}\n`);
  process.exit(2);
}

const result = await bootstrapGroup(options, fetch);
(result.ok ? process.stdout : process.stderr).write(`${result.text}\n`);
process.exit(result.ok ? 0 : 1);
