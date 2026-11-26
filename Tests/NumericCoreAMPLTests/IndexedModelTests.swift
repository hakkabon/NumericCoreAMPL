import NumericCoreOptimization
import XCTest
@testable import NumericCoreAMPL

final class IndexedModelTests: XCTestCase {
    func testIndexedCapacityPlanningMatchesTheExtensiveForm() throws {
        let compiled = try IndexedCapacityPlanning.build(scenarioCount: 8)
        XCTAssertEqual(compiled.firstStageVariables, (0..<8).map { "buy[\($0)]" })
        let extensive = try SparseLinearSolver.solve(compiled.extensiveForm(), configuration: .simplex())
        XCTAssertEqual(extensive.status, .optimal)
        let reference = try compiled.namedExtensiveSolution(point: extensive.variableValues,
                                                             objective: extensive.objectiveValue)
        XCTAssertEqual(reference.objective, 4432.875, accuracy: 1e-7)
        let result = try compiled.solve(options: .init(cutStrategy: .single, maxIterations: 60,
                                                        relativeGapTolerance: 1e-5))
        let incumbent = try XCTUnwrap(result.incumbent)
        XCTAssertEqual(result.numericalResult.termination, .converged)
        XCTAssertEqual(incumbent.objective, reference.objective, accuracy: 1e-7)
        for scenario in incumbent.scenarios {
            XCTAssertEqual(scenario.variables["plan[0]"], incumbent.firstStage["buy[0]"])
            XCTAssertNotNil(scenario.variables["ship[0,0]"])
        }
    }

    func testProductsFiltersAndEmptySumsKeepDeclarationOrder() throws {
        let model = try AMPLParser.parse("""
            set I := west east;
            set J := 2 -1;
            set EMPTY := ;
            param cap {i in I} := west 4 east 6;
            var x {i in I, j in J} >= 0, <= cap[i] integer;
            var sum >= 0;
            subject to capRow {i in I}:
                sum {j in J : j = 2} (x[i,j] + 2 x[i,-1]) <= cap[i];
            minimize total:
                sum {i in I} sum {j in J} x[i,j] + sum {t in EMPTY} x[t,2] + sum;
            """)
        XCTAssertEqual(model.variableNames, ["x[west,2]", "x[west,-1]", "x[east,2]", "x[east,-1]", "sum"])
        XCTAssertEqual(model.variableBounds.map(\.upper), [4, 4, 6, 6, nil])
        XCTAssertEqual(model.variableIsInteger, [true, true, true, true, false])
        XCTAssertEqual(model.constraints.map(\.name), ["capRow[west]", "capRow[east]"])
        XCTAssertEqual(model.constraints[0].lhs.coefficients, [0: 1, 1: 2])
        XCTAssertEqual(model.constraints[1].lhs.coefficients, [2: 1, 3: 2])
        let objective = try XCTUnwrap(model.objective?.expression)
        XCTAssertEqual(objective.coefficients, [0: 1, 1: 1, 2: 1, 3: 1, 4: 1])
    }

    func testMalformedIndexedModelsAreRejected() {
        let sources = [
            "set I := a a;",
            "set I := a (b,c);",
            "set I := 9007199254740993;",
            "var x {i in missing};",
            "set I := (a,b); var x {i in I};",
            "set I := a; var x {i in I, i in I};",
            "set I := a b; param p {i in I} := a 1;",
            "set I := a; param p {i in I} := b 1;",
            "set I := a; param p {i in I} := a 1 a 2;",
            "set I := a; var x {i in I}; minimize o: x[b];",
            "set I := a; var x {i in I}; minimize o: x[a,a];",
            "set E := ; minimize o: sum {i in E} missing[i];",
        ]
        for source in sources {
            XCTAssertThrowsError(try AMPLParser.parse(source), source) { error in
                XCTAssertTrue(error is AMPLParseError, "\(source): \(error)")
            }
        }
    }

