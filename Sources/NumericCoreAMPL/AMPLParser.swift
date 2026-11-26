/// Parser errors. Each case carries the token position `AMPLLexer`
/// recorded, so a caller can point at the offending source location.
public enum AMPLParseError: Error, Equatable {
    case unexpectedToken(expected: String, found: String, position: Int)
    case unknownIdentifier(String, position: Int)
    case lexError(LexError)
}

/// Recursive-descent parser for the grammar in
/// `docs/ampl-grammar.md`. See `Model.swift`'s module docs for
/// why this is hand-rolled rather than built on `hakkabon/Parser`.
///
/// Algebraic expressions use ordinary arithmetic precedence, unary signs,
/// parentheses, constant powers, and the elementary functions documented by
/// the grammar. AMPL's coefficient notation (`3 x`) is treated as implicit
/// multiplication, preserving compatibility with the original affine subset.
public enum AMPLParser {
    public static func parse(_ source: String) throws -> Model {
        let tokens: [Token]
        do {
            tokens = try AMPLLexer.tokenize(source)
        } catch let error as LexError {
            throw AMPLParseError.lexError(error)
        }
        var state = ParserState(tokens: tokens)
        return try state.parseModel()
    }
}

private struct ParserState {
    let tokens: [Token]
    var index = 0
    var model = Model()
    var sets: [String: [[String]]] = [:]
    var variables: [String: Int] = [:]
    var shapes: [String: Set<Int>] = [:]

    var symbols: Symbols { .init(variables: variables, parameters: model.parameterValues) }

    var current: Token { tokens[index] }

    mutating func advance() -> Token {
        let token = tokens[index]
        if case .endOfInput = token.kind {
            // Stay put at end-of-input rather than running off the
            // array — every caller checks for .endOfInput before
            // relying on further advances, but this keeps `advance()`
            // itself safe regardless.
        } else {
            index += 1
        }
        return token
    }

    func describe(_ kind: TokenKind) -> String {
        switch kind {
        case .keyword(let k): return "keyword '\(k)'"
        case .identifier(let name): return "identifier '\(name)'"
        case .number(let n): return "number '\(n)'"
        case .symbol(let s): return "'\(s)'"
        case .endOfInput: return "end of input"
        }
    }

    mutating func expectKeyword(_ keyword: String) throws {
        guard current.kind == .keyword(keyword) else {
            throw AMPLParseError.unexpectedToken(
                expected: "keyword '\(keyword)'", found: describe(current.kind), position: current.position
            )
        }
        _ = advance()
    }

    mutating func expectSymbol(_ symbol: String) throws {
        guard current.kind == .symbol(symbol) else {
            throw AMPLParseError.unexpectedToken(
                expected: "'\(symbol)'", found: describe(current.kind), position: current.position
            )
        }
        _ = advance()
    }

    mutating func matchSymbol(_ symbol: String) -> Bool {
        guard current.kind == .symbol(symbol) else { return false }
        _ = advance()
        return true
    }

    mutating func expectIdentifier() throws -> String {
        guard case .identifier(let name) = current.kind else {
            throw AMPLParseError.unexpectedToken(
                expected: "identifier", found: describe(current.kind), position: current.position
            )
        }
        _ = advance()
        return name
    }

    mutating func expectNumber() throws -> Double {
        guard case .number(let value) = current.kind else {
            throw AMPLParseError.unexpectedToken(
                expected: "number", found: describe(current.kind), position: current.position
            )
        }
        _ = advance()
        return value
    }

    // MARK: - model = { statement }

    mutating func parseModel() throws -> Model {
        while true {
            switch current.kind {
            case .identifier("set"):
                try parseSetDecl()
            case .keyword("var"):
                try parseVarDecl()
            case .keyword("param"):
                try parseParamDecl()
            case .keyword("subject"):
                try parseConstraintDecl()
            case .keyword("minimize"), .keyword("maximize"):
                try parseObjectiveDecl()
            case .endOfInput:
                return model
            default:
                throw AMPLParseError.unexpectedToken(
                    expected: "'set', 'var', 'param', 'subject to', 'minimize', or 'maximize'",
                    found: describe(current.kind), position: current.position
                )
            }
        }
    }

    // MARK: - declarations

    mutating func parseSetDecl() throws {
        let position = advance().position
        let name = try expectIdentifier()
        guard sets[name] == nil else { throw invalid("a new set name", found: name, at: position) }
        try expectSymbol(":=")
        var members: [[String]] = []
        var seen = Set<[String]>()
        while !matchSymbol(";") {
            let position = current.position
            let member: [String]
            if matchSymbol("(") {
                member = try parseIndices(ending: ")")
            } else {
                member = [try parseIndex()]
            }
            guard members.first.map({ $0.count == member.count }) ?? true,
                  seen.insert(member).inserted else {
                throw invalid("a distinct set member of uniform arity", found: member.joined(separator: ","),
                              at: position)
            }
            members.append(member)
        }
        sets[name] = members
    }

