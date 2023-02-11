import Core
import Utils

/// Val's type checker.
public struct TypeChecker {

  /// The program being type checked.
  public internal(set) var program: ScopedProgram

  /// The diagnostics of the type errors.
  public internal(set) var diagnostics: DiagnosticSet = []

  /// The overarching type of each declaration.
  public private(set) var declTypes = DeclProperty<AnyType>()

  /// The type of each expression.
  public private(set) var exprTypes = ExprProperty<AnyType>()

  /// A map from function and subscript declarations to their implicit captures.
  public private(set) var implicitCaptures = DeclProperty<[ImplicitCapture]>()

  /// A map from name expression to its referred declaration.
  public internal(set) var referredDecls: BindingMap = [:]

  /// A map from sequence expressions to their evaluation order.
  public internal(set) var foldedSequenceExprs: [NodeID<SequenceExpr>: FoldedSequenceExpr] = [:]

  /// The type relations of the program.
  public internal(set) var relations = TypeRelations()

  /// Indicates whether the built-in symbols are visible.
  public var isBuiltinModuleVisible: Bool

  /// The site for which type inference tracing is enabled, if any.
  public let inferenceTracingRange: SourceRange?

  /// Creates a new type checker for the specified program.
  ///
  /// - Note: `program` is stored in the type checker and mutated throughout type checking (e.g.,
  ///   to insert synthesized declarations).
  public init(
    program: ScopedProgram,
    isBuiltinModuleVisible: Bool = false,
    tracingInferenceIn inferenceTracingRange: SourceRange? = nil
  ) {
    self.program = program
    self.isBuiltinModuleVisible = isBuiltinModuleVisible
    self.inferenceTracingRange = inferenceTracingRange
  }

  // MARK: Type system

  /// Returns a copy of `genericType` where occurrences of generic parameters keying `subtitutions`
  /// are replaced by their corresponding value, performing any necessary name lookup in `scope`.
  private mutating func specialized(
    _ genericType: AnyType,
    applying substitutions: [NodeID<GenericParameterDecl>: AnyType],
    in scope: AnyScopeID
  ) -> AnyType {
    func _impl(t: AnyType) -> TypeTransformAction {
      switch t.base {
      case let p as GenericTypeParameterType:
        return .stepOver(substitutions[p.decl] ?? t)

      case let t as AssociatedTypeType:
        let d = t.domain.transform(_impl)

        let candidates = lookup(program.ast[t.decl].baseName, memberOf: d, in: scope)
        if let c = candidates.uniqueElement {
          return .stepOver(MetatypeType(realize(decl: c))?.instance ?? .error)
        } else {
          return .stepOver(.error)
        }

      default:
        return .stepInto(t)
      }
    }

    return genericType.transform(_impl(t:))
  }

  /// Returns the set of traits to which `type` conforms in `scope`.
  ///
  /// - Note: If `type` is a trait, it is always contained in the returned set.
  mutating func conformedTraits<S: ScopeID>(of type: AnyType, in scope: S) -> Set<TraitType>? {
    var result: Set<TraitType> = []

    switch type.base {
    case let t as GenericTypeParameterType:
      // Generic parameters declared at trait scope conform to that trait.
      if let decl = NodeID<TraitDecl>(program.declToScope[t.decl]!) {
        return conformedTraits(of: ^TraitType(decl, ast: program.ast), in: scope)
      }

      // Conformances of other generic parameters are stored in generic environments.
      for scope in program.scopes(from: scope) where scope.kind.value is GenericScope.Type {
        guard let e = environment(of: scope) else { continue }
        result.formUnion(e.conformedTraits(of: type))
      }

    case let t as ProductType:
      let decl = program.ast[t.decl]
      let parentScope = program.declToScope[t.decl]!
      guard let traits = realize(conformances: decl.conformances, in: parentScope)
      else { return nil }

      for trait in traits {
        guard let bases = conformedTraits(of: ^trait, in: parentScope)
        else { return nil }
        result.formUnion(bases)
      }

    case let t as TraitType:
      // Gather the conformances defined at declaration.
      guard
        var work = realize(
          conformances: program.ast[t.decl].refinements,
          in: program.declToScope[t.decl]!)
      else { return nil }

      while let base = work.popFirst() {
        if base == t {
          diagnostics.insert(
            .error(circularRefinementAt: program.ast[t.decl].identifier.site))
          return nil
        } else if result.insert(base).inserted {
          guard
            let traits = realize(
              conformances: program.ast[base.decl].refinements,
              in: program.scopeToParent[base.decl]!)
          else { return nil }
          work.formUnion(traits)
        }
      }

      // Add the trait to its own conformance set.
      result.insert(t)

      // Traits can't be refined in extensions; we're done.
      return result

    case is TypeAliasType:
      break

    default:
      break
    }

    // Collect traits declared in conformance declarations.
    for i in extendingDecls(of: type, exposedTo: scope) where i.kind == ConformanceDecl.self {
      let decl = program.ast[NodeID<ConformanceDecl>(i)!]
      let parentScope = program.declToScope[i]!
      guard let traits = realize(conformances: decl.conformances, in: parentScope)
      else { return nil }

      for trait in traits {
        guard let bases = conformedTraits(of: ^trait, in: parentScope)
        else { return nil }
        result.formUnion(bases)
      }
    }

    return result
  }

  // MARK: Type checking

  /// The status of a type checking request on a declaration.
  private enum RequestStatus {

    /// Type realization has started.
    ///
    /// The type checker is realizing the overarching type of the declaration. Initiating a new
    /// type realization or type checking request on the same declaration will cause a circular
    /// dependency error.
    case typeRealizationStarted

    /// Type realization was completed.
    ///
    /// The checker realized the overarching type of the declaration, which is now available in
    /// `declTypes`.
    case typeRealizationCompleted

    /// Type checking has started.
    ///
    /// The checker is verifying whether the declaration is well-typed; its overarching type is
    /// available in `declTypes`. Initiating a new type checking request will cause a circular
    /// dependency error.
    case typeCheckingStarted

    /// Type checking succeeded.
    ///
    /// The declaration is well-typed; its overarching type is availabe in `declTypes`.
    case success

    /// Type realzation or type checking failed.
    ///
    /// If type realization succeeded, the overarching type of the declaration is available in
    /// `declTypes`. Otherwise, it is assigned to `nil`.
    case failure

  }

  /// A cache for type checking requests on declarations.
  private var declRequests = DeclProperty<RequestStatus>()

  /// A cache mapping generic declarations to their environment.
  private var environments = DeclProperty<MemoizationState<GenericEnvironment?>>()

  /// The bindings whose initializers are being currently visited.
  private var bindingsUnderChecking: DeclSet = []

  /// Adds the given diagnostic.
  mutating func addDiagnostic(_ d: Diagnostic) {
    diagnostics.insert(d)
  }

  /// Sets the realized type of `d` to `type`.
  ///
  /// - Requires: `d` has not gone through type realization yet.
  mutating func setInferredType(_ type: AnyType, for d: NodeID<VarDecl>) {
    precondition(declRequests[d] == nil)
    declTypes[d] = type
    declRequests[d] = .typeRealizationCompleted
  }

  /// Type checks the specified module, accumulating diagnostics in `self.diagnostics`
  ///
  /// - Requires: `id` is a valid ID in the type checker's AST.
  public mutating func check(module id: NodeID<ModuleDecl>) {
    // Build the type of the module.
    declTypes[id] = ^ModuleType(id, ast: program.ast)

    // Type check the declarations in the module.
    for decl in program.ast.topLevelDecls(id) {
      _ = check(decl: decl)
    }
  }

  /// Type checks the specified declaration and returns whether that succeeded.
  private mutating func check<T: DeclID>(decl id: T) -> Bool {
    switch id.kind {
    case AssociatedTypeDecl.self:
      return check(associatedType: NodeID(id)!)
    case AssociatedValueDecl.self:
      return check(associatedValue: NodeID(id)!)
    case BindingDecl.self:
      return check(binding: NodeID(id)!)
    case ConformanceDecl.self:
      return check(conformance: NodeID(id)!)
    case FunctionDecl.self:
      return check(function: NodeID(id)!)
    case GenericParameterDecl.self:
      return check(genericParameter: NodeID(id)!)
    case InitializerDecl.self:
      return check(initializer: NodeID(id)!)
    case MethodDecl.self:
      return check(method: NodeID(id)!)
    case MethodImpl.self:
      return check(method: NodeID(program.declToScope[id]!)!)
    case OperatorDecl.self:
      return check(operator: NodeID(id)!)
    case ProductTypeDecl.self:
      return check(productType: NodeID(id)!)
    case SubscriptDecl.self:
      return check(subscript: NodeID(id)!)
    case TraitDecl.self:
      return check(trait: NodeID(id)!)
    case TypeAliasDecl.self:
      return check(typeAlias: NodeID(id)!)
    default:
      unexpected(id, in: program.ast)
    }
  }

  private mutating func check(associatedType: NodeID<AssociatedTypeDecl>) -> Bool {
    return true
  }

  private mutating func check(associatedValue: NodeID<AssociatedValueDecl>) -> Bool {
    return true
  }

  private mutating func check(conformance: NodeID<ConformanceDecl>) -> Bool {
    // FIXME: implement me.
    return true
  }

  /// - Note: Method is internal because it may be called during constraint generation.
  mutating func check(binding id: NodeID<BindingDecl>) -> Bool {
    defer { assert(declTypes[id] != nil) }
    let syntax = program.ast[id]

    // Note: binding declarations do not undergo type realization.
    switch declRequests[id] {
    case nil:
      declRequests[id] = .typeCheckingStarted
    case .typeCheckingStarted:
      diagnostics.insert(.error(circularDependencyAt: syntax.site))
      return false
    case .success:
      return true
    case .failure:
      return false
    default:
      unreachable()
    }

    // Determine the shape of the declaration.
    let declScope = program.declToScope[AnyDeclID(id)]!
    let shape = inferType(
      of: AnyPatternID(syntax.pattern), in: declScope, expecting: nil)
    assert(shape.facts.inferredTypes.storage.isEmpty, "expression in binding pattern")

    if shape.type.isError {
      declTypes[id] = .error
      declRequests[id] = .failure
      return false
    }

    // Determine whether the declaration has a type annotation.
    let hasTypeHint = program.ast[syntax.pattern].annotation != nil

    // Type check the initializer, if any.
    var success = true
    if let initializer = syntax.initializer {
      let initializerType = exprTypes[initializer].setIfNil(^TypeVariable(node: initializer.base))
      var initializerConstraints: [Constraint] = shape.facts.constraints

      // The type of the initializer may be a subtype of the pattern's
      if hasTypeHint {
        initializerConstraints.append(
          SubtypingConstraint(
            initializerType, shape.type,
            because: ConstraintCause(.initializationWithHint, at: syntax.site)))
      } else {
        initializerConstraints.append(
          EqualityConstraint(
            initializerType, shape.type,
            because: ConstraintCause(.initializationWithPattern, at: syntax.site)))
      }

      // Infer the type of the initializer
      let names = program.ast.names(in: syntax.pattern).map({ (name) in
        AnyDeclID(program.ast[name.pattern].decl)
      })

      bindingsUnderChecking.formUnion(names)
      let inference = solveConstraints(
        impliedBy: initializer,
        expecting: shape.type,
        in: declScope,
        initialConstraints: initializerConstraints)
      bindingsUnderChecking.subtract(names)

      // TODO: Complete underspecified generic signatures

      success = inference.succeeded
      declTypes[id] = inference.solution.typeAssumptions.reify(shape.type)

      // Run deferred queries.
      success = shape.deferred.reduce(success, { $1(&self, inference.solution) && $0 })
    } else if hasTypeHint {
      declTypes[id] = shape.type
    } else {
      unreachable("expected type annotation")
    }

    assert(!declTypes[id]![.hasVariable])
    declRequests[id] = success ? .success : .failure
    return success
  }

  private mutating func check(conformance: ConformanceDecl) -> Bool {
    fatalError("not implemented")
  }

  private mutating func check(extension: ExtensionDecl) -> Bool {
    fatalError("not implemented")
  }

  /// Type checks the specified function declaration and returns whether that succeeded.
  ///
  /// The type of the declaration must be realizable from type annotations alone or the declaration
  /// the declaration must be realized and its inferred type must be stored in `declTyes`. Hence,
  /// the method must not be called on the underlying declaration of a lambda or spawn expression
  /// before the type of that declaration has been fully inferred.
  ///
  /// - SeeAlso: `checkPending`
  private mutating func check(function id: NodeID<FunctionDecl>) -> Bool {
    _check(decl: id, { (this, id) in this._check(function: id) })
  }

  private mutating func _check(function id: NodeID<FunctionDecl>) -> Bool {
    // Type check the generic constraints.
    var success = environment(of: id) != nil

    // Type check the parameters.
    var parameterNames: Set<String> = []
    for parameter in program.ast[id].parameters {
      success = check(parameter: parameter, siblingNames: &parameterNames) && success
    }

    // Set the type of the implicit receiver declaration if necessary.
    if program.isNonStaticMember(id) {
      let functionType = declTypes[id]!.base as! LambdaType
      let receiverDecl = program.ast[id].receiver!

      if let type = functionType.captures.first?.type.base as? RemoteType {
        declTypes[receiverDecl] = ^ParameterType(convention: type.capability, bareType: type.base)
      } else {
        // `sink` member functions capture their receiver.
        assert(program.ast[id].isSink)
        declTypes[receiverDecl] = ^ParameterType(
          convention: .sink,
          bareType: functionType.environment)
      }

      declRequests[receiverDecl] = .success
    }

    // Type check the body, if any.
    switch program.ast[id].body {
    case .block(let stmt):
      return check(brace: stmt) && success

    case .expr(let expr):
      // If `expr` has been used to infer the return type, there's no need to visit it again.
      if (program.ast[id].output == nil) && program.ast[id].isInExprContext { return success }

      // Otherwise, it's expected to have the realized return type.
      let t = deduceType(
        of: expr, expecting: LambdaType(declTypes[id]!)!.output.skolemized, in: id)
      return (t != nil) && success

    case nil:
      // Requirements and FFIs can be without a body.
      if program.isRequirement(id) || program.ast[id].isFFI { return success }

      // Declaration requires a body.
      diagnostics.insert(.error(declarationRequiresBodyAt: program.ast[id].introducerSite))
      return false
    }
  }

