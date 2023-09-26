# Compiler Architecture

## Project Overview

The hylo compiler is written in [Swift] and uses [LLVM] as it's code generation
backend. It conforms to the the standard swift project layout:
* [Package.swift] the manifest file used by SPM
* [Sources] all the source code for the compiler
* [Tests] all the test code

Then there are some extra directories specific to the hylo project:
* [Tools] Scripts to aid in development
* [Examples] Some real world hylo programs
* [Library] The hylo standard (and core) library

## Stages of compilation

The hylo compiler goes through the standard stages of compilation:

1. Tokenisation: Transforms hylo source code (Strings) to stream of destinct
   tokens
1. Parsing: Creates an [abstract syntax tree] from the token stream
1. Type-checking: Inspects the abstract syntax tree for type errors
1. IR-lowering: Generates the [intermediate representation] from the abstract
   syntax tree
1. LLVM IR generation: Convert hylo IR into [LLVM] IR
1. Machine Code Generation: This is completely handled by [LLVM]

These top-level stages of the compiler are laid out in [Driver.swift] where you
can see the outline of the compilation phases with their entry points. 

### Interesting parts

Most of the compiler does what you'd expect from the compiltion stages above
but some are worth a deeper look:

#### Abstract syntax tree

The abstract syntax tree is made up of an append-only array that produces
`NodeID` objects as indices into the array. This allows nodes to refer to other
nodes using their `NodeID`.

#### Program Protocol

#### Hylo IR

[Swift]: https://en.wikipedia.org/wiki/Swift_(programming_language)
[LLVM]: https://en.wikipedia.org/wiki/LLVM
[SPM]: https://www.swift.org/package-manager/

[Driver.swift]: ../Sources/Driver/Driver.swift
[Package.swift]: ../Package.swift
[Sources]: ../Sources
[Tests]: ../Tests
[Tools]: ../Tools
[Examples]: ../Examples
[Library]: ../Library

[intermediate representation]: https://en.wikipedia.org/wiki/Intermediate_representation