    mutating func parseVarDecl() throws {
        let position = current.position
        try expectKeyword("var")
        let name = try expectIdentifier()
        let domain = try parseDomainIfPresent()
        if domain.arity > 0 && shapes[name]?.contains(domain.arity) == true {
            throw invalid("a new indexed variable family", found: name, at: position)
        }
        var lower: Expression? = { _, _ in .constant(0) }
        var upper: Expression?
        var isInteger = false
        while true {
            if current.kind == .symbol(">=") || current.kind == .symbol("<=") {
                (lower, upper) = try parseBoundClause()
            } else if current.kind == .keyword("integer") {
                _ = advance()
                isInteger = true
            } else {
                break
            }
        }
        try expectSymbol(";")
        let symbols = self.symbols
        try domain.forEach { key, bindings in
            let column = indexedName(name, key)
            let lo = try lower.map { try boundValue($0, symbols, bindings, at: position) }
            let hi = try upper.map { try boundValue($0, symbols, bindings, at: position) }
            let index = model.addVariable(column, lowerBound: lo, upperBound: hi, isInteger: isInteger)
            if variables[column] == nil { variables[column] = index }
        }
        shapes[name, default: []].insert(domain.arity)
    }

    mutating func parseBoundClause() throws -> (lower: Expression?, upper: Expression?) {
        var lower: Expression?
        var upper: Expression?
        try parseSingleBound(lower: &lower, upper: &upper)
        if matchSymbol(",") { try parseSingleBound(lower: &lower, upper: &upper) }
        return (lower, upper)
    }

    mutating func parseSingleBound(lower: inout Expression?, upper: inout Expression?) throws {
        if matchSymbol(">=") {
            lower = try parseUnary()
        } else if matchSymbol("<=") {
            upper = try parseUnary()
        } else {
            throw invalid("'>=' or '<='", found: describe(current.kind), at: current.position)
        }
    }

    mutating func parseParamDecl() throws {
        let position = current.position
        try expectKeyword("param")
        let name = try expectIdentifier()
        let domain = try parseDomainIfPresent()
        if domain.arity > 0 && shapes[name]?.contains(domain.arity) == true {
            throw invalid("a new indexed parameter family", found: name, at: position)
        }
        try expectSymbol(":=")
        if domain.arity == 0 {
            let value = try parseSignedNumber()
            try expectSymbol(";")
            model.addParameter(name, value: value)
        } else {
            var unassigned = Set<[String]>()
            domain.forEach { key, _ in _ = unassigned.insert(key) }
            while !matchSymbol(";") {
                let position = current.position
                let key: [String]
                if matchSymbol("[") {
                    key = try parseIndices(ending: "]")
                } else if domain.arity == 1 {
                    key = [try parseIndex()]
                } else {
                    throw invalid("a bracketed parameter index", found: describe(current.kind), at: position)
                }
                let instance = indexedName(name, key)
                guard unassigned.remove(key) != nil, model.parameterValues[instance] == nil else {
                    throw invalid("an unassigned parameter index in the domain", found: instance, at: position)
                }
                let value = try parseSignedNumber()
                model.addParameter(instance, value: value)
            }
            if let missing = unassigned.sorted(by: { $0.lexicographicallyPrecedes($1) }).first {
                throw invalid("a value for every parameter index", found: indexedName(name, missing),
                              at: tokens[index - 1].position)
            }
        }
        shapes[name, default: []].insert(domain.arity)
    }

    mutating func parseSignedNumber() throws -> Double {
        let negative = matchSymbol("-")
        if !negative { _ = matchSymbol("+") }
        let value = try expectNumber()
        return negative ? -value : value
    }

    mutating func parseConstraintDecl() throws {
        try expectKeyword("subject")
        try expectKeyword("to")
        let name = try expectIdentifier()
        let domain = try parseDomainIfPresent()
        try expectSymbol(":")
        let lhs = try parseAlgebraicExpression()
        let relation = try parseRelop()
        let rhs = try parseAlgebraicExpression()
        try expectSymbol(";")
        let symbols = self.symbols
        try domain.forEach { key, bindings in
            model.addNonlinearConstraint(name: indexedName(name, key),
                                         lhs: try lhs(symbols, bindings), relation: relation,
                                         rhs: try rhs(symbols, bindings))
        }
    }

