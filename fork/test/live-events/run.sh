#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Runs the web live-events behaviour tests with node's built-in test runner (node 22.18 or newer,
# type stripping on by default). No install needed: package imports are stubbed by hooks.mjs.
set -eu
cd "$(dirname "$0")"
exec node --import ./register.mjs --test ./*.test.mjs
