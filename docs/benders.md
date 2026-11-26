# Two-stage Benders models

`BendersModel` composes existing NumericCoreAMPL models into a
two-stage linear problem. Call `compile()` for the continuous path. Build each block with `Model` or parse it with
`AMPLParser.parse`. Attach the scenario probability and declare which
scenario variables refer to first-stage variables when constructing
`BendersModelScenario`.

```swift
import NumericCoreAMPL

let firstStage = try AMPLParser.parse("""
    var capacity >= 0, <= 10;
    minimize investment: 1.5 * capacity;
    """)

func demandScenario(_ name: String, probability: Double, demand: Int) throws -> BendersModelScenario {
    let block = try AMPLParser.parse("""
        var plan >= 0;
        var extra >= 0;
        subject to demand: plan + extra >= \(demand);
        minimize operating: 4 * extra;
        """)
    return .init(name: name, probability: probability, model: block,
                 sharedVariables: ["plan": "capacity"])
}

let compiled = try BendersModel(firstStage: firstStage, scenarios: [
    demandScenario("normal", probability: 0.8, demand: 2),
    demandScenario("peak", probability: 0.2, demand: 6),
]).compile()
let result = try compiled.solve()
let capacity = result.incumbent?.firstStage["capacity"]
```

Each scenario name must be unique. Positive scenario probabilities must sum
to one. An alias inherits its first-stage variable's bounds. Any finite bound
declared on the alias must match the corresponding first-stage bound. Use a
scenario row for additional restrictions on that alias. All objectives use
the same sense. The compiler folds weighted shared objective coefficients
into the master and preserves objective constants separately. Named results
include private variables and shared aliases, with objective values and bounds
converted back to the original objective sense. Convergence diagnostics in
`numericalResult` use the normalized solver objective.

Use `extensiveForm()` to solve the same compiled model as a single sparse LP.
Use `namedExtensiveSolution(point:objective:)` to decode its numerical result.
Pass `compiled.problem` to `DistributedBendersCoordinator` to use the same
lowering with remote workers. Decode a distributed incumbent with
`namedIncumbent(_:)` and convert its bounds with `sourceBounds(lower:upper:)`.

The minimum supported pairing for all three solve paths is Swift-NumericCore
**2.0.0** with its pinned Rust-NumericCore **v0.45.1** XCFramework.
SwiftPM obtains the Rust binary through Swift-NumericCore. The extensive form
uses the simplex bridge, and the integration test requires both local and
distributed Benders. It compares their incumbents and bounds in source
objective coordinates and replays the distributed proof for both objective
senses.

Run `env -u NUMERICCORE_PACKAGE_PATH swift test` in a clean checkout to
validate with the normal remote dependency. Before the Swift release is
tagged, use the same GitHub URL with the exact candidate commit as the
`revision:` requirement in a disposable copy of the manifest.

Textual decomposition annotations are a later frontend extension.

## Indexed capacity planning

Each stage can use [finite indexed declarations](ampl-grammar.md#finite-indexed-models).
The capacity model declares depots, regions, and route tuples, then uses
filtered sums for depot capacity and regional demand. Scenario data supplies
demand and route limits. A typed scenario maps expanded names such as
`plan[0]` to `buy[0]` using the existing `sharedVariables` dictionary.
The [capacity regression](../Tests/NumericCoreAMPLTests/IndexedModelTests.swift)
contains the eight-depot model and reproduces the extensive-form objective
of 4432.875.

## Mixed-integer stages

Call `compileInteger()` on the same typed partition to keep integrality in
the first stage and private scenario variables. Use the returned
`CompiledIntegerBendersModel.solve()` for native integer Benders or solve
its `extensiveForm()` by branch-and-bound as a reference. Named incumbents
and bounds use source objective coordinates for both objective senses.

An alias inherits first-stage integrality. An explicitly integer alias
must refer to an integer master variable. Native integer Benders requires
finite bounds on integer variables, and integer recourse can be coupled
only to binary master columns.
