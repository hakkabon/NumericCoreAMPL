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

    func testParsedBlocksAgreeAcrossExtensiveLocalAndDistributedSolves() throws {
        XCTAssertTrue(BendersSolver.isAvailable, "Local Benders requires the matching Rust FFI release")
        XCTAssertTrue(DistributedBendersCoordinator.isAvailable, "Distributed Benders requires the matching Rust FFI release")

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
            let local = try compiled.solve()
            XCTAssertEqual(local.numericalResult.termination, .converged)
            let localIncumbent = try XCTUnwrap(local.incumbent)
            XCTAssertEqual(localIncumbent.objective, point.objective, accuracy: 1e-8)
            XCTAssertEqual(try XCTUnwrap(localIncumbent.firstStage["capacity"]), 2, accuracy: 1e-8)
            XCTAssertEqual(try XCTUnwrap(local.lowerBound), point.objective, accuracy: 1e-8)
            XCTAssertEqual(try XCTUnwrap(local.upperBound), point.objective, accuracy: 1e-8)

            let options = DistributedBendersOptions(maxRounds: 10)
            let coordinator = try DistributedBendersCoordinator(problem: compiled.problem, options: options)
            for _ in 0..<options.maxRounds {
                guard try coordinator.progress().status == .awaitingReplies else { break }
                for job in try coordinator.pendingJobs().reversed() {
                    let reply = try DistributedBendersCoordinator.executeJob(job.json)
                    XCTAssertEqual(try coordinator.submit(reply), .accepted)
                }
            }
            XCTAssertEqual(try coordinator.progress().status, .converged)
            let proof = try coordinator.exportProof()
            let audited = try DistributedBendersCoordinator.verify(
                problem: compiled.problem, proof: proof, options: options)
            XCTAssertEqual(audited.claim, .optimality)
            XCTAssertGreaterThan(audited.verifiedSubproblems, 0)
            let distributedIncumbent = try compiled.namedIncumbent(XCTUnwrap(audited.incumbent))
            XCTAssertEqual(distributedIncumbent.objective, point.objective, accuracy: 1e-8)
            XCTAssertEqual(try XCTUnwrap(distributedIncumbent.firstStage["capacity"]), 2, accuracy: 1e-8)
            let bounds = compiled.sourceBounds(lower: audited.lowerBound, upper: audited.upperBound)
            XCTAssertEqual(try XCTUnwrap(bounds.lower), point.objective, accuracy: 1e-8)
            XCTAssertEqual(try XCTUnwrap(bounds.upper), point.objective, accuracy: 1e-8)
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
}
