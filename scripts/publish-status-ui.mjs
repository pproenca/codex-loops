#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";

const publishCommand = findPublishCommand();
const args = ["-C", "apps/status-ui", "publish", "--access", "public"];

for (const flag of ["--dry-run", "--no-git-checks", "--force"]) {
  if (hasFlag(publishCommand, flag)) args.push(flag);
}

for (const option of ["--otp", "--tag", "--registry"]) {
  const value = optionValue(publishCommand, option);
  if (value !== undefined) args.push(option, value);
}

const result = spawnSync("pnpm", args, { stdio: "inherit" });
process.exit(result.status ?? 1);

function findPublishCommand() {
  const rows = execFileSync("ps", ["-axo", "pid=,ppid=,command="], { encoding: "utf8" })
    .trim()
    .split("\n")
    .map((line) => {
      const match = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
      return match === null ? undefined : { pid: Number(match[1]), ppid: Number(match[2]), command: match[3] };
    })
    .filter((row) => row !== undefined);
  const byPid = new Map(rows.map((row) => [row.pid, row]));
  for (let current = byPid.get(process.pid); current !== undefined; current = byPid.get(current.ppid)) {
    if (/\bpnpm(?:\.mjs)?\s+publish\b/.test(current.command)) return current.command;
  }
  return "";
}

function hasFlag(command, flag) {
  return new RegExp(`(^|\\s)${escapeRegExp(flag)}(\\s|$)`).test(command);
}

function optionValue(command, option) {
  const match = command.match(new RegExp(`(^|\\s)${escapeRegExp(option)}(?:=|\\s+)(?:"([^"]+)"|'([^']+)'|(\\S+))`));
  return match?.[2] ?? match?.[3] ?? match?.[4];
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
