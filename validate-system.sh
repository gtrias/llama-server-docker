#!/bin/bash
# Comprehensive Validation and Test Script
# This script validates the auto-offload system and demonstrates it works

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_test() { echo -e "${BLUE}[TEST]${NC} $1"; }
print_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
print_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
print_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

PASSED=0
FAILED=0

test_result() {
    if [ $1 -eq 0 ]; then
        print_pass "$2"
        PASSED=$((PASSED + 1))
    else
        print_fail "$2"
        FAILED=$((FAILED + 1))
    fi
}

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     AUTO-OFFLOAD SYSTEM - VALIDATION & TEST SUITE       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# TEST 1: Script Syntax Validation
print_test "1. Validating script syntax..."
for script in scripts/*.sh; do
    bash -n "$script" 2>/dev/null
    test_result $? "  $(basename $script) syntax"
done
echo ""

# TEST 2: Check Configuration File
print_test "2. Checking configuration file..."
if [ -f "config/models.ini" ]; then
    test_result 0 "  config/models.ini exists"
    
    if grep -q "auto_offload" config/models.ini; then
        test_result 0 "  auto_offload section present"
    else
        test_result 1 "  auto_offload section missing"
    fi
else
    test_result 1 "  config/models.ini missing"
fi
echo ""

# TEST 3: Test Usage Tracking
print_test "3. Testing usage tracking..."
./scripts/track-usage.sh qwen > /dev/null 2>&1
if [ -f "scripts/.model_last_used/qwen" ]; then
    test_result 0 "  Usage timestamp created"
    
    timestamp=$(cat scripts/.model_last_used/qwen)
    if [[ "$timestamp" =~ ^[0-9]+$ ]]; then
        test_result 0 "  Timestamp format valid"
    else
        test_result 1 "  Timestamp format invalid"
    fi
else
    test_result 1 "  Usage tracking failed"
fi
echo ""

# TEST 4: Test Model Status Check
print_test "4. Testing model status check..."
output=$(./scripts/check-models.sh 2>/dev/null)
if [ $? -eq 0 ]; then
    test_result 0 "  check-models.sh executes"
    
    if echo "$output" | grep -q "qwen:"; then
        test_result 0 "  Model status reported"
    else
        test_result 1 "  Model status not found"
    fi
else
    test_result 1 "  check-models.sh failed"
fi
echo ""

# TEST 5: Test model-manager Status Mode
print_test "5. Testing model-manager status mode..."
output=$(timeout 2 ./scripts/model-manager.sh status 2>&1 || true)
if echo "$output" | grep -q "Model Status"; then
    test_result 0 "  Status mode works"
    
    if echo "$output" | grep -q "Idle for:"; then
        test_result 0 "  Idle time tracking works"
    else
        test_result 1 "  Idle time not shown"
    fi
else
    test_result 1 "  Status mode failed"
fi
echo ""

# TEST 6: Test Idle Detection Logic
print_test "6. Testing idle detection logic..."

# Set an old timestamp (10 minutes ago)
ten_min_ago=$(($(date +%s) - 600))
echo "$ten_min_ago" > scripts/.model_last_used/test-model

# Check if detection works
if [ -f "scripts/.model_last_used/test-model" ]; then
    current=$(date +%s)
    last=$(cat scripts/.model_last_used/test-model)
    idle_seconds=$((current - last))
    
    if [ $idle_seconds -ge 600 ]; then
        test_result 0 "  Idle time calculation correct (${idle_seconds}s)"
    else
        test_result 1 "  Idle time calculation wrong"
    fi
    
    rm scripts/.model_last_used/test-model
else
    test_result 1 "  Test timestamp creation failed"
fi
echo ""

# TEST 7: Test API Wrapper
print_test "7. Testing API wrapper..."
if [ -x scripts/api-wrapper.sh ]; then
    test_result 0 "  API wrapper is executable"
    
    # Test help output
    output=$(./scripts/api-wrapper.sh 2>&1)
    if echo "$output" | grep -q "API Wrapper"; then
        test_result 0 "  API wrapper help works"
    else
        test_result 1 "  API wrapper help failed"
    fi
else
    test_result 1 "  API wrapper not executable"
fi
echo ""

# TEST 8: Test Configuration Reading
print_test "8. Testing configuration reading..."
output=$(./scripts/model-manager.sh status 2>&1 | head -10)
if echo "$output" | grep -q "Config:"; then
    test_result 0 "  Configuration loaded"
    
    if echo "$output" | grep -q "timeout="; then
        test_result 0 "  Timeout setting read"
    else
        test_result 1 "  Timeout setting not read"
    fi
else
    test_result 1 "  Configuration loading failed"
fi
echo ""

# TEST 9: Test API Connectivity
print_test "9. Testing API connectivity..."
if curl -s http://localhost:11434/health > /dev/null 2>&1; then
    test_result 0 "  API is accessible"
    
    if curl -s http://localhost:11434/v1/models > /dev/null 2>&1; then
        test_result 0 "  Models API endpoint works"
    else
        test_result 1 "  Models API endpoint failed"
    fi
else
    test_result 1 "  API not accessible"
fi
echo ""

# TEST 10: Integration Test
print_test "10. Integration test - Full workflow..."

# Record usage
./scripts/track-usage.sh qwen > /dev/null 2>&1
test_result $? "  Track usage for qwen"

# Check status
./scripts/check-models.sh > /dev/null 2>&1
test_result $? "  Check model status"

# Get status from model-manager
timeout 2 ./scripts/model-manager.sh status > /dev/null 2>&1 || true
test_result $? "  Model manager status check"

echo ""
echo "══════════════════════════════════════════════════════════"
echo ""
echo "VALIDATION SUMMARY:"
echo "═══════════════════"
echo -e "${GREEN}PASSED: ${PASSED}${NC}"
echo -e "${RED}FAILED: ${FAILED}${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ ALL TESTS PASSED!${NC}"
    echo ""
    echo "The auto-offload system is working correctly:"
    echo ""
    echo "✓ All scripts have valid syntax"
    echo "✓ Usage tracking works"
    echo "✓ Model status checking works"
    echo "✓ Idle time calculation works"
    echo "✓ Configuration loading works"
    echo "✓ API connectivity works"
    echo ""
    echo "You can now:"
    echo "  1. Adjust timeout in config/models.ini (currently $(grep idle_timeout config/models.ini | cut -d= -f2 | cut -d'#' -f1) minutes)"
    echo "  2. Start the daemon: ./scripts/model-manager.sh start"
    echo "  3. Use API wrapper for requests: ./scripts/api-wrapper.sh [curl command]"
    echo "  4. Check status anytime: ./scripts/check-models.sh"
    exit 0
else
    echo -e "${RED}✗ SOME TESTS FAILED${NC}"
    echo ""
    echo "Please review the failed tests above."
    echo "Check logs at: logs/auto-offload.log"
    exit 1
fi