  private mutating func check(genericParameter id: NodeID<GenericParameterDecl>) -> Bool {
    _check(decl: id, { (this, id) in this._check(genericParameter: id) })
  }

  private mutating func _check(genericParameter id: NodeID<GenericParameterDecl>) -> Bool {
    // TODO: Type check default values.
    return true
  }

  private mutating func check(initializer id: NodeID<InitializerDecl>) -> Bool {
    _check(decl: id, { (this, id) in this._check(initializer: id) })
  }

  private mutating func _check(initializer id: NodeID<InitializerDecl>) -> Bool {
    // Memberwize initializers always type check.
    if program.ast[id].introducer.value == .memberwiseInit {
      return true
    }

    // The type of the declaration must have been realized.
    let type = declTypes[id]!.base as! LambdaType

    // Type check the generic constraints.
    var success = environment(of: id) != nil

    // Type check the parameters.
    var parameterNames: Set<String> = []
    for parameter in program.ast[id].parameters {
      success = check(parameter: parameter, siblingNames: &parameterNames) && success
    }

    // Set the type of the implicit receiver declaration.
    // Note: the receiver of an initializer is its first parameter.
    declTypes[program.ast[id].receiver] = type.inputs[0].type
    declRequests[program.ast[id].receiver] = .success

    // Type check the body, if any.
    if let body = program.ast[id].body {
      return check(brace: body) && success
    } else if program.isRequirement(id) {
      return success
    } else {
      diagnostics.insert(.error(declarationRequiresBodyAt: program.ast[id].introducer.site))
      return false
    }
  }

  private mutating func check(method id: NodeID<MethodDecl>) -> Bool {
    _check(decl: id, { (this, id) in this._check(method: id) })
  }

  private mutating func _check(method id: NodeID<MethodDecl>) -> Bool {
    // The type of the declaration must have been realized.
    let type = declTypes[id]!.base as! MethodType
    let outputType = type.output.skolemized

    // Type check the generic constraints.
    var success = environment(of: id) != nil

    // Type check the parameters.
    var parameterNames: Set<String> = []
    for parameter in program.ast[id].parameters {
      success = check(parameter: parameter, siblingNames: &parameterNames) && success
    }

    for impl in program.ast[id].impls {
      // Set the type of the implicit receiver declaration.
      declTypes[program.ast[impl].receiver] = ^ParameterType(
        convention: program.ast[impl].introducer.value.convention,
        bareType: type.receiver)
      declRequests[program.ast[impl].receiver] = .success

      // Type check method's implementations, if any.
      switch program.ast[impl].body {
      case .expr(let expr):
        let expectedType =
          program.ast[impl].introducer.value == .inout
          ? AnyType.void
          : outputType
        let inferredType = deduceType(of: expr, expecting: expectedType, in: impl)
        success = (inferredType != nil) && success

      case .block(let stmt):
        success = check(brace: stmt) && success

      case nil:
        // Requirements can be without a body.
        if program.isRequirement(id) { continue }

        // Declaration requires a body.
        diagnostics.insert(.error(declarationRequiresBodyAt: program.ast[id].introducerSite))
        success = false
      }
    }

    return success
  }

  private mutating func check(methodImpl: MethodImpl) -> Bool {
    fatalError("not implemented")
  }

  private mutating func check(namespace: NamespaceDecl) -> Bool {
    fatalError("not implemented")
  }

  /// Inserts in `siblingNames` the name of the parameter declaration identified by `id` and
  /// returns whether that declaration type checks.
  private mutating func check(
    parameter id: NodeID<ParameterDecl>,
    siblingNames: inout Set<String>
  ) -> Bool {
    // Check for duplicate parameter names.
    if !siblingNames.insert(program.ast[id].baseName).inserted {
      diagnostics.insert(
        .diganose(
          duplicateParameterNamed: program.ast[id].baseName, at: program.ast[id].site))
      declRequests[id] = .failure
      return false
    }

    // Type check the default value, if any.
    if let defaultValue = program.ast[id].defaultValue {
      let parameterType = declTypes[id]!.base as! ParameterType
      let defaultValueType = exprTypes[defaultValue].setIfNil(
        ^TypeVariable(node: defaultValue.base))

      let inference = solveConstraints(
        impliedBy: defaultValue,
        expecting: parameterType.bareType,
        in: program.declToScope[id]!,
        initialConstraints: [
          ParameterConstraint(
            defaultValueType, ^parameterType,
            because: ConstraintCause(.argument, at: program.ast[id].site))
        ])

      if !inference.succeeded {
        declRequests[id] = .failure
        return false
      }
    }

    declRequests[id] = .success
    return true
  }

  private mutating func check(operator id: NodeID<OperatorDecl>) -> Bool {
    let source = NodeID<TranslationUnit>(program.declToScope[id]!)!

    // Look for duplicate operator declaration.
    for decl in program.ast[source].decls where decl.kind == OperatorDecl.self {
      let oper = NodeID<OperatorDecl>(decl)!
      if oper != id,
        program.ast[oper].notation.value == program.ast[id].notation.value,
        program.ast[oper].name.value == program.ast[id].name.value
      {
        diagnostics.insert(
          .error(
            duplicateOperatorNamed: program.ast[id].name.value,
            at: program.ast[id].site))
        return false
      }
    }

    return true
  }

  private mutating func check(productType id: NodeID<ProductTypeDecl>) -> Bool {
    _check(decl: id, { (this, id) in this._check(productType: id) })
  }

  private mutating func _check(productType id: NodeID<ProductTypeDecl>) -> Bool {
    // Type check the memberwise initializer.
    var success = check(initializer: program.ast[id].memberwiseInit)

    // Type check the generic constraints.
    success = (environment(of: id) != nil) && success

    // Type check the type's direct members.
    for j in program.ast[id].members {
      success = check(decl: j) && success
    }

    // Type check conformances.
    let container = program.scopeToParent[id]!
    for e in program.ast[id].conformances {
      guard let rhs = realize(name: e, in: container)?.instance else { continue }
      guard let t = TraitType(rhs) else {
        diagnostics.insert(.error(conformanceToNonTraitType: rhs, at: program.ast[e].site))
        success = false
        continue
      }

      guard
        let c = checkConformance(
          of: realizeSelfTypeExpr(in: id)!.instance, to: t,
          at: program.ast[e].site, in: AnyScopeID(id))
      else {
        // Diagnostics have been reported by `checkConformance`.
        success = false
        continue
      }

      let (inserted, _) = relations.insert(c, testingContainmentWith: program)
      // TODO: Handle duplicate conformance declarations
      assert(inserted, "Not implemented")
    }

    // Type check extending declarations.
    let type = declTypes[id]!
    for j in extendingDecls(of: type, exposedTo: container) {
      success = check(decl: j) && success
    }

    // TODO: Check the conformances

    return success
  }

  private mutating func check(subscript id: NodeID<SubscriptDecl>) -> Bool {
    _check(decl: id, { (this, id) in this._check(subscript: id) })
  }

  private mutating func _check(subscript id: NodeID<SubscriptDecl>) -> Bool {
    // The type of the declaration must have been realized.
    let declType = declTypes[id]!.base as! SubscriptType
    let outputType = declType.output.skolemized

    // Type check the generic constraints.
    var success = environment(of: id) != nil

    // Type check the parameters, if any.
    if let parameters = program.ast[id].parameters {
      var parameterNames: Set<String> = []
      for parameter in parameters {
        success = check(parameter: parameter, siblingNames: &parameterNames) && success
      }
    }

    // Type checks the subscript's implementations.
    for impl in program.ast[id].impls {
      // Set the type of the implicit receiver declaration if necessary.
      if program.isNonStaticMember(id) {
        let receiverType = declType.captures.first!.type.base as! RemoteType
        let receiverDecl = program.ast[impl].receiver!

        declTypes[receiverDecl] = ^ParameterType(
          convention: program.ast[impl].introducer.value.convention,
          bareType: receiverType.base)
        declRequests[receiverDecl] = .success
      }

      // Type checks the body of the implementation.
      switch program.ast[impl].body {
      case .expr(let expr):
        success = (deduceType(of: expr, expecting: outputType, in: impl) != nil) && success

      case .block(let stmt):
        success = check(brace: stmt) && success

      case nil:
        // Requirements can be without a body.
        if program.isRequirement(id) { continue }

        // Declaration requires a body.
        diagnostics.insert(.error(declarationRequiresBodyAt: program.ast[id].introducer.site))
        success = false
      }
    }

    return success
  }

  private mutating func check(subscriptImpl: SubscriptImpl) -> Bool {
    fatalError("not implemented")
  }

  private mutating func check(trait id: NodeID<TraitDecl>) -> Bool {
    _check(decl: id, { (this, id) in this._check(trait: id) })
  }

  private mutating func _check(trait id: NodeID<TraitDecl>) -> Bool {
    // Type check the generic constraints.
    var success = environment(ofTraitDecl: id) != nil

    // Type check the type's direct members.
    for j in program.ast[id].members {
      success = check(decl: j) && success
    }

    // Type check extending declarations.
    let type = declTypes[id]!
    for j in extendingDecls(of: type, exposedTo: program.declToScope[id]!) {
      success = check(decl: j) && success
    }

    // TODO: Check the conformances

    return success
  }

  private mutating func check(typeAlias id: NodeID<TypeAliasDecl>) -> Bool {
    _check(decl: id, { (this, id) in this._check(typeAlias: id) })
  }

  private mutating func _check(typeAlias id: NodeID<TypeAliasDecl>) -> Bool {
    // Realize the subject.
    guard let subject = realize(program.ast[id].aliasedType, in: AnyScopeID(id))?.instance else {
      return false
    }

    // Type-check the generic clause.
    var success = environment(of: id) != nil

    // Type check extending declarations.
    for j in extendingDecls(of: subject, exposedTo: program.declToScope[id]!) {
      success = check(decl: j) && success
    }

    // TODO: Check the conformances

    return success
  }

  private mutating func check(`var`: VarDecl) -> Bool {
    fatalError("not implemented")
  }

  /// Returns whether `decl` is well-typed from the cache, or calls `action` to type check it
  /// and caches the result before returning it.
  private mutating func _check<T: DeclID>(
    decl id: T,
    _ action: (inout Self, T) -> Bool
  ) -> Bool {
    // Check if a type checking request has already been received.
    while true {
      switch declRequests[id] {
      case nil:
        /// The the overarching type of the declaration is available after type realization.
        defer { assert(declRequests[id] != nil) }

        // Realize the type of the declaration before starting type checking.
        if realize(decl: id).isError {
          // Type checking fails if type realization did.
          declRequests[id] = .failure
          return false
        } else {
          // Note: Because the type realization of certain declarations may escalate to type
          // checking perform type checking, we should re-check the status of the request.
          continue
        }

      case .typeRealizationCompleted:
        declRequests[id] = .typeCheckingStarted

      case .typeRealizationStarted, .typeCheckingStarted:
        // Note: The request status will be updated when the request that caused the circular
        // dependency handles the failure.
        diagnostics.insert(.error(circularDependencyAt: program.ast[id].site))
        return false

      case .success:
        return true

      case .failure:
        return false
      }

      break
    }

    // Process the request.
    let success = action(&self, id)

    // Update the request status.
    declRequests[id] = success ? .success : .failure
    return success
  }

  /// Returns an array of declaration implementing `requirement` with type `requirementType` that
  /// are member of `conformingType` and visible in `scope`.
  private mutating func gatherCandidates(
    implementing requirement: NodeID<FunctionDecl>,
    withType requirementType: AnyType,
    for conformingType: AnyType,
    in scope: AnyScopeID
  ) -> [AnyDeclID] {
    let n = Name(of: requirement, in: program.ast)!
    let lookupResult = lookup(n.stem, memberOf: conformingType, in: scope)

    // Filter out the candidates with incompatible types.
    return lookupResult.compactMap { (c) -> AnyDeclID? in
      guard
        c != requirement,
        let d = self.decl(in: c, named: n),
        relations.canonical(realize(decl: d)) == requirementType
      else { return nil }

      if let f = NodeID<FunctionDecl>(d), program.ast[f].body == nil { return nil }
      if let f = NodeID<MethodImpl>(d), program.ast[f].body == nil { return nil }

      // TODO: Filter out the candidates with incompatible constraints.
      // trait A {}
      // type Foo<T> {}
      // extension Foo where T: U { fun foo() }
      // conformance Foo: A {} // <- should not consider `foo` in the extension

      // TODO: Rank candidates

      return d
    }
  }

  /// Returns an array of declaration implementing `requirement` with type `requirementType` that
  /// are member of `conformingType` and visible in `scope`.
  private mutating func gatherCandidates(
    implementing requirement: NodeID<MethodDecl>,
    withType requirementType: AnyType,
    for conformingType: AnyType,
    in scope: AnyScopeID
  ) -> [AnyDeclID] {
    let n = Name(of: requirement, in: program.ast)
    let lookupResult = lookup(n.stem, memberOf: conformingType, in: scope)

    // Filter out the candidates with incompatible types.
    return lookupResult.compactMap { (c) -> AnyDeclID? in
      guard
        c != requirement,
        let d = self.decl(in: c, named: n),
        relations.canonical(realize(decl: d)) == requirementType
      else { return nil }

      if let f = NodeID<MethodDecl>(d) {
        if program.ast[f].impls.contains(where: ({ program.ast[$0].body == nil })) { return nil }
      }

      // TODO: Filter out the candidates with incompatible constraints.
      // trait A {}
      // type Foo<T> {}
      // extension Foo where T: U { fun foo() }
      // conformance Foo: A {} // <- should not consider `foo` in the extension

      // TODO: Rank candidates

      return d
    }
  }

