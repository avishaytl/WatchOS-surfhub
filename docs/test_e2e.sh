#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  SPOTEQ Watch – End-to-End integration test
#  Tests the full flow: login → start → ping → record → end
#  Works for any platform (watchOS / Android / curl).
# ─────────────────────────────────────────────────────────────
set -euo pipefail

BASE="https://vvowvcdylztsqpzifdqc.supabase.co"
ANON="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2b3d2Y2R5bHp0c3FwemlmZHFjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTc1NDcsImV4cCI6MjA5MDk5MzU0N30.jPBYr6f9fTABLHAD1rY_b1HP8xI0cDEQPJczxjCKsSY"
EMAIL="${1:-${SPOTEQ_E2E_EMAIL:-}}"
PASSWORD="${2:-${SPOTEQ_E2E_PASSWORD:-}}"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
step() { echo -e "\n${CYAN}▶ $1${NC}"; }

need() { command -v "$1" &>/dev/null || { echo "Missing: $1"; exit 1; }; }
need curl; need jq
[[ -n "$EMAIL" && -n "$PASSWORD" ]] || fail \
  "Pass email/password as arguments or set SPOTEQ_E2E_EMAIL and SPOTEQ_E2E_PASSWORD"

# ── 1. LOGIN ─────────────────────────────────────────────────
step "1. Sign in  ($EMAIL)"
AUTH=$(curl -sf -X POST "$BASE/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}") \
  || fail "Login request failed (check credentials / network)"

JWT=$(echo "$AUTH" | jq -r '.access_token')
USER_ID=$(echo "$AUTH" | jq -r '.user.id')
USER_EMAIL=$(echo "$AUTH" | jq -r '.user.email')
[[ "$JWT" != "null" && -n "$JWT" ]] || fail "No access_token in response:\n$AUTH"
pass "Signed in  email=$USER_EMAIL  uid=$USER_ID"

# ── 2. START SESSION ─────────────────────────────────────────
step "2. Start session  (Tarifa, Spain)"
STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_RESP=$(curl -sf -X POST "$BASE/functions/v1/watch-ingest" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d "{\"type\":\"start\",\"lat\":36.0128,\"lng\":-5.6012,\"startedAt\":\"$STARTED_AT\"}") \
  || fail "Start request failed"

SESS_ID=$(echo "$START_RESP" | jq -r '.sessId')
SPOT=$(echo "$START_RESP" | jq -r '.spot // "unknown"')
[[ "$SESS_ID" != "null" && -n "$SESS_ID" ]] || fail "No sessId in start response:\n$START_RESP"
pass "Session started  sessId=$SESS_ID  spot=\"$SPOT\""

# ── 3. PING ───────────────────────────────────────────────────
step "3. Ping  (position heartbeat)"
PING_RESP=$(curl -sf -X POST "$BASE/functions/v1/watch-ingest" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d "{\"type\":\"ping\",\"sessId\":$SESS_ID,\"lat\":36.0132,\"lng\":-5.6015,\"jmax\":3.2,\"jcnt\":1}") \
  || fail "Ping request failed"

OK=$(echo "$PING_RESP" | jq -r '.ok // false')
[[ "$OK" == "true" ]] || fail "Ping returned ok=false:\n$PING_RESP"
pass "Ping OK"

# ── 4. RECORD (session-best jump) ────────────────────────────
step "4. Record  (new session-best: 4.8 m jump, 3.1 s air)"
RECORD_RESP=$(curl -sf -X POST "$BASE/functions/v1/watch-ingest" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d "{\"type\":\"record\",\"sessId\":$SESS_ID,\"jumpM\":4.8,\"airS\":3.1}") \
  || fail "Record request failed"

BROKEN=$(echo "$RECORD_RESP" | jq -r '.broken | join(", ")')
pass "Record OK  (all-time PBs broken: [${BROKEN:-none}])"

# ── 5. END SESSION ────────────────────────────────────────────
step "5. End session  (72 min, 9 jumps, 41 km/h max)"
END_RESP=$(curl -sf -X POST "$BASE/functions/v1/watch-ingest" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d "{
    \"type\":\"end\",\"sessId\":$SESS_ID,
    \"durMin\":72,\"windKts\":18,\"dir\":\"W\",
    \"jmax\":4.8,\"jcnt\":9,\"airS\":3.1,\"spdKmh\":41,\"distKm\":12.5,\"avgKmh\":24.3,
    \"stars\":4,
    \"track\":[[360128,-56012],[360130,-56014],[360135,-56018]],
    \"jData\":[{\"t\":120,\"h\":480,\"a\":31,\"s\":41,\"d\":21,\"y\":360128,\"x\":-56012}]
  }") \
  || fail "End request failed"

END_OK=$(echo "$END_RESP" | jq -r '.ok // false')
END_BROKEN=$(echo "$END_RESP" | jq -r '.broken | join(", ")')
[[ "$END_OK" == "true" ]] || fail "End returned ok=false:\n$END_RESP"
pass "Session ended  (final PBs broken: [${END_BROKEN:-none}])"

# ── SUMMARY ───────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}ALL STEPS PASSED${NC}"
echo "  User  : $USER_EMAIL  (uid: $USER_ID)"
echo "  Sess  : $SESS_ID  @  $SPOT"
echo ""
echo "  Check in Supabase Dashboard:"
echo "    Table Editor → sessions  (filter uid = $USER_ID)"
echo "    Table Editor → personal_records (filter uid = $USER_ID)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
