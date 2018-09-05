{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}

module Luna.Package.Dependency.System where

import Prologue

import qualified Luna.Package.Dependency.System.Error   as Error
import qualified Luna.Package.Dependency.System.Unix    as Unix
import qualified Luna.Package.Dependency.System.Windows as Windows



--------------------
-- === System === --
--------------------

-- === Definition === --

data System
    = Linux
    | MacOS
    | Windows
    deriving (Eq, Generic, Ord, Show)


-- === API === --

osType :: System
#ifdef linux_HOST_OS
osType = Linux
#elif  darwin_HOST_OS
osType = MacOS
#elif  mingw32_HOST_OS
osType = Windows
#else
Error.systemError
#endif



-- === Instances === --

instance Default System where
    def = Linux


-----------------
-- === API === --
-----------------

acquireSystemDeps :: MonadIO m => [Text] -> m ()
acquireSystemDeps = case osType of
    Linux   -> Unix.acquireSystemDeps
    MacOS   -> Unix.acquireSystemDeps
    Windows -> Windows.acquireSystemDeps

