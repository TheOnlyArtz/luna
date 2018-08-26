{-# LANGUAGE Strict               #-}
{-# LANGUAGE UndecidableInstances #-}

module Luna.IR.Term.Ast.Invalid where

import Prologue hiding (Symbol)

import qualified Data.Generics.Traversable.Deriving as GTraversable
-- import qualified Data.Graph.Store.External          as ExternalStorable
import qualified Foreign.Storable.Deriving as Storable

-- import Data.Graph.Store.External (ExternalFieldStorable, ExternalStorable)


-----------------------------
-- === Invalid Symbols === --
-----------------------------

-- === Definition === --

data Symbol
    = ForeignImportSafety
    | FunctionHeader
    | FunctionBlock
    | UnexpectedSuffix {- len -} !Int
    | CaselessNameHead
    | Literal InvalidLiteral
    | InvalidMarker
    | InvalidFunctionName
    | InvalidFunctionArg
    | MissingColonBlock
    | InvalidFunctionDefinition
    | AdjacentOperators
    | Unknown
    | EmptyExpression
    | AssocConflict
    | NoAssoc
    | MissingRelation
    | MissingSection
    deriving (Eq, Ord, Generic, Show)
-- instance ExternalStorable Symbol
-- instance ExternalFieldStorable Symbol

data InvalidLiteral
    = String InvalidString
    deriving (Eq, Ord, Generic, Show)

data InvalidString
    = EscapeCode
    | NoClosingMark
    deriving (Eq, Ord, Generic, Show)

Storable.derive     ''Symbol
Storable.derive     ''InvalidLiteral
Storable.derive     ''InvalidString
GTraversable.derive ''Symbol
GTraversable.derive ''InvalidLiteral
GTraversable.derive ''InvalidString
instance NFData Symbol
instance NFData InvalidLiteral
instance NFData InvalidString



unexpectedSuffix :: Convertible' Symbol a => Int -> a
unexpectedSuffix = convert' . UnexpectedSuffix
{-# INLINE unexpectedSuffix #-}

adjacentOperators :: Convertible' Symbol a => a
adjacentOperators = convert' AdjacentOperators
{-# INLINE adjacentOperators #-}

assocConflict :: Convertible' Symbol a => a
assocConflict = convert' AssocConflict
{-# INLINE assocConflict #-}

noAssoc :: Convertible' Symbol a => a
noAssoc = convert' NoAssoc
{-# INLINE noAssoc #-}

missingRelation :: Convertible' Symbol a => a
missingRelation = convert' MissingRelation
{-# INLINE missingRelation #-}