    func testIndexedNonlinearExpressionUsesTheExistingGraphCompiler() throws {
        let model = try AMPLParser.parse("""
            set I := red blue;
            param target {i in I} := red 2 blue 3;
            var x {i in I} >= 0, <= 10;
            minimize loss: sum {i in I} (x[i] - target[i])^2;
            """)
        let problem = try model.compileNonlinear()
        let result = try problem.solve(initial: [0, 0], configuration: .automatic(backend: .swift))
        XCTAssertEqual(result.status, .converged)
        XCTAssertEqual(result.variableValuesByName["x[red]"] ?? .nan, 2, accuracy: 1e-7)
        XCTAssertEqual(result.variableValuesByName["x[blue]"] ?? .nan, 3, accuracy: 1e-7)
    }
}

/// Only scenario data is generated. The same indexed algebra is parsed for
/// every scenario and the row and column order matches the scalar study.
enum IndexedCapacityPlanning {
    static let pairs = (0..<8).flatMap { region in
        [region, region ^ 1, (region + 2) % 8].enumerated().map { (order, depot) in
            (depot: depot, region: region, cost: 3 + order * 3 + depot % 2)
        }
    }
    static let depots = "set DEPOTS := 0 1 2 3 4 5 6 7;"
    static let firstStage = """
        \(depots)
        param reserve {d in DEPOTS} := 0 17 1 19 2 18 3 21 4 17 5 20 6 18 7 22;
        var buy {d in DEPOTS} >= 0, <= 22;
        subject to budget: sum {d in DEPOTS} buy[d] <= 94;
        minimize investment: sum {d in DEPOTS} reserve[d] * buy[d];
        """
    static let recourse = """
        \(depots)
        set REGIONS := 0 1 2 3 4 5 6 7;
        set ROUTES := \(pairs.map { "(\($0.depot),\($0.region))" }.joined(separator: " "));
        param installed {d in DEPOTS} := 0 13 1 11 2 12 3 10 4 14 5 10 6 13 7 11;
        param penalty {r in REGIONS} := 0 82 1 91 2 85 3 95 4 88 5 96 6 84 7 92;
        param freight {(d,r) in ROUTES} :=
            \(pairs.map { "[\($0.depot),\($0.region)] \($0.cost)" }.joined(separator: " "));
        """

    static func build(scenarioCount: Int) throws -> CompiledBendersModel {
        let first = try AMPLParser.parse(firstStage)
        let aliases = Dictionary(uniqueKeysWithValues: (0..<8).map { ("plan[\($0)]", "buy[\($0)]") })
        var seed: UInt64 = 0xa31d_2026
        func draw(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(bound))
        }
        let base = [22, 17, 25, 19, 23, 15, 20, 18]
        let scenarios = try (0..<scenarioCount).map { scenario in
            let weather = draw(9)
            let district = draw(4)
            let disrupted = scenario % 5 == 0 ? draw(8) : -1
            let limits = pairs.map { route in
                let limit = disrupted == route.depot ? 5 + route.region % 3 : 75
                return "[\(route.depot),\(route.region)] \(limit)"
            }.joined(separator: " ")
            let demand = base.enumerated().map { (region, amount) in
                let value = amount + weather + draw(9) - 4 + (region / 2 == district ? weather : 0)
                return "\(region) \(value)"
            }.joined(separator: " ")
            let model = try AMPLParser.parse("""
                \(recourse)
                param limit {(d,r) in ROUTES} := \(limits);
                param demand {r in REGIONS} := \(demand);
                var plan {d in DEPOTS} >= 0;
                var short {r in REGIONS} >= 0, <= 75;
                var ship {(d,r) in ROUTES} >= 0, <= limit[d,r];
                subject to capacity {d in DEPOTS}:
                    sum {(o,r) in ROUTES : o = d} ship[o,r] - plan[d] <= installed[d];
                subject to demandRow {r in REGIONS}:
                    sum {(d,k) in ROUTES : k = r} ship[d,k] + short[r] = demand[r];
                minimize operating:
                    sum {(d,r) in ROUTES} freight[d,r] * ship[d,r]
                    + sum {r in REGIONS} penalty[r] * short[r];
                """)
            return BendersModelScenario(name: "scenario_\(scenario)", probability: 1 / Double(scenarioCount),
                                        model: model, sharedVariables: aliases)
        }
        return try BendersModel(firstStage: first, scenarios: scenarios).compile()
    }
}