    mutating func parseDomainIfPresent() throws -> IndexDomain {
        guard matchSymbol("{") else { return .init() }
        var groups: [IndexGroup] = []
        var names = Set<String>()
        repeat {
            let position = current.position
            var binders: [String]
            if matchSymbol("(") {
                binders = [try expectIdentifier()]
                while matchSymbol(",") { binders.append(try expectIdentifier()) }
                try expectSymbol(")")
            } else {
                binders = [try expectIdentifier()]
            }
            for binder in binders {
                guard names.insert(binder).inserted else {
                    throw invalid("a distinct index binder", found: binder, at: position)
                }
            }
            guard current.kind == .identifier("in") else {
                throw invalid("'in'", found: describe(current.kind), at: current.position)
            }
            _ = advance()
            let setPosition = current.position
            let name = try expectIdentifier()
            guard let members = sets[name] else {
                throw AMPLParseError.unknownIdentifier(name, position: setPosition)
            }
            guard members.first.map({ $0.count == binders.count }) ?? true else {
                throw invalid("index binders matching the set arity", found: name, at: position)
            }
            groups.append(.init(binders: binders, members: members))
        } while matchSymbol(",")
        var filter: (String, String)?
        if matchSymbol(":") {
            let lhs = try parseIndex()
            try expectSymbol("=")
            filter = (lhs, try parseIndex())
        }
        try expectSymbol("}")
        return .init(groups: groups, filter: filter)
    }

    mutating func parseIndices(ending: String) throws -> [String] {
        var values = [try parseIndex()]
        while matchSymbol(",") { values.append(try parseIndex()) }
        try expectSymbol(ending)
        return values
    }

    mutating func parseIndex() throws -> String {
        if case .identifier(let name) = current.kind {
            _ = advance()
            return name
        }
        let position = current.position
        let value = try parseSignedNumber()
        guard let integer = Int64(exactly: value), abs(value) < 9_007_199_254_740_992 else {
            throw invalid("an integer index representable exactly", found: String(value), at: position)
        }
        return String(integer)
    }

    // MARK: - objective_decl

    mutating func parseObjectiveDecl() throws {
        let sense: ObjectiveSense
        if case .keyword("minimize") = current.kind {
            sense = .minimize
            _ = advance()
        } else {
            try expectKeyword("maximize")
            sense = .maximize
        }
        let name = try expectIdentifier()
        try expectSymbol(":")
        let expression = try parseAlgebraicExpression()
        try expectSymbol(";")
        model.setNonlinearObjective(name: name, sense: sense, expression: try expression(symbols, [:]))
    }

    // MARK: - relop

    mutating func parseRelop() throws -> RelationalOperator {
        if matchSymbol("<=") { return .lessThanOrEqual }
        if matchSymbol(">=") { return .greaterThanOrEqual }
        if matchSymbol("=") { return .equal }
        throw AMPLParseError.unexpectedToken(
            expected: "'<=', '>=', or '='", found: describe(current.kind), position: current.position
        )
    }

    // MARK: - algebraic expressions

    mutating func parseAlgebraicExpression() throws -> Expression {
        try parseSum()
    }

    mutating func parseSum() throws -> Expression {
        var value = try parseProduct()
        while true {
            if matchSymbol("+") { value = binary(value, try parseProduct(), AlgebraicExpression.add) }
            else if matchSymbol("-") { value = binary(value, try parseProduct(), AlgebraicExpression.subtract) }
            else { return value }
        }
    }

    mutating func parseProduct() throws -> Expression {
        var value = try parseUnary()
        while true {
            if matchSymbol("*") {
                value = binary(value, try parseUnary(), AlgebraicExpression.multiply)
            } else if matchSymbol("/") {
                value = binary(value, try parseUnary(), AlgebraicExpression.divide)
            } else if beginsPrimary(current.kind) {
                value = binary(value, try parseUnary(), AlgebraicExpression.multiply)
            } else { return value }
        }
    }

    mutating func parseUnary() throws -> Expression {
        if matchSymbol("+") { return try parseUnary() }
        if matchSymbol("-") {
            let value = try parseUnary()
            return { symbols, bindings in .negate(try value(symbols, bindings)) }
        }
        return try parsePower()
    }

    mutating func parsePower() throws -> Expression {
        let value = try parsePrimary()
        guard matchSymbol("^") else { return value }
        let position = current.position
        let exponent = try parseUnary()
        return { symbols, bindings in
            guard case .constant(let scalar) = try exponent(symbols, bindings) else {
                throw invalid("constant exponent", found: "expression", at: position)
            }
            return .power(try value(symbols, bindings), scalar)
        }
    }

