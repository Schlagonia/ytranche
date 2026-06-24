-include .env

# deps
update:; forge update
build  :; forge build
size  :; forge build --sizes

# storage inspection
inspect :; forge inspect ${contract} storageLayout

# if we want to run only matching tests, set that here
test := test_

# Setup chooses fork vs local per test. Invariants override Setup and stay local.
test  :; forge test -vv
trace  :; forge test -vvv
test-invariant :; forge test -vv --match-contract TrancheInvariants
trace-invariant :; forge test -vvv --match-contract TrancheInvariants
test-fork :; forge test -vv
trace-fork:; forge test -vvv
gas  :; forge test --gas-report
test-contract  :; forge test -vv --match-contract $(contract)
test-contract-gas  :; forge test --gas-report --match-contract ${contract}
trace-contract  :; forge test -vvv --match-contract $(contract)
test-test  :; forge test -vv --match-test $(test)
test-test-trace  :; forge test -vvv --match-test $(test)
trace-test  :; forge test -vvvvv --match-test $(test)
snapshot :; forge snapshot -vv
snapshot-diff :; forge snapshot --diff -vv
trace-setup  :; forge test -vvvv
trace-max  :; forge test -vvvvv
coverage :; forge coverage
coverage-report :; forge coverage --report lcov
coverage-debug :; forge coverage --report debug

coverage-html:
	@echo "Running coverage..."
	forge coverage --report lcov
	@if [ "`uname`" = "Darwin" ]; then \
		lcov --ignore-errors inconsistent --remove lcov.info 'src/test/**' --output-file lcov.info; \
		genhtml --ignore-errors inconsistent -o coverage-report lcov.info; \
	else \
		lcov --remove lcov.info 'src/test/**' --output-file lcov.info; \
		genhtml -o coverage-report lcov.info; \
	fi
	@echo "Coverage report generated at coverage-report/index.html"

clean  :; forge clean
