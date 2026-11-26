import Foundation
import NumericCoreOptimization
import NumericCoreSparse

/// A recourse model may refer to first-stage variables through local names.
/// All other variables in the model are private to this scenario.
public struct BendersModelScenario {
    public let name: String
    public let probability: Double
    public let model: Model
    public let sharedVariables: [String: String]

    /// `sharedVariables` maps a recourse-model name to a first-stage name.
    public init(name: String, probability: Double, model: Model,
                sharedVariables: [String: String] = [:]) {
        self.name = name
        self.probability = probability
        self.model = model
        self.sharedVariables = sharedVariables
    }
}

public enum BendersModelError: Error, Equatable {
    case invalidScenarios
    case integerVariables
    case incompatibleObjectiveSense(scenario: String)
    case unknownSharedVariable(scenario: String, name: String)
    case duplicateSharedTarget(scenario: String, name: String)
    case incompatibleSharedBounds(scenario: String, name: String)
    case invalidIncumbent
}

public enum IntegerBendersModelError: Error, Equatable {
    case incompatibleSharedIntegrality(scenario: String, name: String)
}

/// A two-stage linear model with an explicitly declared partition.
public struct BendersModel {
    public let firstStage: Model
    public let scenarios: [BendersModelScenario]

    public init(firstStage: Model, scenarios: [BendersModelScenario]) {
        self.firstStage = firstStage
        self.scenarios = scenarios
    }

    public func compile() throws -> CompiledBendersModel {
        try compile(allowInteger: false)
    }

    /// Lower an explicitly partitioned mixed-integer model for Integer Benders.
    public func compileInteger() throws -> CompiledIntegerBendersModel {
        .init(compiled: try compile(allowInteger: true))
    }

    private func compile(allowInteger: Bool) throws -> CompiledBendersModel {
        let totalWeight = scenarios.reduce(0.0) { $0 + $1.probability }
        guard !scenarios.isEmpty, abs(totalWeight - 1) <= 1e-10,
              scenarios.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.probability.isFinite && $0.probability > 0 }),
              Set(scenarios.map(\.name)).count == scenarios.count else {
            throw BendersModelError.invalidScenarios
        }
        let source = try firstStage.compile()
        let master = try source.sparseLinearProblem()
        guard allowInteger || !master.isInteger.contains(true) else { throw BendersModelError.integerVariables }
        let masterIndices = Dictionary(uniqueKeysWithValues: source.variableNames.enumerated().map { ($1, $0) })
        var masterObjective = master.objective
        var offset = source.objectiveConstant
        var blocks: [BendersScenario] = []
        var mappings: [BendersScenarioMapping] = []
        for scenario in scenarios {
            let compiled = try scenario.model.compile()
            let lp = try compiled.sparseLinearProblem()
            guard allowInteger || !lp.isInteger.contains(true) else { throw BendersModelError.integerVariables }
            guard compiled.objectiveSign == source.objectiveSign else {
                throw BendersModelError.incompatibleObjectiveSense(scenario: scenario.name)
            }
            let localIndices = Dictionary(uniqueKeysWithValues: compiled.variableNames.enumerated().map { ($1, $0) })
            var shared: [Int: Int] = [:]
            var targets = Set<Int>()
            for (name, target) in scenario.sharedVariables.sorted(by: { $0.key < $1.key }) {
                guard let column = localIndices[name] else {
                    throw BendersModelError.unknownSharedVariable(scenario: scenario.name, name: name)
                }
                guard let masterColumn = masterIndices[target] else {
                    throw BendersModelError.unknownSharedVariable(scenario: scenario.name, name: target)
                }
                guard targets.insert(masterColumn).inserted else {
                    throw BendersModelError.duplicateSharedTarget(scenario: scenario.name, name: target)
                }
                let localBound = lp.variableBounds[column]
                guard (localBound.lower == nil || localBound.lower == master.variableBounds[masterColumn].lower),
                      (localBound.upper == nil || localBound.upper == master.variableBounds[masterColumn].upper) else {
                    throw BendersModelError.incompatibleSharedBounds(scenario: scenario.name, name: name)
                }
                if lp.isInteger[column] && !master.isInteger[masterColumn] {
                    throw IntegerBendersModelError.incompatibleSharedIntegrality(scenario: scenario.name, name: name)
                }
                shared[column] = masterColumn
            }
            let locals = lp.objective.indices.filter { shared[$0] == nil }
            let localColumns = Dictionary(uniqueKeysWithValues: locals.enumerated().map { ($1, $0) })
            var coupling: [SparseEntry<Double>] = []
            var recourse: [SparseEntry<Double>] = []
            for row in 0..<lp.rows {
                for i in lp.rowPointers[row]..<lp.rowPointers[row + 1] {
                    let column = lp.columnIndices[i]
                    if let target = shared[column] {
                        coupling.append(.init(row: row, column: target, value: lp.values[i]))
                    } else if let target = localColumns[column] {
                        recourse.append(.init(row: row, column: target, value: lp.values[i]))
                    }
                }
            }
            let weight = scenario.probability / totalWeight
            let orderedShared = shared.sorted { $0.key < $1.key }
            let sharedCosts = orderedShared.map { ($0.value, lp.objective[$0.key]) }
            for (column, cost) in sharedCosts {
                masterObjective[column] += weight * cost
            }
            offset += weight * compiled.objectiveConstant
            let localMatrix = try SparseMatrix(rows: lp.rows, cols: locals.count, entries: recourse)
            let couplingMatrix = try SparseMatrix(rows: lp.rows, cols: master.columns, entries: coupling)
            let local = try linearProblem(localMatrix, objective: locals.map { lp.objective[$0] },
                                          rows: lp.rowBounds, variables: locals.map { lp.variableBounds[$0] },
                                          isInteger: locals.map { lp.isInteger[$0] })
            blocks.append(.init(id: .init(name: scenario.name), probability: weight,
                                recourse: local, coupling: couplingMatrix))
            mappings.append(.init(name: scenario.name, variables: locals.map { compiled.variableNames[$0] },
                                  sharedVariables: orderedShared.map { (compiled.variableNames[$0.key], $0.value) },
                                  sharedCosts: sharedCosts, offset: compiled.objectiveConstant))
        }
        guard offset.isFinite else { throw PresolveError.nonFiniteModelValue }
        let first = try linearProblem(source.constraints, objective: masterObjective,
                                      rows: master.rowBounds, variables: master.variableBounds,
                                      isInteger: master.isInteger)
        return CompiledBendersModel(problem: .init(firstStage: first, scenarios: blocks),
                                   firstStageVariables: source.variableNames, mappings: mappings,
                                   objectiveSign: source.objectiveSign, objectiveOffset: offset)
    }
}

