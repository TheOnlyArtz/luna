module Luna.Package.Dependency.System.Windows where

import Prologue



-----------------
-- === API === --
-----------------

acquireSystemDeps :: MonadIO m => [Text] -> m ()
acquireSystemDeps _ = pure ()

