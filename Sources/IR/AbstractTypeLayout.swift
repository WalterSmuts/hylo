import Core

/// The astract layout of a type, describing the relative offsets of its stored properties.
public struct AbstractTypeLayout {

  /// The name and type of a stored property.
  public typealias StoredProperty = (name: String?, type: AnyType)

  /// The program in which `type` is defined.
  private let program: TypedProgram

  /// The type of which this instance is the abstract layout.
  public let type: AnyType

  /// The stored properties in `type`, in the order in which they are laid out.
  public let properties: [StoredProperty]

  /// Creates the abstract layout of `t` defined in `p`.
  public init(of t: AnyType, definedIn p: TypedProgram) {
    self.program = p
    self.type = t
    self.properties = program.properties(of: t)
  }

  /// Accesses the layout of the stored property at given `offset`.
  ///
  /// - Requires: `offset` is a valid offset in this instance.
  public subscript(offset: Int) -> AbstractTypeLayout {
    AbstractTypeLayout(of: properties[offset].type, definedIn: program)
  }

  /// Accesses the layout of the stored property at given `offsets`.
  public subscript<S: Sequence>(offsets: S) -> AbstractTypeLayout where S.Element == Int {
    offsets.reduce(self, { (l, offset) in l[offset] })
  }

  /// Accesses the layout of the stored property named `n` or `nil` if no such property exists.
  public subscript(n: String) -> AbstractTypeLayout? {
    offset(of: n).map({ self[$0] })
  }

  /// Returns the offset of the stored poperty named `n` or `nil` if no such property exists.
  public func offset(of n: String) -> Int? {
    properties.firstIndex(where: { $0.name == n })
  }

}

extension TypedProgram {

  /// Returns the names and types of the stored properties of `t`.
  fileprivate func properties(of t: AnyType) -> [AbstractTypeLayout.StoredProperty] {
    switch t.base {
    case let p as ProductType:
      return self[p.decl].members.reduce(into: []) { (r, m) in
        if let b = BindingDecl.Typed(m) {
          r.append(contentsOf: b.pattern.names
            .map({ (_, name) in (name.decl.baseName, name.decl.type) }))
        }
      }

    default:
      return []
    }
  }

}