  /// Returns the conformance `model` to `trait` in `scope` if it holds. Otherwise, reports missing
  /// requirements at `site` and returns `nil`.
  private mutating func checkConformance(
    of model: AnyType,
    to trait: TraitType,
    at site: SourceRange,
    in scope: AnyScopeID
  ) -> Conformance? {
    let specialization = [program.ast[trait.decl].selfParameterDecl: model]
    var implementations = Conformance.ImplementationMap()
    var notes: [Diagnostic] = []

    // Get the set of generic parameters defined by `trait`.
    for requirement in program.ast[trait.decl].members {
      let requirementType = specialized(
        relations.canonical(realize(decl: requirement)), applying: specialization, in: scope)
      if requirementType.isError { continue }

      switch requirement.kind {
      case GenericParameterDecl.self:
        assert(requirement == program.ast[trait.decl].selfParameterDecl, "unexpected declaration")
        continue

      case AssociatedTypeDecl.self:
        // TODO: Implement me.
        continue

      case FunctionDecl.self:
        let r = NodeID<FunctionDecl>(requirement)!
        let candidates = gatherCandidates(
          implementing: r, withType: requirementType, for: model, in: scope)

        if let c = candidates.uniqueElement {
          implementations[requirement] = c
        } else {
          notes.append(
            .error(
              traitRequiresMethod: Name(of: r, in: program.ast)!, withType: requirementType,
              at: site))
        }

      case MethodDecl.self:
        let r = NodeID<MethodDecl>(requirement)!
        let candidates = gatherCandidates(
          implementing: r, withType: requirementType, for: model, in: scope)

        if let c = candidates.uniqueElement {
          implementations[requirement] = c
        } else {
          notes.append(
            .error(
              traitRequiresMethod: Name(of: r, in: program.ast), withType: requirementType,
              at: site))
        }

      default:
        break
      }
    }

    if notes.isEmpty {
      return Conformance(
        model: model, concept: trait, conditions: [], scope: scope,
        implementations: implementations)
    } else {
      diagnostics.insert(.error(model, doesNotConformTo: trait, at: site, because: notes))
      return nil
    }
  }

  /// Type checks the specified statement and returns whether that succeeded.
  private mutating func check<T: StmtID, S: ScopeID>(stmt id: T, in lexicalContext: S) -> Bool {
    switch id.kind {
    case AssignStmt.self:
      return check(assign: NodeID(id)!, in: lexicalContext)

    case BraceStmt.self:
      return check(brace: NodeID(id)!)

    case ExprStmt.self:
      let stmt = program.ast[NodeID<ExprStmt>(id)!]
      if let type = deduceType(of: stmt.expr, in: lexicalContext) {
        // Issue a warning if the type of the expression isn't void.
        if type != .void {
          diagnostics.insert(
            .warning(
              unusedResultOfType: type,
              at: program.ast[stmt.expr].site))
        }
        return true
      } else {
        // Type inference/checking failed.
        return false
      }

    case DeclStmt.self:
      return check(decl: program.ast[NodeID<DeclStmt>(id)!].decl)

    case DiscardStmt.self:
      let stmt = program.ast[NodeID<DiscardStmt>(id)!]
      return deduceType(of: stmt.expr, in: lexicalContext) != nil

    case DoWhileStmt.self:
      return check(doWhile: NodeID(id)!, in: lexicalContext)

    case ReturnStmt.self:
      return check(return: NodeID(id)!, in: lexicalContext)

    case WhileStmt.self:
      return check(while: NodeID(id)!, in: lexicalContext)

    case YieldStmt.self:
      return check(yield: NodeID(id)!, in: lexicalContext)

    case WhileStmt.self:
      // TODO: properly implement this
      let stmt = program.ast[NodeID<WhileStmt>(id)!]
      var success = true
      for cond in stmt.condition {
        switch cond {
        case .expr(let condExpr):
          success =
            (deduceType(of: condExpr, expecting: nil, in: lexicalContext) != nil) && success
        default:
          success = false
        }
      }
      success = check(brace: stmt.body) && success
      return success

    case DoWhileStmt.self:
      // TODO: properly implement this
      let stmt = program.ast[NodeID<DoWhileStmt>(id)!]
      var success = true
      success = check(brace: stmt.body) && success
      success =
        (deduceType(of: stmt.condition, expecting: nil, in: lexicalContext) != nil) && success
      return success

    case ForStmt.self, BreakStmt.self, ContinueStmt.self:
      // TODO: implement checks for these statements
      return true

    default:
      unexpected(id, in: program.ast)
    }
  }

  /// - Note: Method is internal because it may be called during constraint generation.
  mutating func check(brace id: NodeID<BraceStmt>) -> Bool {
    var success = true
    for stmt in program.ast[id].stmts {
      success = check(stmt: stmt, in: id) && success
    }
    return success
  }

  private mutating func check<S: ScopeID>(
    assign id: NodeID<AssignStmt>,
    in lexicalContext: S
  ) -> Bool {
    // Infer the type on the left.
    guard let lhsType = deduceType(of: program.ast[id].left, in: lexicalContext) else {
      return false
    }

    // The type on the left must be `Sinkable`.
    let lhsConstraint = ConformanceConstraint(
      lhsType, conformsTo: [program.ast.coreTrait(named: "Sinkable")!],
      because: ConstraintCause(.initializationOrAssignment, at: program.ast[id].site))

    // Constrain the right to be subtype on the left.
    let rhsType = exprTypes[program.ast[id].right].setIfNil(
      ^TypeVariable(node: program.ast[id].right.base))
    let rhsConstraint = SubtypingConstraint(
      rhsType, lhsType,
      because: ConstraintCause(.initializationOrAssignment, at: program.ast[id].site))

    // Infer the type on the right.
    let inference = solveConstraints(
      impliedBy: AnyExprID(program.ast[id].right),
      expecting: lhsType,
      in: lexicalContext,
      initialConstraints: [lhsConstraint, rhsConstraint])
    return inference.succeeded
  }

  private mutating func check<S: ScopeID>(
    doWhile subject: NodeID<DoWhileStmt>,
    in lexicalContext: S
  ) -> Bool {
    let success = check(brace: program.ast[subject].body)

    // Visit the condition of the loop in the scope of the body.
    let boolType = AnyType(program.ast.coreType(named: "Bool")!)
    let inference = solveConstraints(
      impliedBy: program.ast[subject].condition, expecting: boolType,
      in: program.ast[subject].body)

    return success && inference.succeeded
  }

  private mutating func check<S: ScopeID>(
    return id: NodeID<ReturnStmt>,
    in lexicalContext: S
  ) -> Bool {
    // Retreive the expected output type.
    let expectedType = expectedOutputType(in: lexicalContext)!

    if let returnValue = program.ast[id].value {
      // The type of the return value must be subtype of the expected return type.
      let inferredReturnType = exprTypes[returnValue].setIfNil(
        ^TypeVariable(node: returnValue.base))
      let inference = solveConstraints(
        impliedBy: returnValue,
        expecting: expectedType,
        in: lexicalContext,
        initialConstraints: [
          SubtypingConstraint(
            inferredReturnType, expectedType,
            because: ConstraintCause(.return, at: program.ast[returnValue].site))
        ])
      return inference.succeeded
    } else if expectedType != .void {
      diagnostics.insert(.error(missingReturnValueAt: program.ast[id].site))
      return false
    } else {
      return true
    }
  }

  private mutating func check<S: ScopeID>(
    while subject: NodeID<WhileStmt>,
    in lexicalContext: S
  ) -> Bool {
    let syntax = program.ast[subject]

    // Visit the condition(s).
    let boolType = AnyType(program.ast.coreType(named: "Bool")!)
    for item in syntax.condition {
      switch item {
      case .expr(let expr):
        // Condition must be Boolean.
        let inference = solveConstraints(
          impliedBy: expr, expecting: boolType, in: lexicalContext)
        if !inference.succeeded { return false }

      case .decl(let binding):
        if !check(binding: binding) { return false }
      }
    }

    // Visit the body.
    return check(brace: syntax.body)
  }

  private mutating func check<S: ScopeID>(
    yield id: NodeID<YieldStmt>,
    in lexicalContext: S
  ) -> Bool {
    // Retreive the expected output type.
    let expectedType = expectedOutputType(in: lexicalContext)!

    // The type of the return value must be subtype of the expected return type.
    let inferredReturnType = exprTypes[program.ast[id].value].setIfNil(
      ^TypeVariable(node: program.ast[id].value.base))
    let inference = solveConstraints(
      impliedBy: program.ast[id].value,
      expecting: expectedType,
      in: lexicalContext,
      initialConstraints: [
        SubtypingConstraint(
          inferredReturnType, expectedType,
          because: ConstraintCause(.yield, at: program.ast[program.ast[id].value].site))
      ])
    return inference.succeeded
  }

  /// Returns whether `d` is well-typed, reading type inference results from `s`.
  mutating func checkDeferred(varDecl d: NodeID<VarDecl>, _ s: Solution) -> Bool {
    let success = modifying(
      &declTypes[d]!,
      { (t) in
        t = s.typeAssumptions.reify(t)
        return !t[.hasError]
      })
    declRequests[d] = success ? .success : .failure
    return success
  }

  /// Returns whether `e` is well-typed, reading type inference results from `s`.
  mutating func checkDeferred(lambdaExpr e: NodeID<LambdaExpr>, _ s: Solution) -> Bool {
    guard
      let declType = exprTypes[e]?.base as? LambdaType,
      !declType[.hasError]
    else { return false }

    // Reify the type of the underlying declaration.
    declTypes[program.ast[e].decl] = ^declType
    let parameters = program.ast[program.ast[e].decl].parameters
    for i in 0 ..< parameters.count {
      declTypes[parameters[i]] = declType.inputs[i].type
    }

    // Type check the declaration.
    return check(function: program.ast[e].decl)
  }

  /// Returns the expected output type in `lexicalContext`, or `nil` if `lexicalContext` is not
  /// nested in a function or subscript declaration.
  private func expectedOutputType<S: ScopeID>(in lexicalContext: S) -> AnyType? {
    for parent in program.scopes(from: lexicalContext) {
      switch parent.kind {
      case MethodImpl.self:
        // `lexicalContext` is nested in a method implementation.
        let decl = NodeID<MethodImpl>(parent)!
        if program.ast[decl].introducer.value == .inout {
          return .void
        } else {
          let methodDecl = NodeID<FunctionDecl>(program.scopeToParent[decl]!)!
          let methodType = declTypes[methodDecl]!.base as! MethodType
          return methodType.output.skolemized
        }

      case FunctionDecl.self:
        // `lexicalContext` is nested in a function.
        let decl = NodeID<FunctionDecl>(parent)!
        let funType = declTypes[decl]!.base as! LambdaType
        return funType.output.skolemized

      case SubscriptDecl.self:
        // `lexicalContext` is nested in a subscript implementation.
        let decl = NodeID<SubscriptDecl>(parent)!
        let subscriptType = declTypes[decl]!.base as! SubscriptType
        return subscriptType.output.skolemized

      default:
        continue
      }
    }

    return nil
  }

  /// Returns the generic environment defined by `node`, or `nil` if either `node`'s environment
  /// is ill-formed or if node doesn't outline a generic lexical scope.
  private mutating func environment<T: NodeIDProtocol>(of node: T) -> GenericEnvironment? {
    switch node.kind {
    case FunctionDecl.self:
      return environment(of: NodeID<FunctionDecl>(node)!)
    case ProductTypeDecl.self:
      return environment(of: NodeID<ProductTypeDecl>(node)!)
    case SubscriptDecl.self:
      return environment(of: NodeID<SubscriptDecl>(node)!)
    case TypeAliasDecl.self:
      return environment(of: NodeID<TypeAliasDecl>(node)!)
    case TraitDecl.self:
      return environment(ofTraitDecl: NodeID(node)!)
    default:
      return nil
    }
  }

  /// Returns the generic environment defined by `id`, or `nil` if it is ill-typed.
  private mutating func environment<T: GenericDecl>(of id: NodeID<T>) -> GenericEnvironment? {
    assert(T.self != TraitDecl.self, "trait environements use a more specialized method")

    switch environments[id] {
    case .done(let e):
      return e
    case .inProgress:
      fatalError("circular dependency")
    case nil:
      environments[id] = .inProgress
    }

    // Nothing to do if the declaration has no generic clause.
    guard let clause = program.ast[id].genericClause?.value else {
      let e = GenericEnvironment(decl: id, parameters: [], constraints: [], into: &self)
      environments[id] = .done(e)
      return e
    }

    var success = true
    var constraints: [Constraint] = []

    // Check the conformance list of each generic type parameter.
    for p in clause.parameters {
      // Realize the parameter's declaration.
      let parameterType = realize(genericParameterDecl: p)
      if parameterType.isError { return nil }

      // TODO: Type check default values.

      // Skip value declarations.
      guard
        let lhs = MetatypeType(parameterType)?.instance,
        lhs.base is GenericTypeParameterType
      else {
        continue
      }

      // Synthesize the sugared conformance constraint, if any.
      let list = program.ast[p].conformances
      guard
        let traits = realize(
          conformances: list,
          in: program.scopeToParent[AnyScopeID(id)!]!)
      else { return nil }

      if !traits.isEmpty {
        let cause = ConstraintCause(.annotation, at: program.ast[list[0]].site)
        constraints.append(ConformanceConstraint(lhs, conformsTo: traits, because: cause))
      }
    }

    // Evaluate the constraint expressions of the associated type's where clause.
    if let whereClause = clause.whereClause?.value {
      for expr in whereClause.constraints {
        if let constraint = eval(constraintExpr: expr, in: AnyScopeID(id)!) {
          constraints.append(constraint)
        } else {
          success = false
        }
      }
    }

    if success {
      let e = GenericEnvironment(
        decl: id, parameters: clause.parameters, constraints: constraints, into: &self)
      environments[id] = .done(e)
      return e
    } else {
      environments[id] = .done(nil)
      return nil
    }
  }

