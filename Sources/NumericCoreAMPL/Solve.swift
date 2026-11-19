import NumericCoreOptimization
import NumericCore
import NumericCoreSparse

/// Which of `nc-optimize`'s solvers to use — explicit, not
/// policy-based (per the explicit-solver-selection decision from the
/// simplex-vs-interior-point scoping discussion; see `Rust-NumericCore`'s
/// ADR 0004 update). Despite the name (kept for continuity with
/// existing callers rather than renamed to `SolverKind`), this now
/// covers MILP too via `.branchAndBound`.
public enum LPSolverKind {
    /// Uses branch-and-bound when any variable is integer-restricted;
    /// otherwise uses revised simplex. This is the safe default.
    case automatic
    /// `nc-optimize::RevisedSimplexSolver`. Handles equality constraints
    /// and fixed variables; rigorous (not heuristic) infeasibility and
    /// unboundedness detection. Prefer this unless the problem is large
    /// enough that interior-point's better scaling matters.
    case simplex
    /// `nc-optimize::InteriorPointSolver`. Rejects equality-constrained
    /// rows and fixed variables outright (throws — see that solver's
    /// Rust-side module docs); unboundedness detection is heuristic,
    /// not certificate-based.
    case interiorPoint
    /// `nc-optimize::BranchAndBoundSolver` — LP-relaxation
    /// branch-and-bound, the only option that honors
    /// `Model.addVariable(_:isInteger:)`/the AMPL grammar's `integer`
    /// qualifier. `.simplex`/`.interiorPoint` both ignore integrality
    /// entirely and solve the LP relaxation regardless — pick this one
    /// whenever the model actually declared an integer variable.
    case branchAndBound
}

public typealias OptimizationSolveConfiguration = NumericCoreOptimization.OptimizationSolveConfiguration
public typealias SimplexSolveOptions = NumericCoreOptimization.SimplexSolveOptions
public typealias InteriorPointSolveOptions = NumericCoreOptimization.InteriorPointSolveOptions
public typealias BranchAndBoundSolveOptions = NumericCoreOptimization.BranchAndBoundSolveOptions
public typealias MILPNodeSelection = NumericCoreOptimization.MILPNodeSelection
public typealias MILPBranchingStrategy = NumericCoreOptimization.MILPBranchingStrategy
public typealias MILPTermination = NumericCoreOptimization.MILPTermination
public typealias LPSolveStatus = NumericCoreOptimization.LPSolveStatus

public struct LPSolution {
    public let variableValues: [Double]
    /// Values keyed by the source model's variable names.
    public let variableValuesByName: [String: Double]
    /// Already corrected for the model's original objective sense —
    /// see `CompiledProblem.objectiveSign`'s doc comment. A `maximize`
    /// model's solution reports the actual (positive-sense) maximum
    /// here, not the negated internal minimize-form value.
    public let objectiveValue: Double
    public let status: LPSolveStatus
    /// Independently recomputed from the compiled problem and returned
    /// variables, rather than copied from the solver's internal state.
    public let diagnostics: OptimizationSolutionDiagnostics
    /// Present for configured branch-and-bound calls. A nonzero gap
    /// means the incumbent is feasible but optimality was not proven.
    public let searchReport: MILPSearchReport?

    /// True only for an optimal status whose independently recomputed
    /// feasibility, integrality, and objective checks all pass.
    public func isVerified(tolerance: Double) -> Bool {
        status == .optimal && diagnostics.isVerified(tolerance: tolerance)
    }
}

public struct MILPSearchReport: Sendable, Hashable {
    public let nodesExplored: UInt64
    /// Corrected to the source model's objective sense.
    public let bestBound: Double?
    public let absoluteGap: Double?
    public let relativeGap: Double?
    public let nodesPrunedInfeasible: UInt64
    public let nodesPrunedByBound: UInt64
    public let maximumDepth: UInt64
    public let relaxationsSolved: UInt64
    public let boundsTightened: UInt64
    public let incumbentsFound: UInt64
    public let heuristicAttempts: UInt64
    public let heuristicSuccesses: UInt64
    public let termination: MILPTermination
}

public struct OptimizationSolutionDiagnostics: Sendable, Hashable {
    public let finite: Bool
    public let maximumRowViolation: Double
    public let maximumVariableBoundViolation: Double
    public let maximumIntegralityViolation: Double
    public let recomputedObjectiveValue: Double
    public let objectiveError: Double

    public func isVerified(tolerance: Double) -> Bool {
        tolerance.isFinite && tolerance >= 0 && finite
            && maximumRowViolation <= tolerance
            && maximumVariableBoundViolation <= tolerance
            && maximumIntegralityViolation <= tolerance
            && objectiveError <= tolerance
    }
}

extension CompiledProblem {
    /// Solves this presolved problem via the chosen `nc-optimize`
    /// solver through NumericCoreOptimization. This is the
    /// step `docs/design/ampl-grammar.md`'s "Next steps" listed as not
    /// yet done — `AMPLParser.parse(_:)` → `Model.compile()` → here is
    /// a complete path from AMPL source text to an actual solved LP or
    /// MILP (the latter via `.branchAndBound`, once a model declares an
    /// `integer` variable).
    public func solve(using solver: LPSolverKind = .automatic) throws -> LPSolution {
        let configuration: OptimizationSolveConfiguration
        switch solver {
        case .automatic: configuration = .automatic
        case .simplex: configuration = .simplex()
        case .interiorPoint: configuration = .interiorPoint()
        case .branchAndBound: configuration = .branchAndBound()
        }
        return try solve(configuration: configuration)
    }