    mutating func parsePrimary() throws -> Expression {
        if case .number(let value) = current.kind {
            _ = advance()
            return { _, _ in .constant(value) }
        }
        if matchSymbol("(") {
            let value = try parseAlgebraicExpression()
            try expectSymbol(")")
            return value
        }
        if case .identifier(let name) = current.kind {
            let position = advance().position
            if name == "sum", current.kind == .symbol("{") {
                let domain = try parseDomainIfPresent()
                let term = try parseProduct()
                return { symbols, bindings in
                    var terms: [AlgebraicExpression] = []
                    try domain.forEach(in: bindings) { _, scope in terms.append(try term(symbols, scope)) }
                    return balancedSum(terms[...])
                }
            }
            if let function = elementaryFunction(name), matchSymbol("(") {
                let argument = try parseAlgebraicExpression()
                try expectSymbol(")")
                return { symbols, bindings in function(try argument(symbols, bindings)) }
            }
            let indices = matchSymbol("[") ? try parseIndices(ending: "]") : []
            guard shapes[name]?.contains(indices.count) == true else {
                throw AMPLParseError.unknownIdentifier(indexedName(name, indices), position: position)
            }
            return { symbols, bindings in
                let instance = indexedName(name, indices.map { bindings[$0] ?? $0 })
                if let variable = symbols.variables[instance] { return .variable(variable) }
                if let value = symbols.parameters[instance] { return .constant(value) }
                throw AMPLParseError.unknownIdentifier(instance, position: position)
            }
        }
        throw invalid("number, identifier, or parenthesized expression",
                      found: describe(current.kind), at: current.position)
    }

    func beginsPrimary(_ kind: TokenKind) -> Bool {
        if case .number = kind { return true }
        if case .identifier = kind { return true }
        return kind == .symbol("(")
    }
}

private typealias Bindings = [String: String]
private typealias Expression = (Symbols, Bindings) throws -> AlgebraicExpression

private struct Symbols {
    let variables: [String: Int]
    let parameters: [String: Double]
}

private struct IndexGroup {
    let binders: [String]
    let members: [[String]]
}

private struct IndexDomain {
    var groups: [IndexGroup] = []
    var filter: (String, String)?

    var arity: Int { groups.reduce(0) { $0 + $1.binders.count } }

    func forEach(in bindings: Bindings = [:],
                 _ body: ([String], Bindings) throws -> Void) rethrows {
        func visit(_ group: Int, key: [String], scope: Bindings) throws {
            if group == groups.count {
                if let (lhs, rhs) = filter, (scope[lhs] ?? lhs) != (scope[rhs] ?? rhs) { return }
                try body(key, scope)
                return
            }
            let domain = groups[group]
            for member in domain.members {
                var nested = scope
                for (binder, atom) in zip(domain.binders, member) { nested[binder] = atom }
                try visit(group + 1, key: key + member, scope: nested)
            }
        }
        try visit(0, key: [], scope: bindings)
    }
}

private func indexedName(_ name: String, _ indices: [String]) -> String {
    indices.isEmpty ? name : name + "[" + indices.joined(separator: ",") + "]"
}

private func invalid(_ expected: String, found: String, at position: Int) -> AMPLParseError {
    .unexpectedToken(expected: expected, found: found, position: position)
}

private func boundValue(_ expression: Expression, _ symbols: Symbols,
                        _ bindings: Bindings, at position: Int) throws -> Double {
    let value = try expression(symbols, bindings)
    guard let affine = value.affine, affine.coefficients.isEmpty, affine.constant.isFinite else {
        throw invalid("a finite constant bound", found: "expression", at: position)
    }
    return affine.constant
}

private func binary(_ lhs: @escaping Expression, _ rhs: @escaping Expression,
                    _ combine: @escaping (AlgebraicExpression, AlgebraicExpression) -> AlgebraicExpression)
    -> Expression {
    { symbols, bindings in try combine(lhs(symbols, bindings), rhs(symbols, bindings)) }
}

private func elementaryFunction(_ name: String) -> ((AlgebraicExpression) -> AlgebraicExpression)? {
    switch name {
    case "exp": return AlgebraicExpression.exp
    case "log": return AlgebraicExpression.log
    case "sqrt": return AlgebraicExpression.sqrt
    case "sin": return AlgebraicExpression.sin
    case "cos": return AlgebraicExpression.cos
    default: return nil
    }
}

private func balancedSum(_ terms: ArraySlice<AlgebraicExpression>) -> AlgebraicExpression {
    if terms.isEmpty { return .constant(0) }
    if terms.count == 1 { return terms[terms.startIndex] }
    let middle = terms.startIndex + terms.count / 2
    return .add(balancedSum(terms[..<middle]), balancedSum(terms[middle...]))
}