  /// Returns the generic environment defined by `i`, or `nil` if it is ill-typed.
  private mutating func environment<T: TypeExtendingDecl>(
    ofTypeExtendingDecl id: NodeID<T>
  ) -> GenericEnvironment? {
    switch environments[id] {
    case .done(let e):
      return e
    case .inProgress:
      fatalError("circular dependency")
    case nil:
      environments[id] = .inProgress
    }

    let scope = AnyScopeID(id)
    var success = true
    var constraints: [Constraint] = []

    // Evaluate the constraint expressions of the associated type's where clause.
    if let whereClause = program.ast[id].whereClause?.value {
      for expr in whereClause.constraints {
        if let constraint = eval(constraintExpr: expr, in: scope) {
          constraints.append(constraint)
        } else {
          success = false
        }
      }
    }

    if success {
      let e = GenericEnvironment(decl: id, parameters: [], constraints: constraints, into: &self)
      environments[id] = .done(e)
      return e
    } else {
      environments[id] = .done(nil)
      return nil
    }
  }

  /// Returns the generic environment defined by `i`, or `nil` if it is ill-typed.
  private mutating func environment(
    ofTraitDecl id: NodeID<TraitDecl>
  ) -> GenericEnvironment? {
    switch environments[id] {
    case .done(let e):
      return e
    case .inProgress:
      fatalError("circular dependency")
    case nil:
      environments[id] = .inProgress
    }

    /// Indicates whether the checker failed to evaluate an associated constraint.
    var success = true
    /// The constraints on the trait's associated types and values.
    var constraints: [Constraint] = []

    // Collect and type check the constraints defined on associated types and values.
    for member in program.ast[id].members {
      switch member.kind {
      case AssociatedTypeDecl.self:
        success =
          associatedConstraints(
            ofType: NodeID(member)!, ofTrait: id, into: &constraints) && success

      case AssociatedValueDecl.self:
        success =
          associatedConstraints(
            ofValue: NodeID(member)!, ofTrait: id, into: &constraints) && success

      default:
        continue
      }
    }

    // Bail out if we found ill-form constraints.
    if !success {
      environments[id] = .done(nil)
      return nil
    }

    // Synthesize `Self: T`.
    let selfDecl = program.ast[id].selfParameterDecl
    let selfType = GenericTypeParameterType(selfDecl, ast: program.ast)
    let declaredTrait = TraitType(MetatypeType(declTypes[id]!)!.instance)!
    constraints.append(
      ConformanceConstraint(
        ^selfType, conformsTo: [declaredTrait],
        because: ConstraintCause(.structural, at: program.ast[id].identifier.site)))

    let e = GenericEnvironment(
      decl: id, parameters: [selfDecl], constraints: constraints, into: &self)
    environments[id] = .done(e)
    return e
  }

  // Evaluates the constraints declared in `associatedType`, stores them in `constraints` and
  // returns whether they are all well-typed.
  private mutating func associatedConstraints(
    ofType associatedType: NodeID<AssociatedTypeDecl>,
    ofTrait trait: NodeID<TraitDecl>,
    into constraints: inout [Constraint]
  ) -> Bool {
    // Realize the LHS of the constraint.
    let lhs = realize(decl: associatedType)
    if lhs.isError { return false }

    // Synthesize the sugared conformance constraint, if any.
    let list = program.ast[associatedType].conformances
    guard
      let traits = realize(
        conformances: list,
        in: AnyScopeID(trait))
    else { return false }

    if !traits.isEmpty {
      let cause = ConstraintCause(.annotation, at: program.ast[list[0]].site)
      constraints.append(ConformanceConstraint(lhs, conformsTo: traits, because: cause))
    }

    // Evaluate the constraint expressions of the associated type's where clause.
    var success = true
    if let whereClause = program.ast[associatedType].whereClause?.value {
      for expr in whereClause.constraints {
        if let constraint = eval(constraintExpr: expr, in: AnyScopeID(trait)) {
          constraints.append(constraint)
        } else {
          success = false
        }
      }
    }

    return success
  }

  // Evaluates the constraints declared in `associatedValue`, stores them in `constraints` and
  // returns whether they are all well-typed.
  private mutating func associatedConstraints(
    ofValue associatedValue: NodeID<AssociatedValueDecl>,
    ofTrait trait: NodeID<TraitDecl>,
    into constraints: inout [Constraint]
  ) -> Bool {
    // Realize the LHS of the constraint.
    if realize(decl: associatedValue).isError { return false }

    // Evaluate the constraint expressions of the associated value's where clause.
    var success = true
    if let whereClause = program.ast[associatedValue].whereClause?.value {
      for expr in whereClause.constraints {
        if let constraint = eval(constraintExpr: expr, in: AnyScopeID(trait)) {
          constraints.append(constraint)
        } else {
          success = false
        }
      }
    }

    return success
  }

  /// Evaluates `expr` in `scope` and returns a type constraint, or `nil` if evaluation failed.
  ///
  /// - Note: Calling this method multiple times with the same arguments may duplicate diagnostics.
  private mutating func eval(
    constraintExpr expr: SourceRepresentable<WhereClause.ConstraintExpr>,
    in scope: AnyScopeID
  ) -> Constraint? {
    switch expr.value {
    case .equality(let l, let r):
      guard let a = realize(name: l, in: scope)?.instance else { return nil }
      guard let b = realize(r, in: scope)?.instance else { return nil }

      if !a.isTypeParam && !b.isTypeParam {
        diagnostics.insert(.error(invalidEqualityConstraintBetween: a, and: b, at: expr.site))
        return nil
      }

      return EqualityConstraint(a, b, because: ConstraintCause(.structural, at: expr.site))

    case .conformance(let l, let traits):
      guard let a = realize(name: l, in: scope)?.instance else { return nil }
      if !a.isTypeParam {
        diagnostics.insert(.error(invalidConformanceConstraintTo: a, at: expr.site))
        return nil
      }

      var b: Set<TraitType> = []
      for i in traits {
        guard let type = realize(name: i, in: scope)?.instance else { return nil }
        if let trait = type.base as? TraitType {
          b.insert(trait)
        } else {
          diagnostics.insert(.error(conformanceToNonTraitType: a, at: expr.site))
          return nil
        }
      }

      return ConformanceConstraint(
        a, conformsTo: b, because: ConstraintCause(.structural, at: expr.site))

    case .value(let e):
      // TODO: Symbolic execution
      return PredicateConstraint(e, because: ConstraintCause(.structural, at: expr.site))
    }
  }

  // MARK: Type inference

  /// Returns the type of `subject` knowing it occurs in `scope` and is expected to have a type
  /// compatible with `expectedType`.
  ///
  /// - Parameters:
  ///   - subject: The expression whose type should be deduced.
  ///   - expectedType: The type `subject` is expected to have using top-bottom information flow
  ///     or `nil` of such type is unknown.
  ///   - scope: The innermost scope containing `subject`.
  private mutating func deduceType<S: ScopeID>(
    of subject: AnyExprID,
    expecting expectedType: AnyType? = nil,
    in scope: S
  ) -> AnyType? {
    solveConstraints(impliedBy: subject, expecting: expectedType, in: scope).succeeded
      ? exprTypes[subject]!
      : nil
  }

  /// Returns the best solution satisfying `initialConstraints` and describing how to assign types
  /// to `subject` and its sub-expressions and knowing it occurs in `scope` and is expected to have
  /// a type compatible with `expectedType`.
  ///
  /// - Parameters:
  ///   - subject: The expression whose constituent types should be deduced.
  ///   - expectedType: The type `subject` is expected to have given the context it which it
  ///     occurs, or `nil` if no such type exists.
  ///   - scope: The innermost scope containing `subject`.
  ///   - initialConstraints: A collection of constraints on constituent types of `subject`.
  mutating func solveConstraints<S: ScopeID>(
    impliedBy subject: AnyExprID,
    expecting expectedType: AnyType?,
    in scope: S,
    initialConstraints: [Constraint] = []
  ) -> (succeeded: Bool, solution: Solution) {
    // Determine whether tracing should be enabled.
    let shouldLogTrace: Bool
    if let tracingSite = inferenceTracingRange,
      tracingSite.contains(program.ast[subject].site.first())
    {
      let subjectSite = program.ast[subject].site
      shouldLogTrace = true
      let loc = subjectSite.first()
      let subjectDescription = subjectSite.file[subjectSite]
      print("Inferring type of '\(subjectDescription)' at \(loc)")
      print("---")
    } else {
      shouldLogTrace = false
    }

    // Generate constraints.
    let (inferredType, facts, deferredQueries) = inferType(
      of: subject, in: AnyScopeID(scope), expecting: expectedType)

    // Bail out if constraint generation failed.
    if facts.foundConflict {
      return (succeeded: false, solution: .init())
    }

    // Solve the constraints.
    var solver = ConstraintSolver(
      scope: AnyScopeID(scope),
      fresh: initialConstraints + facts.constraints,
      comparingSolutionsWith: inferredType,
      loggingTrace: shouldLogTrace)
    let solution = solver.apply(using: &self)

    if shouldLogTrace {
      print(solution)
    }

    // Apply the solution.
    for (id, type) in facts.inferredTypes.storage {
      exprTypes[id] = solution.typeAssumptions.reify(type)
    }
    for (name, ref) in solution.bindingAssumptions {
      referredDecls[name] = ref
    }

    // Run deferred queries.
    let success = deferredQueries.reduce(
      !solution.diagnostics.containsError, { (s, q) in q(&self, solution) && s })

    diagnostics.formUnion(solution.diagnostics)
    return (succeeded: success, solution: solution)
  }

  // MARK: Name binding

  /// The result of a name lookup.
  public typealias DeclSet = Set<AnyDeclID>

  /// A lookup table.
  private typealias LookupTable = [String: DeclSet]

  private struct MemberLookupKey: Hashable {

    var type: AnyType

    var scope: AnyScopeID

  }

  /// The member lookup tables of the types.
  ///
  /// This property is used to memoize the results of `lookup(_:memberOf:in)`.
  private var memberLookupTables: [MemberLookupKey: LookupTable] = [:]

  /// A set containing the type extending declarations being currently bounded.
  ///
  /// This property is used during conformance and extension binding to avoid infinite recursion
  /// through qualified lookups into the extended type.
  private var extensionsUnderBinding = DeclSet()

  /// The result of a name resolution request.
  enum NameResolutionResult {

    /// A candidate found by name resolution.
    struct Candidate {

      /// Declaration being referenced.
      let reference: DeclRef

      /// The quantifier-free type of the declaration at its use site.
      let type: InstantiatedType

    }

    /// The resolut of name resolution for a single name component.
    struct ResolvedComponent {

      /// The resolved component.
      let component: NodeID<NameExpr>

      /// The declarations to which the component may refer.
      let candidates: [Candidate]

      /// Creates an instance with the given properties.
      init(_ component: NodeID<NameExpr>, _ candidates: [Candidate]) {
        self.component = component
        self.candidates = candidates
      }

    }

    /// Name resolution applied on the nominal prefix that doesn't require any overload resolution.
    /// The payload contains the collections of resolved and unresolved components.
    case done(resolved: [ResolvedComponent], unresolved: [NodeID<NameExpr>])

    /// Name resolution failed.
    case failed

    /// Name resolution couln't start because the first component of the expression isn't a name
    /// The payload contains the collection of unresolved components, after the first one.
    case inexecutable(_ components: [NodeID<NameExpr>])

  }

  /// Resolves the name components of `nameExpr` from left to right until multiple candidate
  /// declarations are found for a single component, or name resolution failed.
  mutating func resolve(
    nominalPrefixOf nameExpr: NodeID<NameExpr>,
    from lookupScope: AnyScopeID
  ) -> NameResolutionResult {
    // Build a stack with the nominal comonents of `nameExpr` or exit if its qualification is
    // either implicit or prefixed by an expression.
    var unresolvedComponents = [nameExpr]
    loop: while true {
      switch program.ast[unresolvedComponents.last!].domain {
      case .implicit:
        return .inexecutable(unresolvedComponents)

      case .expr(let e):
        guard let domain = NodeID<NameExpr>(e) else { return .inexecutable(unresolvedComponents) }
        unresolvedComponents.append(domain)

      case .none:
        break loop
      }
    }

    // Resolve the nominal components of `nameExpr` from left to right as long as we don't need
    // contextual information to resolve overload sets.
    var resolvedPrefix: [NameResolutionResult.ResolvedComponent] = []
    var parentType: AnyType? = nil

    while let component = unresolvedComponents.popLast() {
      // Evaluate the static argument list.
      var arguments: [AnyType] = []
      for a in program.ast[component].arguments {
        guard let type = realize(a.value, in: lookupScope)?.instance else { return .failed }
        arguments.append(type)
      }

      // Resolve the component.
      let componentSyntax = program.ast[component]
      let candidates = resolve(
        componentSyntax.name, withArguments: arguments, memberOf: parentType, from: lookupScope)

      // Fail resolution we didn't find any candidate.
      if candidates.isEmpty { return .failed }

      // Append the resolved component to the nominal prefix.
      resolvedPrefix.append(.init(component, candidates))

      // Defer resolution of the suffix if there are multiple candidates.
      if candidates.count > 1 { break }

      // If the candidate is a direct reference to a type declaration, the next component should be
      // looked up in the referred type's declaration space rather than that of its metatype.
      if let d = candidates[0].reference.decl, isNominalTypeDecl(d) {
        parentType = MetatypeType(candidates[0].type.shape)!.instance
      } else {
        parentType = candidates[0].type.shape
      }
    }

    return .done(resolved: resolvedPrefix, unresolved: unresolvedComponents)
  }

