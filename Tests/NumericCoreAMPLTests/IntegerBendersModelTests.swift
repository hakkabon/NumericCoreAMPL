import NumericCoreOptimization
import XCTest
@testable import NumericCoreAMPL

final class IntegerBendersModelTests: XCTestCase {
    func testIndexedIntegerBendersMatchesExtensiveMILPInSourceCoordinates() throws {
        let first = try AMPLParser.parse("""
            set DEPOTS := north;
            var open {d in DEPOTS} >= 0, <= 1 integer;
            maximize investment: 10 - 2 open[north];
            """)
        let scenarios = try [2, 4].map { demand in
            let recourse = try AMPLParser.parse("""
                var plan >= 0, <= 1;
                var spot >= 0, <= 4 integer;
                subject to service: spot + 3 plan >= \(demand);
                maximize operating: 1 - 5 spot;
                """)
            return BendersModelScenario(name: "demand\(demand)", probability: 0.5, model: recourse,
                                        sharedVariables: ["plan": "open[north]"])
        }
        let model = BendersModel(firstStage: first, scenarios: scenarios)
        XCTAssertThrowsError(try model.compile()) {
            XCTAssertEqual($0 as? BendersModelError, .integerVariables)
        }
        let compiled = try model.compileInteger()
        XCTAssertEqual(compiled.problem.firstStage.isInteger, [true])
        XCTAssertEqual(compiled.problem.scenarios.map { $0.recourse.isInteger }, [[true], [true]])
        let extensive = try compiled.extensiveForm()
        XCTAssertEqual(extensive.isInteger, [true, true, true])

        let solve = try SparseLinearSolver.solve(extensive, configuration: .branchAndBound(.init()))
        XCTAssertEqual(solve.status, .optimal)
        let reference = try compiled.namedExtensiveSolution(point: solve.variableValues,
                                                            objective: solve.objectiveValue)
        let result = try compiled.solve()
        XCTAssertEqual(result.numericalResult.termination, .converged)
        XCTAssertEqual(reference.objective, 6.5, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(result.lowerBound), reference.objective, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(result.upperBound), reference.objective, accuracy: 1e-8)
        let incumbent = try XCTUnwrap(result.incumbent)
        XCTAssertEqual(incumbent.firstStage, ["open[north]": 1])
        XCTAssertEqual(incumbent.scenarios.map(\.variables),
                       [["plan": 1, "spot": 0], ["plan": 1, "spot": 1]])
        XCTAssertEqual(incumbent.scenarios.map(\.objective), [1, -4])
    }

    func testIntegerAliasCannotSilentlyTightenAContinuousMaster() throws {
        let first = try AMPLParser.parse("var x >= 0, <= 1; minimize investment: x;")
        let second = try AMPLParser.parse("var plan >= 0, <= 1 integer; minimize operating: plan;")
        let model = BendersModel(firstStage: first, scenarios: [
            .init(name: "second", probability: 1, model: second, sharedVariables: ["plan": "x"])
        ])
        XCTAssertThrowsError(try model.compileInteger()) {
            XCTAssertEqual($0 as? IntegerBendersModelError, .incompatibleSharedIntegrality(scenario: "second", name: "plan"))
        }
    }
}
