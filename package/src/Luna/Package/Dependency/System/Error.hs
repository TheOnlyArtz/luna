{-# LANGUAGE UndecidableInstances #-}

module Luna.Package.Dependency.System.Error where

import Prologue

import GHC.TypeLits        as TypeLits
import Language.Haskell.TH as TH

class SystemError where
    systemError :: Q [Dec]

instance TypeError ('TypeLits.Text "Unsupported platform.") => SystemError where
    systemError = pure mempty