  /// Returns the declarations of `name` exposed to `lookupScope` and accepting `arguments`,
  /// searching in the declaration space of `parentType` if it isn't `nil`, or using unqualified
  /// lookup otherwise.
  mutating func resolve(
    _ name: SourceRepresentable<Name>,
    withArguments arguments: [AnyType],
    memberOf parentType: AnyType?,
    from lookupScope: AnyScopeID
  ) -> [NameResolutionResult.Candidate] {
    // Handle references to the built-in module.
    if (name.value.stem == "Builtin") && (parentType == nil) && isBuiltinModuleVisible {
      return [
        .init(reference: .builtinType, type: .init(shape: ^BuiltinType.module, constraints: []))
      ]
    }

    // Handle references to built-in symbols.
    if parentType == .builtin(.module) {
      return resolve(builtin: name.value).map({ [$0] }) ?? []
    }

    // Gather declarations qualified by `parentType` if it isn't `nil` or unqualified otherwise.
    let matches: [AnyDeclID]
    if let t = parentType {
      matches = lookup(name.value.stem, memberOf: t, in: lookupScope)
        .compactMap({ decl(in: $0, named: name.value) })
    } else {
      matches = lookup(unqualified: name.value.stem, in: lookupScope)
        .compactMap({ decl(in: $0, named: name.value) })
    }

    // Diagnose undefined symbols.
    if matches.isEmpty {
      diagnostics.insert(.error(undefinedName: name.value, in: parentType, at: name.site))
      return []
    }

    // Create declaration references to the remaining candidates.
    var candidates: [NameResolutionResult.Candidate] = []
    var invalidArgumentsDiagnostics: [Diagnostic] = []

    let isInMemberContext = program.isMemberContext(lookupScope)
    for match in matches {
      // Realize the type of the declaration.
      var targetType = realize(decl: match)

      // Erase parameter conventions.
      if let t = ParameterType(targetType) {
        targetType = t.bareType
      }

      // Apply the static arguments, if any.
      if !arguments.isEmpty {
        // Declaration must be generic.
        guard let env = environment(of: match) else {
          invalidArgumentsDiagnostics.append(
            .error(
              invalidGenericArgumentCountTo: name,
              found: arguments.count, expected: 0))
          continue
        }

        // Declaration must accept the given arguments.
        // TODO: Check labels
        guard env.parameters.count == arguments.count else {
          invalidArgumentsDiagnostics.append(
            .error(
              invalidGenericArgumentCountTo: name,
              found: arguments.count, expected: env.parameters.count))
          continue
        }

        // Apply the arguments.
        targetType = specialized(
          targetType,
          applying: .init(uniqueKeysWithValues: zip(env.parameters, arguments)),
          in: lookupScope)
      }

      // Give up if the declaration has an error type.
      if targetType.isError { continue }

      // Determine how the declaration is being referenced.
      let reference: DeclRef =
        isInMemberContext && program.isMember(match)
        ? .member(match)
        : .direct(match)

      // Instantiate the type of the declaration
      let c = ConstraintCause(.binding, at: name.site)
      switch reference {
      case .direct(let d):
        candidates.append(
          .init(
            reference: reference,
            type: instantiate(targetType, in: program.scopeIntroducing(d), cause: c)))

      case .member(let d):
        candidates.append(
          .init(
            reference: reference,
            type: instantiate(targetType, in: program.scopeIntroducing(d), cause: c)))

      case .builtinFunction, .builtinType:
        candidates.append(
          .init(reference: reference, type: .init(shape: targetType, constraints: [])))
      }
    }

    // If there are no candidates left, diagnose an error.
    if candidates.isEmpty && !invalidArgumentsDiagnostics.isEmpty {
      if let diagnostic = invalidArgumentsDiagnostics.uniqueElement {
        diagnostics.insert(diagnostic)
      } else {
        diagnostics.insert(
          .error(
            invalidGenericArgumentsTo: name,
            candidateDiagnostics: invalidArgumentsDiagnostics))
      }
    }

    return candidates
  }

  /// Resolves a reference to the built-in symbol named `name`.
  private func resolve(builtin name: Name) -> NameResolutionResult.Candidate? {
    if let f = BuiltinFunction(name.stem) {
      return .init(reference: .builtinFunction(f), type: .init(shape: ^f.type, constraints: []))
    }
    if let t = BuiltinType(name.stem) {
      return .init(reference: .builtinType, type: .init(shape: ^t, constraints: []))
    }
    return nil
  }

  /// Returns the declarations that expose `baseName` without qualification in `scope`.
  mutating func lookup(unqualified baseName: String, in scope: AnyScopeID) -> DeclSet {
    let site = scope

    var matches = DeclSet()
    var root: NodeID<ModuleDecl>? = nil
    for scope in program.scopes(from: scope) {
      switch scope.kind {
      case ModuleDecl.self:
        // We reached the module scope.
        root = NodeID<ModuleDecl>(scope)!

      case TranslationUnit.self:
        // Skip file scopes so that we don't search the same file twice.
        continue

      default:
        break
      }

      // Search for the identifier in the current scope.
      let newMatches = lookup(baseName, introducedInDeclSpaceOf: scope, in: site)
        .subtracting(bindingsUnderChecking)

      // We can assume the matches are either empty or all overloadable.
      matches.formUnion(newMatches)

      // We're done if we found at least one non-overloadable match.
      if newMatches.contains(where: { (i) in !(program.ast[i] is FunctionDecl) }) {
        return matches
      }
    }

    // We're done if we found at least one match.
    if !matches.isEmpty { return matches }

    // Check if the identifier refers to the module containing `scope`.
    if program.ast[root]?.baseName == baseName {
      return [AnyDeclID(root!)]
    }

    // Search for the identifier in imported modules.
    for module in program.ast.modules where module != root {
      matches.formUnion(names(introducedIn: module)[baseName, default: []])
    }

    return matches
  }

  /// Returns the declarations that introduce a name whose stem is `baseName` in the declaration
  /// space of `lookupContext`.
  mutating func lookup<T: ScopeID>(
    _ baseName: String,
    introducedInDeclSpaceOf lookupContext: T,
    in site: AnyScopeID
  ) -> DeclSet {
    switch lookupContext.kind {
    case ProductTypeDecl.self:
      let type = ^ProductType(NodeID(lookupContext)!, ast: program.ast)
      return lookup(baseName, memberOf: type, in: site)

    case TraitDecl.self:
      let type = ^TraitType(NodeID(lookupContext)!, ast: program.ast)
      return lookup(baseName, memberOf: type, in: site)

    case TypeAliasDecl.self:
      // We can't re-enter `realize(typeAliasDecl:)` if the aliased type of `d` is being resolved
      // but its generic parameters can be lookep up already.
      let d = NodeID<TypeAliasDecl>(lookupContext)!
      if declRequests[d] == .typeRealizationStarted {
        return names(introducedIn: d)[baseName, default: []]
      }

      if let t = MetatypeType(realize(typeAliasDecl: d))?.instance {
        return t.isError ? [] : lookup(baseName, memberOf: t, in: site)
      } else {
        return []
      }

    default:
      return names(introducedIn: lookupContext)[baseName, default: []]
    }
  }

  /// Returns the declarations that introduce a name whose stem is `baseName` as a member of `type`
  /// in `scope`.
  mutating func lookup(
    _ baseName: String,
    memberOf type: AnyType,
    in scope: AnyScopeID
  ) -> DeclSet {
    if let t = type.base as? ConformanceLensType {
      return lookup(baseName, memberOf: ^t.lens, in: scope)
    }

    let key = MemberLookupKey(type: type, scope: scope)
    if let m = memberLookupTables[key]?[baseName] {
      return m
    }

    var matches: DeclSet
    defer { memberLookupTables[key, default: [:]][baseName] = matches }

    switch type.base {
    case let t as BoundGenericType:
      matches = lookup(baseName, memberOf: t.base, in: scope)
      return matches

    case let t as ProductType:
      matches = names(introducedIn: t.decl)[baseName, default: []]
      if baseName == "init" {
        matches.insert(AnyDeclID(program.ast[t.decl].memberwiseInit))
      }

    case let t as TraitType:
      matches = names(introducedIn: t.decl)[baseName, default: []]

    case let t as TypeAliasType:
      matches = names(introducedIn: t.decl)[baseName, default: []]

    default:
      matches = DeclSet()
    }

    // We're done if we found at least one non-overloadable match.
    if matches.contains(where: { i in !(program.ast[i] is FunctionDecl) }) {
      return matches
    }

    // Look for members declared in extensions.
    for i in extendingDecls(of: type, exposedTo: scope) {
      matches.formUnion(names(introducedIn: i)[baseName, default: []])
    }

    // We're done if we found at least one non-overloadable match.
    if matches.contains(where: { i in !(program.ast[i] is FunctionDecl) }) {
      return matches
    }

    // Look for members declared inherited by conformance/refinement.
    guard let traits = conformedTraits(of: type, in: scope) else { return matches }
    for trait in traits {
      if type == trait { continue }

      // TODO: Read source of conformance to disambiguate associated names
      let newMatches = lookup(baseName, memberOf: ^trait, in: scope)
      switch type.base {
      case is AssociatedTypeType,
        is GenericTypeParameterType,
        is TraitType:
        matches.formUnion(newMatches)

      default:
        // Associated type and value declarations are not inherited by conformance.
        matches.formUnion(
          newMatches.filter({
            $0.kind != AssociatedTypeDecl.self && $0.kind != AssociatedValueDecl.self
          }))
      }
    }

    return matches
  }

  /// Returns the declaration(s) of the specified operator that are visible in `scope`.
  func lookup(
    operator operatorName: Identifier,
    notation: OperatorNotation,
    in scope: AnyScopeID
  ) -> [NodeID<OperatorDecl>] {
    let currentModule = program.module(containing: scope)
    if let module = currentModule,
      let oper = lookup(operator: operatorName, notation: notation, in: module)
    {
      return [oper]
    }

    return program.ast.modules.compactMap({ (module) -> NodeID<OperatorDecl>? in
      if module == currentModule { return nil }
      return lookup(operator: operatorName, notation: notation, in: module)
    })
  }

  /// Returns the declaration of the specified operator in `module`, if any.
  func lookup(
    operator operatorName: Identifier,
    notation: OperatorNotation,
    in module: NodeID<ModuleDecl>
  ) -> NodeID<OperatorDecl>? {
    for decl in program.ast.topLevelDecls(module) where decl.kind == OperatorDecl.self {
      let oper = NodeID<OperatorDecl>(decl)!
      if program.ast[oper].notation.value == notation
        && program.ast[oper].name.value == operatorName
      {
        return oper
      }
    }
    return nil
  }

  /// Returns the extending declarations of `subject` exposed to `scope`.
  ///
  /// - Note: The declarations referred by the returned IDs conform to `TypeExtendingDecl`.
  private mutating func extendingDecls<S: ScopeID>(
    of subject: AnyType,
    exposedTo scope: S
  ) -> [AnyDeclID] {
    /// The canonical form of `subject`.
    let canonicalSubject = relations.canonical(subject)
    /// The declarations extending `subject`.
    var matches: [AnyDeclID] = []
    /// The module at the root of `scope`, when found.
    var root: NodeID<ModuleDecl>? = nil

    // Look for extension declarations in all visible scopes.
    for scope in program.scopes(from: scope) {
      switch scope.kind {
      case ModuleDecl.self:
        let module = NodeID<ModuleDecl>(scope)!
        insert(
          into: &matches,
          decls: program.ast.topLevelDecls(module),
          extending: canonicalSubject,
          in: scope)
        root = module

      case TranslationUnit.self:
        continue

      default:
        let decls = program.scopeToDecls[scope, default: []]
        insert(into: &matches, decls: decls, extending: canonicalSubject, in: scope)
      }
    }

    // Look for extension declarations in imported modules.
    for module in program.ast.modules where module != root {
      insert(
        into: &matches,
        decls: program.ast.topLevelDecls(module),
        extending: canonicalSubject,
        in: AnyScopeID(module))
    }

    return matches
  }

  /// Insert into `matches` the declarations in `decls` that extend `subject` in `scope`.
  ///
  /// - Requires: `subject` must be canonical.
  private mutating func insert<S: Sequence>(
    into matches: inout [AnyDeclID],
    decls: S,
    extending subject: AnyType,
    in scope: AnyScopeID
  )
  where S.Element == AnyDeclID {
    precondition(subject[.isCanonical])

    for i in decls where i.kind == ConformanceDecl.self || i.kind == ExtensionDecl.self {
      // Skip extending declarations that are being bound.
      guard extensionsUnderBinding.insert(i).inserted else { continue }
      defer { extensionsUnderBinding.remove(i) }

      // Check for matches.
      guard let extendedType = realize(decl: i).base as? MetatypeType else { continue }
      if relations.canonical(extendedType.instance) == subject {
        matches.append(i)
      }
    }
  }

  /// Returns the names and declarations introduced in `scope`.
  private func names<T: NodeIDProtocol>(introducedIn scope: T) -> LookupTable {
    if let module = NodeID<ModuleDecl>(scope) {
      return program.ast[module].sources.reduce(
        into: [:],
        { (table, s) in
          table.merge(names(introducedIn: s), uniquingKeysWith: { (l, _) in l })
        })
    }

    guard let decls = program.scopeToDecls[scope] else { return [:] }
    var table: LookupTable = [:]

    for id in decls {
      switch id.kind {
      case AssociatedValueDecl.self,
        AssociatedTypeDecl.self,
        GenericParameterDecl.self,
        NamespaceDecl.self,
        ParameterDecl.self,
        ProductTypeDecl.self,
        TraitDecl.self,
        TypeAliasDecl.self,
        VarDecl.self:
        let name = (program.ast[id] as! SingleEntityDecl).baseName
        table[name, default: []].insert(id)

      case BindingDecl.self,
        ConformanceDecl.self,
        MethodImpl.self,
        OperatorDecl.self,
        SubscriptImpl.self:
        // Note: operator declarations are not considered during standard name lookup.
        break

      case FunctionDecl.self:
        let node = program.ast[NodeID<FunctionDecl>(id)!]
        guard let i = node.identifier?.value else { continue }
        table[i, default: []].insert(id)

      case InitializerDecl.self:
        table["init", default: []].insert(id)

      case MethodDecl.self:
        let node = program.ast[NodeID<MethodDecl>(id)!]
        table[node.identifier.value, default: []].insert(id)

      case SubscriptDecl.self:
        let node = program.ast[NodeID<SubscriptDecl>(id)!]
        let i = node.identifier?.value ?? "[]"
        table[i, default: []].insert(id)

      default:
        unexpected(id, in: program.ast)
      }
    }

    // Note: Results should be memoized.
    return table
  }

