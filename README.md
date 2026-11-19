# NumericCoreAMPL

A Swift frontend for a subset of AMPL-style modeling syntax. It owns parsing,
the symbolic model, and lowering to linear, mixed-integer and nonlinear
numerical problems. Swift-NumericCore provides the numerical solvers.

Clients migrating from the bundled product keep `import NumericCoreAMPL`
and select that product from this package. Its published dependency requires
Swift-NumericCore 2.0.0 or later in the 2.x series. To test with an unreleased
checkout, run:

```sh
NUMERICCORE_PACKAGE_PATH=/path/to/Swift-NumericCore swift test
```

For the supported syntax and examples, see [Grammar](docs/ampl-grammar.md).
