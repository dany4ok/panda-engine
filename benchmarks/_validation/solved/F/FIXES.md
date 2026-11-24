Root causes identified and fixed:

- mean: divisor was len(vals)-1 (sample mean) instead of len(vals) -> population mean.
- median: returned the middle element of the unsorted input; now sorts first.
- percentile: index used len(vals) causing off-by-one and out-of-range at 100; now len(vals)-1.
- report: summarize read the wrong key "value" instead of "score"; empty input now returns zeros.
- cli: parsing skipped argv[0] with argv[1:], dropping the first number.
- help: --help was not handled; now prints usage and returns 0.