    public func solve(
        configuration: OptimizationSolveConfiguration
    ) throws -> LPSolution {
        let problem = try SparseLinearProblem(
            objective: objective.storage, rows: constraints.rows, columns: constraints.cols,
            rowPointers: constraints.csrRowPointers, columnIndices: constraints.csrColumnIndices,
            values: constraints.csrValues,
            rowBounds: rowBounds.map { .init(lower: $0.lower, upper: $0.upper) },
            variableBounds: zip(variableLowerBounds, variableUpperBounds).map {
                .init(lower: $0.0, upper: $0.1)
            },
            isInteger: variableIsInteger)
        let result = try SparseLinearSolver.solve(problem, configuration: configuration)
        let correctedObjective = result.objectiveValue * objectiveSign + objectiveConstant
        let values = result.variableValues
        return LPSolution(
            variableValues: values,
            variableValuesByName: Dictionary(
                uniqueKeysWithValues: zip(variableNames, values)
            ),
            objectiveValue: correctedObjective,
            status: result.status,
            diagnostics: solutionDiagnostics(
                values: values, reportedObjective: correctedObjective
            ),
            searchReport: result.searchReport.map { report in
                MILPSearchReport(
                    nodesExplored: report.nodesExplored,
                    bestBound: report.bestBound.map {
                        $0 * objectiveSign + objectiveConstant
                    },
                    absoluteGap: report.absoluteGap,
                    relativeGap: report.relativeGap,
                    nodesPrunedInfeasible: report.nodesPrunedInfeasible,
                    nodesPrunedByBound: report.nodesPrunedByBound,
                    maximumDepth: report.maximumDepth,
                    relaxationsSolved: report.relaxationsSolved,
                    boundsTightened: report.boundsTightened,
                    incumbentsFound: report.incumbentsFound,
                    heuristicAttempts: report.heuristicAttempts,
                    heuristicSuccesses: report.heuristicSuccesses,
                    termination: report.termination
                )
            }
        )
    }

    private func solutionDiagnostics(
        values: [Double], reportedObjective: Double
    ) -> OptimizationSolutionDiagnostics {
        guard values.count == objective.count,
              variableLowerBounds.count == objective.count,
              variableUpperBounds.count == objective.count,
              variableIsInteger.count == objective.count,
              rowBounds.count == constraints.rows,
              constraints.cols == objective.count
        else {
            return OptimizationSolutionDiagnostics(
                finite: false,
                maximumRowViolation: .infinity,
                maximumVariableBoundViolation: .infinity,
                maximumIntegralityViolation: .infinity,
                recomputedObjectiveValue: .nan,
                objectiveError: .infinity
            )
        }

        var rowValues = [Double](repeating: 0, count: constraints.rows)
        let rowPointers = constraints.csrRowPointers
        let columns = constraints.csrColumnIndices
        let coefficients = constraints.csrValues
        for row in 0..<constraints.rows {
            for index in rowPointers[row]..<rowPointers[row + 1] {
                rowValues[row] += coefficients[index] * values[columns[index]]
            }
        }

        let rowViolation = zip(rowValues, rowBounds).reduce(0.0) {
            max($0, Self.boundViolation(value: $1.0, lower: $1.1.lower, upper: $1.1.upper))
        }
        let variableViolation = values.indices.reduce(0.0) { partial, index in
            max(partial, Self.boundViolation(
                value: values[index], lower: variableLowerBounds[index],
                upper: variableUpperBounds[index]
            ))
        }
        let integralityViolation = values.indices.reduce(0.0) { partial, index in
            guard variableIsInteger[index] else { return partial }
            return max(partial, abs(values[index] - values[index].rounded()))
        }
        // The compiled objective is always minimization form. Convert it back
        // to the source model's sense before comparing with the public result.
        let recomputedObjective = zip(objective.storage, values)
            .reduce(0.0) { $0 + $1.0 * $1.1 } * objectiveSign + objectiveConstant
        let objectiveError = abs(reportedObjective - recomputedObjective)
        let finite = values.allSatisfy(\.isFinite) && rowValues.allSatisfy(\.isFinite)
            && reportedObjective.isFinite && recomputedObjective.isFinite
            && rowViolation.isFinite && variableViolation.isFinite
            && integralityViolation.isFinite && objectiveError.isFinite

        return OptimizationSolutionDiagnostics(
            finite: finite,
            maximumRowViolation: rowViolation,
            maximumVariableBoundViolation: variableViolation,
            maximumIntegralityViolation: integralityViolation,
            recomputedObjectiveValue: recomputedObjective,
            objectiveError: objectiveError
        )
    }

    private static func boundViolation(
        value: Double, lower: Double?, upper: Double?
    ) -> Double {
        max(lower.map { max($0 - value, 0) } ?? 0,
            upper.map { max(value - $0, 0) } ?? 0)
    }
}