  // MARK: Type realization

  /// Realizes and returns the type denoted by `expr` evaluated in `scope`.
  mutating func realize(_ expr: AnyExprID, in scope: AnyScopeID) -> MetatypeType? {
    switch expr.kind {
    case ConformanceLensTypeExpr.self:
      return realize(conformanceLens: NodeID(expr)!, in: scope)

    case LambdaTypeExpr.self:
      return realize(lambda: NodeID(expr)!, in: scope)

    case NameExpr.self:
      return realize(name: NodeID(expr)!, in: scope)

    case ParameterTypeExpr.self:
      let id = NodeID<ParameterTypeExpr>(expr)!
      diagnostics.insert(
        .error(
          illegalParameterConvention: program.ast[id].convention.value,
          at: program.ast[id].convention.site))
      return nil

    case TupleTypeExpr.self:
      return realize(tuple: NodeID(expr)!, in: scope)

    case WildcardExpr.self:
      return MetatypeType(of: TypeVariable(node: expr.base))

    default:
      unexpected(expr, in: program.ast)
    }
  }

  /// Returns the type of the function declaration underlying `expr`.
  mutating func realize(underlyingDeclOf expr: NodeID<LambdaExpr>) -> AnyType? {
    realize(functionDecl: program.ast[expr].decl)
  }

  /// Realizes and returns a "magic" type expression.
  private mutating func realizeMagicTypeExpr(
    _ expr: NodeID<NameExpr>,
    in scope: AnyScopeID
  ) -> MetatypeType? {
    precondition(program.ast[expr].domain == .none)

    // Determine the "magic" type expression to realize.
    let name = program.ast[expr].name
    switch name.value.stem {
    case "Sum":
      return realizeSumTypeExpr(expr, in: scope)
    default:
      break
    }

    // Evaluate the static argument list.
    var arguments: [(value: BoundGenericType.Argument, site: SourceRange)] = []
    for a in program.ast[expr].arguments {
      // TODO: Symbolic execution
      guard let type = realize(a.value, in: scope)?.instance else { return nil }
      arguments.append((value: .type(type), site: program.ast[a.value].site))
    }

    switch name.value.stem {
    case "Any":
      let type = MetatypeType(of: .any)
      if arguments.count > 0 {
        diagnostics.insert(.error(argumentToNonGenericType: type.instance, at: name.site))
        return nil
      }
      return type

    case "Never":
      let type = MetatypeType(of: .never)
      if arguments.count > 0 {
        diagnostics.insert(.error(argumentToNonGenericType: type.instance, at: name.site))
        return nil
      }
      return type

    case "Void":
      let type = MetatypeType(of: .void)
      if arguments.count > 0 {
        diagnostics.insert(.error(argumentToNonGenericType: type.instance, at: name.site))
        return nil
      }
      return type

    case "Self":
      guard let type = realizeSelfTypeExpr(in: scope) else {
        diagnostics.insert(.error(invalidReferenceToSelfTypeAt: name.site))
        return nil
      }
      if arguments.count > 0 {
        diagnostics.insert(.error(argumentToNonGenericType: type.instance, at: name.site))
        return nil
      }
      return type

    case "Metatype":
      if arguments.count != 1 {
        diagnostics.insert(.error(metatypeRequiresOneArgumentAt: name.site))
      }
      if case .type(let a) = arguments.first!.value {
        return MetatypeType(of: MetatypeType(of: a))
      } else {
        fatalError("not implemented")
      }

    case "Builtin" where isBuiltinModuleVisible:
      let type = MetatypeType(of: .builtin(.module))
      if arguments.count > 0 {
        diagnostics.insert(.error(argumentToNonGenericType: type.instance, at: name.site))
        return nil
      }
      return type

    default:
      diagnostics.insert(.error(noType: name.value, in: nil, at: name.site))
      return nil
    }
  }

  /// Returns the type of a sum type expression with the given arguments.
  ///
  /// - Requires: `sumTypeExpr` is a sum type expression.
  private mutating func realizeSumTypeExpr(
    _ sumTypeExpr: NodeID<NameExpr>,
    in scope: AnyScopeID
  ) -> MetatypeType? {
    precondition(program.ast[sumTypeExpr].name.value.stem == "Sum")

    var elements = SumType.Elements()
    for a in program.ast[sumTypeExpr].arguments {
      guard let type = realize(a.value, in: scope)?.instance else {
        diagnostics.insert(.error(valueInSumTypeAt: program.ast[a.value].site))
        return nil
      }
      elements.insert(type)
    }

    switch elements.count {
    case 0:
      diagnostics.insert(.warning(sumTypeWithZeroElementsAt: program.ast[sumTypeExpr].name.site))
      return MetatypeType(of: .never)

    case 1:
      diagnostics.insert(.error(sumTypeWithOneElementAt: program.ast[sumTypeExpr].name.site))
      return nil

    default:
      return MetatypeType(of: SumType(elements))
    }
  }

  /// Realizes and returns the type of the `Self` expression in `scope`.
  ///
  /// - Note: This method does not issue diagnostics.
  private mutating func realizeSelfTypeExpr<T: ScopeID>(in scope: T) -> MetatypeType? {
    for scope in program.scopes(from: scope) {
      switch scope.kind {
      case TraitDecl.self:
        let decl = NodeID<TraitDecl>(scope)!
        return MetatypeType(of: GenericTypeParameterType(selfParameterOf: decl, in: program.ast))

      case ProductTypeDecl.self:
        // Synthesize unparameterized `Self`.
        let decl = NodeID<ProductTypeDecl>(scope)!
        let unparameterized = ProductType(decl, ast: program.ast)

        // Synthesize arguments to generic parameters if necessary.
        if let parameters = program.ast[decl].genericClause?.value.parameters {
          let arguments = parameters.map({ (p) -> BoundGenericType.Argument in
            .type(^GenericTypeParameterType(p, ast: program.ast))
          })
          return MetatypeType(of: BoundGenericType(unparameterized, arguments: arguments))
        } else {
          return MetatypeType(of: unparameterized)
        }

      case ConformanceDecl.self:
        let decl = NodeID<ConformanceDecl>(scope)!
        return realize(program.ast[decl].subject, in: scope)

      case ExtensionDecl.self:
        let decl = NodeID<ConformanceDecl>(scope)!
        return realize(program.ast[decl].subject, in: scope)

      case TypeAliasDecl.self:
        fatalError("not implemented")

      default:
        continue
      }
    }

    return nil
  }

  private mutating func realize(
    conformanceLens id: NodeID<ConformanceLensTypeExpr>,
    in scope: AnyScopeID
  ) -> MetatypeType? {
    let node = program.ast[id]

    /// The lens must be a trait.
    guard let lens = realize(node.lens, in: scope)?.instance else { return nil }
    guard let lensTrait = lens.base as? TraitType else {
      diagnostics.insert(.error(notATrait: lens, at: program.ast[node.lens].site))
      return nil
    }

    // The subject must conform to the lens.
    guard let subject = realize(node.subject, in: scope)?.instance else { return nil }
    guard let traits = conformedTraits(of: subject, in: scope),
      traits.contains(lensTrait)
    else {
      diagnostics.insert(
        .error(subject, doesNotConformTo: lensTrait, at: program.ast[node.lens].site))
      return nil
    }

    return MetatypeType(of: ConformanceLensType(viewing: subject, through: lensTrait))
  }

  private mutating func realize(
    lambda id: NodeID<LambdaTypeExpr>,
    in scope: AnyScopeID
  ) -> MetatypeType? {
    let node = program.ast[id]

    // Realize the lambda's environment.
    let environment: AnyType
    if let environmentExpr = node.environment {
      guard let ty = realize(environmentExpr, in: scope) else { return nil }
      environment = ty.instance
    } else {
      environment = .any
    }

    // Realize the lambda's parameters.
    var inputs: [CallableTypeParameter] = []
    inputs.reserveCapacity(node.parameters.count)

    for p in node.parameters {
      guard let ty = realize(parameter: p.type, in: scope)?.instance else { return nil }
      inputs.append(.init(label: p.label?.value, type: ty))
    }

    // Realize the lambda's output.
    guard let output = realize(node.output, in: scope)?.instance else { return nil }

    return MetatypeType(
      of: LambdaType(
        receiverEffect: node.receiverEffect?.value,
        environment: environment,
        inputs: inputs,
        output: output))
  }

  private mutating func realize(
    name id: NodeID<NameExpr>,
    in scope: AnyScopeID
  ) -> MetatypeType? {
    let name = program.ast[id].name
    let domain: AnyType?
    let matches: DeclSet

    // Realize the name's domain, if any.
    switch program.ast[id].domain {
    case .none:
      // Name expression has no domain.
      domain = nil

      // Search for the referred type declaration with an unqualified lookup.
      matches = lookup(unqualified: name.value.stem, in: scope)

      // If there are no matches, check for magic symbols.
      if matches.isEmpty {
        return realizeMagicTypeExpr(id, in: scope)
      }

    case .expr(let j):
      // The domain is a type expression.
      guard let d = realize(j, in: scope)?.instance else { return nil }
      domain = d

      // Handle references to built-in types.
      if relations.areEquivalent(d, .builtin(.module)) {
        if let type = BuiltinType(name.value.stem) {
          return MetatypeType(of: .builtin(type))
        } else {
          diagnostics.insert(.error(noType: name.value, in: domain, at: name.site))
          return nil
        }
      }

      // Search for the referred type declaration with a qualified lookup.
      matches = lookup(name.value.stem, memberOf: d, in: scope)

    case .implicit:
      diagnostics.insert(
        .error(notEnoughContextToResolveMember: name.value, at: name.site))
      return nil
    }

    // Diagnose unresolved names.
    guard let match = matches.first else {
      diagnostics.insert(.error(noType: name.value, in: domain, at: name.site))
      return nil
    }

    // Diagnose ambiguous references.
    if matches.count > 1 {
      diagnostics.insert(.error(ambiguousUse: id, in: program.ast))
      return nil
    }

    // Realize the referred type.
    let referredType: MetatypeType

    if match.kind == AssociatedTypeDecl.self {
      let decl = NodeID<AssociatedTypeDecl>(match)!

      switch domain?.base {
      case is AssociatedTypeType,
        is ConformanceLensType,
        is GenericTypeParameterType:
        referredType = MetatypeType(
          of: AssociatedTypeType(decl, domain: domain!, ast: program.ast))

      case nil:
        // Assume that `Self` in `scope` resolves to an implicit generic parameter of a trait
        // declaration, since associated declarations cannot be looked up unqualified outside
        // the scope of a trait and its extensions.
        let domain = realizeSelfTypeExpr(in: scope)!.instance
        let instance = AssociatedTypeType(NodeID(match)!, domain: domain, ast: program.ast)
        referredType = MetatypeType(of: instance)

      case .some:
        diagnostics.insert(
          .error(
            invalidUseOfAssociatedType: program.ast[decl].baseName,
            at: name.site))
        return nil
      }
    } else {
      let declType = realize(decl: match)
      if let instance = declType.base as? MetatypeType {
        referredType = instance
      } else {
        diagnostics.insert(.error(nameRefersToValue: id, in: program.ast))
        return nil
      }
    }

    // Evaluate the arguments of the referred type, if any.
    if program.ast[id].arguments.isEmpty {
      return referredType
    } else {
      var arguments: [BoundGenericType.Argument] = []

      for a in program.ast[id].arguments {
        // TODO: Symbolic execution
        guard let type = realize(a.value, in: scope)?.instance else { return nil }
        arguments.append(.type(type))
      }

      return MetatypeType(of: BoundGenericType(referredType.instance, arguments: arguments))
    }
  }

  private mutating func realize(
    parameter id: NodeID<ParameterTypeExpr>,
    in scope: AnyScopeID
  ) -> MetatypeType? {
    let node = program.ast[id]

    guard let bareType = realize(node.bareType, in: scope)?.instance else { return nil }
    return MetatypeType(of: ParameterType(convention: node.convention.value, bareType: bareType))
  }

  private mutating func realize(
    tuple id: NodeID<TupleTypeExpr>,
    in scope: AnyScopeID
  ) -> MetatypeType? {
    var elements: [TupleType.Element] = []
    elements.reserveCapacity(program.ast[id].elements.count)

    for e in program.ast[id].elements {
      guard let ty = realize(e.type, in: scope)?.instance else { return nil }
      elements.append(.init(label: e.label?.value, type: ty))
    }

    return MetatypeType(of: TupleType(elements))
  }

  /// Realizes and returns the traits of the specified conformance list, or `nil` if at least one
  /// of them is ill-typed.
  private mutating func realize(
    conformances: [NodeID<NameExpr>],
    in scope: AnyScopeID
  ) -> Set<TraitType>? {
    // Realize the traits in the conformance list.
    var traits: Set<TraitType> = []
    for expr in conformances {
      guard let rhs = realize(name: expr, in: scope)?.instance else { return nil }
      if let trait = rhs.base as? TraitType {
        traits.insert(trait)
      } else {
        diagnostics.insert(.error(conformanceToNonTraitType: rhs, at: program.ast[expr].site))
        return nil
      }
    }

    return traits
  }

