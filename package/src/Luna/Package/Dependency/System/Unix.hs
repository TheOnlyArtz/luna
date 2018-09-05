module Luna.Package.Dependency.System.Unix where

import Prologue



-----------------
-- === API === --
-----------------

acquireSystemDeps :: MonadIO m => [Text] -> m ()
acquireSystemDeps _ = pure ()