public struct NamedBendersScenarioSolution {
    public let name: String
    public let variables: [String: Double]
    /// Unweighted source objective for the scenario, including shared terms.
    public let objective: Double
}

public struct NamedBendersSolution {
    public let firstStage: [String: Double]
    public let scenarios: [NamedBendersScenarioSolution]
    public let objective: Double
}

public struct BendersModelResult {
    public let numericalResult: BendersResult
    public let incumbent: NamedBendersSolution?
    public let lowerBound: Double?
    public let upperBound: Double?
}

fileprivate struct BendersScenarioMapping {
    let name: String
    let variables: [String]
    let sharedVariables: [(String, Int)]
    let sharedCosts: [(Int, Double)]
    let offset: Double
}

public struct CompiledBendersModel {
    /// The normalized minimization model for local or distributed Benders.
    public let problem: BendersProblem
    public let firstStageVariables: [String]
    fileprivate let mappings: [BendersScenarioMapping]
    public let objectiveSign: Double
    public let objectiveOffset: Double

    public func solve(options: BendersOptions = .init()) throws -> BendersModelResult {
        let result = try BendersSolver.solve(problem, options: options)
        let bounds = sourceBounds(lower: result.lowerBound, upper: result.upperBound)
        return .init(numericalResult: result, incumbent: try result.incumbent.map(namedIncumbent),
                     lowerBound: bounds.lower, upperBound: bounds.upper)
    }

    /// Convert numerical bounds to source objective coordinates, also reversing
    /// their order for maximization.
    public func sourceBounds(lower: Double?, upper: Double?) -> (lower: Double?, upper: Double?) {
        func transform(_ bound: Double) -> Double? {
            let value = objectiveSign * bound + objectiveOffset
            return value.isFinite ? value : nil
        }
        let lowerValue = lower.flatMap(transform)
        let upperValue = upper.flatMap(transform)
        return objectiveSign > 0 ? (lowerValue, upperValue) : (upperValue, lowerValue)
    }

    /// Map a local or distributed incumbent back to source names.
    public func namedIncumbent(_ incumbent: BendersIncumbent) throws -> NamedBendersSolution {
        guard incumbent.recourse.count == mappings.count else { throw BendersModelError.invalidIncumbent }
        var points: [String: [Double]] = [:]
        for block in incumbent.recourse {
            guard block.id.scenario == nil, points.updateValue(block.point, forKey: block.id.name) == nil else {
                throw BendersModelError.invalidIncumbent
            }
        }
        return try namedSolution(first: incumbent.firstStage, points: points, objective: incumbent.objective)
    }