  /// Returns the overarching type of the specified declaration.
  mutating func realize<T: DeclID>(decl id: T) -> AnyType {
    switch id.kind {
    case AssociatedTypeDecl.self:
      return _realize(
        decl: id,
        { (this, id) in
          // Parent scope must be a trait declaration.
          let traitDecl = NodeID<TraitDecl>(this.program.declToScope[id]!)!

          let instance = AssociatedTypeType(
            NodeID(id)!,
            domain: ^GenericTypeParameterType(selfParameterOf: traitDecl, in: this.program.ast),
            ast: this.program.ast)
          return ^MetatypeType(of: instance)
        })

    case AssociatedValueDecl.self:
      return _realize(
        decl: id,
        { (this, id) in
          // Parent scope must be a trait declaration.
          let traitDecl = NodeID<TraitDecl>(this.program.declToScope[id]!)!

          let instance = AssociatedValueType(
            NodeID(id)!,
            domain: ^GenericTypeParameterType(selfParameterOf: traitDecl, in: this.program.ast),
            ast: this.program.ast)
          return ^MetatypeType(of: instance)
        })

    case GenericParameterDecl.self:
      return realize(genericParameterDecl: NodeID(id)!)

    case BindingDecl.self:
      return realize(bindingDecl: NodeID(id)!)

    case ConformanceDecl.self, ExtensionDecl.self:
      return _realize(
        decl: id,
        { (this, id) in
          let decl = this.program.ast[id] as! TypeExtendingDecl
          let type = this.realize(decl.subject, in: this.program.declToScope[id]!)
          return type.flatMap(AnyType.init(_:))
        })

    case FunctionDecl.self:
      return realize(functionDecl: NodeID(id)!)

    case InitializerDecl.self:
      return realize(initializerDecl: NodeID(id)!)

    case MethodDecl.self:
      return realize(methodDecl: NodeID(id)!)

    case MethodImpl.self:
      return realize(methodDecl: NodeID(program.declToScope[id]!)!)

    case ParameterDecl.self:
      return realize(parameterDecl: NodeID(id)!)

    case ProductTypeDecl.self:
      return _realize(
        decl: id,
        { (this, id) in
          let instance = ProductType(NodeID(id)!, ast: this.program.ast)
          return ^MetatypeType(of: instance)
        })

    case SubscriptDecl.self:
      return realize(subscriptDecl: NodeID(id)!)

    case TraitDecl.self:
      return _realize(
        decl: id,
        { (this, id) in
          let instance = TraitType(NodeID(id)!, ast: this.program.ast)
          return ^MetatypeType(of: instance)
        })

    case TypeAliasDecl.self:
      return realize(typeAliasDecl: NodeID(id)!)

    case VarDecl.self:
      let bindingDecl = program.varToBinding[NodeID(id)!]!
      let bindingType = realize(bindingDecl: bindingDecl)
      return bindingType.isError
        ? bindingType
        : declTypes[id]!

    default:
      unexpected(id, in: program.ast)
    }
  }

  private mutating func realize(bindingDecl id: NodeID<BindingDecl>) -> AnyType {
    _ = check(binding: NodeID(id)!)
    return declTypes[id]!
  }

  private mutating func realize(functionDecl id: NodeID<FunctionDecl>) -> AnyType {
    _realize(decl: id, { (this, id) in this._realize(functionDecl: id) })
  }

  private mutating func _realize(functionDecl id: NodeID<FunctionDecl>) -> AnyType {
    var success = true

    // Realize the input types.
    var inputs: [CallableTypeParameter] = []
    for i in program.ast[id].parameters {
      declRequests[i] = .typeCheckingStarted

      if let annotation = program.ast[i].annotation {
        if let type = realize(parameter: annotation, in: AnyScopeID(id))?.instance {
          // The annotation may not omit generic arguments.
          if type[.hasVariable] {
            diagnostics.insert(
              .error(
                notEnoughContextToInferArgumentsAt: program.ast[annotation].site))
            success = false
          }

          declTypes[i] = type
          declRequests[i] = .typeRealizationCompleted
          inputs.append(CallableTypeParameter(label: program.ast[i].label?.value, type: type))
        } else {
          declTypes[i] = .error
          declRequests[i] = .failure
          success = false
        }
      } else {
        // Note: parameter type annotations may be elided if the declaration represents a lambda
        // expression. In that case, the unannotated parameters are associated with a fresh type
        // so inference can proceed. The actual type of the parameter will be reified during type
        // checking, when `checkPending` is called.
        if program.ast[id].isInExprContext {
          let parameterType = ^TypeVariable(node: AnyNodeID(i))
          declTypes[i] = parameterType
          declRequests[i] = .typeRealizationCompleted
          inputs.append(
            CallableTypeParameter(
              label: program.ast[i].label?.value,
              type: parameterType))
        } else {
          unreachable("expected type annotation")
        }
      }
    }

    // Bail out if the parameters could not be realized.
    if !success { return .error }

    // Collect captures.
    var explicitCaptureNames: Set<Name> = []
    guard
      let explicitCaptureTypes = realize(
        explicitCaptures: program.ast[id].explicitCaptures,
        collectingNamesIn: &explicitCaptureNames)
    else { return .error }

    let implicitCaptures: [ImplicitCapture] =
      program.isLocal(id)
      ? realize(implicitCapturesIn: id, ignoring: explicitCaptureNames)
      : []
    self.implicitCaptures[id] = implicitCaptures

    // Realize the function's receiver if necessary.
    let isNonStaticMember = program.isNonStaticMember(id)
    var receiver: AnyType? =
      isNonStaticMember
      ? realizeSelfTypeExpr(in: program.declToScope[id]!)!.instance
      : nil

    // Realize the output type.
    let outputType: AnyType
    if let o = program.ast[id].output {
      // Use the explicit return annotation.
      guard let type = realize(o, in: AnyScopeID(id))?.instance else { return .error }
      outputType = type
    } else if program.ast[id].isInExprContext {
      // Infer the return type from the body in expression contexts.
      outputType = ^TypeVariable()
    } else {
      // Default to `Void`.
      outputType = .void
    }

    if isNonStaticMember {
      // Create a lambda bound to a receiver.
      let effect: AccessEffect?
      if program.ast[id].isInout {
        receiver = ^TupleType([.init(label: "self", type: ^RemoteType(.inout, receiver!))])
        effect = .inout
      } else if program.ast[id].isSink {
        receiver = ^TupleType([.init(label: "self", type: receiver!)])
        effect = .sink
      } else {
        receiver = ^TupleType([.init(label: "self", type: ^RemoteType(.let, receiver!))])
        effect = nil
      }

      return ^LambdaType(
        receiverEffect: effect,
        environment: receiver!,
        inputs: inputs,
        output: outputType)
    } else {
      // Create a regular lambda.
      let environment = TupleType(
        explicitCaptureTypes.map({ (t) -> TupleType.Element in
          .init(label: nil, type: t)
        })
          + implicitCaptures.map({ (c) -> TupleType.Element in
            .init(label: nil, type: ^c.type)
          }))

      // TODO: Determine if the lambda is mutating.

      return ^LambdaType(environment: ^environment, inputs: inputs, output: outputType)
    }
  }

  public mutating func realize(
    genericParameterDecl id: NodeID<GenericParameterDecl>
  ) -> AnyType {
    _realize(decl: id, { (this, id) in this._realize(genericParameterDecl: id) })
  }

  private mutating func _realize(
    genericParameterDecl id: NodeID<GenericParameterDecl>
  ) -> AnyType {
    // The declaration introduces a generic *type* parameter the first annotation refers to a
    // trait. Otherwise, it denotes a generic *value* parameter.
    if let annotation = program.ast[id].conformances.first {
      // Bail out if we can't evaluate the annotation.
      guard let type = realize(name: annotation, in: program.declToScope[id]!) else {
        return .error
      }

      if !(type.instance.base is TraitType) {
        // Value parameters shall not have more than one type annotation.
        if program.ast[id].conformances.count > 1 {
          let diagnosticOrigin = program.ast[program.ast[id].conformances[1]].site
          diagnostics.insert(
            .error(tooManyAnnotationsOnGenericValueParametersAt: diagnosticOrigin))
          return .error
        }

        // The declaration introduces a generic value parameter.
        return type.instance
      }
    }

    // If the declaration has no annotations or its first annotation does not refer to a trait,
    // assume it declares a generic type parameter.
    let instance = GenericTypeParameterType(id, ast: program.ast)
    return ^MetatypeType(of: instance)
  }

  private mutating func realize(initializerDecl id: NodeID<InitializerDecl>) -> AnyType {
    _realize(decl: id, { (this, id) in this._realize(initializerDecl: id) })
  }

  private mutating func _realize(initializerDecl id: NodeID<InitializerDecl>) -> AnyType {
    // Handle memberwise initializers.
    if program.ast[id].introducer.value == .memberwiseInit {
      let productTypeDecl = NodeID<ProductTypeDecl>(program.declToScope[id]!)!
      if let lambda = memberwiseInitType(of: productTypeDecl) {
        return ^lambda
      } else {
        return .error
      }
    }

    var success = true

    // Realize the input types.
    var inputs: [CallableTypeParameter] = []
    for i in program.ast[id].parameters {
      declRequests[i] = .typeCheckingStarted

      // Parameters of initializers must have a type annotation.
      guard let annotation = program.ast[i].annotation else {
        unexpected(i, in: program.ast)
      }

      if let type = realize(parameter: annotation, in: AnyScopeID(id))?.instance {
        // The annotation may not omit generic arguments.
        if type[.hasVariable] {
          diagnostics.insert(
            .error(notEnoughContextToInferArgumentsAt: program.ast[annotation].site))
          success = false
        }

        declTypes[i] = type
        declRequests[i] = .typeRealizationCompleted
        inputs.append(CallableTypeParameter(label: program.ast[i].label?.value, type: type))
      } else {
        declTypes[i] = .error
        declRequests[i] = .failure
        success = false
      }
    }

    // Bail out if the parameters could not be realized.
    if !success { return .error }

    // Initializers are global functions.
    let receiverType = realizeSelfTypeExpr(in: program.declToScope[id]!)!.instance
    let receiverParameterType = CallableTypeParameter(
      label: "self",
      type: ^ParameterType(convention: .set, bareType: receiverType))
    inputs.insert(receiverParameterType, at: 0)
    return ^LambdaType(environment: .void, inputs: inputs, output: .void)
  }

  private mutating func realize(methodDecl id: NodeID<MethodDecl>) -> AnyType {
    _realize(decl: id, { (this, id) in this._realize(methodDecl: id) })
  }

  private mutating func _realize(methodDecl id: NodeID<MethodDecl>) -> AnyType {
    var success = true

    // Realize the input types.
    var inputs: [CallableTypeParameter] = []
    for i in program.ast[id].parameters {
      declRequests[i] = .typeCheckingStarted

      // Parameters of methods must have a type annotation.
      guard let annotation = program.ast[i].annotation else {
        unexpected(i, in: program.ast)
      }

      if let type = realize(parameter: annotation, in: AnyScopeID(id))?.instance {
        // The annotation may not omit generic arguments.
        if type[.hasVariable] {
          diagnostics.insert(
            .error(notEnoughContextToInferArgumentsAt: program.ast[annotation].site))
          success = false
        }

        declTypes[i] = type
        declRequests[i] = .typeRealizationCompleted
        inputs.append(.init(label: program.ast[i].label?.value, type: type))
      } else {
        declTypes[i] = .error
        declRequests[i] = .failure
        success = false
      }
    }

    // Bail out if the parameters could not be realized.
    if !success { return .error }

    // Realize the method's receiver if necessary.
    let receiver = realizeSelfTypeExpr(in: program.declToScope[id]!)!.instance

    // Realize the output type.
    let outputType: AnyType
    if let o = program.ast[id].output {
      // Use the explicit return annotation.
      guard let type = realize(o, in: AnyScopeID(id))?.instance else { return .error }
      outputType = type
    } else {
      // Default to `Void`.
      outputType = .void
    }

    // Create a method bundle.
    let capabilities = Set(program.ast[id].impls.map({ program.ast[$0].introducer.value }))
    if capabilities.contains(.inout) && (outputType != receiver) {
      let range =
        program.ast[id].output.map({ (output) in
          program.ast[output].site
        }) ?? program.ast[id].introducerSite
      diagnostics.insert(.error(inoutCapableMethodBundleMustReturn: receiver, at: range))
      return .error
    }

    return ^MethodType(
      capabilities: capabilities,
      receiver: receiver,
      inputs: inputs,
      output: outputType)
  }

  /// Returns the overarching type of the specified parameter declaration.
  ///
  /// - Requires: The containing function or subscript declaration must have been realized.
  private mutating func realize(parameterDecl id: NodeID<ParameterDecl>) -> AnyType {
    switch declRequests[id] {
    case nil:
      preconditionFailure()

    case .typeRealizationStarted:
      diagnostics.insert(.error(circularDependencyAt: program.ast[id].site))
      return .error

    case .typeRealizationCompleted, .typeCheckingStarted, .success, .failure:
      return declTypes[id]!
    }
  }

  private mutating func realize(subscriptDecl id: NodeID<SubscriptDecl>) -> AnyType {
    _realize(decl: id, { (this, id) in this._realize(subscriptDecl: id) })
  }

