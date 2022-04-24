/// A (nominal) product type declaration.
public struct ProductTypeDecl: GenericDecl, SingleEntityDecl, GenericScope {

  public static let kind = NodeKind.productTypeDecl

  /// The access modifier of the declaration, if any.
  public var access: SourceRepresentable<AccessModifier>?

  /// The identifier of the type.
  public var identifier: SourceRepresentable<Identifier>

  /// The generic clause of the declaration, if any.
  public var genericClause: SourceRepresentable<GenericClause>?

  /// The names of traits to which the type conforms.
  public var conformances: [NodeID<NameTypeExpr>]

  /// The member declarations in the lexical scope of the trait.
  public var members: [AnyDeclID]

  public var name: String { identifier.value }

  public init(
    access: SourceRepresentable<AccessModifier>? = nil,
    identifier: SourceRepresentable<Identifier>,
    genericClause: SourceRepresentable<GenericClause>? = nil,
    conformances: [NodeID<NameTypeExpr>] = [],
    members: [AnyDeclID] = []
  ) {
    self.access = access
    self.identifier = identifier
    self.genericClause = genericClause
    self.conformances = conformances
    self.members = members
  }

}