    /// Assemble the deterministic equivalent for solving or comparison.
    /// Column order is first stage, followed by each scenario in declaration order.
    public func extensiveForm() throws -> SparseLinearProblem {
        let master = problem.firstStage
        var objective = master.objective
        var rowBounds = master.rowBounds
        var variableBounds = master.variableBounds
        var isInteger = master.isInteger
        var entries: [SparseEntry<Double>] = []
        func append(_ lp: SparseLinearProblem, rowOffset: Int, columnOffset: Int) {
            for row in 0..<lp.rows {
                for i in lp.rowPointers[row]..<lp.rowPointers[row + 1] {
                    entries.append(.init(row: rowOffset + row, column: columnOffset + lp.columnIndices[i],
                                         value: lp.values[i]))
                }
            }
        }
        append(master, rowOffset: 0, columnOffset: 0)
        for block in problem.scenarios {
            let rowOffset = rowBounds.count
            let lp = block.recourse
            append(lp, rowOffset: rowOffset, columnOffset: objective.count)
            let coupling = block.coupling
            for row in 0..<coupling.rows {
                for i in coupling.csrRowPointers[row]..<coupling.csrRowPointers[row + 1] {
                    entries.append(.init(row: rowOffset + row, column: coupling.csrColumnIndices[i],
                                         value: coupling.csrValues[i]))
                }
            }
            objective += lp.objective.map { block.probability * $0 }
            rowBounds += lp.rowBounds
            variableBounds += lp.variableBounds
            isInteger += lp.isInteger
        }
        let matrix = try SparseMatrix(rows: rowBounds.count, cols: objective.count, entries: entries)
        return try linearProblem(matrix, objective: objective, rows: rowBounds, variables: variableBounds,
                                 isInteger: isInteger)
    }

    /// Decode the point and minimization objective returned by an extensive-form solver.
    public func namedExtensiveSolution(point: [Double], objective: Double) throws -> NamedBendersSolution {
        guard point.count == firstStageVariables.count + mappings.reduce(0, { $0 + $1.variables.count }) else {
            throw BendersModelError.invalidIncumbent
        }
        var cursor = firstStageVariables.count
        var points: [String: [Double]] = [:]
        for mapping in mappings {
            let end = cursor + mapping.variables.count
            points[mapping.name] = Array(point[cursor..<end])
            cursor = end
        }
        return try namedSolution(first: Array(point.prefix(firstStageVariables.count)), points: points, objective: objective)
    }

    private func namedSolution(first: [Double], points: [String: [Double]],
                               objective: Double) throws -> NamedBendersSolution {
        let sourceObjective = objectiveSign * objective + objectiveOffset
        guard first.count == firstStageVariables.count, first.allSatisfy(\.isFinite), sourceObjective.isFinite else {
            throw BendersModelError.invalidIncumbent
        }
        let scenarios = try zip(mappings, problem.scenarios).map { mapping, block in
            guard let point = points[mapping.name], point.count == mapping.variables.count,
                  point.allSatisfy(\.isFinite) else { throw BendersModelError.invalidIncumbent }
            let local = zip(block.recourse.objective, point).reduce(0.0) { $0 + $1.0 * $1.1 }
            let shared = mapping.sharedCosts.reduce(0.0) { $0 + $1.1 * first[$1.0] }
            let objective = objectiveSign * (local + shared) + mapping.offset
            guard objective.isFinite else { throw BendersModelError.invalidIncumbent }
            var variables = Dictionary(uniqueKeysWithValues: zip(mapping.variables, point))
            for (name, column) in mapping.sharedVariables {
                variables[name] = first[column]
            }
            return NamedBendersScenarioSolution(name: mapping.name, variables: variables, objective: objective)
        }
        return .init(firstStage: Dictionary(uniqueKeysWithValues: zip(firstStageVariables, first)),
                     scenarios: scenarios, objective: sourceObjective)
    }
}

public struct IntegerBendersModelResult {
    public let numericalResult: IntegerBendersResult
    public let incumbent: NamedBendersSolution?
    public let lowerBound: Double?
    public let upperBound: Double?
}

public struct CompiledIntegerBendersModel {
    fileprivate let compiled: CompiledBendersModel

    /// The normalized minimization model for the native integer Benders solver.
    public var problem: BendersProblem { compiled.problem }
    public var firstStageVariables: [String] { compiled.firstStageVariables }

    public func solve(options: IntegerBendersOptions = .init()) throws -> IntegerBendersModelResult {
        let result = try IntegerBendersSolver.solve(problem, options: options)
        let bounds = compiled.sourceBounds(lower: result.lowerBound, upper: result.upperBound)
        return .init(numericalResult: result, incumbent: try result.incumbent.map(compiled.namedIncumbent),
                     lowerBound: bounds.lower, upperBound: bounds.upper)
    }

    /// The deterministic equivalent retains first-stage and recourse integrality.
    public func extensiveForm() throws -> SparseLinearProblem {
        try compiled.extensiveForm()
    }

    public func namedExtensiveSolution(point: [Double], objective: Double) throws -> NamedBendersSolution {
        try compiled.namedExtensiveSolution(point: point, objective: objective)
    }
}

private func linearProblem(_ matrix: SparseMatrix<Double>, objective: [Double],
                           rows: [ParameterBound], variables: [ParameterBound],
                           isInteger: [Bool]) throws -> SparseLinearProblem {
    try .init(objective: objective, rows: matrix.rows, columns: matrix.cols,
              rowPointers: matrix.csrRowPointers, columnIndices: matrix.csrColumnIndices,
              values: matrix.csrValues, rowBounds: rows, variableBounds: variables, isInteger: isInteger)
}