  private mutating func _realize(subscriptDecl id: NodeID<SubscriptDecl>) -> AnyType {
    var success = true

    // Realize the input types.
    var inputs: [CallableTypeParameter] = []
    for i in program.ast[id].parameters ?? [] {
      declRequests[i] = .typeCheckingStarted

      // Parameters of subscripts must have a type annotation.
      guard let annotation = program.ast[i].annotation else {
        unexpected(i, in: program.ast)
      }

      if let type = realize(parameter: annotation, in: AnyScopeID(id))?.instance {
        // The annotation may not omit generic arguments.
        if type[.hasVariable] {
          diagnostics.insert(
            .error(notEnoughContextToInferArgumentsAt: program.ast[annotation].site))
          success = false
        }

        declTypes[i] = type
        declRequests[i] = .typeRealizationCompleted
        inputs.append(CallableTypeParameter(label: program.ast[i].label?.value, type: type))
      } else {
        declTypes[i] = .error
        declRequests[i] = .failure
        success = false
      }
    }

    // Bail out if the parameters could not be realized.
    if !success { return .error }

    // Collect captures.
    var explicitCaptureNames: Set<Name> = []
    guard
      let explicitCaptureTypes = realize(
        explicitCaptures: program.ast[id].explicitCaptures,
        collectingNamesIn: &explicitCaptureNames)
    else { return .error }

    let implicitCaptures: [ImplicitCapture] =
      program.isLocal(id)
      ? realize(implicitCapturesIn: id, ignoring: explicitCaptureNames)
      : []
    self.implicitCaptures[id] = implicitCaptures

    // Build the subscript's environment.
    let environment: TupleType
    if program.isNonStaticMember(id) {
      let receiver = realizeSelfTypeExpr(in: program.declToScope[id]!)!.instance
      environment = TupleType([.init(label: "self", type: ^RemoteType(.yielded, receiver))])
    } else {
      environment = TupleType(
        explicitCaptureTypes.map({ (t) -> TupleType.Element in
          .init(label: nil, type: t)
        })
          + implicitCaptures.map({ (c) -> TupleType.Element in
            .init(label: nil, type: ^c.type)
          }))
    }

    // Realize the ouput type.
    guard let output = realize(program.ast[id].output, in: AnyScopeID(id))?.instance else {
      return .error
    }

    // Create a subscript type.
    let capabilities = Set(program.ast[id].impls.map({ program.ast[$0].introducer.value }))
    return ^SubscriptType(
      isProperty: program.ast[id].parameters == nil,
      capabilities: capabilities,
      environment: ^environment,
      inputs: inputs,
      output: output)
  }

  private mutating func realize(typeAliasDecl d: NodeID<TypeAliasDecl>) -> AnyType {
    _realize(decl: d, { (this, id) in this._realize(typeAliasDecl: d) })
  }

  private mutating func _realize(typeAliasDecl d: NodeID<TypeAliasDecl>) -> AnyType {
    guard let resolved = realize(program.ast[d].aliasedType, in: AnyScopeID(d))?.instance else {
      return .error
    }

    let instance = TypeAliasType(aliasing: resolved, declaredBy: NodeID(d)!, in: program.ast)
    return ^MetatypeType(of: instance)
  }

  /// Realizes the explicit captures in `list`, writing the captured names in `explicitNames`, and
  /// returns their types if they are semantically well-typed. Otherwise, returns `nil`.
  private mutating func realize(
    explicitCaptures list: [NodeID<BindingDecl>],
    collectingNamesIn explictNames: inout Set<Name>
  ) -> [AnyType]? {
    var explictNames: Set<Name> = []
    var captures: [AnyType] = []
    var success = true

    // Process explicit captures.
    for i in list {
      // Collect the names of the capture.
      for (_, namePattern) in program.ast.names(in: program.ast[i].pattern) {
        let varDecl = program.ast[namePattern].decl
        if !explictNames.insert(Name(stem: program.ast[varDecl].baseName)).inserted {
          diagnostics.insert(
            .error(
              duplicateCaptureNamed: program.ast[varDecl].baseName,
              at: program.ast[varDecl].site))
          success = false
        }
      }

      // Realize the type of the capture.
      let type = realize(bindingDecl: i)
      if type.isError {
        success = false
      } else {
        switch program.ast[program.ast[i].pattern].introducer.value {
        case .let:
          captures.append(^RemoteType(.let, type))
        case .inout:
          captures.append(^RemoteType(.inout, type))
        case .sinklet, .var:
          captures.append(type)
        }
      }
    }

    return success ? captures : nil
  }

  /// Realizes the implicit captures found in the body of `decl` and returns their types and
  /// declarations if they are well-typed. Otherwise, returns `nil`.
  private mutating func realize<T: Decl & LexicalScope>(
    implicitCapturesIn decl: NodeID<T>,
    ignoring explictNames: Set<Name>
  ) -> [ImplicitCapture] {
    // Process implicit captures.
    var captures: [ImplicitCapture] = []
    var receiverIndex: Int? = nil

    var collector = CaptureCollector(ast: program.ast)
    for (name, uses) in collector.freeNames(in: decl) {
      // Explicit captures are already accounted for.
      if explictNames.contains(name) { continue }

      // Resolve the name.
      let matches = lookup(unqualified: name.stem, in: program.declToScope[decl]!)

      // If there are multiple matches, attempt to filter them using the name's argument labels or
      // operator notation. If that fails, complain about an ambiguous implicit capture.
      let captureDecl: AnyDeclID
      switch matches.count {
      case 0:
        continue
      case 1:
        captureDecl = matches.first!
      default:
        fatalError("not implemented")
      }

      // Global declarations are not captured.
      if program.isGlobal(captureDecl) { continue }

      // References to member declarations implicitly capture of their receiver.
      if program.isMember(captureDecl) {
        // If the function refers to a member declaration, it must be nested in a type scope.
        let innermostTypeScope =
          program
          .scopes(from: program.scopeToParent[decl]!)
          .first(where: { $0.kind.value is TypeScope.Type })!

        // Ignore illegal implicit references to foreign receiver.
        if program.isContained(innermostTypeScope, in: program.scopeToParent[captureDecl]!) {
          continue
        }

        if let i = receiverIndex, uses.capability != .let {
          // Update the mutability of the capture.
          captures[i] = ImplicitCapture(
            name: captures[i].name,
            type: RemoteType(.inout, captures[i].type.base),
            decl: captures[i].decl)
        } else {
          // Resolve the implicit reference to `self`.
          let receiverMatches = lookup(unqualified: "self", in: program.scopeToParent[decl]!)
          let receiverDecl: AnyDeclID
          switch receiverMatches.count {
          case 0:
            continue
          case 1:
            receiverDecl = matches.first!
          default:
            unreachable()
          }

          // Realize the type of `self`.
          let receiverType = realize(decl: receiverDecl)
          if receiverType.isError { continue }

          // Register the capture of `self`.
          receiverIndex = captures.count
          captures.append(
            ImplicitCapture(
              name: Name(stem: "self"),
              type: RemoteType(uses.capability, receiverType.skolemized),
              decl: receiverDecl))
        }

        continue
      }

      // Capture-less local functions are not captured.
      if let d = NodeID<FunctionDecl>(captureDecl) {
        guard let lambda = realize(functionDecl: d).base as? LambdaType else { continue }
        if relations.areEquivalent(lambda.environment, .void) { continue }
      }

      // Other local declarations are captured.
      let captureType = realize(decl: captureDecl).skolemized
      if captureType.isError { continue }
      captures.append(
        ImplicitCapture(
          name: name,
          type: RemoteType(uses.capability, captureType),
          decl: captureDecl))
    }

    return captures
  }

  /// Returns the type of `decl` from the cache, or calls `action` to compute it and caches the
  /// result before returning it.
  private mutating func _realize<T: DeclID>(
    decl id: T,
    _ action: (inout Self, T) -> AnyType?
  ) -> AnyType {
    // Check if a type realization request has already been received.
    switch declRequests[id] {
    case nil:
      declRequests[id] = .typeRealizationStarted

    case .typeRealizationStarted:
      diagnostics.insert(.error(circularDependencyAt: program.ast[id].site))
      declRequests[id] = .failure
      declTypes[id] = .error
      return declTypes[id]!

    case .typeRealizationCompleted, .typeCheckingStarted, .success, .failure:
      return declTypes[id]!
    }

    // Process the request.
    declTypes[id] = action(&self, id)

    // Update the request status.
    declRequests[id] = .typeRealizationCompleted
    return declTypes[id]!
  }

  /// Returns the type of `decl`'s memberwise initializer.
  private mutating func memberwiseInitType(of decl: NodeID<ProductTypeDecl>) -> LambdaType? {
    var inputs: [CallableTypeParameter] = []

    // Synthesize the receiver type.
    let receiver = realizeSelfTypeExpr(in: decl)!.instance
    inputs.append(
      CallableTypeParameter(
        label: "self",
        type: ^ParameterType(convention: .set, bareType: receiver)))

    // List and realize the type of all stored bindings.
    for m in program.ast[decl].members {
      guard let member = NodeID<BindingDecl>(m) else { continue }
      if realize(bindingDecl: member).isError { return nil }

      for (_, name) in program.ast.names(in: program.ast[member].pattern) {
        let d = program.ast[name].decl
        inputs.append(
          CallableTypeParameter(
            label: program.ast[d].baseName,
            type: ^ParameterType(convention: .sink, bareType: declTypes[d]!)))
      }
    }

    return LambdaType(environment: .void, inputs: inputs, output: .void)
  }

  // MARK: Type role determination

  /// Replaces occurrences of associated types and generic type parameters in `type` by fresh
  /// type variables variables.
  func open(type: AnyType) -> InstantiatedType {
    /// A map from generic parameter type to its opened type.
    var openedParameters: [AnyType: AnyType] = [:]

    func _impl(type: AnyType) -> TypeTransformAction {
      switch type.base {
      case is AssociatedTypeType:
        fatalError("not implemented")

      case is GenericTypeParameterType:
        if let opened = openedParameters[type] {
          // The parameter was already opened.
          return .stepOver(opened)
        } else {
          // Open the parameter.
          let opened = ^TypeVariable()
          openedParameters[type] = opened

          // TODO: Collect constraints

          return .stepOver(opened)
        }

      default:
        // Nothing to do if `type` isn't parameterized.
        if type[.hasGenericTypeParameter] || type[.hasGenericValueParameter] {
          return .stepInto(type)
        } else {
          return .stepOver(type)
        }
      }
    }

    return InstantiatedType(shape: type.transform(_impl(type:)), constraints: [])
  }

  /// Replaces the generic parameters in `subject` by skolems or fresh variables depending on the
  /// whether their declaration is contained in `scope`.
  func instantiate<S: ScopeID>(
    _ subject: AnyType,
    in scope: S,
    cause: ConstraintCause
  ) -> InstantiatedType {
    /// A map from generic parameter type to its opened type.
    var openedParameters: [AnyType: AnyType] = [:]

    func _impl(type: AnyType) -> TypeTransformAction {
      switch type.base {
      case is AssociatedTypeType:
        fatalError("not implemented")

      case let base as GenericTypeParameterType:
        // Identify the generic environment that introduces the parameter.
        let site: AnyScopeID
        if base.decl.kind == TraitDecl.self {
          site = AnyScopeID(base.decl)!
        } else {
          site = program.declToScope[base.decl]!
        }

        if program.isContained(scope, in: site) {
          // Skolemize.
          return .stepOver(^SkolemType(quantifying: type))
        } else if let opened = openedParameters[type] {
          // The parameter was already opened.
          return .stepOver(opened)
        } else {
          // Open the parameter.
          let opened = ^TypeVariable()
          openedParameters[type] = opened

          // TODO: Collect constraints

          return .stepOver(opened)
        }

      default:
        // Nothing to do if `type` isn't parameterized.
        if type[.hasGenericTypeParameter] || type[.hasGenericValueParameter] {
          return .stepInto(type)
        } else {
          return .stepOver(type)
        }
      }
    }

    return InstantiatedType(shape: subject.transform(_impl(type:)), constraints: [])
  }

  // MARK: Utils

  /// Returns whether `decl` is a nominal type declaration.
  mutating func isNominalTypeDecl(_ decl: AnyDeclID) -> Bool {
    switch decl.kind {
    case AssociatedTypeDecl.self, ProductTypeDecl.self, TypeAliasDecl.self:
      return true

    case GenericParameterDecl.self:
      return realize(genericParameterDecl: NodeID(decl)!).base is MetatypeType

    default:
      return false
    }
  }

  /// Resets `self` to an empty state, returning `self`'s old value.
  mutating func release() -> Self {
    var r: Self = .init(program: program)
    swap(&r, &self)
    return r
  }

  /// Returns `d` if it has name `n`, otherwise the implementation of `d` with name `n` or `nil`
  /// if no such implementation exists.
  ///
  /// - Requires: The base name of `d` is equal to `n.stem`
  mutating func decl(in d: AnyDeclID, named n: Name) -> AnyDeclID? {
    if !n.labels.isEmpty && (n.labels != labels(d)) {
      return nil
    }

    if let x = n.notation, x != operatorNotation(d) {
      return nil
    }

    // If the looked up name has an introducer, return the corresponding implementation.
    if let introducer = n.introducer {
      guard let m = program.ast[NodeID<MethodDecl>(d)] else { return nil }
      return m.impls.first(where: { (i) in
        program.ast[i].introducer.value == introducer
      }).map(AnyDeclID.init(_:))
    }

    return d
  }

  /// Returns the labels of `d`s name.
  ///
  /// Only function, method, or subscript declarations may have labels. This method returns `[]`
  /// for any other declaration.
  private mutating func labels(_ d: AnyDeclID) -> [String?] {
    switch d.kind {
    case FunctionDecl.self:
      return program.ast[NodeID<FunctionDecl>(d)!]
        .parameters
        .map({ (p) in program.ast[p].label?.value })

    case InitializerDecl.self:
      return LambdaType(realize(initializerDecl: NodeID(d)!))
        .map({ (t) in t.inputs.map(\.label) }) ?? []

    case MethodDecl.self:
      return program.ast[NodeID<MethodDecl>(d)!]
        .parameters
        .map({ (p) in program.ast[p].label?.value })

    case SubscriptDecl.self:
      return program.ast[NodeID<SubscriptDecl>(d)!]
        .parameters
        .map({ (ps) in ps.map({ (p) in program.ast[p].label?.value }) }) ?? []

    default:
      return []
    }
  }

  /// Returns the operator notation of `d`'s name, if any.
  private func operatorNotation(_ d: AnyDeclID) -> OperatorNotation? {
    switch d.kind {
    case FunctionDecl.self:
      return program.ast[NodeID<FunctionDecl>(d)!].notation?.value

    case MethodDecl.self:
      return program.ast[NodeID<MethodDecl>(d)!].notation?.value

    default:
      return nil
    }
  }

}
