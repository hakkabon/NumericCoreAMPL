import NumericCoreOptimization
import XCTest
@testable import NumericCoreAMPL

final class BendersModelTests: XCTestCase {
    private func fixture(maximize: Bool = false, shared: [String: String] = ["plan": "capacity"],
                         sharedBound: Double = 0) throws -> BendersModel {
        let sense = maximize ? "maximize" : "minimize"
        let sign = maximize ? "-" : ""
        let first = try AMPLParser.parse("""
            var capacity >= 0, <= 10;
            \(sense) investment: \(sign)capacity + 5;
            """)
        let scenarios = try [("normal", 0.8, 2), ("peak", 0.2, 6)].map { name, weight, demand in
            let recourse = try AMPLParser.parse("""
                var extra >= 0, <= 10;
                var plan >= \(sharedBound);
                subject to demand: extra + plan >= \(demand);
                \(sense) operating: \(sign)(4 * extra + 0.5 * plan) + 2;
                """)
            return BendersModelScenario(name: name, probability: weight, model: recourse, sharedVariables: shared)
        }
        return .init(firstStage: first, scenarios: scenarios)
    }

    func testParsedBlocksMatchTheExtensiveAndDecomposedSolutions() throws {
        for maximize in [false, true] {
            let compiled = try fixture(maximize: maximize).compile()
            XCTAssertEqual(compiled.problem.firstStage.objective, [1.5])
            XCTAssertEqual(compiled.problem.scenarios.first?.coupling.csrValues, [1])
            let extensive = try SparseLinearSolver.solve(compiled.extensiveForm(), configuration: .simplex())
            XCTAssertEqual(extensive.status, .optimal)
            let point = try compiled.namedExtensiveSolution(point: extensive.variableValues, objective: extensive.objectiveValue)
            let expected = maximize ? 0.8 : 13.2
            XCTAssertEqual(point.objective, expected, accuracy: 1e-8)
            XCTAssertEqual(try XCTUnwrap(point.firstStage["capacity"]), 2, accuracy: 1e-8)
            XCTAssertEqual(point.scenarios.map(\.name), ["normal", "peak"])
            XCTAssertEqual(try XCTUnwrap(point.scenarios[1].variables["extra"]), 4, accuracy: 1e-8)
            XCTAssertEqual(try XCTUnwrap(point.scenarios[1].variables["plan"]), 2, accuracy: 1e-8)
            XCTAssertEqual(point.scenarios[1].objective, maximize ? -15 : 19, accuracy: 1e-8)
            let transformed = compiled.sourceBounds(lower: 1, upper: 3)
            XCTAssertEqual(transformed.lower, maximize ? 4 : 8)
            XCTAssertEqual(transformed.upper, maximize ? 6 : 10)
            if BendersSolver.isAvailable {
                let solve = try compiled.solve()
                XCTAssertEqual(solve.numericalResult.termination, .converged)
                XCTAssertEqual(try XCTUnwrap(solve.incumbent).objective, expected, accuracy: 1e-8)
                XCTAssertEqual(try XCTUnwrap(solve.lowerBound), expected, accuracy: 1e-8)
                XCTAssertEqual(try XCTUnwrap(solve.upperBound), expected, accuracy: 1e-8)
            } else {
                XCTAssertThrowsError(try compiled.solve()) {
                    XCTAssertEqual($0 as? LPDecompositionError, .unsupportedFFI)
                }
            }
        }
    }

    func testRejectsUnknownSharedColumnsAndConflictingBounds() throws {
        XCTAssertThrowsError(try fixture(shared: ["plan": "unknown"]).compile()) {
            XCTAssertEqual($0 as? BendersModelError, .unknownSharedVariable(scenario: "normal", name: "unknown"))
        }
        XCTAssertThrowsError(try fixture(sharedBound: 1).compile()) {
            XCTAssertEqual($0 as? BendersModelError, .incompatibleSharedBounds(scenario: "normal", name: "plan"))
        }
        let model = try fixture()
        XCTAssertThrowsError(try BendersModel(firstStage: model.firstStage, scenarios: [model.scenarios[0]]).compile()) {
            XCTAssertEqual($0 as? BendersModelError, .invalidScenarios)
        }
    }

    func testSameLoweringWorksWithDistributedBenders() throws {
        guard DistributedBendersCoordinator.isAvailable else { return }
        let compiled = try fixture().compile()
        let coordinator = try DistributedBendersCoordinator(problem: compiled.problem)
        for _ in 0..<10 {
            guard try coordinator.progress().status == .awaitingReplies else { break }
            for job in try coordinator.pendingJobs().reversed() {
                try coordinator.submit(DistributedBendersCoordinator.executeJob(job.json))
            }
        }
        let proof = try DistributedBendersCoordinator.verify(problem: compiled.problem, proof: coordinator.exportProof())
        XCTAssertEqual(proof.claim, .optimality)
        let incumbent = try compiled.namedIncumbent(XCTUnwrap(proof.incumbent))
        XCTAssertEqual(incumbent.objective, 13.2, accuracy: 1e-8)
    }
}
